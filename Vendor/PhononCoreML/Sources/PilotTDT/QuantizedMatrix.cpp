#include "QuantizedMatrix.h"
#include "pilot_tdt.h"
#include <Accelerate/Accelerate.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <dispatch/dispatch.h>

namespace pilot {
float decodeHalf(uint16_t bits) {
    __fp16 value;
    std::memcpy(&value, &bits, sizeof(bits));
    return float(value);
}

QuantizedMatrix::QuantizedMatrix(const int8_t *codes, const uint16_t *scales, int r, int c) {
    if (!codes || !scales || r <= 0 || c <= 0 || c > int(scratchFloats) ||
        size_t(r) > (size_t(256) * 1024 * 1024) / size_t(c))
        throw std::invalid_argument("Invalid compact matrix dimensions or pointers");
    for (int i = 0; i < r; ++i)
        if (!std::isfinite(decodeHalf(scales[i])))
            throw std::invalid_argument("Nonfinite compact matrix scale");
    rows = r; cols = c;
    codes_.assign(codes, codes + size_t(r) * c);
    scales_.assign(scales, scales + r);
}

QuantizedMatrix::QuantizedMatrix(const void *values, int dtype, int r, int c) {
    if (!values || (dtype != 0 && dtype != 1) || r <= 0 || c <= 0 || c > int(scratchFloats) ||
        size_t(r) > (size_t(256) * 1024 * 1024) / size_t(c))
        throw std::invalid_argument("Invalid float matrix dimensions or pointers");
    const size_t n = size_t(r) * c;
    if (dtype == 0) {
        f32_.resize(n);
        std::memcpy(f32_.data(), values, n * sizeof(float));
        for (float v : f32_) if (!std::isfinite(v)) throw std::invalid_argument("Nonfinite float matrix value");
    } else {
        f16_.resize(n);
        std::memcpy(f16_.data(), values, n * sizeof(uint16_t));
        for (uint16_t v : f16_) if (!std::isfinite(decodeHalf(v))) throw std::invalid_argument("Nonfinite float matrix value");
    }
    rows = r; cols = c;
}

size_t QuantizedMatrix::compactBytes() const {
    return codes_.capacity() * sizeof(int8_t) + scales_.capacity() * sizeof(uint16_t) + f16_.capacity() * sizeof(uint16_t);
}

Vector QuantizedMatrix::row(int index) const {
    if (index < 0 || index >= rows) throw std::out_of_range("Compact matrix row");
    Vector result(cols);
    if (!f32_.empty()) { std::copy_n(f32_.data() + size_t(index) * cols, cols, result.begin()); return result; }
    if (!f16_.empty()) { for (int j = 0; j < cols; ++j) result[j] = decodeHalf(f16_[size_t(index) * cols + j]); return result; }
    const float scale = decodeHalf(scales_[index]);
    const int8_t *source = codes_.data() + size_t(index) * cols;
    for (int j = 0; j < cols; ++j) result[j] = float(source[j]) * scale;
    return result;
}

Vector QuantizedMatrix::apply(const Vector &input, const Vector &bias, int workers) const {
    if (rows <= 0 || input.size() != size_t(cols) || bias.size() != size_t(rows))
        throw std::invalid_argument("Compact GEMV shape mismatch");
    for (float x : input) if (!std::isfinite(x)) throw std::invalid_argument("Nonfinite GEMV input");
    for (float b : bias) if (!std::isfinite(b)) throw std::invalid_argument("Nonfinite GEMV bias");
    Vector result = bias;
    const int blockRows = int(scratchFloats / size_t(cols));
    const int blocks = (rows + blockRows - 1) / blockRows;
    const int jobs = std::min(std::clamp(workers, 1, 4), blocks);
    struct Job {
        const QuantizedMatrix *matrix;
        const float *input;
        float *output;
        int blockRows, blocks, jobs;
    } job{this, input.data(), result.data(), blockRows, blocks, jobs};
    // All heap allocations and all throwing validation happen outside callback.
    // Each job owns bounded stack scratch and disjoint, unchanged row blocks.
    const auto run = [](void *opaque, size_t worker) {
        const auto &job = *static_cast<const Job *>(opaque);
        const auto &matrix = *job.matrix;
        const int cols = matrix.cols;
        alignas(64) std::array<float, scratchFloats> scratch;
        for (int block = int(worker); block < job.blocks; block += job.jobs) {
            const int start = block * job.blockRows;
            const int count = std::min(job.blockRows, matrix.rows - start);
            if (!matrix.f32_.empty()) {   // uncompressed float32: GEMV straight from the stored matrix
                cblas_sgemv(CblasRowMajor, CblasNoTrans, count, cols, 1, matrix.f32_.data() + size_t(start) * cols, cols,
                            job.input, 1, 1, job.output + start, 1);
                continue;
            }
            if (!matrix.f16_.empty()) {
                const uint16_t *source = matrix.f16_.data() + size_t(start) * cols;
                for (size_t i = 0, n = size_t(count) * cols; i < n; ++i) scratch[i] = decodeHalf(source[i]);
                cblas_sgemv(CblasRowMajor, CblasNoTrans, count, cols, 1, scratch.data(), cols,
                            job.input, 1, 1, job.output + start, 1);
                continue;
            }
            for (int i = 0; i < count; ++i) {
                const float scale = decodeHalf(matrix.scales_[start + i]);
                const int8_t *source = matrix.codes_.data() + size_t(start + i) * cols;
                float *destination = scratch.data() + size_t(i) * cols;
                // Preserve float(code) * float(fp16) rounding and BLAS shape.
                for (int j = 0; j < cols; ++j) destination[j] = float(source[j]) * scale;
            }
            cblas_sgemv(CblasRowMajor, CblasNoTrans, count, cols, 1, scratch.data(), cols,
                        job.input, 1, 1, job.output + start, 1);
        }
    };
    if (jobs == 1) run(&job, 0);
    else dispatch_apply_f(size_t(jobs), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), &job, run);
    for (float y : result) if (!std::isfinite(y)) throw std::overflow_error("Nonfinite compact GEMV result");
    return result;
}
}

extern "C" int pilot_quantized_parallel_probe(const int8_t *codes, const uint16_t *scales,
    int rows, int cols, int workers, const float *input, const float *bias, float *output,
    float *denseOutput, uint64_t *compactBytes, uint64_t *persistentFloatBytes,
    uint64_t *scratchBytes) {
    if (!input || !bias || !output || workers < 1 || workers > 4) return -1;
    try {
        pilot::QuantizedMatrix matrix(codes, scales, rows, cols);
        const pilot::Vector x(input, input + cols), b(bias, bias + rows);
        const auto result = matrix.apply(x, b, workers);
        std::copy(result.begin(), result.end(), output);
        if (denseOutput) {
            // Test-only reference. Production scoring has no dense allocation.
            pilot::Vector dense(size_t(rows) * cols);
            for (int i = 0; i < rows; ++i) {
                const auto row = matrix.row(i);
                std::copy(row.begin(), row.end(), dense.begin() + size_t(i) * cols);
            }
            std::copy(b.begin(), b.end(), denseOutput);
            cblas_sgemv(CblasRowMajor, CblasNoTrans, rows, cols, 1, dense.data(), cols,
                        x.data(), 1, 1, denseOutput, 1);
        }
        if (compactBytes) *compactBytes = matrix.compactBytes();
        if (persistentFloatBytes) *persistentFloatBytes = matrix.persistentFloatBytes();
        const size_t blocks = (size_t(rows) + matrix.scratchFloats / size_t(cols) - 1) / (matrix.scratchFloats / size_t(cols));
        if (scratchBytes) *scratchBytes = matrix.scratchBytes * std::min(size_t(workers), blocks);
        return 0;
    } catch (...) { return -1; }
}

extern "C" int pilot_quantized_probe(const int8_t *codes, const uint16_t *scales,
    int rows, int cols, const float *input, const float *bias, float *output,
    float *denseOutput, uint64_t *compactBytes, uint64_t *persistentFloatBytes,
    uint64_t *scratchBytes) {
    return pilot_quantized_parallel_probe(codes, scales, rows, cols, 1, input, bias,
        output, denseOutput, compactBytes, persistentFloatBytes, scratchBytes);
}

extern "C" int pilot_quantized_row_probe(const int8_t *codes, const uint16_t *scales,
    int rows, int cols, int index, float *output) {
    if (!output) return -1;
    try {
        const pilot::QuantizedMatrix matrix(codes, scales, rows, cols);
        const auto result = matrix.row(index);
        std::copy(result.begin(), result.end(), output);
        return 0;
    } catch (...) { return -1; }
}

// Test-only: GEMV on an uncompressed float matrix (dtype 0 float32, 1 float16) with the production path.
extern "C" int pilot_float_matrix_probe(const void *values, int dtype, int rows, int cols, int workers,
    const float *input, const float *bias, float *output) {
    if (!input || !bias || !output || workers < 1 || workers > 4) return -1;
    try {
        pilot::QuantizedMatrix matrix(values, dtype, rows, cols);
        const auto result = matrix.apply(pilot::Vector(input, input + cols), pilot::Vector(bias, bias + rows), workers);
        std::copy(result.begin(), result.end(), output);
        return 0;
    } catch (...) { return -1; }
}

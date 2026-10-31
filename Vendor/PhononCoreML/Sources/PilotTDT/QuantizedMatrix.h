#pragma once
#include <cstddef>
#include <cstdint>
#include <vector>

namespace pilot {
using Vector = std::vector<float>;
float decodeHalf(uint16_t bits);

// Immutable compact weights, shared by cloned decoders. Only GEMV's bounded
// stack block and a selected embedding row ever contain float coefficients.
class QuantizedMatrix {
public:
    static constexpr size_t scratchFloats = 16 * 1024;
    static constexpr size_t scratchBytes = scratchFloats * sizeof(float);
    int rows = 0, cols = 0;
    QuantizedMatrix() = default;
    QuantizedMatrix(const int8_t *codes, const uint16_t *scales, int rows, int cols);
    // Uncompressed float matrix (decoder.bin v3): dtype 0 = float32, 1 = float16. Same GEMV shape and fp32 accumulation.
    QuantizedMatrix(const void *values, int dtype, int rows, int cols);
    Vector apply(const Vector &input, const Vector &bias, int workers = 1) const;
    Vector row(int index) const;
    size_t compactBytes() const;
    size_t persistentFloatBytes() const { return f32_.size() * sizeof(float); }
private:
    std::vector<int8_t> codes_;
    std::vector<uint16_t> scales_;
    std::vector<float> f32_;      // float32 matrices
    std::vector<uint16_t> f16_;   // float16 matrices (converted exactly to float per GEMV block)
};
}

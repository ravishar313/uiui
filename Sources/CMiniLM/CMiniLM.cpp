#include "include/CMiniLM.h"
#include "Tokenizer.hpp"
#include <onnxruntime_cxx_api.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace {
void error_code(char *buffer, size_t capacity, const char *code) noexcept {
    if (!buffer || capacity == 0) return;
    const auto count = std::min(capacity - 1, std::strlen(code));
    std::memcpy(buffer, code, count);
    buffer[count] = '\0';
}
void ORT_API_CALL discard_log(void *, OrtLoggingLevel, const char *, const char *,
                              const char *, const char *) {}
using uiui_minilm::Failure;
}

struct UIUIMiniLM {
    uiui_minilm::Tokenizer tokenizer;
    Ort::Env environment{ORT_LOGGING_LEVEL_FATAL, "uiui-minilm", discard_log, nullptr};
    std::unique_ptr<Ort::Session> session;
    Ort::MemoryInfo memory = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    std::vector<std::string> input_names;
    std::vector<const char *> input_pointers;
    std::vector<size_t> input_indices;
    std::string output_name;

    UIUIMiniLM(const char *model, const char *sp) : tokenizer(sp) {
        if (!model || !*model) throw Failure("model_path_missing");
        Ort::SessionOptions options;
        options.SetIntraOpNumThreads(1);
        options.SetInterOpNumThreads(1);
        options.SetExecutionMode(ExecutionMode::ORT_SEQUENTIAL);
        options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
        // No optional execution provider is appended: ORT's default is CPU.
        // Keep default CPU arena and prepacking, as selected by the benchmark.
        session = std::make_unique<Ort::Session>(environment, model, options);
        const auto count = session->GetInputCount();
        if ((count != 2 && count != 3) || session->GetOutputCount() != 1)
            throw Failure("model_interface_mismatch");
        Ort::AllocatorWithDefaultOptions allocator;
        std::array<bool, 3> seen{};
        input_names.reserve(count);
        for (size_t i = 0; i < count; ++i) {
            auto name = session->GetInputNameAllocated(i, allocator);
            input_names.emplace_back(name.get());
            size_t index;
            if (input_names.back() == "input_ids") index = 0;
            else if (input_names.back() == "attention_mask") index = 1;
            else if (input_names.back() == "token_type_ids") index = 2;
            else throw Failure("model_input_mismatch");
            if (seen[index]) throw Failure("model_duplicate_input");
            seen[index] = true;
            input_indices.push_back(index);
            const auto type = session->GetInputTypeInfo(i);
            const auto info = type.GetTensorTypeAndShapeInfo();
            const auto shape = info.GetShape();
            if (info.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64 || shape.size() != 2 ||
                (shape[0] != 1 && shape[0] >= 0) || shape[1] >= 0)
                throw Failure("model_input_shape_mismatch");
        }
        if (!seen[0] || !seen[1]) throw Failure("model_required_input_missing");
        for (const auto &name : input_names) input_pointers.push_back(name.c_str());
        output_name = session->GetOutputNameAllocated(0, allocator).get();
        const auto output_type = session->GetOutputTypeInfo(0);
        const auto output_info = output_type.GetTensorTypeAndShapeInfo();
        const auto shape = output_info.GetShape();
        if (output_info.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT || shape.size() != 3 ||
            (shape[0] != 1 && shape[0] >= 0) || shape[1] >= 0 || shape[2] != 8)
            throw Failure("model_output_shape_mismatch");
    }
};

extern "C" UIUIMiniLM *uiui_minilm_create(const char *model, const char *sp,
                                          char *error, size_t error_capacity) {
    error_code(error, error_capacity, "");
    try { return new UIUIMiniLM(model, sp); }
    catch (const Failure &failure) { error_code(error, error_capacity, failure.what()); }
    catch (...) { error_code(error, error_capacity, "native_initialization_failed"); }
    return nullptr;
}

extern "C" void uiui_minilm_destroy(UIUIMiniLM *context) { delete context; }

static int encode_tokens(UIUIMiniLM *context, const char *utf8, int64_t *out,
                         size_t capacity, char *error, size_t error_capacity) {
    error_code(error, error_capacity, "");
    try {
        if (!context || !utf8 || (!out && capacity != 0)) throw Failure("invalid_argument");
        return context->tokenizer.encode_into(utf8, out, capacity);
    } catch (const Failure &failure) { error_code(error, error_capacity, failure.what()); }
    catch (...) { error_code(error, error_capacity, "native_tokenization_failed"); }
    return -1;
}

extern "C" int uiui_minilm_encode(UIUIMiniLM *context, const char *utf8, int64_t *out,
                                  size_t capacity, char *error, size_t error_capacity) {
    return encode_tokens(context, utf8, out, capacity, error, error_capacity);
}

extern "C" int uiui_minilm_predict(UIUIMiniLM *context, const int64_t *ids, size_t count,
                                   float *logits, size_t capacity, char *error, size_t error_capacity) {
    error_code(error, error_capacity, "");
    try {
        if (!context || !ids || !logits) throw Failure("invalid_argument");
        if (count == 0 || count > UIUI_MINILM_MAX_TOKENS) throw Failure("unsupported_window_length");
        if (capacity < count * UIUI_MINILM_LOGITS_PER_TOKEN) throw Failure("logit_buffer_too_small");
        std::array<std::array<int64_t, UIUI_MINILM_MAX_TOKENS>, 3> values{};
        for (size_t i = 0; i < count; ++i) {
            if (ids[i] < 0 || ids[i] >= 32000) throw Failure("unsupported_token_id");
            values[0][i] = ids[i];
            values[1][i] = 1;
        }
        const std::array<int64_t, 2> shape{1, static_cast<int64_t>(count)};
        std::vector<Ort::Value> tensors;
        tensors.reserve(context->input_indices.size());
        for (auto index : context->input_indices)
            tensors.push_back(Ort::Value::CreateTensor<int64_t>(context->memory,
                values[index].data(), count, shape.data(), shape.size()));
        const char *output = context->output_name.c_str();
        auto result = context->session->Run(Ort::RunOptions{nullptr}, context->input_pointers.data(),
            tensors.data(), tensors.size(), &output, 1);
        if (result.size() != 1 || !result[0].IsTensor()) throw Failure("invalid_model_output");
        const auto info = result[0].GetTensorTypeAndShapeInfo();
        const std::vector<int64_t> expected{1, static_cast<int64_t>(count), 8};
        if (info.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT || info.GetShape() != expected)
            throw Failure("invalid_model_output_shape");
        const float *source = result[0].GetTensorData<float>();
        for (size_t i = 0; i < count * 8; ++i)
            if (!std::isfinite(source[i])) throw Failure("nonfinite_model_output");
        std::copy(source, source + count * 8, logits);
        return 0;
    } catch (const Failure &failure) { error_code(error, error_capacity, failure.what()); }
    catch (...) { error_code(error, error_capacity, "native_prediction_failed"); }
    return -1;
}

// Opt-in executable for the lead's serialized model validation. Merely building
// this executable does not create a session. Do not run alongside other models.
#include "../../../Sources/CMiniLM/include/CMiniLM.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

static void require(bool condition, const char *code) {
    if (!condition) throw std::runtime_error(code);
}
static void parity(UIUIMiniLM *context, const std::string &path,
                   uint64_t expected_hash, double expected_sum, double expected_weighted) {
    std::ifstream file(path);
    require(bool(file), "fixture_open");
    std::vector<int64_t> ids;
    int64_t value;
    while (file >> value) ids.push_back(value);
    require(file.eof(), "fixture_format");
    std::vector<float> logits(ids.size() * 8);
    char error[128];
    require(uiui_minilm_predict(context, ids.data(), ids.size(), logits.data(), logits.size(),
                               error, sizeof(error)) == 0, "fixture_prediction_failed");
    double sum = 0, weighted = 0;
    uint64_t hash = 14695981039346656037ULL;
    for (size_t i = 0; i < logits.size(); ++i) {
        require(std::isfinite(logits[i]), "nonfinite_logits");
        sum += logits[i];
        weighted += logits[i] * double(i + 1);
    }
    for (size_t i = 0; i < ids.size(); ++i) {
        auto row = logits.data() + i * 8;
        for (auto label : {std::max_element(row, row + 5) - row,
                           std::max_element(row + 5, row + 8) - (row + 5)}) {
            hash ^= static_cast<uint8_t>(label);
            hash *= 1099511628211ULL;
        }
    }
    require(hash == expected_hash, "argmax_parity_mismatch");
    require(std::abs(sum - expected_sum) <= 1e-5 + 1e-6 * std::abs(expected_sum), "logit_sum_mismatch");
    require(std::abs(weighted - expected_weighted) <= 1e-3 + 1e-6 * std::abs(expected_weighted),
            "logit_weighted_sum_mismatch");
}

int main(int argc, char **argv) {
    try {
        require(argc == 4, "arguments_model_sentencepiece_fixture_directory");
        char error[128];
        std::unique_ptr<UIUIMiniLM, decltype(&uiui_minilm_destroy)> context(
            uiui_minilm_create(argv[1], argv[2], error, sizeof(error)), uiui_minilm_destroy);
        require(bool(context), error);
        auto count = uiui_minilm_encode(context.get(), "revised", nullptr, 0, error, sizeof(error));
        require(count > 0, "encode_size_query");
        std::vector<int64_t> tokens(static_cast<size_t>(count), -777);
        require(uiui_minilm_encode(context.get(), "revised", tokens.data(), tokens.size() - 1,
                                  error, sizeof(error)) == -1 &&
                std::all_of(tokens.begin(), tokens.end(), [](int64_t id) { return id == -777; }),
                "encode_capacity_wrote_partial");
        require(uiui_minilm_encode(context.get(), "revised", tokens.data(), tokens.size(),
                                  error, sizeof(error)) == count, "encode_size_changed");
        const int64_t valid = 0, invalid = 32000;
        std::array<float, 8> untouched;
        untouched.fill(123.0f);
        for (size_t length : {size_t(0), size_t(129)})
            require(uiui_minilm_predict(context.get(), &valid, length, untouched.data(), untouched.size(),
                                       error, sizeof(error)) == -1, "invalid_window_accepted");
        require(uiui_minilm_predict(context.get(), &invalid, 1, untouched.data(), untouched.size(),
                                   error, sizeof(error)) == -1, "invalid_id_accepted");
        require(uiui_minilm_predict(context.get(), &valid, 1, untouched.data(), 7,
                                   error, sizeof(error)) == -1, "undersized_logits_accepted");
        require(std::all_of(untouched.begin(), untouched.end(), [](float v) { return v == 123.0f; }),
                "error_changed_logits");
        // These expectations come from the previously frozen Python/native
        // core comparison, not from outputs produced by this implementation.
        const std::string directory(argv[3]);
        parity(context.get(), directory + "/short.ids", 0xe5981256e45e4df0ULL,
               -96.91430541872978, -4199.552887350321);
        parity(context.get(), directory + "/long.ids", 0xcc5841dda99f6544ULL,
               -1072.582038069144, -435925.24911012687);
        std::cout << "Passed single owned CPU session, encode capacities, inference guards,"
                     " and two frozen Python/native logit and argmax parity fixtures.\n";
        return 0;
    } catch (const std::exception &failure) {
        std::cerr << "Native session contract failed: " << failure.what() << '\n';
        return 1;
    }
}

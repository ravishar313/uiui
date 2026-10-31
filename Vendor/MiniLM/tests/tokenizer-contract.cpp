#include "../../../Sources/CMiniLM/Tokenizer.hpp"
#include "../../../Sources/CMiniLM/include/CMiniLM.h"
#include <algorithm>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>

static void require(bool condition, const char *code) {
    if (!condition) throw std::runtime_error(code);
}

// Exercise the same direct-fill tokenizer boundary used by the C bridge,
// without creating an ORT session. Expected IDs come from frozen HF fixtures.
static void direct_encoding(const uiui_minilm::Tokenizer &tokenizer, const std::string &text,
                            const std::vector<int64_t> &expected) {
    require(tokenizer.encode_into(text, nullptr, 0) == static_cast<int>(expected.size()), "direct_count");
    std::vector<int64_t> output(expected.size() + 3, -777);
    require(tokenizer.encode_into(text, output.data(), expected.size()) == static_cast<int>(expected.size()),
            "direct_fill_count");
    require(std::equal(expected.begin(), expected.end(), output.begin()), "direct_fill_parity");
    require(std::all_of(output.begin() + expected.size(), output.end(), [](int64_t id) { return id == -777; }),
            "direct_fill_wrote_tail");
    if (expected.empty()) return;
    std::fill(output.begin(), output.end(), -777);
    bool rejected = false;
    try { (void)tokenizer.encode_into(text, output.data(), expected.size() - 1); }
    catch (const uiui_minilm::Failure &failure) { rejected = std::string(failure.what()) == "token_buffer_too_small"; }
    require(rejected, "direct_capacity_accepted");
    require(std::all_of(output.begin(), output.end(), [](int64_t id) { return id == -777; }),
            "direct_capacity_wrote_prefix");
}

int main(int argc, char **argv) {
    try {
        require(argc == 3, "arguments");
        uiui_minilm::Tokenizer tokenizer(argv[1]); // No ORT environment/session.
        std::ifstream fixtures(argv[2]);
        require(bool(fixtures), "fixtures_open");
        std::string line;
        size_t tested = 0;
        while (std::getline(fixtures, line)) {
            auto tab = line.find('\t');
            require(tab != std::string::npos, "fixture_format");
            std::istringstream numbers(line.substr(0, tab));
            std::vector<int64_t> expected;
            int64_t number;
            while (numbers >> number) expected.push_back(number);
            require(tokenizer.encode(line.substr(tab + 1)) == expected, "tokenizer_parity_mismatch");
            direct_encoding(tokenizer, line.substr(tab + 1), expected);
            ++tested;
        }
        require(tested >= 20, "insufficient_fixtures");
        // Literal specials must not become HF special IDs or disappear.
        for (const auto *text : {"<s>", "</s>", "<pad>", "<unk>", "<mask>"}) {
            auto ids = tokenizer.encode(text);
            require(!ids.empty(), "literal_special_empty");
            require(std::all_of(ids.begin(), ids.end(), [](int64_t id) {
                return id >= 3 && id < 31999;
            }), "literal_special_interpreted");
        }
        require(tokenizer.encode("").empty(), "empty_input");
        direct_encoding(tokenizer, "", {});
        std::string boundary_text;
        for (int i = 0; i < 126; ++i) boundary_text += i == 0 ? "the" : " the";
        std::vector<int64_t> boundary_ids(126, 53); // Frozen HF ID for the word "the".
        direct_encoding(tokenizer, boundary_text, boundary_ids);
        boundary_text += " the";
        std::vector<int64_t> boundary_buffer(126, -777);
        bool boundary_rejected = false;
        try { (void)tokenizer.encode_into(boundary_text, boundary_buffer.data(), boundary_buffer.size()); }
        catch (const uiui_minilm::Failure &failure) {
            boundary_rejected = std::string(failure.what()) == "token_buffer_too_small";
        }
        require(boundary_rejected && std::all_of(boundary_buffer.begin(), boundary_buffer.end(),
                [](int64_t id) { return id == -777; }), "127_piece_input_truncated");
        std::string long_word(2000, 'z');
        const auto long_ids = tokenizer.encode(long_word);
        require(long_ids.size() > 128, "encoding_was_truncated");
        direct_encoding(tokenizer, long_word, long_ids);
        std::vector<int64_t> budget(126, -777);
        bool oversized_rejected = false;
        try { (void)tokenizer.encode_into(long_word, budget.data(), budget.size()); }
        catch (const uiui_minilm::Failure &failure) {
            oversized_rejected = std::string(failure.what()) == "token_buffer_too_small";
        }
        require(oversized_rejected && std::all_of(budget.begin(), budget.end(), [](int64_t id) { return id == -777; }),
                "fixed_budget_truncated_or_wrote_prefix");
        require(tokenizer.encode("\U0010ffff") == std::vector<int64_t>({6, 3}), "unknown_mapping");
        for (std::string invalid : {std::string("\xc0\xaf"), std::string("\xed\xa0\x80"),
                                     std::string("\xf4\x90\x80\x80"), std::string("\xe2\x82")}) {
            bool rejected = false;
            try { (void)tokenizer.encode(invalid); }
            catch (const uiui_minilm::Failure &failure) { rejected = std::string(failure.what()) == "invalid_utf8"; }
            require(rejected, "invalid_utf8_accepted");
            int64_t untouched_id = -777;
            rejected = false;
            try { (void)tokenizer.encode_into(invalid, &untouched_id, 1); }
            catch (const uiui_minilm::Failure &failure) { rejected = std::string(failure.what()) == "invalid_utf8"; }
            require(rejected && untouched_id == -777, "direct_invalid_utf8_wrote_output");
        }
        // C argument and fixed diagnostic behavior can be checked without a
        // model context or ORT environment. Model-backed checks run separately.
        char error[5] = {};
        require(uiui_minilm_encode(nullptr, "public", nullptr, 0, error, sizeof(error)) == -1,
                "null_context_accepted");
        require(error[4] == '\0' && std::string(error) == "inva", "error_termination");
        float untouched = 123.0f;
        require(uiui_minilm_predict(nullptr, nullptr, 1, &untouched, 1, nullptr, 0) == -1 && untouched == 123.0f,
                "invalid_prediction_changed_output");
        uiui_minilm_destroy(nullptr);
        std::cout << "Passed " << tested << " frozen HF tokenization fixtures, literal specials, unknown IDs,"
                     " direct-fill parity/capacities, no truncation, malformed UTF-8, and C boundary errors;"
                     " no model session/inference.\n";
        return 0;
    } catch (const std::exception &failure) {
        std::cerr << "Native tokenizer contract failed: " << failure.what() << '\n';
        return 1;
    }
}

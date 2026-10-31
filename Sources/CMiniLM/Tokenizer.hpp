#ifndef UIUI_MINILM_TOKENIZER_HPP
#define UIUI_MINILM_TOKENIZER_HPP

#include <sentencepiece_processor.h>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string_view>
#include <vector>

namespace uiui_minilm {

// Fixed diagnostics avoid copying source text, paths, or dependency exceptions
// into application errors. The caller never logs the text being tokenized.
class Failure : public std::runtime_error {
public:
    explicit Failure(const char *code) : std::runtime_error(code) {}
};

inline bool valid_utf8(std::string_view text) {
    size_t i = 0;
    while (i < text.size()) {
        const auto first = static_cast<unsigned char>(text[i++]);
        if (first <= 0x7f) continue;
        unsigned remaining;
        uint32_t value;
        uint32_t minimum;
        if (first >= 0xc2 && first <= 0xdf) { remaining = 1; value = first & 0x1f; minimum = 0x80; }
        else if (first >= 0xe0 && first <= 0xef) { remaining = 2; value = first & 0x0f; minimum = 0x800; }
        else if (first >= 0xf0 && first <= 0xf4) { remaining = 3; value = first & 7; minimum = 0x10000; }
        else return false;
        if (remaining > text.size() - i) return false;
        for (unsigned j = 0; j < remaining; ++j) {
            const auto next = static_cast<unsigned char>(text[i++]);
            if ((next & 0xc0) != 0x80) return false;
            value = (value << 6) | (next & 0x3f);
        }
        if (value < minimum || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) return false;
    }
    return true;
}

class Tokenizer {
    sentencepiece::SentencePieceProcessor processor_;
public:
    explicit Tokenizer(const char *path) {
        if (!path || !*path) throw Failure("tokenizer_path_missing");
        if (!processor_.Load(path).ok()) throw Failure("tokenizer_load_failed");
        // XLM-R reserves HF 0/1/2/3 and shifts ordinary SP pieces by one.
        // This model has 31,998 SP entries; HF mask is separately added at 31,999.
        if (processor_.GetPieceSize() != 31998 || processor_.unk_id() != 0 ||
            processor_.bos_id() != 1 || processor_.eos_id() != 2 || processor_.pad_id() != -1 ||
            processor_.IdToPiece(0) != "<unk>" || processor_.IdToPiece(1) != "<s>" ||
            processor_.IdToPiece(2) != "</s>") throw Failure("tokenizer_vocabulary_mismatch");
    }

    std::vector<int64_t> encode(std::string_view text) const {
        const auto pieces = tokenize(text);
        std::vector<int64_t> result;
        result.reserve(pieces.size());
        for (int piece : pieces) result.push_back(mapped_id(piece));
        return result;
    }

    // Tokenize once, validate the entire result, then copy directly into the
    // caller's bounded buffer. Capacity failures never write a partial prefix.
    // The vector-returning overload remains available for tokenizer fixtures.
    int encode_into(std::string_view text, int64_t *out, size_t capacity) const {
        if (!out && capacity != 0) throw Failure("invalid_argument");
        const auto pieces = tokenize(text);
        if (pieces.size() > static_cast<size_t>(std::numeric_limits<int>::max()))
            throw Failure("token_count_overflow");
        if (out) {
            if (capacity < pieces.size()) throw Failure("token_buffer_too_small");
            for (size_t i = 0; i < pieces.size(); ++i) out[i] = mapped_id(pieces[i]);
        }
        return static_cast<int>(pieces.size());
    }

private:
    static int64_t mapped_id(int piece) { return piece == 0 ? 3 : static_cast<int64_t>(piece) + 1; }

    std::vector<int> tokenize(std::string_view text) const {
        if (!valid_utf8(text)) throw Failure("invalid_utf8");
        std::vector<int> pieces;
        if (!processor_.Encode(text, &pieces).ok()) throw Failure("tokenizer_encode_failed");
        for (int piece : pieces) {
            if (piece != 0 && !(piece >= 3 && piece < 31998 && !processor_.IsControl(piece) &&
                               !processor_.IsUnused(piece))) throw Failure("unsupported_token_id");
        }
        return pieces;
    }
};
} // namespace uiui_minilm
#endif

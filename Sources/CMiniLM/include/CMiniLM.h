#ifndef UIUI_CMINILM_H
#define UIUI_CMINILM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct UIUIMiniLM UIUIMiniLM;

enum { UIUI_MINILM_MAX_TOKENS = 128, UIUI_MINILM_LOGITS_PER_TOKEN = 8 };

/* One context owns one CPU-only, single-threaded ORT session and tokenizer.
 * Calls on a context, including destroy, must be serialized by its owner.
 * Errors contain only fixed diagnostic codes, never input text or file paths.
 * All functions accept a NULL error buffer; otherwise errors are NUL-terminated
 * when error_capacity is nonzero. No exception crosses this C boundary. */
UIUIMiniLM *uiui_minilm_create(const char *model_path, const char *sentencepiece_path,
                             char *error, size_t error_capacity);
void uiui_minilm_destroy(UIUIMiniLM *context);

/* Encode literal UTF-8 with the pinned SentencePiece model, mapping to the
 * publisher's XLM-R vocabulary. The caller applies NFKC/lowercase and adds
 * CLS=0 / SEP=2. Added-special-token strings are never interpreted specially.
 * Returns the complete token count, or -1 on error. There is no truncation.
 * An adequate output buffer encodes and fills in one tokenization pass;
 * callers with a fixed token budget need not query the count first.
 * out_ids=NULL, output_capacity=0 queries the required count. An insufficient
 * buffer fails without writing any IDs. Empty input may return zero.
 * Embedded NULs cannot be represented by this API and must be rejected by Swift. */
int uiui_minilm_encode(UIUIMiniLM *context, const char *utf8, int64_t *out_ids,
                       size_t output_capacity, char *error, size_t error_capacity);

/* Synchronous inference for one [1,count] window, 1 <= count <= 128. The caller
 * supplies CLS/SEP and allocates at least count*8 floats. Attention is all ones;
 * token types are all zero. Returns 0 on success or -1 on failure; output is
 * untouched on failure. The caller checks cancellation before and after this
 * bounded CPU call. No background work, network, or logging is performed. */
int uiui_minilm_predict(UIUIMiniLM *context, const int64_t *ids, size_t count,
                        float *logits, size_t logit_capacity,
                        char *error, size_t error_capacity);

#ifdef __cplusplus
}
#endif
#endif

// Phonon-2 greedy decoder (compiled library).
#ifndef PILOT_TDT_H
#define PILOT_TDT_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
void *pilot_tdt_create(int V, int E, int H, int nhead, int ndur, const int *durations, int blank, int max_sym,
                         const int8_t *emb_q, const uint16_t *emb_s,
                         const int8_t *ih0_q, const uint16_t *ih0_s, const uint16_t *bih0, const int8_t *hh0_q, const uint16_t *hh0_s, const uint16_t *bhh0,
                         const int8_t *ih1_q, const uint16_t *ih1_s, const uint16_t *bih1, const int8_t *hh1_q, const uint16_t *hh1_s, const uint16_t *bhh1,
                         const int8_t *proj_q, const uint16_t *proj_s, const uint16_t *proj_b,
                         const int8_t *head_q, const uint16_t *head_s, const uint16_t *head_b);
/* decoder.bin v3: uncompressed matrices, dtype 0 = float32, 1 = float16 (biases use the same dtype); fp32 accumulate.
   No compiled reference decoder backs these handles; the unbiased reference for selective vocabulary bias is a plain greedy
   decode over the same float weights, so selective rollback behaves as for int8 tables. */
void *pilot_tdt_create_float(int V, int E, int H, int nhead, int ndur, const int *durations, int blank, int max_sym, int dtype,
                         const void *emb,
                         const void *ih0, const void *bih0, const void *hh0, const void *bhh0,
                         const void *ih1, const void *bih1, const void *hh1, const void *bhh1,
                         const void *proj, const void *proj_b, const void *head, const void *head_b);
int pilot_tdt_decode(void *h, const float *encp, int T, int32_t *out, int max_out);
/* token ids + the encoder frame each token was emitted at + its predicted duration (frames of 80 ms); handles are independent */
int pilot_tdt_decode_timed(void *h, const float *encp, int T, int32_t *out, int32_t *out_frame, int32_t *out_dur, int max_out);
void pilot_tdt_handle_threads(void *h, int n);
/* a handle sharing the weight tables of h (own state, scratch, pool); destroy clones before h */
void *pilot_tdt_clone(void *h);
void pilot_tdt_set_threads(int n);
void pilot_tdt_destroy(void *h);
/* 0 valid; 1 sticky allocation failure during configuration; -1 null handle. */
int pilot_tdt_configuration_status(void *h);
int pilot_tdt_abi_version(void);
/* Numeric diagnostics: denseOutput is an optional test-only dense BLAS reference.
   Reported memory is compact retained coefficients, retained FP32 coefficients,
   and maximum GEMV stack scratch; invalid/nonfinite inputs return -1. */
int pilot_quantized_probe(const int8_t *codes, const uint16_t *scales, int rows, int cols,
    const float *input, const float *bias, float *output, float *denseOutput,
    uint64_t *compactBytes, uint64_t *persistentFloatBytes, uint64_t *scratchBytes);
int pilot_quantized_parallel_probe(const int8_t *codes, const uint16_t *scales,
    int rows, int cols, int workers, const float *input, const float *bias,
    float *output, float *denseOutput, uint64_t *compactBytes,
    uint64_t *persistentFloatBytes, uint64_t *scratchBytes);
int pilot_quantized_row_probe(const int8_t *codes, const uint16_t *scales,
    int rows, int cols, int index, float *output);
int pilot_float_matrix_probe(const void *values, int dtype, int rows, int cols, int workers,
    const float *input, const float *bias, float *output);
/* Shared immutable custom-table allocation only, excludes original ABI tables.
   Clone handles share these bytes; GEMV scratch is per active call, not retained. */
int pilot_tdt_weight_memory(void *h, uint64_t *compactBytes, uint64_t *floatWeightBytes,
    uint64_t *biasBytes, uint64_t *scratchBytes);
void pilot_tdt_bias(void *h, const int32_t *tokens, const int32_t *lengths, int count, float strength);
void pilot_tdt_reference(void *h, int enabled);
/* Cache only embedding/LSTM/projector results for immutable nonblank history.
   Diagnostic switch; both modes preserve prediction-step/cancellation budgets.
   Counters reset at the start of each decode; fixtures bypass this cache. */
void pilot_tdt_predictor_cache(void *h, int enabled);
void pilot_tdt_predictor_cache_statistics(void *h, uint64_t *hits, uint64_t *misses);
/* Small seeded matrix/state diagnostic only; no model or original ABI calls.
   Returns an invariant failure bitmask, zero on exact parity. */
int pilot_predictor_cache_invariant_probe(void);
/* Model-free allocation-failure diagnostic for native configuration setters. */
int pilot_configuration_failure_probe(void);
/* 0 off, 1 diagnostics-only, 2 enforce context evidence. Invalid config
   disables vocabulary bias; the original decoder remains available. */
void pilot_tdt_context(void *h, int mode, double maxLoss);
void pilot_tdt_context_weight(void *h, double weight);
int pilot_tdt_bias_states(void *h);
void pilot_tdt_suppress_tokens(void *h, const int32_t *tokens, int count);
int pilot_bias_probe_suppressed(const int32_t *tokens, const int32_t *lengths, int count, const int32_t *emitted, int emittedCount, const float *scores, int V, int blank, float strength, float *bonuses, const int32_t *suppressed, int suppressedCount);
int pilot_tdt_timing_probe(int predicted, int isBlank, int priorSymbols, int maxSymbols, int *advance, int *nextSymbols);
int pilot_selective_path_probe(const int32_t *tokens, const int32_t *lengths, int count, const float *scores, int T, int V, const int32_t *boundaries, int boundary_count, float budget, float margin, int32_t *out, int32_t *frames, int32_t *durations, int cap, int *end_frame);
int pilot_selective_utterance_probe(const int32_t *tokens, const int32_t *lengths, int count, const float *scores, int T, int V, const int32_t *boundaries, int boundary_count, float budget, float margin, int32_t *out, int32_t *frames, int32_t *durations, int cap, int *commits, int cancel_after, int prediction_limit);
int pilot_selective_context_utterance_probe(const int32_t *tokens, const int32_t *lengths, int count, const float *scores, int T, int V, const int32_t *boundaries, int boundary_count, float budget, float margin, int32_t *out, int32_t *frames, int32_t *durations, int cap, int *commits, int cancel_after, int prediction_limit);
int pilot_selective_competition_probe(const int32_t *tokens, const int32_t *lengths, int count, const float *scores, int T, int V, const int32_t *boundaries, int boundary_count, float budget, float margin, int32_t *out, int32_t *frames, int32_t *durations, int cap, int *end_frame, int positive_duration);
int pilot_selective_context_competition_probe(const int32_t *tokens, const int32_t *lengths, int count, const float *scores, int T, int V, const int32_t *boundaries, int boundary_count, float budget, float margin, int32_t *out, int32_t *frames, int32_t *durations, int cap, int *end_frame, int positive_duration);
void pilot_tdt_selective(void *h, const int32_t *boundary_tokens, int count, float local_margin);
typedef int (*pilot_cancel_fn)(void *context);
void pilot_tdt_cancellation(void *h, pilot_cancel_fn callback, void *context);
void pilot_tdt_word_starts(void *h, const int32_t *tokens, int count);
void pilot_tdt_statistics(void *h, int *attempts, int *commits, int *steps, float *regret);
int pilot_selective_gate_probe(float total, float step, float budget, float margin, int complete, int end_boundary);
int pilot_bias_probe(const int32_t *tokens, const int32_t *lengths, int count, const int32_t *emitted, int emittedCount, const float *scores, int V, int blank, float strength, float *bonuses);
#ifdef __cplusplus
}
#endif
#endif

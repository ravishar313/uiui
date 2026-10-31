// Local TDT continuation evidence. No lexical tables, transcript rewriting,
// learned/private data, allocation, model work or background activity here.
#pragma once
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <limits>

namespace phonon_context {

enum class Stop { complete, no_context, cancelled, prediction_budget, invalid, step_limit };

struct Limits {
    int maxFrames = 32;
    int maxSteps = 64;
    int maxWords = 3;
};

// The callback computes BOTH model probabilities for the SAME ordinary token
// and raw duration, at the SAME frame. It advances two independent recurrent
// states using that event. `advance` is effective advancement after native
// blank-zero/max-symbol safety handling, not necessarily the raw duration.
struct PairedStep {
    double ordinary = 0;
    double candidate = 0;
    int advance = 0;
    bool nonblank = false;
    bool wordStart = false;
    bool valid = false;
};

struct Continuation {
    double ordinary = 0;
    double candidate = 0;
    int events = 0;
    int tokens = 0;
    int words = 0;
    int endFrame = 0;
    bool reachedEOS = false;
    Stop stop = Stop::no_context;
    double delta() const { return candidate - ordinary; }
};

// `stop()` returns complete to proceed, or a failure reason. It MUST consult
// the decoder's existing cooperative cancellation/prediction budget. The
// callback MUST also check between its two predictions. Ordinary/candidate
// states are temporary copies and must not be committed by the callback.
template<class StopFn, class PairedPredictionFn>
Continuation scoreContinuation(int startFrame, int totalFrames, Limits limits,
                               StopFn stop, PairedPredictionFn paired) {
    Continuation out;
    out.endFrame = startFrame;
    if (startFrame < 0 || totalFrames <= 0 || startFrame > totalFrames ||
        limits.maxFrames <= 0 || limits.maxSteps <= 0 || limits.maxWords <= 0) {
        out.stop = Stop::invalid;
        return out;
    }
    if (startFrame == totalFrames) { out.reachedEOS = true; return out; }
    // Overflow-free, clamped horizon; never ask for prediction at frame T.
    const int horizon = startFrame + std::min(limits.maxFrames, totalFrames - startFrame);
    for (int step = 0; step < limits.maxSteps; ++step) {
        if (out.endFrame >= horizon) {
            out.reachedEOS = out.endFrame >= totalFrames;
            out.stop = out.words ? Stop::complete : Stop::no_context;
            return out;
        }
        const Stop status = stop();
        if (status != Stop::complete) { out.stop = status; return out; }
        const PairedStep p = paired(out.endFrame);
        // Duration log probabilities and token log probabilities are <= 0.
        // Small positive rounding is allowed, but NaN/+inf never enters a gate.
        if (!p.valid || !std::isfinite(p.ordinary) || !std::isfinite(p.candidate) ||
            p.ordinary > 1e-5 || p.candidate > 1e-5 || p.advance < 0) {
            out.stop = Stop::invalid;
            return out;
        }
        if (p.nonblank && p.wordStart && out.words >= limits.maxWords) {
            out.stop = out.tokens ? Stop::complete : Stop::no_context;
            return out;
        }
        out.ordinary += p.ordinary;
        out.candidate += p.candidate;
        ++out.events;
        if (p.nonblank) {
            ++out.tokens;
            if (p.wordStart) ++out.words;
        }
        // A long final duration may cross T. Clamp without integer overflow.
        out.endFrame += std::min(p.advance, totalFrames - out.endFrame);
    }
    out.stop = Stop::step_limit;
    return out;
}

inline double logProbability(const float* logits, int count, int chosen) {
    if (!logits || count <= 0 || chosen < 0 || chosen >= count)
        return -std::numeric_limits<double>::infinity();
    double maximum = -std::numeric_limits<double>::infinity();
    for (int i = 0; i < count; ++i) {
        if (!std::isfinite(logits[i])) return -std::numeric_limits<double>::infinity();
        maximum = std::max(maximum, double(logits[i]));
    }
    double sum = 0;
    for (int i = 0; i < count; ++i) sum += std::exp(double(logits[i]) - maximum);
    return double(logits[chosen]) - maximum - std::log(sum);
}

struct Policy {
    double spanBudget = 8;
    // A candidate must explain the observed continuation at least this well
    // relative to ordinary. This is a tunable DEVELOPMENT selection parameter,
    // not a semantic claim. +infinity explicitly disables the context veto.
    double maxContextLoss = 0;
    // Development-calibrated cost of contradictory continuation evidence.
    // Supportive continuation cannot increase the existing local span budget.
    double contextWeight = 1;
    int minContextTokens = 1;
};

enum class Verdict { accept, span_loss, context_loss, insufficient_context, interrupted, invalid };

inline Verdict decide(double candidateSpan, double ordinarySpan,
                      const Continuation& context, Policy policy = {}) {
    if (!std::isfinite(candidateSpan) || !std::isfinite(ordinarySpan) ||
        !std::isfinite(policy.spanBudget) || policy.spanBudget < 0 ||
        std::isnan(policy.maxContextLoss) || policy.maxContextLoss < 0 ||
        !std::isfinite(policy.contextWeight) || policy.contextWeight < 1 || policy.contextWeight > 16 ||
        policy.minContextTokens < 1)
        return Verdict::invalid;
    if (context.stop == Stop::cancelled || context.stop == Stop::prediction_budget)
        return Verdict::interrupted;
    if (context.stop == Stop::invalid) return Verdict::invalid;
    if (context.stop != Stop::complete || context.tokens < policy.minContextTokens || context.words < 1)
        return Verdict::insufficient_context;
    if (!std::isfinite(context.ordinary) || !std::isfinite(context.candidate))
        return Verdict::invalid;
    const double delta = context.delta();
    if (candidateSpan - ordinarySpan + policy.spanBudget < 0)
        return Verdict::span_loss;
    if (delta < -policy.maxContextLoss) return Verdict::context_loss;
    if (candidateSpan - ordinarySpan + policy.contextWeight * std::min(0.0, delta) + policy.spanBudget < 0)
        return Verdict::span_loss;
    return Verdict::accept;
}

} // namespace phonon_context

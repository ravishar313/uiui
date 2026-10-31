import Foundation

public struct TranscriptSegment: Equatable, Sendable {
    public let timestamp: TimeInterval
    public let duration: TimeInterval
    /// UTF-16 range in this hypothesis's formatted text, not the session text.
    public let range: NSRange
    public init(timestamp: TimeInterval, duration: TimeInterval, range: NSRange) {
        self.timestamp = timestamp
        self.duration = duration
        self.range = range
    }
}

/// Reconciles timed recognition windows within one explicit recording session.
/// Text length alone is never evidence that a hypothesis is a new utterance.
public struct TranscriptAccumulator: Sendable {
    public private(set) var text = ""
    /// Best text was retained because the latest hypothesis lacked usable alignment.
    public private(set) var hasUnalignedHypothesis = false
    private var epoch: UInt64?
    private var earlierTasks = ""
    private var currentText = ""
    private var entries: [Entry] = []
    private var windowStart: TimeInterval?
    private var windowEnd: TimeInterval?
    private var latestWindowText = ""
    private var hasConfirmedWindowAdvance = false
    private let timingTolerance: TimeInterval = 0.12
    // A short leading-word retraction is ambiguous with a window shift. Preserve
    // historical prefix only when it is separated by disjoint audio or a long
    // timed window, not for a single omitted word in a short utterance.
    private let historyInterval: TimeInterval = 8

    public init() {}

    /// A large loss of timed coverage is unresolved even for partial results;
    /// retain the recoverable draft instead of accepting a possible clock reset.
    @discardableResult
    public mutating func update(_ hypothesis: String, segments: [TranscriptSegment] = [], recognitionEpoch: UInt64 = 0) -> String {
        if let epoch, recognitionEpoch < epoch { return text }
        if epoch != recognitionEpoch {
            earlierTasks = joining(earlierTasks, currentText)
            currentText = ""
            entries = []
            windowStart = nil
            windowEnd = nil
            latestWindowText = ""
            hasConfirmedWindowAdvance = false
            hasUnalignedHypothesis = false
            epoch = recognitionEpoch
        }
        guard var incoming = timedEntries(hypothesis, segments: segments),
              let first = incoming.first, let last = incoming.last else {
            if hasConfirmedWindowAdvance || hasLongTimedDraft {
                // A long first window is also recoverable history, even before a
                // rolling boundary has appeared. Missing timing cannot establish
                // which part of that draft a short final would replace.
                return retainUnaligned(hypothesis)
            }
            // Missing/invalid timing cannot establish a new window. Preserve normal
            // revision/retraction semantics instead of blindly appending a tail.
            currentText = hypothesis
            entries = []
            windowStart = nil
            windowEnd = nil
            latestWindowText = hypothesis
            hasUnalignedHypothesis = false
            text = joining(earlierTasks, currentText)
            return text
        }
        var prefix: [Entry] = []
        var adjacentBoundary = false
        var inheritedGap = false
        if let previousStart = windowStart, let previousEnd = windowEnd, !entries.isEmpty {
            let advancing = first.start > previousStart + timingTolerance
            let disjoint = first.start >= previousEnd - timingTolerance
            let anchor = entries.firstIndex { abs($0.start - first.start) <= timingTolerance }
            if hasLongTimedDraft {
                let unanchoredReset = first.start < previousStart - timingTolerance && anchor == nil
                let catastrophicContraction = first.start <= previousStart + timingTolerance &&
                    previousEnd - last.end >= historyInterval
                if unanchoredReset || catastrophicContraction {
                    // A reset clock can make a tail look like a whole-window
                    // revision. The inconsistent coverage remains uncertain even
                    // if its text matches an earlier rolling window.
                    return retainUnaligned(hypothesis, requiresReview: true)
                }
            }
            let longWindow = first.start - previousStart >= historyInterval ||
                (anchor != nil && previousEnd - first.start >= historyInterval)
            // A non-advancing update replaces its covered interval, including
            // revisions that expand backwards into a previously preserved window.
            let cutoff = !advancing || disjoint || longWindow ? first.start : previousStart
            // Tolerance classifies windows; it must not remove short words that
            // actually end before the incoming audio interval begins.
            prefix = entries.prefix { $0.start < cutoff && $0.end <= cutoff + 0.001 }.map { $0 }
            let exactAnchor = entries.firstIndex { abs($0.start - first.start) <= 0.001 }
            adjacentBoundary = exactAnchor != nil && abs(cutoff - first.start) <= 0.001
            inheritedGap = exactAnchor.map { entries[$0].piece.first?.isWhitespace == true } ?? false
        }
        let prefixText = prefix.map(\.piece).joined()
        if !prefixText.isEmpty, (!adjacentBoundary || inheritedGap),
           prefixText.last?.isWhitespace != true, incoming[0].piece.first?.isWhitespace != true {
            incoming[0].piece = " " + incoming[0].piece
        }
        entries = prefix + incoming
        currentText = entries.map(\.piece).joined()
        windowStart = first.start
        windowEnd = last.end
        latestWindowText = hypothesis
        hasConfirmedWindowAdvance = !prefix.isEmpty
        hasUnalignedHypothesis = false
        text = joining(earlierTasks, currentText)
        return text
    }

    private var hasLongTimedDraft: Bool {
        // Count covered speech, not silence between windows. Two short phrases
        // separated by a long pause must keep ordinary revision semantics.
        var covered: TimeInterval = 0
        var coveredUntil: TimeInterval = 0
        for entry in entries {
            covered += max(0, entry.end - max(entry.start, coveredUntil))
            coveredUntil = max(coveredUntil, entry.end)
        }
        return covered >= historyInterval
    }

    private mutating func retainUnaligned(_ hypothesis: String, requiresReview: Bool = false) -> String {
        hasUnalignedHypothesis = requiresReview || (hypothesis != currentText && hypothesis != latestWindowText)
        text = joining(earlierTasks, currentText)
        return text
    }

    private struct Entry: Sendable {
        let start: TimeInterval
        let end: TimeInterval
        var piece: String
    }

    private func timedEntries(_ hypothesis: String, segments: [TranscriptSegment]) -> [Entry]? {
        guard !segments.isEmpty else { return nil }
        let count = hypothesis.utf16.count
        var ranges: [Range<String.Index>] = []
        var previousRangeEnd = 0
        var previousTime: TimeInterval = -.infinity
        for segment in segments {
            guard segment.timestamp.isFinite, segment.timestamp >= 0,
                  segment.duration.isFinite, segment.duration >= 0,
                  (segment.timestamp + segment.duration).isFinite,
                  segment.timestamp >= previousTime,
                  segment.range.location >= previousRangeEnd, segment.range.location <= count,
                  segment.range.length > 0, segment.range.length <= count - segment.range.location,
                  let range = Range(segment.range, in: hypothesis) else { return nil }
            ranges.append(range)
            previousRangeEnd = segment.range.location + segment.range.length
            previousTime = segment.timestamp
        }
        // Some early hypotheses publish only zero timestamps. They do not provide
        // a temporal window boundary; leave them on ordinary replacement semantics.
        if segments.count > 1, segments.last!.timestamp - segments[0].timestamp <= 0.001 { return nil }
        if segments.count == 1, segments[0].timestamp == 0, segments[0].duration == 0 { return nil }
        return segments.enumerated().map { index, segment in
            let start = index == 0 ? hypothesis.startIndex : ranges[index].lowerBound
            let end = index + 1 < ranges.count ? ranges[index + 1].lowerBound : hypothesis.endIndex
            return Entry(start: segment.timestamp, end: segment.timestamp + segment.duration,
                         piece: String(hypothesis[start..<end]))
        }
    }

    private func joining(_ prefix: String, _ suffix: String) -> String {
        guard !prefix.isEmpty else { return suffix }
        guard !suffix.isEmpty else { return prefix }
        return prefix + ((prefix.last?.isWhitespace == true || suffix.first?.isWhitespace == true) ? "" : " ") + suffix
    }
}

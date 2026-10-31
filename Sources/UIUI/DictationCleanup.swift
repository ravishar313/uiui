import Dispatch
import Foundation
import UIUICore

protocol CleanupGenerating: Sendable {
    var isReady: Bool { get }
    func prepare() async
    func generate(_ text: String, cancellation: CleanupCancellation) async throws -> String
    func release()
    func shutdown() async
}

extension CleanupGenerating {
    func shutdown() async { release() }
}

enum CleanupFailure: Error { case unavailable }

@MainActor
protocol DictationCleaning: AnyObject {
    func prepare()
    func begin(_ id: UUID)
    func update(_ text: String, captureID: UUID)
    func finish(_ text: String, captureID: UUID) async throws -> String
    func cancel()
    func release()
    func shutdown() async
}

extension DictationCleaning {
    func shutdown() async { release() }
}

/// Event-driven prefix work amortizes long dictations while the person speaks.
/// Finalization has a fixed budget; every unprocessed or rejected segment falls
/// back to its complete original. Only the caller may copy/paste the one result.
@MainActor
final class DictationCleanup: DictationCleaning {
    private struct Cached { let source: String; let result: String }
    private let engine: any CleanupGenerating
    private let finalBudget: Duration
    private let tailDelay: Duration
    private var captureID: UUID?
    private var segments: [DictationCleanupSegment] = []
    private var cache: [Int: Cached] = [:]
    private var background: Task<Void, Never>?
    private var backgroundID: UUID?
    private struct Active {
        let index: Int
        let source: String
        let cancellation: CleanupCancellation
    }
    private var active: Active?
    private var stableTail: Task<Void, Never>?
    private var stableTailID: UUID?
    private var tailIsStable = false
    private var transcript: String?
    private var finishingCaptureID: UUID?
    private var finalCancellation: CleanupCancellation?
    private var warmup: Task<Void, Never>?
    private let memoryPressure: any DispatchSourceMemoryPressure

    init(engine: any CleanupGenerating = LocalCleanupModel.makeEngine(), finalBudget: Duration = .milliseconds(600),
         tailDelay: Duration = .milliseconds(900)) {
        self.engine = engine; self.finalBudget = finalBudget; self.tailDelay = tailDelay
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        memoryPressure = pressure
        pressure.setEventHandler { [weak self] in Task { @MainActor in self?.trimMemory() } }
        pressure.resume()
    }

    func prepare() {
        guard warmup == nil, !engine.isReady else { return }
        warmup = Task { [weak self, engine] in
            await engine.prepare()
            self?.warmup = nil
        }
    }

    func begin(_ id: UUID) {
        cancel()
        captureID = id
    }

    func update(_ text: String, captureID id: UUID) {
        guard captureID == id, finishingCaptureID != id else { return }
        if transcript != text {
            transcript = text
            segments = DictationCleanupText.segments(for: text, maximumUTF8Bytes: 450)
            cache = cache.filter { index, value in index < segments.count && segments[index].text == value.source }
            if let active, active.index >= segments.count || segments[active.index].text != active.source {
                active.cancellation.cancel()
            }
            stopStableTail()
            tailIsStable = false
            if engine.isReady, !segments.isEmpty {
                let delayID = UUID(); stableTailID = delayID
                stableTail = Task { [weak self, tailDelay] in
                    do { try await Task.sleep(for: tailDelay) } catch { return }
                    guard let self, self.captureID == id, self.stableTailID == delayID,
                          self.finishingCaptureID != id, !Task.isCancelled else { return }
                    self.stableTail = nil; self.stableTailID = nil
                    self.tailIsStable = true
                    self.startBackground(captureID: id)
                }
            }
        }
        startBackground(captureID: id)
    }

    private func startBackground(captureID id: UUID) {
        guard engine.isReady, background == nil, captureID == id, finishingCaptureID != id,
              !DictationCleanupText.isFormatted(transcript ?? "") else { return }
        let jobID = UUID(); backgroundID = jobID
        background = Task { [weak self] in
            guard let self else { return }
            defer {
                if backgroundID == jobID { background = nil; backgroundID = nil; active = nil }
            }
            while self.captureID == id, self.finishingCaptureID != id, !Task.isCancelled {
                let eligible = tailIsStable ? segments.indices : segments.indices.dropLast()
                guard let index = eligible.first(where: { self.cache[$0] == nil }) else { return }
                let source = segments[index].text
                if source.isEmpty || source.utf8.count > 900 || DictationCleanupText.accepted(source, for: source) == nil {
                    cache[index] = Cached(source: source, result: source); continue
                }
                let cancellation = CleanupCancellation(deadline: .now.advanced(by: .seconds(2)))
                active = Active(index: index, source: source, cancellation: cancellation)
                let candidate = try? await engine.generate(source, cancellation: cancellation)
                guard self.captureID == id, !Task.isCancelled, backgroundID == jobID else { return }
                active = nil
                guard index < segments.count, segments[index].text == source else { continue }
                let accepted = cancellation.isCancelled ? nil : candidate.flatMap { DictationCleanupText.accepted($0, for: source) }
                cache[index] = Cached(source: source, result: accepted ?? source)
            }
        }
    }

    func finish(_ text: String, captureID id: UUID) async throws -> String {
        try Task.checkCancellation()
        // Direct/manual typing has no preceding stream. The application checks
        // its generation before calling; this creates only that capture's cache.
        if captureID != id { begin(id) }
        let deadline = ContinuousClock.now.advanced(by: finalBudget)
        let finalSegments = DictationCleanupText.segments(for: text, maximumUTF8Bytes: 450)
        let cancellation = CleanupCancellation(deadline: deadline)
        finalCancellation = cancellation
        finishingCaptureID = id
        stopStableTail()
        defer {
            if captureID == id {
                finalCancellation = nil; finishingCaptureID = nil
                cache.removeAll(); segments.removeAll(); transcript = nil
            }
        }
        if DictationCleanupText.isFormatted(text) {
            stopBackground()
            return DictationPunctuation.finalize(text)
        }
        if let active, let background, active.index < finalSegments.count,
           finalSegments[active.index].text == active.source {
            // Await only the already-running exact source. The finishing flag
            // prevents the background loop from admitting another operation.
            active.cancellation.shortenDeadline(to: deadline)
            await withTaskCancellationHandler {
                await background.value
            } onCancel: { active.cancellation.cancel() }
            try Task.checkCancellation()
            guard captureID == id else { throw CancellationError() }
        } else { stopBackground() }
        var result = ""
        result.reserveCapacity(text.utf8.count + finalSegments.count * 4)
        for (index, segment) in finalSegments.enumerated() {
            try Task.checkCancellation()
            guard captureID == id else { throw CancellationError() }
            let source = segment.text
            let cleaned: String
            if let cached = cache[index], cached.source == source { cleaned = cached.result }
            else if engine.isReady, !cancellation.isCancelled, !source.isEmpty, source.utf8.count <= 900, DictationCleanupText.accepted(source, for: source) != nil {
                do {
                    let candidate = try await engine.generate(source, cancellation: cancellation)
                    try Task.checkCancellation()
                    guard captureID == id else { throw CancellationError() }
                    cleaned = DictationCleanupText.accepted(candidate, for: source) ?? source
                } catch {
                    try Task.checkCancellation()
                    guard captureID == id else { throw CancellationError() }
                    cleaned = source
                }
            } else { cleaned = source }
            result += cleaned + segment.separator
        }
        try Task.checkCancellation()
        guard captureID == id else { throw CancellationError() }
        return DictationPunctuation.finalize(result)
    }

    private func stopStableTail() {
        stableTail?.cancel(); stableTail = nil; stableTailID = nil
    }

    private func stopBackground() {
        active?.cancellation.cancel(); active = nil
        background?.cancel(); background = nil; backgroundID = nil
    }

    func cancel() {
        // This is synchronous even if Metal is completing a kernel. The caller
        // immediately invalidates delivery; native work checks at each decode.
        captureID = nil; finishingCaptureID = nil; transcript = nil; tailIsStable = false
        stopStableTail()
        stopBackground()
        finalCancellation?.cancel(); finalCancellation = nil
        cache.removeAll(); segments.removeAll()
    }

    private func trimMemory() {
        stopStableTail()
        stopBackground()
        finalCancellation?.cancel()
        cache.removeAll(); segments.removeAll()
        warmup?.cancel(); warmup = nil
        engine.release()
    }
    func release() { cancel(); trimMemory() }
    func shutdown() async { release(); await engine.shutdown() }
    deinit { memoryPressure.cancel() }
}

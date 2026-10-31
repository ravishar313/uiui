import Foundation
import XCTest
import UIUICore
@testable import UIUI

final class NotchSignalPolicyTests: XCTestCase {
    private func snapshot(elapsed: TimeInterval = 0, peak: Float = 0, deadFor: TimeInterval = 0,
                          text: Bool = false, paused: Bool = false) -> NotchSignalPolicy.Snapshot {
        .init(elapsed: elapsed, peakLevel: peak, secondsSinceSignal: nil, deadFor: deadFor, hasTranscript: text, isPaused: paused)
    }

    func testSilentStartWarnsOnlyAfterGrace() {
        XCTAssertFalse(NotchSignalPolicy.cannotHear(snapshot(elapsed: 2.9, peak: 0.002)))
        XCTAssertTrue(NotchSignalPolicy.cannotHear(snapshot(elapsed: 3.0, peak: 0.002)))
    }

    func testSpeechOrWordsPreventStartWarning() {
        XCTAssertFalse(NotchSignalPolicy.cannotHear(snapshot(elapsed: 10, peak: 0.05)))
        XCTAssertFalse(NotchSignalPolicy.cannotHear(snapshot(elapsed: 10, peak: 0.002, text: true)))
    }

    func testNormalPauseAfterSpeakingNeverWarns() {
        // A live microphone keeps a noise floor above the dead threshold.
        var monitor = NotchSignalMonitor()
        monitor.begin(at: 0)
        monitor.hasTranscript = true
        monitor.record(level: 0.08, at: 0.5)
        for tenth in 6...400 { monitor.record(level: 0.0015, at: Double(tenth) / 10) } // 40 s of quiet room
        XCTAssertFalse(NotchSignalPolicy.cannotHear(monitor.snapshot(at: 40)))
    }

    func testDeadInputAfterSpeechWarnsAndClearsOnSignal() {
        var monitor = NotchSignalMonitor()
        monitor.begin(at: 0)
        monitor.hasTranscript = true
        monitor.record(level: 0.08, at: 1)
        for tenth in 11...50 { monitor.record(level: 0.00001, at: Double(tenth) / 10) }
        XCTAssertFalse(NotchSignalPolicy.cannotHear(monitor.snapshot(at: 4.0)), "Not yet 4 s of dead input")
        XCTAssertTrue(NotchSignalPolicy.cannotHear(monitor.snapshot(at: 5.2)))
        monitor.record(level: 0.05, at: 5.1)
        XCTAssertFalse(NotchSignalPolicy.cannotHear(monitor.snapshot(at: 5.1)), "A returning signal clears the hint")
    }

    func testPausedTimeDoesNotCountAndNeverWarns() {
        var monitor = NotchSignalMonitor()
        monitor.begin(at: 0)
        monitor.setPaused(true, at: 1)
        XCTAssertFalse(NotchSignalPolicy.cannotHear(monitor.snapshot(at: 30)))
        monitor.setPaused(false, at: 30)
        XCTAssertEqual(monitor.snapshot(at: 30).elapsed, 1, accuracy: 0.001)
        XCTAssertFalse(NotchSignalPolicy.cannotHear(monitor.snapshot(at: 31)))
        XCTAssertTrue(NotchSignalPolicy.cannotHear(monitor.snapshot(at: 33.1)), "The 3 s grace counts only unpaused time")
    }

    func testTimerAppearsOnlyAfterThirtySeconds() {
        XCTAssertFalse(NotchTimerPolicy.isVisible(elapsed: 29.9))
        XCTAssertTrue(NotchTimerPolicy.isVisible(elapsed: 30))
        XCTAssertEqual(NotchTimerPolicy.text(72), "1:12")
        XCTAssertEqual(NotchTimerPolicy.text(5), "0:05")
    }

    func testMicHintOnlyForNonBuiltInInput() {
        XCTAssertNil(NotchMicHintPolicy.text(deviceName: "MacBook Pro Microphone", isBuiltIn: true))
        XCTAssertNil(NotchMicHintPolicy.text(deviceName: nil, isBuiltIn: false))
        XCTAssertNil(NotchMicHintPolicy.text(deviceName: "  ", isBuiltIn: false))
        XCTAssertEqual(NotchMicHintPolicy.text(deviceName: "AirPods Pro", isBuiltIn: false), "Mic: AirPods Pro")
    }

    func testPasteFailureNamesTheDestinationWhenKnown() {
        XCTAssertEqual(NotchPasteFailureText.copied(appName: "Slack"), "Copied, press ⌘V in Slack")
        XCTAssertEqual(NotchPasteFailureText.copied(appName: nil), "Copied, press ⌘V")
        XCTAssertEqual(NotchPasteFailureText.copied(appName: " "), "Copied, press ⌘V")
    }
}

final class NotchUndoPolicyTests: XCTestCase {
    func testAvailableOnlyForSameAppSameCaptureWithinWindow() {
        let id = UUID()
        func available(sent: UUID? = id, current: UUID = id, active: Bool = false,
                       target: pid_t? = 10, front: pid_t? = 10, now: TimeInterval = 1, deadline: TimeInterval? = 3.5) -> Bool {
            NotchUndoPolicy.isAvailable(sentCaptureID: sent, currentCaptureID: current, captureActive: active,
                                        targetPID: target, frontmostPID: front, now: now, deadline: deadline)
        }
        XCTAssertTrue(available())
        XCTAssertFalse(available(front: 11), "Another app in front")
        XCTAssertFalse(available(current: UUID()), "A newer capture started")
        XCTAssertFalse(available(active: true))
        XCTAssertFalse(available(target: nil))
        XCTAssertFalse(available(sent: nil))
        XCTAssertFalse(available(now: 4))
    }
}

final class NotchPlacementTests: XCTestCase {
    private let notched = NotchPlacement.Screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944), safeAreaTop: 38, isMain: true)
    private let external = NotchPlacement.Screen(frame: CGRect(x: 1512, y: 100, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1512, y: 100, width: 2560, height: 1415), safeAreaTop: 0, isMain: false)

    func testNotchedDisplayWinsAndSitsAtTheVeryTop() throws {
        let placement = try XCTUnwrap(NotchPlacement.decide(screens: [external, notched]))
        XCTAssertEqual(placement.screenIndex, 1)
        XCTAssertEqual(placement.shape, .cameraNotch)
        XCTAssertEqual(placement.topEdge, 982)
        XCTAssertEqual(placement.frame(size: CGSize(width: 300, height: 40)), CGRect(x: 606, y: 942, width: 300, height: 40))
    }

    func testExternalOnlyGetsACenteredPillBelowTheMenuBar() throws {
        let placement = try XCTUnwrap(NotchPlacement.decide(screens: [external]))
        XCTAssertEqual(placement.shape, .floatingPill)
        XCTAssertEqual(placement.topEdge, 1515 - NotchPlacement.pillGapBelowMenuBar)
        let frame = placement.frame(size: CGSize(width: 200, height: 38))
        XCTAssertEqual(frame.midX, 1512 + 1280)
        XCTAssertLessThan(frame.maxY, 1515, "Fully below the menu bar")
    }

    func testNotchlessMacUsesTheMainDisplay() throws {
        var main = external; main.isMain = true
        var other = external; other.isMain = false; other.frame.origin.x = 9_000
        let placement = try XCTUnwrap(NotchPlacement.decide(screens: [other, main]))
        XCTAssertEqual(placement.screenIndex, 1)
        XCTAssertEqual(placement.shape, .floatingPill)
        XCTAssertNil(NotchPlacement.decide(screens: []))
    }

    func testPillNeverCarriesACameraAndMatchesLayout() {
        let size = NotchLayout.closedSize(cameraWidth: 0, cameraHeight: 0, hasCamera: false)
        XCTAssertEqual(size.width, NotchSize.standard.closedWidthWithoutCamera)
        let geometry = NotchMosaicGeometry(size: size, hasCamera: false, cameraWidth: 0, cameraHeight: 0)
        XCTAssertNil(geometry.cameraRect)
    }
}

final class NotchLayoutExtrasTests: XCTestCase {
    func testHoverTranscriptOnlyGrowsARecording() {
        let base = NotchLayout.surfaceSize(phase: .recording, cameraWidth: 220, cameraHeight: 38, hasCamera: true, expanded: true)
        let open = NotchLayout.surfaceSize(phase: .recording, cameraWidth: 220, cameraHeight: 38, hasCamera: true,
                                           expanded: true, transcriptOpen: true)
        XCTAssertEqual(open.height - base.height, NotchLayout.hoverTranscriptExtra)
        XCTAssertEqual(open.width, base.width)
        for phase in [NotchFeedbackPhase.processing, .dispatched, .copied, .idle] {
            XCTAssertEqual(NotchLayout.surfaceSize(phase: phase, cameraWidth: 220, cameraHeight: 38, hasCamera: true,
                                                   expanded: true, transcriptOpen: true),
                           NotchLayout.surfaceSize(phase: phase, cameraWidth: 220, cameraHeight: 38, hasCamera: true, expanded: true))
        }
        XCTAssertGreaterThanOrEqual(NotchLayout.expandedHeight(cameraHeight: 38, transcriptOpen: true), open.height)
    }
}

final class NotchNativeStylesTests: XCTestCase {
    func testRetiredStylesFallBackToMosaic() throws {
        XCTAssertEqual(NotchVisualStyle.allCases, [.mosaic, .eyes, .bars, .words])
        for value in ["liquid", "ribbon", "future", ""] {
            let data = try JSONSerialization.data(withJSONObject: ["notchVisualStyle": value, "quietMode": true])
            let restored = try JSONDecoder().decode(UIUISettings.self, from: data)
            XCTAssertEqual(restored.notchVisualStyle, .mosaic)
            XCTAssertTrue(restored.quietMode)
        }
        XCTAssertEqual(NotchVisualStyle(stored: "bars"), .bars)
    }

    func testBlinkIsOccasionalAndBounded() {
        var closedSamples = 0
        let samples = 12_000
        for index in 0..<samples {
            let open = NotchEyeMotion.openness(time: Double(index) * 0.005)
            XCTAssertGreaterThanOrEqual(open, 0)
            XCTAssertLessThanOrEqual(open, 1)
            if open < 0.5 { closedSamples += 1 }
        }
        XCTAssertGreaterThan(closedSamples, 0, "The eyes do blink")
        XCTAssertLessThan(Double(closedSamples) / Double(samples), 0.08, "Blinks stay occasional")
        XCTAssertEqual(NotchEyeMotion.openness(time: 0), 1)
    }

    func testEyePosesFollowTheStates() {
        func pose(_ phase: NotchFeedbackPhase, audio: Double = 0.5, progress: Double = 1, paused: Bool = false, glance: Double = 0) -> NotchNativeDrawing.EyePose {
            NotchNativeDrawing.eyePose(phase: phase, time: 0, progress: progress, audio: audio, paused: paused, glance: glance, reduceMotion: true)
        }
        XCTAssertGreaterThan(pose(.recording, audio: 1).open, pose(.recording, audio: 0).open, "Eyes grow with the voice")
        XCTAssertLessThan(pose(.processing).open, 0.4, "Squint while processing")
        XCTAssertLessThan(pose(.dispatched, progress: 1).open, 0.1, "Closed on send")
        XCTAssertGreaterThan(pose(.cancelled, progress: 1).droop, 0.5, "Droop on cancel")
        XCTAssertGreaterThan(pose(.recording, glance: 1).drop, pose(.recording, glance: 0).drop, "Glance toward the text")
        XCTAssertLessThan(pose(.recording, paused: true).open, 0.4)
    }

    func testBarsFollowRealLevelsAndSettle() {
        let loud = Array(repeating: 1.0, count: NotchNativeDrawing.barCount)
        let quiet = Array(repeating: 0.0, count: NotchNativeDrawing.barCount)
        let up = NotchNativeDrawing.barHeights(phase: .recording, time: 0, progress: 1, bars: loud, paused: false, header: 38).heights
        let down = NotchNativeDrawing.barHeights(phase: .recording, time: 0, progress: 1, bars: quiet, paused: false, header: 38).heights
        XCTAssertTrue(zip(up, down).allSatisfy { $0 > $1 })
        let sent = NotchNativeDrawing.barHeights(phase: .dispatched, time: 0, progress: 1, bars: loud, paused: false, header: 38).heights
        for (a, b) in zip(sent, down) { XCTAssertEqual(a, b, accuracy: 0.0001, "Settles to baseline on send") }
        let a = NotchNativeDrawing.barHeights(phase: .processing, time: 0.1, progress: 1, bars: quiet, paused: false, header: 38).heights
        let b = NotchNativeDrawing.barHeights(phase: .processing, time: 0.6, progress: 1, bars: quiet, paused: false, header: 38).heights
        XCTAssertNotEqual(a, b, "A shimmer travels while processing")
    }

    func testLevelHistoryDelaysBarsAndSmooths() {
        var history = NotchLevelHistory()
        history.append(0, at: 10.0)
        history.append(1, at: 10.1)
        let now = 10.25
        XCTAssertEqual(history.value(at: now, delay: 0), 1, accuracy: 0.001)
        XCTAssertLessThan(history.value(at: now, delay: 0.15), 0.6, "A later bar still shows the earlier, quieter moment")
        XCTAssertEqual(history.value(at: 10.0, delay: 0), 0, accuracy: 0.001)
        history.append(0.5, at: 12)
        XCTAssertEqual(history.samples.count, 1, "Old samples are dropped")
    }

    func testWordsFadeFromAccentToWhite() {
        XCTAssertEqual(NotchWordsText.recency(index: 9, count: 10), 1)
        XCTAssertEqual(NotchWordsText.recency(index: 0, count: 10), 0)
        XCTAssertGreaterThan(NotchWordsText.recency(index: 8, count: 10), NotchWordsText.recency(index: 6, count: 10))
        XCTAssertEqual(String(NotchWordsText.attributed("one two  three").characters), "one two three")
    }

    func testAnnouncementsNeverContainTranscript() {
        XCTAssertEqual(NotchAnnouncement.resolve(phase: .recording, paused: false, cannotHear: false), .listening)
        XCTAssertEqual(NotchAnnouncement.resolve(phase: .recording, paused: true, cannotHear: false), .paused)
        XCTAssertEqual(NotchAnnouncement.resolve(phase: .recording, paused: false, cannotHear: true), .cannotHear)
        XCTAssertEqual(NotchAnnouncement.resolve(phase: .processing, paused: false, cannotHear: false), .processing)
        XCTAssertEqual(NotchAnnouncement.resolve(phase: .dispatched, paused: false, cannotHear: false), .sent)
        XCTAssertNil(NotchAnnouncement.resolve(phase: .idle, paused: false, cannotHear: false))
        XCTAssertEqual(NotchAnnouncement.cannotHear.text, "Can't hear you")
    }

    func testUndoReceiptKeepsFastIlluminationButHoldsTheState() {
        XCTAssertEqual(NotchFeedbackTiming.pasteAnimationSeconds, 0.46)
        XCTAssertEqual(NotchFeedbackTiming.pasteDwell, .milliseconds(650))
        XCTAssertEqual(NotchFeedbackTiming.undoDwell, .seconds(3))
    }

    @MainActor
    func testUndoReceiptExpiresAtThreeSecondsNotSooner() async {
        var clock: TimeInterval = 100
        var expired: [UUID] = []
        let lifetime = NotchFeedbackLifetime(now: { clock }, sleep: { _ in }, onExpiry: { id, _ in expired.append(id); return true })
        var receipt = VoiceActionFeedback(state: .information, title: "Paste sent", detail: "", presentation: .pasteDispatch)
        receipt.offersUndo = true
        lifetime.update(feedback: receipt, busy: true)
        clock = 102.9
        lifetime.update(feedback: receipt, busy: true)
        XCTAssertTrue(expired.isEmpty, "Still within the 3 s undo window")
        clock = 103.1
        lifetime.update(feedback: receipt, busy: false)
        XCTAssertEqual(expired, [receipt.id])
    }
}

// MARK: Pause and resume inside one capture

final class NotchPauseTests: XCTestCase {
    @MainActor
    private func fixture() async throws -> (AppModel, PauseCapture, PauseDelivery) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uiui-pause-\(UUID().uuidString)")
        let suite = "uiui-pause-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let capture = PauseCapture()
        let voice = TriggeredVoice(capture: capture)
        let delivery = PauseDelivery()
        let model = AppModel(dataDirectory: root, defaults: defaults, persistSettings: false,
                             delivery: delivery, cleanup: PauseCleanup(), voice: voice)
        voice.onTrigger = {}
        voice.onRecordingSound = nil
        await model.start(installSystemServices: false)
        model.captureEnabled = true
        model.settings.saveDictationHistory = false
        addTeardownBlock {
            await MainActor.run { model.shutdown() }
            try? FileManager.default.removeItem(at: root)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return (model, capture, delivery)
    }

    @MainActor
    private func startCapture(_ model: AppModel, _ capture: PauseCapture) async throws {
        model.beginVoiceCapture()
        for _ in 0..<2_000 where capture.startCount == 0 { await Task.yield() }
        capture.resumeStart()
        for _ in 0..<2_000 where model.voice.state != "capturing" { await Task.yield() }
        XCTAssertEqual(model.voice.state, "capturing")
    }

    @MainActor
    func testPauseHoldsTheSameCaptureAndKeepsItsTranscript() async throws {
        let (model, capture, _) = try await fixture()
        try await startCapture(model, capture)
        capture.onPartial?("first part")
        let generation = model.dictationCaptureGeneration
        XCTAssertTrue(model.canPauseVoiceCapture)
        model.pauseVoiceCapture()
        XCTAssertTrue(model.voice.isPaused)
        XCTAssertTrue(capture.paused)
        XCTAssertEqual(model.notchFeedbackPhase, .recording)
        XCTAssertEqual(model.voiceTranscript, "first part", "Transcript preserved")
        XCTAssertEqual(model.dictationCaptureGeneration, generation, "Same capture")
        XCTAssertEqual(capture.startCount, 1)
        capture.onAudioLevel?(0.4)
        XCTAssertEqual(model.voiceLevel, 0, "No level reaches the notch while paused")
        model.toggleVoicePause()
        XCTAssertFalse(model.voice.isPaused)
        XCTAssertFalse(capture.paused)
        capture.onPartial?("first part and more")
        XCTAssertEqual(model.voiceTranscript, "first part and more")
        XCTAssertEqual(model.dictationCaptureGeneration, generation)
    }

    @MainActor
    func testPauseThenFinishDeliversExactlyOnce() async throws {
        let (model, capture, delivery) = try await fixture()
        try await startCapture(model, capture)
        capture.onPartial?("words before the pause")
        model.pauseVoiceCapture()
        model.finishVoiceCapture()
        XCTAssertFalse(model.voice.isPaused, "Finishing ends the pause")
        XCTAssertEqual(capture.stopCount, 1)
        capture.emitFinal("words before the pause")
        capture.emitFinal("words before the pause")
        for _ in 0..<2_000 where delivery.delivered.isEmpty { await Task.yield() }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(delivery.delivered, ["words before the pause"])
    }

    @MainActor
    func testCancelWhilePausedReleasesEverythingWithoutDelivery() async throws {
        let (model, capture, delivery) = try await fixture()
        try await startCapture(model, capture)
        capture.onPartial?("never sent")
        model.pauseVoiceCapture()
        model.cancelVoiceInputFromEscape()
        XCTAssertFalse(model.voice.isPaused)
        XCTAssertFalse(model.canPauseVoiceCapture)
        XCTAssertGreaterThanOrEqual(capture.cancelCount, 1)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertTrue(delivery.delivered.isEmpty)
    }

    @MainActor
    func testPauseIsIgnoredWhenNothingIsCapturing() async throws {
        let (model, capture, _) = try await fixture()
        model.pauseVoiceCapture()
        XCTAssertFalse(model.voice.isPaused)
        XCTAssertEqual(capture.pauseCalls, 0)
        XCTAssertFalse(model.canPauseVoiceCapture)
    }

    @MainActor
    func testUndoWithoutAnOfferIsUnavailableAndSendsNothing() async throws {
        let (model, _, delivery) = try await fixture()
        XCTAssertFalse(model.notchUndoAvailable)
        model.undoLastPaste()
        XCTAssertEqual(delivery.undoCount, 0)
        XCTAssertEqual(model.dictationFeedback?.title, "Undo unavailable")
    }

    @MainActor
    func testSuccessfulPasteReceiptOffersUndoAndCopy() async throws {
        let (model, capture, delivery) = try await fixture()
        try await startCapture(model, capture)
        capture.onPartial?("hello there")
        model.finishVoiceCapture()
        capture.emitFinal("hello there")
        for _ in 0..<2_000 where model.dictationFeedback?.presentation != .pasteDispatch { await Task.yield() }
        XCTAssertEqual(model.dictationFeedback?.presentation, .pasteDispatch)
        XCTAssertEqual(model.dictationFeedback?.offersUndo, true)
        XCTAssertEqual(delivery.delivered, ["hello there"])
        XCTAssertEqual(delivery.undoCount, 0, "Nothing is undone automatically")
    }
}

@MainActor
private final class PauseCapture: TriggeredVoiceCapture {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onCompletion: ((SpeechCompletion) -> Void)?
    var onError: ((String) -> Void)?
    var onRecovery: ((String) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onFinalization: ((Double) -> Void)?
    private var startup: CheckedContinuation<Void, Error>?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    private(set) var pauseCalls = 0
    private(set) var paused = false

    func requestAuthorization() async -> Bool { true }
    func start(locale: String, contextualStrings: [String]) async throws {
        startCount += 1
        try await withCheckedThrowingContinuation { startup = $0 }
        try Task.checkCancellation()
    }
    func resumeStart() { let pending = startup; startup = nil; pending?.resume() }
    func stop() { stopCount += 1 }
    func cancel() {
        cancelCount += 1
        let pending = startup; startup = nil; pending?.resume(throwing: CancellationError())
    }
    func setPaused(_ value: Bool) -> Bool { pauseCalls += 1; paused = value; return true }
    func emitFinal(_ text: String) {
        onCompletion?(SpeechCompletion(text: text, reason: .final, wasExplicitlyStopped: true))
    }
}

@MainActor
private final class PauseDelivery: TextDelivering {
    private(set) var delivered: [String] = []
    private(set) var undoCount = 0
    func deliver(_ text: String, to target: DeliveryTarget?) async -> DeliveryResult { delivered.append(text); return .pasteSent }
    func cancel() {}
    func undoPaste(to target: DeliveryTarget) -> Bool { undoCount += 1; return true }
}

@MainActor
private final class PauseCleanup: DictationCleaning {
    func prepare() {}
    func begin(_ id: UUID) {}
    func update(_ text: String, captureID: UUID) {}
    func finish(_ text: String, captureID: UUID) async throws -> String { text }
    func cancel() {}
    func release() {}
}

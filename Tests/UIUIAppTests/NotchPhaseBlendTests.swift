import XCTest
@testable import UIUI

final class NotchPhaseBlendTests: XCTestCase {
    func testShortHandoffsUseSmootherCadenceWithoutRaisingSteadyOrIdleBudget() {
        for phase in [NotchFeedbackPhase.recording, .processing] {
            XCTAssertEqual(NotchMosaicMetrics.preferredFrameInterval(phase: phase, blending: false, settled: false), 1.0 / 30.0)
            XCTAssertEqual(NotchMosaicMetrics.preferredFrameInterval(phase: phase, blending: true, settled: false), 1.0 / 60.0)
        }
        for phase in [NotchFeedbackPhase.dispatched, .cancelled] {
            XCTAssertEqual(NotchMosaicMetrics.preferredFrameInterval(phase: phase, blending: false, settled: false), 1.0 / 60.0)
            XCTAssertEqual(NotchMosaicMetrics.preferredFrameInterval(phase: phase, blending: false, settled: true), 1.0 / 30.0)
            XCTAssertFalse(NotchMosaicMetrics.requestsFrames(phase: phase, elapsed: 1, reduceMotion: false))
        }
        XCTAssertEqual(NotchMosaicMetrics.preferredFrameInterval(phase: .idle, blending: true, settled: false), 1.0 / 30.0)
        XCTAssertFalse(NotchMosaicMetrics.requestsFrames(phase: .idle, elapsed: 0, reduceMotion: false))
    }

    func testRapidProcessingThenSendRetainsTheVisibleRecordingMixture() {
        var blend = NotchPhaseBlend()
        blend.transition(phase: .recording, style: .mosaic, eventStartedAt: 0,
                         at: 0, audio: 0.8, fieldTime: 40, immediate: false)
        blend.transition(phase: .processing, style: .mosaic, eventStartedAt: 1,
                         at: 1, audio: 0.8, fieldTime: 41, immediate: false)
        let beforeSend = blend.layers(at: 1.04, audio: 0.4, fieldTime: 41.04)
        XCTAssertEqual(beforeSend.count, 2)
        blend.transition(phase: .dispatched, style: .mosaic, eventStartedAt: 1.04,
                         at: 1.04, audio: 0.4, fieldTime: 41.04, immediate: false)
        let afterSend = blend.layers(at: 1.04, audio: 0, fieldTime: 41.04)
        XCTAssertEqual(afterSend.count, 2, "A new receipt must retain both in-flight phase fields")
        for phase in [NotchFeedbackPhase.recording, .processing] {
            let before = beforeSend.first { $0.drawing.phase == phase }
            let after = afterSend.first { $0.drawing.phase == phase }
            XCTAssertEqual(before?.weight ?? -1, after?.weight ?? -2, accuracy: 0.00001)
            XCTAssertEqual(before?.drawing.time ?? -1, after?.drawing.time ?? -2, accuracy: 0.00001)
            XCTAssertEqual(before?.drawing.audio ?? -1, after?.drawing.audio ?? -2, accuracy: 0.00001)
        }
        let during = blend.layers(at: 1.08, audio: 0, fieldTime: 41.08)
        XCTAssertEqual(during.count, 3)
        XCTAssertGreaterThan(during.first { $0.drawing.phase == .recording }?.weight ?? 0, 0)
        XCTAssertEqual(during.reduce(0) { $0 + $1.weight }, 1, accuracy: 0.00001)
        let settled = blend.layers(at: 1.17, audio: 0, fieldTime: 41.17)
        XCTAssertEqual(settled.count, 1)
        XCTAssertEqual(settled.first?.drawing.phase, .dispatched)
    }

    func testStyleChangeKeepsExistingReceiptProgressAndFieldTime() {
        var blend = NotchPhaseBlend()
        blend.transition(phase: .dispatched, style: .mosaic, eventStartedAt: 10,
                         at: 10, audio: 0, fieldTime: 50, immediate: true)
        blend.transition(phase: .dispatched, style: .eyes, eventStartedAt: 10,
                         at: 10.2, audio: 0, fieldTime: 50.2, immediate: false)
        let layers = blend.layers(at: 10.33, audio: 0, fieldTime: 50.33)
        XCTAssertEqual(layers.count, 1)
        XCTAssertEqual(layers.first?.drawing.style, .eyes)
        XCTAssertEqual(layers.first?.drawing.progress ?? 0, 0.33 / 0.46, accuracy: 0.00001)
        XCTAssertEqual(layers.first?.drawing.time ?? 0, 50.33, accuracy: 0.00001)
    }

    func testTerminalEnvelopeKillsAllRetainedFieldsAtExistingDeadlines() {
        for (phase, deadline) in [(NotchFeedbackPhase.dispatched, 0.46), (.cancelled, 0.26)] {
            let before = NotchMosaicMetrics.progress(phase: phase, elapsed: deadline - 0.001)
            let terminal = NotchMosaicMetrics.progress(phase: phase, elapsed: deadline)
            XCTAssertGreaterThan(NotchPhaseBlend.terminalEnvelope(phase: phase, progress: before), 0)
            XCTAssertEqual(NotchPhaseBlend.terminalEnvelope(phase: phase, progress: terminal), 0)
        }
        XCTAssertEqual(NotchPhaseBlend.terminalEnvelope(phase: .idle, progress: 0), 0)
    }

    func testTransitionBurstKeepsDrawingBudgetBoundedAndWeightsNormalized() {
        var blend = NotchPhaseBlend()
        let phases: [NotchFeedbackPhase] = [.recording, .processing, .dispatched, .preparing, .recording, .processing]
        for (index, phase) in phases.enumerated() {
            let time = Double(index) * 0.02
            blend.transition(phase: phase, style: index.isMultiple(of: 2) ? .mosaic : .bars,
                             eventStartedAt: time, at: time, audio: 0.6,
                             fieldTime: 20 + time, immediate: false)
            let layers = blend.layers(at: time + 0.01, audio: 0.6, fieldTime: 20 + time + 0.01)
            XCTAssertLessThanOrEqual(layers.count, NotchPhaseBlend.maximumStates)
            XCTAssertEqual(layers.reduce(0) { $0 + $1.weight }, 1, accuracy: 0.00001)
        }
    }

    func testReducedMotionImmediateTransitionRetainsNoPriorFieldsOrBlendClock() {
        var blend = NotchPhaseBlend()
        blend.transition(phase: .recording, style: .eyes, eventStartedAt: 0,
                         at: 0, audio: 0.8, fieldTime: 1, immediate: false)
        blend.transition(phase: .cancelled, style: .eyes, eventStartedAt: 1,
                         at: 1, audio: 0, fieldTime: 0, immediate: true)
        XCTAssertFalse(blend.isBlending(at: 1))
        let layers = blend.layers(at: 1.26, audio: 0, fieldTime: 0)
        XCTAssertEqual(layers.count, 1)
        XCTAssertEqual(layers.first?.drawing.phase, .cancelled)
        XCTAssertEqual(layers.first?.drawing.time, 0)
    }
}

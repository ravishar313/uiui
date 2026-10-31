import Foundation
import XCTest
@testable import UIUI

final class NotchPresentationTests: XCTestCase {
    @MainActor
    func testCopiedFallbackRetainsItsMeaningAndRealCaptureFailureWins() throws {
        let suite = "uiui-mosaic-projection-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(defaults: defaults, persistSettings: false, cleanup: PresentationCleanup())
        defer { model.shutdown(); defaults.removePersistentDomain(forName: suite) }
        model.dictationDeliveryIssue = "Synthetic destination is not editable"
        model.dictationFeedback = VoiceActionFeedback(state: .needsInput, title: "Synthetic copied receipt",
            detail: "Synthetic destination", presentation: .copiedOnly)
        XCTAssertEqual(model.notchFeedbackPhase, .copied)
        model.manualVoiceIssue = "Synthetic microphone failure"
        XCTAssertEqual(model.notchFeedbackPhase, .needsInput)
        model.manualVoiceIssue = nil
        model.queuedVoiceCaptureKind = .dictation
        XCTAssertEqual(model.notchFeedbackPhase, .queued)
        XCTAssertEqual(model.notchAudioLevel, 0)
        model.queuedVoiceCaptureKind = nil
        model.voiceCaptureRequested = true
        XCTAssertEqual(model.notchFeedbackPhase, .preparing, "Old receipts must not imply a new microphone is ready")
        model.manualVoiceIssue = "Retained manual capture failure"
        model.cancelVoiceInputFromEscape()
        XCTAssertEqual(model.notchFeedbackPhase, .cancelled)
        XCTAssertNil(model.manualVoiceIssue)
    }

    func testPhysicalCameraCoordinatesSurviveAllSurfaceMorphs() throws {
        let phases: [NotchFeedbackPhase] = [.idle, .preparing, .recording, .processing, .queued,
            .dispatched, .copied, .needsInput, .cancelled, .success, .message]
        let hostWidth: CGFloat = 368
        for phase in phases {
            for expanded in [false, true] {
                let size = NotchLayout.surfaceSize(phase: phase, cameraWidth: 220, cameraHeight: 38,
                    hasCamera: true, expanded: expanded)
                let geometry = NotchMosaicGeometry(size: size, hasCamera: true, cameraWidth: 220, cameraHeight: 38)
                let camera = try XCTUnwrap(geometry.cameraRect)
                XCTAssertEqual(camera.minX + (hostWidth - size.width) / 2, 74)
                XCTAssertEqual(camera.minY, 0)
                XCTAssertEqual(camera.width, 220)
                XCTAssertEqual(camera.height, 38)
                XCTAssertLessThanOrEqual(size.width, hostWidth)
                XCTAssertLessThanOrEqual(size.height, 65)
            }
        }
        let recording = NotchLayout.surfaceSize(phase: .recording, cameraWidth: 220, cameraHeight: 38,
            hasCamera: true, expanded: true)
        XCTAssertEqual(recording, CGSize(width: 368, height: 65))
        XCTAssertGreaterThanOrEqual(recording.height - 38, 27, "Keep the one-line live transcript below the hardware")
    }

    func testWholeVoiceCycleKeepsOneFootprintAcrossQuickStateHandoffs() {
        let phases: [NotchFeedbackPhase] = [.preparing, .recording, .processing, .queued, .dispatched, .cancelled]
        for (width, height, camera) in [(CGFloat(220), CGFloat(38), true), (180, 36, true), (0, 0, false)] {
            let listening = NotchLayout.surfaceSize(phase: .recording, cameraWidth: width,
                cameraHeight: height, hasCamera: camera, expanded: true)
            for phase in phases {
                XCTAssertEqual(NotchLayout.surfaceSize(phase: phase, cameraWidth: width,
                    cameraHeight: height, hasCamera: camera, expanded: true), listening,
                    "Fast cleanup must not cause shrink-expand-shrink between phases")
            }
        }
    }

    func testNoCameraSurfaceDoesNotReserveAnInvisibleCamera() {
        let collapsed = NotchLayout.surfaceSize(phase: .idle, cameraWidth: 220, cameraHeight: 38,
            hasCamera: false, expanded: false)
        let recording = NotchLayout.surfaceSize(phase: .recording, cameraWidth: 220, cameraHeight: 38,
            hasCamera: false, expanded: true)
        XCTAssertEqual(collapsed, CGSize(width: 180, height: 38))
        XCTAssertEqual(recording, CGSize(width: 360, height: 59))
    }

    func testNotchSizeGrowsTheWingsButKeepsTheCameraCovered() throws {
        var previous: (closed: CGSize, open: CGSize)?
        for size in NotchSize.allCases {
            let closed = NotchLayout.surfaceSize(phase: .idle, cameraWidth: 220, cameraHeight: 38,
                hasCamera: true, expanded: false, size: size)
            let open = NotchLayout.surfaceSize(phase: .recording, cameraWidth: 220, cameraHeight: 38,
                hasCamera: true, expanded: true, size: size)
            let geometry = NotchMosaicGeometry(size: open, hasCamera: true, cameraWidth: 220, cameraHeight: 38)
            let camera = try XCTUnwrap(geometry.cameraRect)
            XCTAssertEqual(camera.width, 220)
            XCTAssertEqual(camera.midX, open.width / 2)
            XCTAssertGreaterThan(closed.width, 220)
            XCTAssertEqual(closed.height, 41, "The closed notch stays flush with the hardware")
            XCTAssertGreaterThanOrEqual(open.height - 38, size.rowHeight + 9)
            // The window always fits the drawn surface.
            XCTAssertGreaterThanOrEqual(NotchLayout.expandedWidth(cameraWidth: 220, hasCamera: true, size: size), open.width)
            XCTAssertGreaterThanOrEqual(NotchLayout.expandedHeight(cameraHeight: 38, size: size), open.height)
            if let previous {
                XCTAssertGreaterThan(closed.width, previous.closed.width)
                XCTAssertGreaterThan(open.width, previous.open.width)
                XCTAssertGreaterThan(open.height, previous.open.height)
            }
            previous = (closed, open)
        }
        XCTAssertEqual(NotchLayout.surfaceSize(phase: .recording, cameraWidth: 220, cameraHeight: 38,
            hasCamera: true, expanded: true, size: .standard), CGSize(width: 368, height: 65), "Standard is unchanged")
    }
}

@MainActor
private final class PresentationCleanup: DictationCleaning {
    func prepare() {}
    func begin(_ id: UUID) {}
    func update(_ text: String, captureID: UUID) {}
    func finish(_ text: String, captureID: UUID) async throws -> String { text }
    func cancel() {}
    func release() {}
}

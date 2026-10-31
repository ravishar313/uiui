import AppKit
import SwiftUI
import XCTest
@testable import UIUI

final class WorkspaceWindowLifetimeTests: XCTestCase {
    @MainActor
    private func makeModel() throws -> AppModel {
        let suite = "uiui-workspace-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(defaults: defaults, persistSettings: false, cleanup: WorkspaceNoopCleanup(),
                             voice: TriggeredVoice(capture: SpeechCapture()))
        addTeardownBlock {
            await MainActor.run { model.shutdown(); UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        }
        return model
    }

    @MainActor
    private func makeLifetime(model: AppModel) -> WorkspaceWindowLifetime {
        _ = NSApplication.shared
        return WorkspaceWindowLifetime(model: model) {
            // Offscreen only: no presentation, event monitors, microphone,
            // recognizer, clipboard, or library access belongs to these tests.
            let window = NSWindow(contentRect: NSRect(x: 20, y: 30, width: 760, height: 580),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: Text("Synthetic history"))
            return window
        }
    }

    @MainActor
    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate() {
            if .now >= deadline { XCTFail("Closed workspace did not release"); throw CleanupFailure.unavailable }
            await Task.yield()
        }
    }

    @MainActor
    func testClosedHistoryReleasesHostAndWindowAndRestoresFrameAndNavigation() async throws {
        let model = try makeModel()
        model.selection = .dictations; model.searchText = "synthetic query"
        let lifetime = makeLifetime(model: model)
        let frame = NSRect(x: 120, y: 140, width: 900, height: 640)
        weak var oldWindow: NSWindow?
        weak var oldHost: NSView?
        autoreleasepool {
            let window = lifetime.windowForOpening()
            window.setFrame(frame, display: false)
            oldWindow = window; oldHost = window.contentView
            window.close() // The same delegate notification as the red close button.
        }
        await lifetime.pendingClose?.value
        try await eventually { oldWindow == nil && oldHost == nil }
        XCTAssertNil(lifetime.window)
        XCTAssertEqual(model.selection, .dictations)
        XCTAssertEqual(model.searchText, "synthetic query")
        let reopened = lifetime.windowForOpening()
        XCTAssertEqual(reopened.frame, frame)
        XCTAssertNotNil(reopened.contentView)
        reopened.close()
        await lifetime.pendingClose?.value
    }

    @MainActor
    func testHistorySelectionSettingsRecoveryAndCaptureKeepTheirExactWindowAndHost() async throws {
        let guards: [(String, (AppModel) -> Void)] = [
            ("selected history item", { $0.selectedItemID = UUID() }),
            ("settings", { $0.workspaceSheet = .settings }),
            ("recovery composer", {
                let id = UUID()
                $0.composerRecoveryDraftID = id
                $0.explicitlyOpenedRecoveryDraftID = id
                $0.captureText = "Synthetic recovered words"
                $0.showComposer = true
            }),
            ("starting voice", { $0.voiceCaptureRequested = true }),
            ("cleanup", { $0.manualCleanupInProgress = true })
        ]
        for (name, protect) in guards {
            let model = try makeModel(); protect(model)
            let lifetime = makeLifetime(model: model)
            let window = lifetime.windowForOpening(), host = window.contentView
            window.close()
            await lifetime.pendingClose?.value
            XCTAssertTrue(lifetime.window === window, name)
            XCTAssertTrue(window.contentView === host, name)
            XCTAssertTrue(lifetime.windowForOpening() === window, name)
            // Remove only the synthetic guard after proving retention.
            model.selectedItemID = nil; model.workspaceSheet = nil; model.selection = .dictations
            model.showComposer = false; model.captureText = ""
            model.composerRecoveryDraftID = nil; model.explicitlyOpenedRecoveryDraftID = nil
            model.voiceCaptureRequested = false; model.manualCleanupInProgress = false
            window.close()
            await lifetime.pendingClose?.value
        }
    }

    @MainActor
    func testReopeningBeforeDeferredClosePreventsEvictionOfReusedWindow() async throws {
        let lifetime = makeLifetime(model: try makeModel())
        let original = lifetime.windowForOpening(), host = original.contentView
        original.close()
        let pending = lifetime.pendingClose
        let reopened = lifetime.windowForOpening()
        await pending?.value
        XCTAssertTrue(reopened === original)
        XCTAssertTrue(lifetime.window === reopened)
        XCTAssertTrue(reopened.contentView === host)
        reopened.close()
        await lifetime.pendingClose?.value
    }

    @MainActor
    func testCaptureStartingAfterCloseProtectsTreeBeforeDeferredEviction() async throws {
        let model = try makeModel()
        let lifetime = makeLifetime(model: model)
        let window = lifetime.windowForOpening(), host = window.contentView
        window.close()
        model.voiceCaptureRequested = true
        await lifetime.pendingClose?.value
        XCTAssertTrue(lifetime.window === window)
        XCTAssertTrue(window.contentView === host)
        model.voiceCaptureRequested = false
        window.close()
        await lifetime.pendingClose?.value
    }
}

@MainActor
private final class WorkspaceNoopCleanup: DictationCleaning {
    func prepare() {}
    func begin(_ id: UUID) {}
    func update(_ text: String, captureID: UUID) {}
    func finish(_ text: String, captureID: UUID) async throws -> String { text }
    func cancel() {}
    func release() {}
}

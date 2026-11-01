import Foundation
import XCTest
import UIUICore
@testable import UIUI

/// Runs the real answer path with a silent capture, and the real socket with a local client.
final class AgentAskIntegrationTests: XCTestCase {
    @MainActor
    private final class SilentCapture: TriggeredVoiceCapture {
        var onPartial: ((String) -> Void)?
        var onFinal: ((String) -> Void)?
        var onCompletion: ((SpeechCompletion) -> Void)?
        var onError: ((String) -> Void)?
        var onRecovery: ((String) -> Void)?
        var onAudioLevel: ((Float) -> Void)?
        var onFinalization: ((Double) -> Void)?
        var pendingFinal = "staging, migration mat chalana"
        func requestAuthorization() async -> Bool { true }
        func start(locale: String, contextualStrings: [String]) async throws {}
        func stop() { onFinal?(pendingFinal) }
        func cancel() {}
    }

    private final class NoDelivery: TextDelivering {
        func deliver(_ text: String, to target: DeliveryTarget?) async -> DeliveryResult { .pasteSent }
        func cancel() {}
    }

    private final class Directory {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uiui-ask-\(UUID().uuidString.prefix(8))")
        init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    @MainActor
    private func fixture() async throws -> (AppModel, AgentAskServer, Directory) {
        let directory = Directory()
        let suite = "uiui-ask-\(UUID().uuidString)"
        let voice = TriggeredVoice(capture: SilentCapture())
        let model = AppModel(dataDirectory: directory.url, defaults: try XCTUnwrap(UserDefaults(suiteName: suite)),
                             persistSettings: false, delivery: NoDelivery(), voice: voice)
        voice.onTrigger = {}
        voice.onRecordingSound = nil
        await model.start(installSystemServices: false)
        model.captureEnabled = true
        model.settings.agentAskEnabled = true
        model.settings.saveDictationHistory = false
        let server = AgentAskServer(socketURL: model.agentAskSocketURL)
        server.onRequest = { [weak model] id, request in model?.receiveAgentRequest(id, request) }
        server.onDisconnect = { [weak model] id in model?.agentDisconnected(id) }
        try server.start()
        model.agentAskServer = server
        addTeardownBlock {
            await MainActor.run { server.stop(); model.shutdown() }
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return (model, server, directory)
    }

    @MainActor
    private func waitUntil(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(what)
    }

    /// Runs the same client an agent uses, off the main actor.
    private func runAsk(_ directory: URL, timeout: String = "10") -> Task<(Int32, String), Never> {
        Task.detached {
            let code = AgentAskCommand.runIfRequested(arguments: ["uiui", "ask", "staging or prod?", "--from", "zelta", "--timeout", timeout], dataDirectory: directory) ?? -1
            return (code, "")
        }
    }

    @MainActor
    func testAskIsShownAnsweredAndReturnedWithoutTouchingDictation() async throws {
        let (model, _, directory) = try await fixture()
        let ask = runAsk(directory.url)
        try await waitUntil("question shown") { model.agentAsk.line.shown != nil }
        XCTAssertEqual(model.askPresentation?.agent, "zelta")
        XCTAssertEqual(model.askPresentation?.mode, .question)

        model.answerKeyPressed()
        XCTAssertNil(model.agentAsk.answering, "A press before the question was visible is ignored")

        try await Task.sleep(for: .milliseconds(550))
        model.answerKeyPressed()
        XCTAssertEqual(model.agentAsk.answering?.agent, "zelta")
        try await waitUntil("capturing") { model.voice.state == "capturing" }
        try await Task.sleep(for: .milliseconds(260))
        model.answerKeyReleased()

        let (code, _) = await ask.value
        XCTAssertEqual(code, 0)
        XCTAssertEqual(model.agentAsk.receipt?.kind, .sent)
        XCTAssertEqual(model.lastTypedText, "", "An answer never counts as dictation")
        XCTAssertTrue(model.recordingRecovery.drafts.isEmpty, "An answer is never kept as a draft")
        XCTAssertTrue(model.settings.agentAnswerKeyLearned)
    }

    @MainActor
    func testLockTellsEveryWaitingAgentAtOnce() async throws {
        let (model, _, directory) = try await fixture()
        let ask = runAsk(directory.url)
        try await waitUntil("question shown") { model.agentAsk.line.shown != nil }
        model.agentAskLockChanged(true)
        let (code, _) = await ask.value
        XCTAssertEqual(code, AskOutcome.away.exitCode)
        XCTAssertNil(model.askPresentation)

        let later = await runAsk(directory.url).value
        XCTAssertEqual(later.0, AskOutcome.away.exitCode, "New questions get away while locked")
    }

    @MainActor
    func testATimedOutAgentWithdrawsItsQuestionSilently() async throws {
        let (model, _, directory) = try await fixture()
        let ask = runAsk(directory.url, timeout: "0.2")
        try await waitUntil("question shown") { model.agentAsk.line.shown != nil }
        let (code, _) = await ask.value
        XCTAssertEqual(code, AskOutcome.timeout.exitCode)
        try await waitUntil("question withdrawn") { model.agentAsk.line.shown == nil }
        XCTAssertNil(model.askPresentation)
    }

    func testNotListeningIsReportedAtOnceAndNeverLaunchesTheApp() {
        let directory = Directory()
        let code = AgentAskCommand.runIfRequested(arguments: ["uiui", "ask", "hello"], dataDirectory: directory.url)
        XCTAssertEqual(code, AskOutcome.unavailable.exitCode)
        XCTAssertNil(AgentAskCommand.runIfRequested(arguments: ["uiui"], dataDirectory: directory.url), "A plain launch is the app")
    }

    @MainActor
    func testDictationHidesAWaitingQuestionAndNeverShowsAName() async throws {
        let (model, _, _) = try await fixture()
        let connection = UUID()
        model.receiveAgentRequest(connection, AskRequest(agent: "zelta", question: "which?"))
        XCTAssertNotNil(model.askPresentation)
        model.voiceTriggerIsPressed = true
        model.refreshAgentAsk()
        XCTAssertNil(model.askPresentation)
        model.voiceTriggerIsPressed = false
        model.refreshAgentAsk()
        XCTAssertNotNil(model.askPresentation, "It comes back when dictation ends")
    }
}

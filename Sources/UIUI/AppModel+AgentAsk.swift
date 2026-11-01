import AppKit
import Observation
import UIUICore

/// A receipt for words that went, or failed to go, to an agent.
struct AskReceipt: Equatable {
    enum Kind: Equatable { case sent, notDelivered }
    var id = UUID()
    var kind: Kind
    var agent: String
    var words: String
}

/// What the notch shows for agents. The agent's name is visible if and only if words
/// are going to that agent; dictation never shows a name.
struct AskPresentation: Equatable {
    enum Mode: Equatable { case question, answering, sent, notDelivered }
    var mode: Mode
    var agent: String
    var question: String
    var words: String
    var othersWaiting: Int
    var folded: Bool
    var hovering: Bool
    var latched: Bool
    var showsKeyHint: Bool
    var keyTitle: String
}

@MainActor @Observable
final class AgentAskState {
    static let foldDelay: Duration = .seconds(8)
    static let sentReceipt: Duration = .milliseconds(800)
    static let answerCap: Duration = .seconds(600)

    var line = AskLine()
    var answering: AskQuestion?
    /// The agent left while the person was speaking; their words must not be lost.
    var answerTargetGone = false
    var answerStartedAt: Date?
    var questionShownAt: Date?
    var receipt: AskReceipt?
    var folded = false
    var hovering = false
    var latched = false
    var locked = false
    @ObservationIgnored var gesture = AskKeyGesture()
    @ObservationIgnored var requests: [UUID: UUID] = [:] // question ID -> connection ID
    @ObservationIgnored var foldTask: Task<Void, Never>?
    @ObservationIgnored var receiptTask: Task<Void, Never>?
    @ObservationIgnored var capTask: Task<Void, Never>?
}

@MainActor
extension AppModel {
    /// One fixed key per Mac: Right Option, unless dictation already uses it.
    var agentAnswerKey: VoiceTriggerKey {
        settings.voiceTriggerKey == .rightOption ? .rightCommand : .rightOption
    }

    var agentAskAcceptsKey: Bool { settings.agentAskEnabled && (agentAsk.line.shown != nil || agentAsk.answering != nil) }

    var askPresentation: AskPresentation? {
        let state = agentAsk
        if let answering = state.answering {
            return AskPresentation(mode: .answering, agent: answering.agent, question: answering.text,
                                   words: voice.partialCommand, othersWaiting: max(0, state.line.waiting.count - (state.answerTargetGone ? 0 : 1)),
                                   folded: false, hovering: false, latched: state.latched,
                                   showsKeyHint: false, keyTitle: agentAnswerKey.title)
        }
        if let receipt = state.receipt {
            return AskPresentation(mode: receipt.kind == .sent ? .sent : .notDelivered, agent: receipt.agent, question: "",
                                   words: receipt.words, othersWaiting: state.line.othersWaiting,
                                   folded: false, hovering: false, latched: false,
                                   showsKeyHint: false, keyTitle: agentAnswerKey.title)
        }
        guard let shown = state.line.shown else { return nil }
        return AskPresentation(mode: .question, agent: shown.agent, question: shown.text, words: "",
                               othersWaiting: state.line.othersWaiting, folded: state.folded && !state.hovering,
                               hovering: state.hovering, latched: false,
                               showsKeyHint: !settings.agentAnswerKeyLearned, keyTitle: agentAnswerKey.title)
    }

    /// Requests from the server. Text is displayed and returned, never stored or logged.
    func receiveAgentRequest(_ connection: UUID, _ request: AskRequest) {
        switch request.kind {
        case .stats:
            let days = 7
            let since = Date().addingTimeInterval(-Double(days) * 86_400)
            let summary = AskUsage.summary(of: events, since: since, days: days)
            agentAskServer?.reply(connection, AskResponse(outcome: .answered, text: summary.report))
        case .ask:
            guard settings.agentAskEnabled, settings.notchEnabled else {
                agentAskServer?.reply(connection, AskResponse(outcome: .unavailable)); return
            }
            Task { await record(UsageEvent(action: AskUsage.received)) }
            if agentAsk.locked {
                agentAskServer?.reply(connection, AskResponse(outcome: .away))
                Task { await record(UsageEvent(action: AskUsage.away)) }
                return
            }
            let question = AskQuestion(agent: request.agent, text: request.question)
            guard !question.text.isEmpty else {
                agentAskServer?.reply(connection, AskResponse(outcome: .unavailable)); return
            }
            agentAsk.requests[question.id] = connection
            agentAsk.line.add(question)
            refreshAgentAsk()
            onActivityChanged?()
        }
    }

    /// The asker is gone: it timed out, was answered in the terminal, or died.
    func agentDisconnected(_ connection: UUID) {
        guard let id = agentAsk.requests.first(where: { $0.value == connection })?.key else { return }
        agentAsk.requests[id] = nil
        Task { await record(UsageEvent(action: AskUsage.withdrawn)) }
        if agentAsk.answering?.id == id { agentAsk.answerTargetGone = true }
        agentAsk.line.remove(id)
        refreshAgentAsk()
        onActivityChanged?()
    }

    /// Event-driven: runs when a question arrives or leaves, and on every voice state change.
    func refreshAgentAsk() {
        let state = agentAsk
        let dictating = voiceInputKind == .dictation && (hasCancellableVoiceInput || isRecording || voiceTriggerIsPressed)
        if dictating {
            // Never while speaking. It comes back afterwards with a fresh visible clock.
            if state.line.shown != nil { state.line.hide(); state.foldTask?.cancel(); onAskKeyChanged?() }
            return
        }
        guard state.answering == nil, state.receipt == nil, state.line.showNext(at: ProcessInfo.processInfo.systemUptime) else {
            if state.line.shown == nil { onAskKeyChanged?() }
            return
        }
        state.folded = false
        state.questionShownAt = Date()
        state.foldTask?.cancel()
        state.foldTask = Task { [weak self] in
            do { try await Task.sleep(for: AgentAskState.foldDelay) } catch { return }
            self?.agentAsk.folded = true
        }
        onAskKeyChanged?()
    }

    func answerKeyPressed() {
        let state = agentAsk
        guard settings.agentAskEnabled else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        if state.answering == nil {
            // A press too soon, or during dictation, is ignored and the question stays.
            guard !hasCancellableVoiceInput, !isRecording, !voiceTriggerIsPressed,
                  let question = state.line.bindableQuestion(at: uptime) else { return }
            state.gesture.reset()
            guard state.gesture.pressed(at: uptime) == .start else { return }
            state.answering = question
            state.answerTargetGone = false
            state.answerStartedAt = Date()
            state.latched = false
            state.foldTask?.cancel()
            state.line.hide()
            beginVoiceCapture(kind: .agentAnswer)
            onActivityChanged?()
        } else { _ = state.gesture.pressed(at: uptime) }
    }

    func answerKeyReleased() {
        let state = agentAsk
        guard state.answering != nil else { return }
        let action = state.gesture.released(at: ProcessInfo.processInfo.systemUptime)
        state.latched = state.gesture.isLatched
        if state.latched, state.capTask == nil {
            // A latched microphone has no finger on it, so it always has an end.
            state.capTask = Task { [weak self] in
                do { try await Task.sleep(for: AgentAskState.answerCap) } catch { return }
                self?.finishVoiceCapture()
            }
        }
        if action == .finish { finishVoiceCapture() }
        onActivityChanged?()
    }

    func answerKeyChorded() {
        guard agentAsk.answering != nil, agentAsk.gesture.chord() == .cancel else { return }
        stopVoiceSession()
        endAgentAnswerWithoutWords()
    }

    /// Called from the voice owner's state changes. Cancelling, silence or an error
    /// leaves the question where it was, and nothing reaches the agent.
    func agentAnswerCaptureChanged() {
        guard agentAsk.answering != nil, voiceInputKind == .agentAnswer, !voiceIsRecording else { return }
        let state = voice.state
        if state == "off" || state == "error" || (state == "idle" && voice.partialCommand.isEmpty) {
            endAgentAnswerWithoutWords()
        }
    }

    func completeAgentAnswer(_ raw: String) {
        let state = agentAsk
        guard let question = state.answering else { return }
        let words = TextProcessing.applyingVocabulary(to: raw, entries: effectiveVocabulary, project: captureProject, isKnownWord: KnownWords.contains)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let latched = state.gesture.isLatched || state.latched
        let startedAt = state.questionShownAt
        clearAnswerCapture()
        voice.setWorking(false)
        voice.discardHeldText()
        guard !words.isEmpty else { refreshAgentAsk(); onActivityChanged?(); return }
        if let connection = state.requests.removeValue(forKey: question.id), !state.answerTargetGone {
            state.line.remove(question.id)
            agentAskServer?.reply(connection, AskResponse(outcome: .answered, text: words))
            settings.agentAnswerKeyLearned = true
            let milliseconds = startedAt.map { Date().timeIntervalSince($0) * 1000 }
            Task { await record(UsageEvent(action: latched ? AskUsage.answeredTap : AskUsage.answeredHold,
                                           durationMS: milliseconds, wordCount: TextProcessing.wordCount(words))) }
            showAskReceipt(AskReceipt(kind: .sent, agent: question.agent, words: words))
        } else {
            Task { await record(UsageEvent(action: AskUsage.notDelivered, succeeded: false)) }
            showAskReceipt(AskReceipt(kind: .notDelivered, agent: question.agent, words: words))
        }
    }

    /// From Settings: the real notch and key, with an answer that goes nowhere.
    func sendTestAgentQuestion() {
        receiveAgentRequest(UUID(), AskRequest(agent: "uiui", question: "This is a test. Hold \(agentAnswerKey.title) and say anything."))
    }

    func copyAskReceiptWords() {
        guard let words = agentAsk.receipt?.words else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(words, forType: .string)
        dismissAskReceipt()
    }

    func dismissAskReceipt() {
        agentAsk.receiptTask?.cancel()
        agentAsk.receipt = nil
        refreshAgentAsk()
        onActivityChanged?()
    }

    func setAskPointerOver(_ over: Bool) { agentAsk.hovering = over }

    func agentAskLockChanged(_ locked: Bool) {
        agentAsk.locked = locked
        guard locked else { refreshAgentAsk(); return }
        // Words already spoken still go; everything else is told at once.
        if agentAsk.answering != nil { finishVoiceCapture() }
        flushAgentQuestions(.away)
    }

    func agentAskWillSleep() {
        if agentAsk.answering != nil {
            stopVoiceSession()
            clearAnswerCapture()
        }
        flushAgentQuestions(.away)
    }

    /// Every waiting asker gets an answer at once. Nothing is ever left hanging.
    func flushAgentQuestions(_ outcome: AskOutcome) {
        let state = agentAsk
        let answeringID = state.answering?.id
        for question in state.line.removeAll() where question.id != answeringID {
            guard let connection = state.requests.removeValue(forKey: question.id) else { continue }
            agentAskServer?.reply(connection, AskResponse(outcome: outcome))
            if outcome == .away { Task { await record(UsageEvent(action: AskUsage.away)) } }
        }
        state.foldTask?.cancel()
        if let answering = state.answering, !state.answerTargetGone { state.line.add(answering) }
        onAskKeyChanged?()
        onActivityChanged?()
    }

    private func endAgentAnswerWithoutWords() {
        clearAnswerCapture()
        refreshAgentAsk()
        onActivityChanged?()
    }

    private func clearAnswerCapture() {
        let state = agentAsk
        state.answering = nil
        state.latched = false
        state.gesture.reset()
        state.capTask?.cancel(); state.capTask = nil
        voiceInputKind = .dictation
        onAskKeyChanged?()
    }

    private func showAskReceipt(_ receipt: AskReceipt) {
        let state = agentAsk
        state.receipt = receipt
        state.receiptTask?.cancel()
        // A failed delivery stays until acted on, because it holds the person's words.
        if receipt.kind == .sent {
            state.receiptTask = Task { [weak self] in
                do { try await Task.sleep(for: AgentAskState.sentReceipt) } catch { return }
                self?.dismissAskReceipt()
            }
        }
        onActivityChanged?()
    }
}

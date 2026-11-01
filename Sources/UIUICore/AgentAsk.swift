import Foundation

/// What `uiui ask` sends over the local socket. uiui displays the question and never
/// interprets it. One request per connection; closing the connection withdraws it.
public struct AskRequest: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case ask, stats }
    public static let maximumQuestionLength = 500
    public static let maximumEncodedSize = 8_192

    public var kind: Kind
    public var agent: String
    public var question: String

    public init(kind: Kind = .ask, agent: String = "", question: String = "") {
        self.kind = kind; self.agent = agent; self.question = question
    }
}

/// Every non-answer is an outcome, never text on stdout, so nothing else can be
/// mistaken for the person's words.
public enum AskOutcome: String, Codable, Equatable, Sendable {
    case answered, away, unavailable, timeout

    public var exitCode: Int32 {
        switch self {
        case .answered: 0
        case .unavailable: 3
        case .away: 4
        case .timeout: 5
        }
    }
}

public struct AskResponse: Codable, Equatable, Sendable {
    public var outcome: AskOutcome
    public var text: String
    public init(outcome: AskOutcome, text: String = "") { self.outcome = outcome; self.text = text }
}

public struct AskQuestion: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let agent: String
    public let text: String
    public init(id: UUID = UUID(), agent: String, text: String) {
        self.id = id
        let name = agent.trimmingCharacters(in: .whitespacesAndNewlines)
        self.agent = name.isEmpty ? "agent" : String(name.prefix(24))
        self.text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(AskRequest.maximumQuestionLength))
    }
}

/// One line across all agents: oldest first, one on screen. The answer key binds only
/// to a question that has been visible long enough to have been seen, so the rhythm of
/// answering can never carry an answer onto the next question.
public struct AskLine: Equatable, Sendable {
    public static let minimumVisibleTime: TimeInterval = 0.5

    public private(set) var waiting: [AskQuestion] = []
    public private(set) var shown: AskQuestion?
    private var shownAt: TimeInterval?

    public init() {}

    public var othersWaiting: Int { max(0, waiting.count - (shown == nil ? 0 : 1)) }

    public mutating func add(_ question: AskQuestion) { waiting.append(question) }

    @discardableResult
    public mutating func remove(_ id: UUID) -> AskQuestion? {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return nil }
        if shown?.id == id { hide() }
        return waiting.remove(at: index)
    }

    /// Shows the oldest question if nothing is on screen. Returns true when it changed.
    @discardableResult
    public mutating func showNext(at now: TimeInterval) -> Bool {
        guard shown == nil, let next = waiting.first else { return false }
        shown = next
        shownAt = now
        return true
    }

    /// Hiding restarts the visible clock, because the person must see it again.
    public mutating func hide() { shown = nil; shownAt = nil }

    public func bindableQuestion(at now: TimeInterval) -> AskQuestion? {
        guard let shown, let shownAt, now - shownAt >= Self.minimumVisibleTime else { return nil }
        return shown
    }

    public mutating func removeAll() -> [AskQuestion] {
        defer { waiting = []; hide() }
        return waiting
    }
}

/// The answer key: hold and release sends, a quick tap latches the microphone and the
/// next tap sends. The person decides how long to talk; there is no setting or flag.
public struct AskKeyGesture: Equatable, Sendable {
    public static let tapThreshold: TimeInterval = 0.25
    public enum Action: Equatable, Sendable { case start, finish, cancel }
    private enum State: Equatable, Sendable { case idle, down(at: TimeInterval), latched, ending }

    private var state = State.idle
    public init() {}

    public var isLatched: Bool { state == .latched || state == .ending }

    public mutating func pressed(at now: TimeInterval) -> Action? {
        switch state {
        case .idle: state = .down(at: now); return .start
        case .latched: state = .ending; return nil
        case .down, .ending: return nil
        }
    }

    public mutating func released(at now: TimeInterval) -> Action? {
        switch state {
        case .down(let at):
            if now - at < Self.tapThreshold { state = .latched; return nil }
            state = .idle
            return .finish
        case .ending: state = .idle; return .finish
        case .idle, .latched: return nil
        }
    }

    /// Another key joined the press, so this was a chord and not an answer.
    public mutating func chord() -> Action? {
        switch state {
        case .down: state = .idle; return .cancel
        case .ending: state = .latched; return nil
        case .idle, .latched: return nil
        }
    }

    public mutating func reset() { state = .idle }
}

/// Local counts only. Actions never include a question, an answer or an agent's name.
public enum AskUsage {
    public static let received = "ask_received"
    public static let answeredHold = "ask_answered_hold"
    public static let answeredTap = "ask_answered_tap"
    public static let withdrawn = "ask_withdrawn"
    public static let away = "ask_away"
    public static let notDelivered = "ask_not_delivered"

    public struct Summary: Equatable, Sendable {
        public var days: Int
        public var dictations = 0
        public var dictatedWords = 0
        public var questions = 0
        public var answeredByHold = 0
        public var answeredByTap = 0
        /// The question went away unanswered: usually answered in the terminal or timed out.
        public var withdrawn = 0
        public var away = 0
        public var notDelivered = 0
        public var medianAnswerSeconds: Double?

        public var answeredByVoice: Int { answeredByHold + answeredByTap }

        public var report: String {
            var lines = ["Last \(days) days on this Mac",
                         "Dictations: \(dictations) (\(dictatedWords) words)",
                         "Questions from agents: \(questions)",
                         "Answered by voice: \(answeredByVoice) (\(answeredByHold) hold, \(answeredByTap) tap)",
                         "Went unanswered here: \(withdrawn)",
                         "Mac locked: \(away)",
                         "Not delivered: \(notDelivered)"]
            if let medianAnswerSeconds { lines.append(String(format: "Typical time to answer: %.1f s", medianAnswerSeconds)) }
            return lines.joined(separator: "\n")
        }
    }

    public static func summary(of events: [UsageEvent], since: Date, days: Int) -> Summary {
        var summary = Summary(days: days)
        var answerTimes: [Double] = []
        for event in events where event.date >= since {
            switch event.action {
            case "paste_dispatched", "dictation_copied":
                summary.dictations += 1
                summary.dictatedWords += event.wordCount
            case received: summary.questions += 1
            case answeredHold, answeredTap:
                if event.action == answeredHold { summary.answeredByHold += 1 } else { summary.answeredByTap += 1 }
                if let duration = event.durationMS { answerTimes.append(duration / 1000) }
            case withdrawn: summary.withdrawn += 1
            case away: summary.away += 1
            case notDelivered: summary.notDelivered += 1
            default: break
            }
        }
        if !answerTimes.isEmpty { summary.medianAnswerSeconds = answerTimes.sorted()[answerTimes.count / 2] }
        return summary
    }
}

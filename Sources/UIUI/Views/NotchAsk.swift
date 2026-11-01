import SwiftUI
import UIUICore

extension NotchLayout {
    /// Extra height while the pointer rests on a waiting question: the rest of the text.
    static let askHoverExtra: CGFloat = 64

    /// One fixed footprint, so nothing jumps between asking and answering. A question
    /// folds to its header while it waits, leaving only the name and the count.
    static func askSize(_ ask: AskPresentation, cameraWidth: CGFloat, cameraHeight: CGFloat,
                        hasCamera: Bool, size: NotchSize) -> CGSize {
        let header = hasCamera ? max(32, cameraHeight) : 32
        let width = expandedWidth(cameraWidth: cameraWidth, hasCamera: hasCamera, size: size)
        if ask.folded { return CGSize(width: width, height: header + 1) }
        let body: CGFloat = 66 + (ask.hovering ? askHoverExtra : 0)
        return CGSize(width: width, height: header + body)
    }
}

/// Words for an agent. It takes no focus, and clicks do nothing except on a failed
/// delivery, where the person's words must be recoverable.
struct NotchAskView: View {
    let ask: AskPresentation
    let cameraWidth: CGFloat
    let header: CGFloat
    var onCopy: () -> Void = {}
    var onDismiss: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    @Environment(\.notchReduceMotion) private var reduceMotion
    @State private var sentWordsRisen = false

    private static let amber = Color(red: 0.97, green: 0.67, blue: 0.26)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(ask.mode == .question ? "\(ask.agent) asks" : ask.agent)
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 10)
                Color.clear.frame(width: cameraWidth, height: 1)
                HStack(spacing: 8) {
                    if ask.mode == .answering { AnswerTimer() }
                    if ask.othersWaiting > 0 { Text("+\(ask.othersWaiting)").monospacedDigit() }
                }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 10)
            }
            .padding(.horizontal, 14)
            .frame(height: header)
            if !ask.folded {
                content.padding(.horizontal, 18).padding(.bottom, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder private var content: some View {
        switch ask.mode {
        case .question:
            VStack(alignment: .leading, spacing: 3) {
                Text(ask.question).font(.system(size: 13)).lineLimit(ask.hovering ? 7 : 2).truncationMode(.middle)
                if ask.showsKeyHint {
                    Text("Hold \(ask.keyTitle) to answer").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                }
            }
        case .answering:
            VStack(alignment: .leading, spacing: 3) {
                Text(ask.question).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1).truncationMode(.middle)
                Text(ask.words.isEmpty ? "Listening" : ask.words)
                    .font(.system(size: 13)).foregroundStyle(ask.words.isEmpty ? .white.opacity(0.55) : .white)
                    .lineLimit(2).truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .sent:
            VStack(alignment: .leading, spacing: 3) {
                Text(ask.words).font(.system(size: 13)).lineLimit(1).truncationMode(.head)
                    .offset(y: sentWordsRisen && !reduceMotion ? -22 : 0)
                    .opacity(sentWordsRisen ? 0 : 1)
                Text("Sent to \(ask.agent)").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.8))
            }
            .onAppear { withAnimation(.easeOut(duration: 0.2)) { sentWordsRisen = true } }
        case .notDelivered:
            VStack(alignment: .leading, spacing: 4) {
                Text(ask.words).font(.system(size: 12)).lineLimit(1).truncationMode(.head)
                HStack {
                    Text("Not delivered to \(ask.agent)").font(.system(size: 12, weight: .medium)).foregroundStyle(Self.amber).lineLimit(1)
                    Spacer()
                    Button("Copy", action: onCopy).buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                    Button("Dismiss", action: onDismiss).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
    }

    private var accessibilityText: String {
        switch ask.mode {
        case .question: "\(ask.agent) asks: \(ask.question). Hold \(ask.keyTitle) to answer."
        case .answering: "Answering \(ask.agent). Microphone on."
        case .sent: "Sent to \(ask.agent)."
        case .notDelivered: "Not delivered to \(ask.agent). Copy available."
        }
    }
}

/// In the right wing, the same place as during dictation.
private struct AnswerTimer: View {
    @State private var startedAt = Date()
    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            Text(NotchTimerPolicy.text(context.date.timeIntervalSince(startedAt)))
                .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.7))
        }
    }
}

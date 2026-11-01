import Charts
import SwiftUI
import UIUICore

/// Home's numbers: how much you have dictated, from counts kept on this Mac.
struct UsageOverview: View {
    let model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var hoveredDay: Date?

    private var overview: DictationUsage.Overview { DictationUsage.overview(of: model.events, now: Date()) }
    private var agents: AskUsage.Summary {
        AskUsage.summary(of: model.events, since: Date().addingTimeInterval(-7 * 86_400), days: 7)
    }

    var body: some View {
        let overview = overview
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                tile("Today", "\(overview.dictationsToday)", detail: "\(overview.wordsToday.formatted()) words")
                tile("This week", "\(overview.dictationsThisWeek)", detail: "\(overview.wordsThisWeek.formatted()) words")
                tile("Time talking", DictationUsage.durationText(overview.spokenSecondsThisWeek), detail: "this week")
                tile("Pace", overview.wordsPerMinute.map(String.init) ?? "–", detail: "words a minute")
                if model.settings.agentAskEnabled {
                    tile("Agents", "\(agents.answeredByVoice)", detail: "of \(agents.questions) answered")
                }
            }
            chart(overview)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    private func tile(_ title: String, _ value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func chart(_ overview: DictationUsage.Overview) -> some View {
        let hovered = hoveredDay.flatMap { date in overview.days.first { Calendar.current.isDate($0.date, inSameDayAs: date) } }
        VStack(alignment: .leading, spacing: 6) {
            Text(hovered.map { "\($0.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))): \($0.dictations) dictations, \($0.words.formatted()) words" }
                 ?? "Dictations a day, last 14 days")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
            if overview.isEmpty {
                Text("Your first dictation will show up here.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 56)
            } else {
                Chart(overview.days) { day in
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Dictations", day.dictations), width: .ratio(0.7))
                        .cornerRadius(4)
                        .foregroundStyle(UIUIStyle.tint(scheme).opacity(hovered == nil || hovered?.date == day.date ? 1 : 0.45))
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 2)) { _ in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                        AxisValueLabel().font(.system(size: 9)).foregroundStyle(Color.secondary)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(.system(size: 9)).foregroundStyle(Color.secondary)
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    guard let frame = proxy.plotFrame else { return }
                                    hoveredDay = proxy.value(atX: location.x - geometry[frame].minX, as: Date.self)
                                case .ended: hoveredDay = nil
                                }
                            }
                    }
                }
                .frame(height: 76)
                .accessibilityLabel("Dictations a day for the last 14 days")
                .accessibilityValue("\(overview.dictationsThisWeek) in the last 7 days")
            }
        }
    }
}

import SwiftUI
import Charts

struct InsightsView: View {
    @ObservedObject var engine = Engine.shared
    @State private var week: (words: Int, seconds: Double) = (0, 0)
    @State private var streak = 0
    @State private var points: [(date: Date, words: Int)] = []

    /// Typing at ~40 wpm vs. the time actually spent dictating.
    private var minutesSaved: Int {
        max(0, Int((Double(week.words) / 40.0 - week.seconds / 60.0).rounded()))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.spacingL) {
                HStack(spacing: DS.spacingL) {
                    tile("Words This Week", week.words.formatted(), "text.word.spacing")
                    tile("Time Saved", timeSavedText, "clock.badge.checkmark")
                    tile("Streak", streak == 1 ? "1 day" : "\(streak) days", "flame")
                }

                GroupBox {
                    Chart(points, id: \.date) { p in
                        BarMark(x: .value("Day", p.date, unit: .day),
                                y: .value("Words", p.words))
                            .foregroundStyle(Color.accentColor)
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                            AxisGridLine(); AxisTick()
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        }
                    }
                    .frame(height: 220)
                    .padding(DS.spacing)
                } label: {
                    Text("Words per Day").font(.headline).padding(.bottom, DS.spacing / 2)
                }
            }
            .padding(DS.spacingL)
        }
        .navigationTitle("Insights")
        .onAppear(perform: reload)
        .onChange(of: engine.historyVersion) { reload() }
    }

    private var timeSavedText: String {
        minutesSaved >= 60 ? "\(minutesSaved / 60) h \(minutesSaved % 60) m" : "\(minutesSaved) min"
    }

    private func tile(_ title: String, _ value: String, _ symbol: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: DS.spacing / 2) {
                Label(title, systemImage: symbol)
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(value).font(.system(.title, design: .rounded, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.spacing)
        }
    }

    private func reload() {
        week = Store.shared.totals(days: 7)
        streak = Store.shared.stats().streakDays
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = Calendar(identifier: .gregorian)
        let counts = Dictionary(Store.shared.wordsByDay(days: 31).map { ($0.day, $0.words) },
                                uniquingKeysWith: +)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        points = (0..<30).reversed().map { back in
            let d = cal.date(byAdding: .day, value: -back, to: today)!
            return (d, counts[fmt.string(from: d)] ?? 0)
        }
    }
}

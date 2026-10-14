import SwiftUI

/// Owns its pointer state. Hover never invalidates the parent or any Swift Charts view.
struct StatsHeatmapView: View {
    let period: StatsActivityPeriod
    let weekdayLabels: [String]
    private let labels: [Date: DayLabels]

    struct DayLabels {
        let shortDate: String
        let accessible: String
        let words: String
    }

    init(period: StatsActivityPeriod) {
        self.period = period
        self.weekdayLabels = period.weekdays.map(\.label)
        // Format once when the data/range changes, never while moving between squares.
        self.labels = Dictionary(uniqueKeysWithValues: period.days.map { day in
            (day.date, Self.dayLabels(for: day, calendar: period.calendar))
        })
    }

    /// The cached tooltips and accessibility labels use the same calendar,
    /// locale and time zone that placed their cells in the period's grid.
    static func dayLabels(for day: StatsActivityPeriod.Day, calendar: Calendar, bundle: Bundle = .main) -> DayLabels {
        let locale = calendar.locale ?? Locale.current
        let shortDate = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.abbreviated).month(.abbreviated).day()
        let fullDate = Date.FormatStyle(date: .complete, time: .omitted, locale: locale,
                                       calendar: calendar, timeZone: calendar.timeZone)
        return DayLabels(shortDate: day.date.formatted(shortDate),
            accessible: PichiLocalization.format("%@, %lld words", locale: locale, bundle: bundle,
                                                arguments: [day.date.formatted(fullDate), day.words]),
            words: PichiLocalization.format("%lld words", locale: locale, bundle: bundle, arguments: [day.words]))
    }

    @Environment(\.theme) private var theme
    @State private var hoveredDate: Date?

    var body: some View {
        self.heatmap(self.period)
            .onDisappear { self.hoveredDate = nil }
    }

    private func heatmap(_ period: StatsActivityPeriod) -> some View {
        let columns = period.weeks
        return HStack(alignment: .top, spacing: 6) {
            VStack(spacing: 4) {
                Color.clear.frame(height: 16)
                ForEach(0..<7) { row in
                    Text(row.isMultiple(of: 2) ? self.weekdayLabels[row] : "")
                        .font(self.theme.typography.captionSmall)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .frame(width: 30, height: 16)
                }
            }
            .frame(width: 30)
            GeometryReader { geometry in
                let width = max(2, min(26, (geometry.size.width - CGFloat(max(0, columns.count - 1)) * 4) / CGFloat(max(1, columns.count))))
                HStack(alignment: .top, spacing: 4) {
                    ForEach(columns.indices, id: \.self) { column in
                        VStack(spacing: 4) {
                            Text(period.monthLabel(for: column))
                                .font(self.theme.typography.captionSmall)
                                .foregroundStyle(self.theme.palette.secondaryText)
                                .fixedSize()
                                .frame(width: width, height: 16, alignment: .leading)
                            ForEach(0..<7) { row in
                                self.dayCell(
                                    columns[column][row],
                                    maximum: period.peakWords,
                                    tooltipAlignment: column < 3 ? .topLeading : (column >= columns.count - 3 ? .topTrailing : .top)
                                )
                                .frame(width: width, height: 16)
                            }
                        }
                        .zIndex(columns[column].contains { $0?.date == self.hoveredDate } ? 1 : 0)
                    }
                }
            }
            .frame(height: 160)
        }
    }

    @ViewBuilder
    private func dayCell(_ day: StatsActivityPeriod.Day?, maximum: Int, tooltipAlignment: Alignment) -> some View {
        if let day {
            let level = day.words == 0 ? 0 : max(1, min(4, Int(ceil(Double(day.words) / Double(max(1, maximum)) * 4))))
            let highlighted = self.hoveredDate == day.date
            RoundedRectangle(cornerRadius: 3)
                .fill(self.cellColor(level))
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(highlighted ? self.theme.palette.primaryText : .clear, lineWidth: 2)
                }
                .contentShape(Rectangle())
                .overlay(alignment: tooltipAlignment) {
                    if self.hoveredDate == day.date {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(self.labels[day.date]?.shortDate ?? "")
                                .font(self.theme.typography.caption)
                                .foregroundStyle(self.theme.palette.secondaryText)
                            Text(self.labels[day.date]?.words ?? "")
                                .font(self.theme.typography.bodySmallStrong)
                        }
                        .padding(10)
                        .background(self.theme.palette.elevatedCardBackground, in: RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm))
                        .overlay(RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm).strokeBorder(self.theme.palette.cardBorder))
                        .fixedSize()
                        .offset(y: -62)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
                .zIndex(self.hoveredDate == day.date ? 1 : 0)
                .onHover { hovering in
                    if hovering {
                        self.hoveredDate = day.date
                    } else if self.hoveredDate == day.date {
                        self.hoveredDate = nil
                    }
                }
                .accessibilityLabel(self.labels[day.date]?.accessible ?? "")
                .accessibilityElement(children: .ignore)

        } else {
            Color.clear.accessibilityHidden(true)
        }
    }

    private func cellColor(_ level: Int) -> Color {
        level == 0 ? self.theme.palette.primaryText.opacity(0.07) : self.theme.palette.accent.opacity(0.25 + Double(level) * 0.18)
    }
}

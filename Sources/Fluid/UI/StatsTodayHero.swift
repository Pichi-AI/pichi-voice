import SwiftUI

struct StatsTodayHero: View {
    let words: Int
    let sessions: Int
    let savedMinutes: Double
    let streak: Int
    let activity: [(date: Date, words: Int)]
    @Environment(\.theme) private var theme
    @Environment(\.locale) private var interfaceLocale

    private var milestone: StatsDailyMilestone { StatsDailyMilestone(words: self.words) }
    private var nextTarget: Int? { self.milestone.nextTarget }
    private var progress: Double { self.milestone.progress }
    private var savedTime: String {
        PichiLocalization.formattedTimeSaved(minutes: self.savedMinutes)
    }

    var body: some View {
        ThemedCard(style: .prominent, padding: 28, hoverEffect: false) {
            VStack(alignment: .leading, spacing: 24) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 40) {
                        self.headline.frame(minWidth: 300, maxWidth: .infinity, alignment: .leading)
                        self.momentum.frame(width: 240)
                    }
                    VStack(alignment: .leading, spacing: 24) {
                        self.headline
                        self.momentum
                    }
                }
                Divider().opacity(0.35)
                self.nextStep
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 6) {
            if self.words > 0, self.savedMinutes > 0 {
                Text(self.savedTime)
                    .font(.fluidSystem(size: 56, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("back in your day.")
                    .font(self.theme.typography.title)
            } else {
                Text(PichiLocalization.text(self.words == 0 ? "Great ideas\nstart with a word." : "Look at you go."))
                    .font(self.theme.typography.displayTitle)
                    .fixedSize(horizontal: false, vertical: true)
                Text(self.words == 0 ? PichiLocalization.text("Make a little space for your next big thought.") : PichiLocalization.format("%@ words captured, without the typing.", self.words.formatted()))
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
        }
    }

    private var momentum: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "flame.fill")
                    .font(self.theme.typography.titleIcon)
                    .foregroundStyle(self.theme.palette.warning)
                Text("\(self.streak)")
                    .font(self.theme.typography.displayTitle)
                    .monospacedDigit()
                Text(PichiLocalization.formattedStreakUnit(days: self.streak))
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            Text(PichiLocalization.text(self.streak == 0 ? "Your next streak starts with today." : "One day at a time. Look how far you've come."))
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(Array(self.activity.enumerated()), id: \.element.date) { index, day in
                    StatsStreakDay(
                        date: day.date,
                        words: day.words,
                        tooltipAlignment: index < 2 ? .topLeading : (index > 4 ? .topTrailing : .top)
                    )
                }
            }
        }
    }

    private var nextStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(self.nextTarget.map { PichiLocalization.format("You're %@ words from your next win.", ($0 - self.words).formatted()) } ?? PichiLocalization.text("Look how far your voice has taken you today."))
                .font(.fluidSystem(size: 30, weight: .semibold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline) {
                Text(self.nextTarget.map { PichiLocalization.format("%@ spoken. Let's make it %@.", self.words.formatted(), $0.formatted()) } ?? PichiLocalization.format("%@ words spoken. Keep your ideas coming.", self.words.formatted()))
                    .font(self.theme.typography.statement)
                    .foregroundStyle(self.theme.palette.secondaryText)
                Spacer(minLength: 12)
                Text("\(Int(self.progress * 100))%")
                    .font(self.theme.typography.title)
                    .foregroundStyle(self.theme.palette.accentText)
                    .monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(self.theme.palette.primaryText.opacity(0.08))
                    Capsule()
                        .fill(self.theme.palette.accent.gradient)
                        .frame(width: geometry.size.width * self.progress)
                }
            }
            .frame(height: 14)
            .accessibilityLabel(PichiLocalization.text("Today's word milestone"))
            .accessibilityValue(PichiLocalization.format("%lld percent", Int(self.progress * 100)))
            Label("\(self.sessions.formatted()) dictations", systemImage: "waveform")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
                .padding(.top, 4)
        }
    }
}

/// Hover changes only an overlay in this cell, never the streak caption or page layout.
private struct StatsStreakDay: View {
    let date: Date
    let words: Int
    let tooltipAlignment: Alignment
    @Environment(\.theme) private var theme
    @Environment(\.locale) private var interfaceLocale
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: self.words > 0 ? "checkmark" : "minus")
                .font(self.theme.typography.badge)
                .foregroundStyle(self.words > 0 ? self.theme.palette.accentText : self.theme.palette.secondaryText)
                .frame(width: 24, height: 24)
                .background(self.theme.palette.accent.opacity(self.words > 0 ? 0.15 : 0.04), in: Circle())
            Text(self.date.formatted(.dateTime.weekday(.narrow).locale(self.interfaceLocale)))
                .font(self.theme.typography.captionSmall)
                .foregroundStyle(self.theme.palette.secondaryText)
        }
        .contentShape(Rectangle())
        .overlay(alignment: self.tooltipAlignment) {
            if self.isHovered {
                VStack(alignment: .leading, spacing: 4) {
                    Text(self.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(self.interfaceLocale)))
                        .foregroundStyle(self.theme.palette.secondaryText)
                    Text("\(self.words.formatted()) words")
                        .font(self.theme.typography.captionStrong)
                }
                .font(self.theme.typography.caption)
                .padding(10)
                .background(self.theme.palette.elevatedCardBackground, in: RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm))
                .overlay(RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm).strokeBorder(self.theme.palette.cardBorder))
                .fixedSize()
                .offset(y: -60)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .zIndex(self.isHovered ? 1 : 0)
        .onHover { self.isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PichiLocalization.format("%@, %lld words", self.date.formatted(Date.FormatStyle(date: .complete, time: .omitted).locale(self.interfaceLocale)), self.words))
    }
}

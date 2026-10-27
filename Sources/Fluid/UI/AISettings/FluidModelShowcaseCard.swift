import SwiftUI

/// Presentation only: model browsing is injected by the carousel.
struct FluidModelShowcaseCard: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovered = false
    @State private var showsInfo = false
    let model: PrivateAIRegisteredModel
    let isPreview: Bool
    let isSelected: Bool
    let compact: Bool
    var isRecommended = false
    let browse: () -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: AppTheme.Metrics.Showcase.cardRadius, style: .continuous)
    }

    var body: some View {
        let presentation = self.model.presentation ?? PrivateAIModelPresentation.forModel(id: self.model.id)
        Button(action: self.browse) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                Color.clear.frame(height: 20)
                    .overlay(alignment: .leading) {
                        if let badge = presentation.badge {
                            Text(PichiLocalization.text(badge))
                                .font(self.theme.typography.captionSmall)
                                .foregroundStyle(self.theme.palette.secondaryText)
                                .lineLimit(1)
                                .padding(.trailing, 24)
                        } else if self.isRecommended {
                            Text(PichiLocalization.text(self.compact ? "Recommended" : "Recommended for your Mac"))
                                .font(self.theme.typography.captionStrong)
                                .foregroundStyle(self.theme.palette.primaryText)
                                .lineLimit(1).minimumScaleFactor(0.8)
                                .padding(.trailing, 24)
                                .help(PichiLocalization.text("Based on your Mac’s RAM. You can choose either model."))
                        }
                    }
                HStack(spacing: 8) {
                    Text(self.model.displayName.replacingOccurrences(of: "Fluid-1", with: "Fluid 1"))
                        .font(self.compact ? self.theme.typography.sectionTitle : self.theme.typography.title)
                        .foregroundStyle(self.theme.palette.primaryText)
                        .lineLimit(2).minimumScaleFactor(0.85)
                    if self.isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.fluidSystem(size: 18, weight: .semibold))
                            .foregroundStyle(self.theme.palette.accentText)
                            .accessibilityLabel(PichiLocalization.text("Selected"))
                    }
                }
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                        Text(PichiLocalization.text(presentation.summary))
                            .font(self.theme.typography.bodyStrong)
                            .foregroundStyle(self.theme.palette.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(PichiLocalization.text(presentation.useCase))
                            .font(self.theme.typography.body)
                            .foregroundStyle(self.theme.palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(3)
                    }
                    .opacity(self.showsInfo ? 0 : 1)
                    .accessibilityHidden(self.showsInfo)
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                        if let language = presentation.language { self.infoRow("Languages", value: language) }
                        if let memory = self.model.recommendedMemoryGB {
                            self.infoRow("Recommended", value: PichiLocalization.format("Mac with %lld GB+ RAM", Int64(memory)))
                        }
                        if let bytes = self.model.artifact.byteCount, bytes > 0 {
                            self.infoRow("Download size", value: "≈\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(self.showsInfo ? 1 : 0)
                    .accessibilityHidden(!self.showsInfo)
                }
                .animation(self.reduceMotion ? nil : .easeInOut(duration: 0.16), value: self.showsInfo)
                Spacer(minLength: self.theme.metrics.spacing.sm)
                // Separate sibling controls are overlaid by the carousel; never nest buttons.
                Color.clear.frame(height: 64)
                    .overlay(alignment: .bottomLeading) {
                        if self.compact, self.isSelected {
                            Text(PichiLocalization.text("Active"))
                                .font(self.theme.typography.captionStrong)
                                .foregroundStyle(self.theme.palette.accent)
                        }
                    }
            }
            .padding(self.theme.metrics.spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background {
                self.shape.fill(self.theme.palette.elevatedCardBackground)
            }
            .overlay {
                self.shape.strokeBorder(
                    self.isPreview ? self.theme.palette.accent.opacity(self.contrast == .increased ? 1 : 0.5) : self.theme.palette.cardBorder,
                    lineWidth: self.contrast == .increased ? 2 : 1
                )
            }
            .shadow(color: .black.opacity(self.colorScheme == .dark ? 0.28 : 0.08), radius: self.isPreview ? 12 : 4, y: self.isPreview ? 8 : 2)
            .brightness(self.hovered ? 0.01 : 0)
            .contentShape(self.shape)
        }
        .buttonStyle(.plain)
        .onHover { self.hovered = $0 }
        .animation(self.reduceMotion ? nil : .easeOut(duration: 0.12), value: self.hovered)
        .accessibilityLabel(PichiLocalization.format("Preview %@", self.model.displayName.replacingOccurrences(of: "Fluid-1", with: "Fluid 1")))
        .accessibilityValue([self.isPreview ? PichiLocalization.text("Previewed") : "", self.isSelected ? PichiLocalization.text("Selected") : "", self.isRecommended ? PichiLocalization.text("Recommended for your Mac") : ""].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityHint(self.showsInfo ? self.infoAccessibilityDescription : PichiLocalization.format("%@. %@ Browse without changing the selected model.", PichiLocalization.text(presentation.summary), PichiLocalization.text(presentation.useCase)))
        .overlay(alignment: .topTrailing) {
            // Sibling to the browse button: opening details never selects or activates a model.
            Button { self.showsInfo.toggle() } label: {
                Image(systemName: self.showsInfo ? "xmark.circle" : "info.circle")
                    .font(.fluidSystem(size: 19, weight: .regular))
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(self.showsInfo ? PichiLocalization.text("Close model information") : PichiLocalization.format("About %@", self.model.displayName))
            .accessibilityLabel(PichiLocalization.format(self.showsInfo ? "Close information for %@" : "About %@", self.model.displayName))
            .accessibilityValue(PichiLocalization.text(self.showsInfo ? "Expanded" : "Collapsed"))
            .padding(14)
        }
    }

    private func infoRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: self.theme.metrics.spacing.sm) {
            Text(PichiLocalization.text(title)).foregroundStyle(self.theme.palette.secondaryText)
            Spacer(minLength: 0)
            Text(PichiLocalization.text(value)).foregroundStyle(self.theme.palette.primaryText)
                .multilineTextAlignment(.trailing)
        }
        .font(self.theme.typography.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var infoAccessibilityDescription: String {
        let presentation = self.model.presentation ?? PrivateAIModelPresentation.forModel(id: self.model.id)
        var details: [String] = []
        if let language = presentation.language { details.append(PichiLocalization.format("Languages: %@", PichiLocalization.text(language))) }
        if let memory = self.model.recommendedMemoryGB {
            details.append(PichiLocalization.format("Recommended: Mac with %lld GB or more RAM.", Int64(memory)))
        }
        if let bytes = self.model.artifact.byteCount, bytes > 0 {
            details.append(PichiLocalization.format("Download size: %@", ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))
        }
        return details.joined(separator: ". ")
    }
}

struct FluidModelMetrics: View {
    @Environment(\.theme) private var theme
    let modelID: String

    var body: some View {
        let presentation = PrivateAIModelPresentation.forModel(id: self.modelID)
        if let intelligence = presentation.intelligence, let speed = presentation.speed {
            VStack(spacing: self.theme.metrics.spacing.xs) {
                FluidModelMetric(label: "Intelligence", value: intelligence, tint: self.theme.palette.accentText, compact: true)
                FluidModelMetric(label: "Speed", value: speed, tint: .teal, compact: true)
            }
            .frame(width: AppTheme.Metrics.Showcase.compactMetricWidth)
            .help(PichiLocalization.text("Illustrative design preview — not benchmark scores"))
        }
    }
}

/// Five bounded static segments: no work beyond rendering immutable preview values.
private struct FluidModelMetric: View {
    @Environment(\.theme) private var theme
    let label: String
    let value: Int
    let tint: Color
    let compact: Bool

    var body: some View {
        HStack(spacing: self.theme.metrics.spacing.xs) {
            Text(PichiLocalization.text(self.label))
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: self.compact ? 58 : 64, alignment: .leading)
            HStack(spacing: 3) {
                ForEach(1...5, id: \.self) { step in
                    Capsule()
                        .fill(step <= self.value ? self.tint : self.theme.palette.secondaryText.opacity(0.25))
                        .frame(maxWidth: .infinity)
                        .frame(height: 3)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PichiLocalization.format("%@: illustrative level %lld of 5, not a benchmark score", PichiLocalization.text(self.label), self.value))
    }
}

import SwiftUI

/// A stationary blue invitation with quiet motion inside; capture uses a static red control.
struct FluidRecordInvitationStyle: ButtonStyle {
    let inviting: Bool
    let recording: Bool
    var prominent = true
    var fillsWidth = false
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isEnabled) private var isEnabled
    @State private var visible = false
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let animate = self.visible && self.inviting && self.isEnabled && !self.reduceMotion && self.scenePhase == .active
        let highlighted = self.hovered && self.isEnabled
        let ink = !self.isEnabled ? self.theme.palette.secondaryText
            : (self.prominent ? self.theme.palette.foreground(on: self.recording ? .red : self.theme.palette.accent) : self.theme.palette.primaryText)
        configuration.label
            .font(self.theme.typography.bodyStrong)
            .foregroundStyle(ink)
            .padding(.horizontal, 22)
            .frame(minWidth: 144, maxWidth: self.fillsWidth ? .infinity : nil, minHeight: FluidButtonSize.large.controlHeight)
            .background {
                Group {
                    if !self.isEnabled {
                        Capsule().fill(self.theme.palette.elevatedCardBackground)
                    } else if self.prominent {
                        FluidRecordInvitationSurface(
                            animate: animate,
                            recording: self.recording,
                            reduceTransparency: self.reduceTransparency
                        )
                    } else {
                        Capsule().fill(self.theme.palette.contentBackground)
                    }
                }
                .animation(self.reduceMotion ? nil : .easeOut(duration: 0.18), value: highlighted)
            }
            .overlay {
                Capsule().strokeBorder(ink.opacity(configuration.isPressed ? 0.6 : (highlighted ? 0.48 : 0.35)), lineWidth: 1)
                    .animation(self.reduceMotion ? nil : .easeOut(duration: 0.18), value: highlighted)
                    .allowsHitTesting(false)
            }
            .contentShape(Capsule())
            .fixedSize(horizontal: !self.fillsWidth, vertical: false)
            .onHover { self.hovered = $0 && self.isEnabled }
            .onChange(of: self.isEnabled) { _, enabled in
                if !enabled { self.hovered = false }
            }
            .onAppear { self.visible = true }
            .onDisappear { self.visible = false; self.hovered = false }
    }
}

/// Only this small background redraws. The label, hit target, and surrounding layout stay fixed.
private struct FluidRecordInvitationSurface: View {
    let animate: Bool
    let recording: Bool
    let reduceTransparency: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            if self.recording {
                Color.red
            } else {
                LinearGradient(
                    colors: [self.theme.palette.accent, self.theme.palette.accent, self.theme.palette.accent],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !self.animate)) { timeline in
                    let time = self.animate ? timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 24) : 0
                    Canvas { context, size in
                        guard size.width > 0, size.height > 0 else { return }
                        // One broad highlight travels slowly beneath the dots; no blur or particles to retain.
                        if !self.reduceTransparency {
                            let centre = CGPoint(x: size.width * (0.5 + 0.28 * sin(time / 24 * .pi * 2)), y: size.height * 0.35)
                            context.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
                                Gradient(colors: [(AppTheme.Palette.contrastingInk(on: self.theme.palette.accent) == .white ? Color.black : Color.white).opacity(0.08), .clear]),
                                center: centre,
                                startRadius: 0,
                                endRadius: size.width * 0.55
                            ))
                        }
                        for index in 0..<12 {
                            let fraction = (Double(index) * 0.61_803_398_875 + time / 24).truncatingRemainder(dividingBy: 1)
                            let x = size.width * fraction
                            let y = size.height * (0.18 + Double((index * 7) % 13) / 13 * 0.64)
                            let diameter = 1.5 + Double(index % 3) * 0.45
                            let edgeFade = min(1, min(fraction, 1 - fraction) * 12)
                            let opacity = (self.reduceTransparency ? 0.45 : 0.32) * edgeFade
                            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: diameter, height: diameter)), with: .color(.white.opacity(opacity)))
                        }
                    }
                }
            }
        }
        .clipShape(Capsule())
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct ProviderDefaultButton: View {
    let isCurrent: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 6) {
                if self.isCurrent { Image(systemName: "checkmark.circle.fill") }
                Text(LocalizedStringKey(self.isCurrent ? "Current default" : "Set as default"))
            }
        }
        .fluidGlassAction()
        .disabled(self.isCurrent || !self.isEnabled)
        .help(self.isCurrent ? "Used by your main dictation shortcut. App-specific cleanup styles can override it."
            : "Use this provider for your main dictation shortcut. Choose a model and complete setup first; verification is optional.")
    }
}

/// Opt-in native controls. Existing app-wide button styles are deliberately unchanged.
struct FluidGlassControlGroup<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(macOS 26, *), !self.reduceTransparency {
            GlassEffectContainer(spacing: 8) { self.content() }
        } else {
            self.content()
        }
    }
}

private struct FluidGlassActionModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.theme) private var theme
    let prominent: Bool
    let circular: Bool
    let tone: Color?
    let spacious: Bool
    let quiet: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if self.quiet, !self.prominent {
            content.buttonStyle(FluidQuietActionStyle(circular: self.circular, tone: self.tone, spacious: self.spacious))
        } else if !self.isEnabled {
            // Native disabled glass discards its tint and can retain white ink on
            // a white surface. Use paired neutral tokens without fading the label.
            content.buttonStyle(FluidDisabledActionStyle(circular: self.circular, spacious: self.spacious))
        } else if #available(macOS 26, *), !self.reduceTransparency {
            if self.prominent {
                content.buttonStyle(FluidGlassProminentActionStyle(tone: self.tone))
                    .tint(self.tone ?? self.theme.palette.accent)
                    .controlSize(self.spacious ? .extraLarge : .large).buttonBorderShape(self.circular ? .circle : .capsule)
            } else {
                content.buttonStyle(FluidGlassSecondaryActionStyle(tone: self.tone))
                    .controlSize(self.spacious ? .extraLarge : .large).buttonBorderShape(self.circular ? .circle : .capsule)
            }
        } else {
            if self.prominent {
                content.buttonStyle(AccentButtonStyle(tone: self.tone))
            } else {
                content.buttonStyle(FluidOutlinedButtonStyle(height: FluidButtonSize.large.controlHeight, foreground: self.tone ?? self.theme.palette.primaryText))
            }
        }
    }
}

/// Secondary glass uses neutral material, independently of the inherited accent
/// tint. Keep its theme/semantic ink inside the native button's actual label.
@available(macOS 26, *)
struct FluidGlassSecondaryActionStyle: PrimitiveButtonStyle {
    let tone: Color?
    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        let foreground = self.theme.palette.readableText(self.tone ?? self.theme.palette.primaryText)
        return FluidGlassProminentActionStyle.pairedLabelButton(role: configuration.role,
                                                               foreground: foreground,
                                                               action: configuration.trigger) { configuration.label }
            .buttonStyle(.glass)
            .tint(.clear)
    }
}

/// Native glass replaces an inherited foreground on Button itself. Decorate the
/// label inside the real button, then delegate activation and rendering to glass.
@available(macOS 26, *)
struct FluidGlassProminentActionStyle: PrimitiveButtonStyle {
    let tone: Color?
    @Environment(\.theme) private var theme
    @Environment(\.appearsActive) private var appearsActive

    func makeBody(configuration: Configuration) -> some View {
        // Inactive native glass removes its accent fill. Its neutral material
        // needs system ink, including when a brand palette inverts the app surfaces.
        let foreground = self.appearsActive ? self.theme.palette.foreground(on: self.tone ?? self.theme.palette.accent) : Color.primary
        return Self.pairedLabelButton(role: configuration.role,
                                      foreground: foreground,
                                      action: configuration.trigger) { configuration.label }
            .buttonStyle(.glassProminent)
    }

    /// One production construction point keeps the explicit label foreground
    /// below a renderer's inherited defaults. Tests exercise this exact Button.
    static func pairedLabelButton<Label: View>(role: ButtonRole?, foreground: Color,
                                              action: @escaping @MainActor () -> Void,
                                              @ViewBuilder label: () -> Label) -> some View {
        Button(role: role, action: action) {
            label().foregroundStyle(foreground)
        }
    }
}

/// Keeps disabled glass actions legible while retaining their native Button semantics.
struct FluidDisabledActionStyle: ButtonStyle {
    let circular: Bool
    let spacious: Bool
    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        let height = self.spacious ? FluidButtonSize.large.controlHeight : 36
        let shape = Capsule()
        return configuration.label
            .font(self.theme.typography.bodyStrong)
            .foregroundStyle(self.theme.palette.secondaryText)
            .padding(.horizontal, self.circular ? 0 : 18)
            .frame(minWidth: height, minHeight: height)
            .background(self.theme.palette.elevatedCardBackground, in: shape)
            .overlay { shape.strokeBorder(self.theme.palette.secondaryText.opacity(0.35), lineWidth: 1) }
            .contentShape(shape)
    }
}

/// Native button behavior with an unboxed label and a stable, usable hit target.
private struct FluidQuietActionStyle: ButtonStyle {
    let circular: Bool
    let tone: Color?
    let spacious: Bool
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let highlighted = self.isHovered && self.isEnabled
        let height = self.spacious ? FluidButtonSize.large.controlHeight : FluidButtonSize.small.controlHeight
        configuration.label
            .font(self.theme.typography.bodySmall)
            .foregroundStyle(self.isEnabled ? self.theme.palette.readableText(self.tone ?? (highlighted ? self.theme.palette.primaryText : self.theme.palette.secondaryText)) : self.theme.palette.secondaryText)
            .padding(.horizontal, self.circular ? 0 : 8)
            .frame(minWidth: height, minHeight: height)
            .contentShape(Rectangle())
            .scaleEffect(self.isEnabled && configuration.isPressed ? FluidInteractionVisuals.pressedScale : 1)
            .onHover { self.isHovered = $0 && self.isEnabled }
            .onChange(of: self.isEnabled) { _, enabled in
                if !enabled { self.isHovered = false }
            }
            .animation(self.reduceMotion ? nil : .easeOut(duration: 0.12), value: highlighted)
    }
}

/// Glass stays outside the menu label; macOS flattens anything drawn inside it.
private struct FluidGlassMenuActionModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.theme) private var theme

    @ViewBuilder func body(content: Content) -> some View {
        let menu = content
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(FluidGlassMenuActionStyle())
            .fixedSize(horizontal: true, vertical: false)
        // Stationary glass: native menu tracking swallows the release that interactive glass waits for.
        if #available(macOS 26, *), !self.reduceTransparency {
            menu.glassEffect(.regular, in: .capsule)
        } else {
            menu
                .background(self.theme.palette.cardBackground, in: Capsule())
                .overlay { Capsule().strokeBorder(self.theme.palette.cardBorder, lineWidth: 1).allowsHitTesting(false) }
        }
    }
}

/// Padding lives in the label so the whole pill opens the menu.
private struct FluidGlassMenuActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14)
            .frame(height: 32)
            .contentShape(Capsule())
    }
}

extension View {
    func fluidGlassMenuAction() -> some View {
        self.modifier(FluidGlassMenuActionModifier())
    }

    func fluidGlassAction(prominent: Bool = false, circular: Bool = false, tone: Color? = nil, spacious: Bool = false, quiet: Bool = false) -> some View {
        self.modifier(FluidGlassActionModifier(prominent: prominent, circular: circular, tone: tone, spacious: spacious, quiet: quiet))
            .fixedSize(horizontal: true, vertical: false)
    }
}

extension AppTheme.Metrics {
    /// Shared showcase geometry, separate from compact form rows.
    enum Showcase {
        static let pageMaxWidth: CGFloat = 1080
        static let sideCardMaxWidth: CGFloat = 240
        static let cardHeight: CGFloat = 320
        static let cardMaxWidth: CGFloat = 320
        static let cardRadius: CGFloat = 24
        static let stageHeight: CGFloat = 350
        static let metricWidth: CGFloat = 128
        static let compactMetricWidth: CGFloat = 112
    }
}

import SwiftUI

/// Shared page geometry. Pane interiors and readable document columns retain their own layouts.
enum FluidPageLayout {
    static let inset: CGFloat = 20
    static let sectionSpacing: CGFloat = 20

    enum Width {
        case overview, standard, reading, form, expanding

        var maximum: CGFloat {
            switch self {
            case .expanding: .infinity
            case .overview: 1440
            case .standard: 1080
            case .reading: 880
            case .form: 720
            }
        }
    }
}

private struct FluidPageToolbarVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

private struct FluidToolbarTrailingInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 80
}

private struct FluidToolbarPairedForegroundKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    fileprivate var fluidToolbarPairedForeground: Color? {
        get { self[FluidToolbarPairedForegroundKey.self] }
        set { self[FluidToolbarPairedForegroundKey.self] = newValue }
    }

    var fluidToolbarTrailingInset: CGFloat {
        get { self[FluidToolbarTrailingInsetKey.self] }
        set { self[FluidToolbarTrailingInsetKey.self] = newValue }
    }

    /// Hidden app content remains mounted behind Settings, but must not contribute actions.
    var fluidPageToolbarVisible: Bool {
        get { self[FluidPageToolbarVisibleKey.self] }
        set { self[FluidPageToolbarVisibleKey.self] = newValue }
    }
}

private struct FluidPageActions<Actions: View>: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.fluidPageToolbarVisible) private var isVisible
    @Environment(\.fluidToolbarTrailingInset) private var trailingInset
    let enabled: Bool
    let actions: Actions

    func body(content: Content) -> some View {
        // Keep the portable palette and its physical scheme together when
        // AppKit rehosts actions. The native glass can retain an older scheme.
        let pageTheme = self.theme
        let pageColorScheme = pageTheme.palette.nativeColorScheme(fallback: pageTheme.variant ?? self.colorScheme)
        #if os(macOS)
        ToolbarAppearanceTrace.emit(kind: "page-action-input", source: "FluidPageActions", payload: [
            "colorScheme": pageColorScheme == .dark ? "dark" : "light",
            "visible": self.isVisible, "enabled": self.enabled,
        ])
        #endif
        return content.toolbar {
            if self.isVisible, self.enabled {
                // Keep page actions separate from the shared trailing controls.
                if #available(macOS 26, *) {
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                }
                if #available(macOS 26, *) {
                    ToolbarItemGroup(placement: .primaryAction) {
                        self.pairedActions(theme: pageTheme, colorScheme: pageColorScheme)
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItemGroup(placement: .primaryAction) {
                        self.pairedActions(theme: pageTheme, colorScheme: pageColorScheme)
                    }
                }
                FluidToolbarEdgeSpace(width: self.trailingInset)
            }
        }
    }

    private func pairedActions(theme: AppTheme, colorScheme: ColorScheme) -> some View {
        self.actions
            .buttonStyle(FluidOutlinedButtonStyle())
            .labelStyle(FluidToolbarLabelStyle())
            // Nested controls may retain an explicit automatic button style.
            // Pair their labels with this surface as well as the shared style.
            .background(theme.palette.elevatedCardBackground,
                        in: RoundedRectangle(cornerRadius: theme.metrics.corners.md, style: .continuous))
            .environment(\.fluidToolbarPairedForeground, theme.palette.readableText(theme.palette.primaryText))
            .environment(\.theme, theme)
            .environment(\.colorScheme, colorScheme)
    }
}

/// Match symbol geometry without replacing native macOS toolbar chrome or interaction.
private struct FluidToolbarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.icon.fluidToolbarIcon()
    }
}

/// A page action owns an opaque surface, so even nested Image labels must use
/// its paired ink. Other toolbar items retain native ink or their explicit tone.
private struct FluidToolbarIconStyle: ViewModifier {
    @Environment(\.fluidToolbarPairedForeground) private var pairedForeground
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    let foreground: Color?

    func body(content: Content) -> some View {
        let pairedInk = self.pairedForeground.map { self.isEnabled ? $0 : self.theme.palette.secondaryText }
        content.foregroundStyle(self.foreground ?? pairedInk ?? .primary)
    }
}

extension View {
    // Native glass can choose an appearance independently of the app palette.
    // Color.primary resets inherited brand ink; HierarchicalShapeStyle.primary
    // would merely reuse that inherited foreground style.
    func fluidToolbarIcon(foreground: Color? = nil, file: StaticString = #fileID, line: UInt = #line) -> some View {
        self.modifier(FluidToolbarIconStyle(foreground: foreground))
            .font(.system(size: 17, weight: .medium))
            .imageScale(.medium)
            .frame(width: 22, height: 22)
            .traceToolbarAppearance(file: file, line: line)
    }

    func fluidPageContent(width: FluidPageLayout.Width = .standard, alignment: Alignment = .leading) -> some View {
        self.padding(FluidPageLayout.inset)
            .frame(maxWidth: width.maximum, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    func fluidPageActions<Actions: View>(enabled: Bool = true, @ViewBuilder actions: () -> Actions) -> some View {
        self.modifier(FluidPageActions(enabled: enabled, actions: actions()))
    }
}

/// A separate invisible item leaves the native glass and button hit areas intact.
struct FluidToolbarEdgeSpace: ToolbarContent {
    let width: CGFloat

    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItem(placement: .primaryAction) { self.space }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) { self.space }
        }
    }

    private var space: some View {
        Color.clear
            .frame(width: max(0, self.width - 8), height: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

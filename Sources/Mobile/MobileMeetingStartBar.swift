import SwiftUI
import UIKit

/// Presentation only; recording admission and preparation stay with the existing root action.
struct MobileMeetingStartBar: View {
    let floating: Bool
    let preparing: Bool
    let startDisabled: Bool
    let start: () -> Void
    @Environment(\.theme) private var theme

    static func usesFloatingLayout(idiom: UIUserInterfaceIdiom, verticalSizeClass: UserInterfaceSizeClass?,
                                   dynamicTypeSize: DynamicTypeSize) -> Bool {
        idiom == .phone && verticalSizeClass == .compact && !dynamicTypeSize.isAccessibilitySize
    }

    var body: some View {
        Group {
            if floating {
                startButton.fixedSize(horizontal: true, vertical: false)
            } else {
                startButton
                    .padding(.horizontal, 24).padding(.top, 12)
                    .frame(maxWidth: 560).frame(maxWidth: .infinity)
                    .background(theme.palette.toolbarBackground)
            }
        }
    }

    private var startButton: some View {
        Button(action: start) {
            Label(PichiLocalization.text(preparing ? "Preparing recording…" : "Start Recording"), systemImage: "record.circle")
                .foregroundStyle(theme.palette.accentForeground)
                .frame(maxWidth: floating ? nil : .infinity, minHeight: floating ? 32 : 48)
                .animation(nil, value: preparing)
        }.buttonStyle(.borderedProminent)
            .disabled(startDisabled)
            .accessibilityIdentifier("meeting.start")
    }
}

/// Reserve scrolling room, not a footer strip: the last row can move above the floating action.
struct MobileMeetingStartPlacement: ViewModifier {
    let control: MobileMeetingStartBar
    @State private var floatingHeight: CGFloat = 80

    func body(content: Content) -> some View {
        if control.floating {
            content
                .contentMargins(.bottom, floatingHeight, for: .scrollContent)
                .overlay(alignment: .bottomTrailing) {
                    control.padding(.horizontal, 24).padding(.vertical, 12)
                        .background {
                            GeometryReader { geometry in
                                Color.clear
                                    .onAppear { floatingHeight = geometry.size.height }
                                    .onChange(of: geometry.size.height) { _, height in floatingHeight = height }
                            }
                        }
                }
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) { control }
        }
    }
}

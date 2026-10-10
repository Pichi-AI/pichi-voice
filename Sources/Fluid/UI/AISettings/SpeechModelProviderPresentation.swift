import AppKit
import SwiftUI

/// Provider marks describe the execution provider; model names and publisher credits stay data.
/// Typed metadata replaces label substring matching and is shared by every model surface.
nonisolated struct SpeechModelProviderPresentation: Equatable, Sendable {
    enum Mark: Equatable, Sendable {
        case appBrand
        case systemSymbol(String)
        case asset(String)
    }
    enum Background: Equatable, Sendable { case neutral, themed, accent }
    let mark: Mark
    let background: Background
    var imageScale: CGFloat = 0.64

    func resolvedMark(assetAvailable: (String) -> Bool) -> Mark {
        guard case let .asset(name) = self.mark, !assetAvailable(name) else { return self.mark }
        return .systemSymbol("waveform")
    }
}

extension SettingsStore.SpeechModel.Provider {
    var presentation: SpeechModelProviderPresentation {
        switch self {
        case .pichi:
            SpeechModelProviderPresentation(mark: .appBrand, background: .accent, imageScale: 1)
        case .nvidia:
            SpeechModelProviderPresentation(mark: .asset("Provider_NVIDIA"), background: .neutral, imageScale: 0.86)
        case .apple:
            SpeechModelProviderPresentation(mark: .systemSymbol("apple.logo"), background: .themed)
        case .openai:
            SpeechModelProviderPresentation(mark: .asset("Provider_OpenAI"), background: .neutral)
        case .cohere:
            SpeechModelProviderPresentation(mark: .asset("Provider_Cohere"), background: .accent)
        default:
            SpeechModelProviderPresentation(mark: .systemSymbol("waveform"), background: .accent)
        }
    }
}

/// Existing shared card geometry, with a consistent mark for providers without a bundled asset.
struct SpeechModelProviderMark: View {
    @Environment(\.theme) private var theme
    let presentation: SpeechModelProviderPresentation
    var providerColor: Color? = nil
    var size: CGFloat = 28

    private var background: Color {
        switch self.presentation.background {
        case .neutral: Color(red: 0.97, green: 0.97, blue: 0.97)
        case .themed: self.theme.palette.cardBackground.opacity(0.9)
        case .accent:
            (self.presentation.mark == .appBrand ? self.theme.palette.accent : (self.providerColor ?? self.theme.palette.accent)).opacity(0.2)
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: self.size / 4, style: .continuous).fill(self.background)
            switch self.presentation.resolvedMark(assetAvailable: { NSImage(named: $0) != nil }) {
            case .appBrand:
                PichiBrandMark(size: self.size, color: self.theme.palette.accent)
            case let .systemSymbol(name):
                Image(systemName: name)
                    .font(.fluidSystem(size: self.size / 2, weight: .medium))
                    .foregroundStyle(self.presentation.background == .neutral ? Color.black : self.theme.palette.primaryText)
            case let .asset(name):
                Image(name).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: self.size * self.presentation.imageScale, height: self.size * self.presentation.imageScale)
            }
        }
        .frame(width: self.size, height: self.size)
        .clipShape(RoundedRectangle(cornerRadius: self.size / 4, style: .continuous))
        .accessibilityHidden(true)
    }
}

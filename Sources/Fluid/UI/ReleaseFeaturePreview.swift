import SwiftUI

/// Static product illustrations: no live user data, model loading, or recording work.
struct ReleaseFeaturePreview: View {
    let kind: ReleaseHighlightsContent.Preview
    @Environment(\.theme) private var theme
    @Environment(\.locale) private var locale

    var body: some View {
        Group {
            switch self.kind {
            case .meeting: self.meeting
            case .dashboard: self.dashboard
            case .models: self.models
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(self.theme.palette.elevatedCardBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(self.theme.palette.cardBorder, lineWidth: 1)
        }
        .foregroundStyle(self.theme.palette.primaryText)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var meeting: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "waveform").foregroundStyle(self.theme.palette.accentText)
                Text("Product catch-up").font(.fluidSystem(size: 11, weight: .semibold))
                Spacer(minLength: 0)
                Text("12:48").font(.fluidSystem(size: 9, design: .monospaced))
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(self.theme.palette.accent.opacity(0.18))
                    .frame(width: 19, height: 19)
                    .overlay(Text("A").font(.fluidSystem(size: 9, weight: .medium)).foregroundStyle(self.theme.palette.accentText))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Let’s get the next release ready.")
                        .font(.fluidSystem(size: 10))
                    Text("We’ll start with the new features.")
                        .font(.fluidSystem(size: 9)).foregroundStyle(self.theme.palette.secondaryText)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Label("Summary", systemImage: "sparkles")
                    .font(.fluidSystem(size: 9, weight: .semibold))
                    .foregroundStyle(self.theme.palette.accentText)
                Text("Review features. Prepare the release.")
                    .font(.fluidSystem(size: 9)).foregroundStyle(self.theme.palette.secondaryText)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(self.theme.palette.cardBackground, in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Good morning.").font(.fluidSystem(size: 16, weight: .semibold, role: .title))
            HStack(spacing: 8) {
                self.stat(1240.formatted(.number.locale(self.locale)), label: "WORDS DICTATED", symbol: "waveform")
                self.stat(String(format: PichiLocalization.text("%lld min", locale: self.locale), locale: self.locale, arguments: [Int64(24)]), label: "TIME SAVED", symbol: "clock")
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                Text(AppBrand.text("Search across FluidVoice"))
                Spacer(minLength: 0)
            }
            .font(.fluidSystem(size: 9))
            .foregroundStyle(self.theme.palette.secondaryText)
            .padding(8)
            .background(self.theme.palette.cardBackground, in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private func stat(_ value: String, label: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(self.theme.palette.accentText)
            Text(value).font(.fluidSystem(size: 16, weight: .semibold, design: .rounded))
            Text(PichiLocalization.text(label)).font(.fluidSystem(size: 6, weight: .medium)).foregroundStyle(self.theme.palette.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(PrivateAIProviderFeature.shared.isAvailable ? AppBrand.text("Fluid Intelligence") : PichiLocalization.text("AI Providers"), systemImage: "sparkles")
                .font(.fluidSystem(size: 11, weight: .semibold))
            if PrivateAIProviderFeature.shared.isAvailable {
                self.model("Fluid-1 Pico", detail: "Light & quick", symbol: "bolt")
                self.model("Fluid-1 Mini", detail: "Everyday writing", symbol: "text.alignleft")
                self.model("Fluid-1 Quad", detail: "More capable", symbol: "cpu")
            } else {
                self.model("Your provider", detail: "Your choice", symbol: "sparkles")
                self.model("Your model", detail: "Your workflow", symbol: "cpu")
            }
        }
    }

    private func model(_ name: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11)).foregroundStyle(self.theme.palette.accentText)
                .frame(width: 23, height: 23)
                .background(self.theme.palette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            Text(PichiLocalization.text(name)).font(.fluidSystem(size: 10, weight: .medium))
            Spacer(minLength: 0)
            Text(PichiLocalization.text(detail)).font(.fluidSystem(size: 8)).foregroundStyle(self.theme.palette.secondaryText)
        }
    }
}

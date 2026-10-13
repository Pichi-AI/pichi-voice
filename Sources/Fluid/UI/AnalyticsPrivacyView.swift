import SwiftUI

struct AnalyticsPrivacyView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Anonymous Analytics")
                        .font(.fluidSystem(size: 18, weight: .semibold))
                    Text(PichiLocalization.text(AnalyticsConfig.fromBundle().isConfigured ? "Daily activity and optional detailed analytics" : "Telemetry is disabled in this distribution"))
                        .font(.fluidSystem(size: 12))
                        .foregroundStyle(self.theme.palette.secondaryText)
                }

                Spacer()

                Button("Done") { self.dismiss() }
                    .fluidOutlinedButton()
            }

            Divider().opacity(0.4)

            self.contactInfoView

            Divider().opacity(0.4)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !AnalyticsConfig.fromBundle().isConfigured {
                        self.sectionTitle("No analytics are sent")
                        self.bullet("This app does not send daily activity, detailed metrics or beta timing summaries to an analytics service.")
                        self.bullet("Speech recognition runs on this Mac. AI enhancement may use a provider you configure.")
                    } else {
                    self.bullet(PichiLocalization.format("Analytics destination: %@", AnalyticsConfig.fromBundle().postHogHost))
                    self.sectionTitle("Always collected")
                    self.bullet("A random installation ID, app version, the operating-system label macOS, and basic hardware info.")
                    self.bullet("One active-use signal per local day after you interact with the app, buffered on this Mac and sent weekly.")
                    self.bullet(AppBrand.text("Beta builds also send one daily aggregate of ASR and Fluid Intelligence timing distributions, including macOS version. No individual timing samples are sent."))

                    self.sectionTitle("When detailed analytics is enabled")
                    self.bullet("Daily totals for Dictation, Command Mode, Edit Mode, and meeting transcription.")
                    self.bullet("Onboarding steps viewed and completed, including skips.")
                    self.bullet("Approved public transcription and AI provider/model identifiers, counted as daily totals. Custom names are replaced with generic categories.")
                    self.bullet("Model download source, outcome, and download duration.")
                    self.bullet("Daily aggregated insertion timing statistics—including toggle-stop-to-paste-dispatch—split by delivery path and outcome.")

                    self.sectionTitle("We do NOT collect")
                    self.bullet("Any transcription text or audio.")
                    self.bullet("Selected text, rewrite prompts, or AI responses.")
                    self.bullet("Terminal commands or outputs from Command Mode.")
                    self.bullet("Window titles, app names, file names/paths, clipboard contents, or anything you type.")
                    self.bullet("Hardware serial numbers, other unique device identifiers, target-app identity, or individual transcription and insertion timings/events.")
                    self.bullet("No session replay, automatic UI capture, person profiles or geographic enrichment are enabled.")

                    self.sectionTitle("How it’s used")
                    self.bullet("Daily activity measures active installations and retention without requiring accounts.")
                    self.bullet("Optional detailed analytics helps us understand feature adoption, insertion performance, onboarding completion, and model usage.")
                    self.bullet(AppBrand.text("Beta timing summaries help us compare ASR and Fluid Intelligence speed across Mac hardware and macOS versions."))

                    self.sectionTitle("Control")
                    self.bullet("You can disable detailed analytics anytime in Settings → Share Detailed Anonymous Analytics.")
                    self.bullet("Disabling detailed analytics securely removes its queued and aggregated data from this Mac. Daily activity and beta timing summaries remain enabled.")
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(self.theme.palette.contentBackground)
    }

    private var contactInfoView: some View {
        Text(self.contactInfoText)
            .font(.fluidSystem(size: 13))
            .foregroundStyle(self.theme.palette.primaryText)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(self.theme.palette.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(self.theme.palette.cardBorder.opacity(0.6), lineWidth: 1)
            )
    }

    private var contactInfoText: AttributedString {
        var text = AttributedString(PichiLocalization.text("For privacy questions, contact our support team."))
        if let range = text.range(of: PichiLocalization.text("support team")) {
            text[range].link = AppBrand.supportURL
            text[range].foregroundColor = self.theme.palette.accentText
        }

        return text
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(PichiLocalization.text(text))
            .font(.fluidSystem(size: 12, weight: .semibold))
            .foregroundStyle(self.theme.palette.accentText)
            .padding(.top, 4)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundStyle(self.theme.palette.secondaryText)
            Text(PichiLocalization.text(text))
                .font(.fluidSystem(size: 13))
                .foregroundStyle(self.theme.palette.primaryText)
            Spacer(minLength: 0)
        }
    }
}

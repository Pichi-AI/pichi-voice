import SwiftUI

struct MeetingModelSettingsSection: View {
    let processingMode: MeetingSpeakerProcessingMode
    let onModelImported: @MainActor () -> Void
    @Environment(\.theme) private var theme
    @ObservedObject private var store: MeetingDiarizationModelStore
    @State private var showingDetails = false

    init(store: MeetingDiarizationModelStore, processingMode: MeetingSpeakerProcessingMode,
         onModelImported: @escaping @MainActor () -> Void) {
        self._store = ObservedObject(wrappedValue: store)
        self.processingMode = processingMode
        self.onModelImported = onModelImported
    }

    var body: some View {
        FluidManagementGroup(title: PichiLocalization.text("Speaker labels")) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                HStack(spacing: self.theme.metrics.spacing.lg) {
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                        Text("Identify each speaker")
                            .font(self.theme.typography.bodyStrong)
                            .foregroundStyle(self.theme.palette.primaryText)
                        self.status
                    }
                    Spacer(minLength: self.theme.metrics.spacing.md)
                    if case .failed = self.store.state {
                        Button("Try again") { self.store.prepareInBackground() }
                            .meetingGlassAction()
                            .disabled(!CPUArchitecture.isAppleSilicon)
                    }
                }
                DisclosureGroup(isExpanded: self.$showingDetails) {
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                        if case let .ready(installed) = self.store.state {
                            Text("Nemotron 3 Diarization · \(installed.totalByteCount.formatted(.byteCount(style: .file).locale(PichiLocalization.locale)))")
                        }
                        Text(CPUArchitecture.isAppleSilicon
                            ? (self.processingMode == .streaming
                                ? PichiLocalization.text("Downloads once and stays on this Mac. Speaker identification runs locally during recording.")
                                : PichiLocalization.text("Downloads once and stays on this Mac. Speaker identification runs locally after recording."))
                            : PichiLocalization.text("Automatic speaker separation requires Apple Silicon. GigaAM can transcribe recordings on Intel with unknown speaker identities."))
                    }
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, self.theme.metrics.spacing.sm)
                } label: {
                    Text("Model details")
                        .meetingHoverFeedback(cornerRadius: self.theme.metrics.corners.sm)
                }
                .disclosureGroupStyle(FluidDisclosureGroupStyle())
                .font(self.theme.typography.captionStrong)
                .foregroundStyle(self.theme.palette.secondaryText)
            }
        }
        .task(id: ObjectIdentifier(self.store)) { self.store.prepareInBackground() }
        .onChange(of: self.store.state) { _, state in
            if case .ready = state { self.onModelImported() }
        }
    }

    @ViewBuilder private var status: some View {
        switch self.store.state {
        case .idle, .checking:
            HStack(spacing: self.theme.metrics.spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Checking model…")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
        case let .downloading(fraction):
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                ProgressView(value: fraction)
                    .frame(maxWidth: 220)
                Text(fraction < 1 ? "Downloading · \(Int(fraction * 100))%" : PichiLocalization.text("Installing…"))
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .monospacedDigit()
            }
        case .ready:
            Label(self.processingMode == .streaming
                ? PichiLocalization.text("Ready · runs during recording")
                : PichiLocalization.text("Ready · runs after recording"), systemImage: "checkmark.circle.fill")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.success)
        case let .failed(message):
            Text(message)
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

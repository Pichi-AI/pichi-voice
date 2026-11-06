import Combine
import SwiftUI

/// A compact browser for one word's persisted pronunciation examples. Feature-only
/// legacy references remain matching data and are never presented as playable audio.
struct DictionarySavedSamplesView: View {
    let entry: SettingsStore.CustomDictionaryEntry
    @ObservedObject var asr: ASRService
    private let profile = PrivateProfileStorage.current
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @StateObject private var playback = DictionaryInspectionPlayback()
    @State private var samples: [Sample] = []
    @State private var refresh = 0
    @State private var loading = true
    @State private var deleting = false
    @State private var deletion: Sample?
    @State private var error: String?

    private struct Sample: Identifiable {
        let id: String
        let profileLabel: String
        let capture: PronunciationEnrollmentCapture
    }

    private var isCurrent: Bool {
        PrivateProfileStorage.isReadable(self.profile) && PrivateProfileStorage.acceptsNewWork &&
            SettingsStore.shared.customDictionaryEntries.contains { $0.id == self.entry.id && $0.replacement == self.entry.replacement }
    }

    private var recordingBusy: Bool { self.asr.isRunningOrStarting || self.asr.activeExclusiveActivity != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
            HStack {
                Text(verbatim: self.entry.replacement).font(self.theme.typography.sectionTitle)
                Spacer()
                Button("Done") { self.dismiss() }.fluidGlassAction()
            }
            if self.loading {
                ProgressView().frame(maxWidth: .infinity)
            } else if self.samples.isEmpty {
                Text("No saved recordings.")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                        ForEach(Array(self.samples.enumerated()), id: \.element.id) { index, sample in
                            HStack(spacing: self.theme.metrics.spacing.sm) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(PichiLocalization.format("Recording %lld", index + 1))
                                        .font(self.theme.typography.bodySmallStrong)
                                    if let heard = sample.capture.observedText, !heard.isEmpty {
                                        Text(PichiLocalization.format("Recognized as: %@", heard))
                                            .font(self.theme.typography.caption)
                                            .foregroundStyle(self.theme.palette.secondaryText)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer(minLength: self.theme.metrics.spacing.sm)
                                Button {
                                    guard self.isCurrent, !self.recordingBusy else { return }
                                    self.playback.playSavedSample(sample.capture, entryID: self.entry.id,
                                        profileLabel: sample.profileLabel, store: PronunciationDictionaryStore.shared,
                                        id: sample.id, isCurrent: { self.isCurrent && !self.recordingBusy })
                                } label: {
                                    Image(systemName: self.playback.playing == sample.id ? "stop.fill" : "play.fill")
                                }
                                .fluidGlassAction(circular: true)
                                .help(PichiLocalization.text(self.playback.playing == sample.id ? "Stop" : "Play recording"))
                                .accessibilityLabel(PichiLocalization.text(self.playback.playing == sample.id ? "Stop" : "Play recording"))
                                Button(role: .destructive) { self.deletion = sample } label: {
                                    Image(systemName: "trash")
                                }
                                .fluidGlassAction(circular: true)
                                .help("Delete recording")
                                .accessibilityLabel("Delete recording")
                            }
                            .disabled(self.recordingBusy || self.deleting)
                            if index < self.samples.count - 1 { Divider() }
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
            if let message = self.error ?? self.playback.error {
                Text(PichiLocalization.text(message))
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.readableText(.red))
            }
        }
        .padding(self.theme.metrics.spacing.lg)
        .frame(width: 430)
        .foregroundStyle(self.theme.palette.primaryText)
        .background(self.theme.palette.contentBackground)
        .task(id: self.refresh) { await self.loadSamples() }
        .onReceive(NotificationCenter.default.publisher(for: PronunciationDictionaryStore.didChangeNotification).receive(on: RunLoop.main)) { _ in
            self.playback.stop()
            self.refresh &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: PrivateProfileService.willConceal)) { _ in
            self.playback.stop(); self.samples = []; self.deletion = nil; self.error = nil; self.dismiss()
        }
        .onReceive(NotificationCenter.default.publisher(for: .parakeetVocabularyDidChange).receive(on: RunLoop.main)) { _ in
            if !self.isCurrent { self.playback.stop(); self.dismiss() }
        }
        .onChange(of: self.recordingBusy) { _, busy in if busy { self.playback.stop() } }
        .onDisappear { self.playback.stop() }
        .alert("Delete recording?", isPresented: Binding(get: { self.deletion != nil }, set: { if !$0 { self.deletion = nil } })) {
            Button("Cancel", role: .cancel) { self.deletion = nil }
            Button("Delete recording", role: .destructive) {
                guard let selected = self.deletion else { return }
                self.deletion = nil
                Task { await self.remove(selected) }
            }
        } message: {
            Text("The word and its other recordings will stay saved.")
        }
    }

    private func loadSamples() async {
        guard self.isCurrent else { self.playback.stop(); self.dismiss(); return }
        let profiles = await PronunciationDictionaryStore.shared.allProfiles()
        guard !Task.isCancelled, self.isCurrent else { return }
        self.samples = profiles.filter { $0.dictionaryEntryID == self.entry.id && $0.label.caseInsensitiveCompare(self.entry.replacement) == .orderedSame }
            .flatMap { stored in
                stored.enrollments.enumerated().compactMap { index, capture in
                    guard let audioID = capture.originalAudioID ?? capture.inspectionID else { return Sample?.none }
                    return Sample(id: "\(stored.id):\(audioID):\(index)", profileLabel: stored.label, capture: capture)
                }
            }
        self.loading = false
    }

    private func remove(_ sample: Sample) async {
        guard self.isCurrent, !self.recordingBusy, !self.deleting else { return }
        self.playback.stop()
        self.deleting = true
        self.error = nil
        defer { self.deleting = false }
        let store = PronunciationDictionaryStore.shared
        DictionaryAudioLearningService.shared.preserveDictionaryEntry(self.entry.id)
        if let evidenceID = sample.capture.originalAudioID {
            DictionaryAudioLearningService.shared.discardPendingEvidence(evidenceID)
        }
        do {
            try await store.removeSavedSample(sample.capture, dictionaryEntryID: self.entry.id, expectedProfileLabel: sample.profileLabel)
            guard self.isCurrent else { return }
            ASRService.invalidateDictionaryCache()
            DictionaryEntriesChangeNotice.post()
            self.refresh &+= 1
        } catch {
            guard self.isCurrent else { return }
            self.error = error.localizedDescription
        }
    }
}

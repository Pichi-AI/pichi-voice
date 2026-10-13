import AVFoundation
import Combine
import SwiftUI
import UIKit

/// Platform navigation and transient view state only. The shared coordinator owns every meeting.
struct MobileMeetingRoot: View {
    @ObservedObject var coordinator: MeetingSessionCoordinator
    @ObservedObject var asr: ASRService
    let store: any MeetingSessionStoring
    let privacy: PichiTranscriptPrivacyService
    let microphones: @Sendable () async throws -> MeetingMicrophoneCatalogSnapshot
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme
    @State private var destination = Destination.meetings
    @StateObject private var historySnapshot: MeetingHistorySnapshot
    private var sessions: [MeetingSession] { historySnapshot.sessions }
    @State private var selectedHistory: MeetingSession?
    @State private var search = ""
    @State private var isBusy = false
    @State private var error: String?
    @State private var showError = false
    @State private var showMicrophoneSettings = false
    @State private var showRecordingSettings = false
    @State private var microphoneSnapshot = MeetingMicrophoneCatalogSnapshot(identities: [], defaultCoreAudioUID: nil)
    @State private var edit: MeetingEditDraft?
    @State private var deleteCandidate: MeetingSession?
    @State private var share: MeetingSharePayload?
    @StateObject private var playback = MeetingSegmentPlayback()


    init(coordinator: MeetingSessionCoordinator, asr: ASRService, store: any MeetingSessionStoring,
         privacy: PichiTranscriptPrivacyService,
         microphones: @escaping @Sendable () async throws -> MeetingMicrophoneCatalogSnapshot) {
        self.coordinator = coordinator; self.asr = asr; self.store = store
        self.privacy = privacy; self.microphones = microphones
        self._historySnapshot = StateObject(wrappedValue: MeetingHistorySnapshot(load: { try await store.loadAll() }))
    }

    enum Destination: String, CaseIterable, Identifiable {
        case meetings, history, settings
        var id: String { rawValue }
        var title: String {
            switch self { case .meetings: return "Meetings"; case .history: return "History"; case .settings: return "Settings" }
        }
        var symbol: String {
            switch self { case .meetings: return "waveform"; case .history: return "clock"; case .settings: return "gearshape" }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 700 {
                HStack(spacing: 0) {
                    sidebar.frame(width: 220)
                    Divider()
                    navigation.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                TabView(selection: $destination) {
                    ForEach(Destination.allCases) { item in
                        navigation(for: item)
                            .tag(item)
                            .tabItem { Label(PichiLocalization.text(item.title), systemImage: item.symbol) }
                    }
                }
            }
        }
        .foregroundStyle(theme.palette.primaryText)
        .background(theme.palette.windowBackground)
        .alert(PichiLocalization.text("Error"), isPresented: $showError) {
            if showMicrophoneSettings {
                Button(PichiLocalization.text("Open Settings")) {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            }
            Button(PichiLocalization.text("OK"), role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .sheet(isPresented: $showRecordingSettings) {
            NavigationStack { MobileRecordingSettings(microphones: microphoneSnapshot.identities) }
        }
        .sheet(item: $edit) { draft in
            MeetingEditSheet(draft: draft) { updated in
                run {
                    let result: MeetingSession
                    switch draft.kind {
                    case .segment(let segment):
                        result = try await coordinator.editTranscriptText(sessionID: draft.session.id, segmentID: segment.id, text: updated,
                            expectedRevision: segment.revision)
                    case .speaker(let speaker):
                        result = try await coordinator.renameSpeaker(sessionID: draft.session.id, speakerID: speaker.id, to: updated)
                    case .title:
                        result = try await coordinator.renameSession(sessionID: draft.session.id, to: updated)
                    }
                    if selectedHistory?.id == result.id { selectedHistory = result }
                    await refreshHistory()
                }
            }
        }
        .sheet(item: $share) { payload in
            VStack(spacing: 0) {
                Text(AppBrand.text("Exported transcripts are outside FluidVoice's retention controls and may be indexed or synced by other apps."))
                    .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText).padding()
                MobileActivitySheet(items: payload.items) { share = nil }
            }.onDisappear { payload.cleanup() }
        }
        .confirmationDialog(PichiLocalization.text("Delete Meeting"), isPresented: Binding(
            get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }
        )) {
            Button(PichiLocalization.text("Delete"), role: .destructive) {
                guard let candidate = deleteCandidate else { return }
                run {
                    try await coordinator.deleteSession(id: candidate.id)
                    if selectedHistory?.id == candidate.id { selectedHistory = nil }
                    await refreshHistory()
                }
                deleteCandidate = nil
            }
        } message: { Text(PichiLocalization.text("Delete this meeting and its recordings?")) }
        .task {
            await coordinator.ensureRestored()
            await coordinator.sweepExpiredAudio()
            await refreshHistory()
            await refreshMicrophones()
        }
        .onChange(of: coordinator.state) { _, state in
            if coordinator.isRecording { playback.stop() }
            Task { await refreshHistory() }
        }
        .onChange(of: destination) { _, _ in playback.stop() }
        .onChange(of: selectedHistory?.id) { _, _ in playback.stop() }
        .onChange(of: settings.meetingAudioRetentionPolicy) { _, _ in
            Task { await coordinator.sweepExpiredAudio(); await refreshHistory() }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.xxl) {
            HStack {
                PichiBrandMark(size: 34, color: theme.palette.accent)
                Text(AppBrand.appName).font(theme.typography.sectionTitle)
            }.padding(.vertical, 16)
            ForEach(Destination.allCases) { item in
                Button { destination = item } label: {
                    Label(PichiLocalization.text(item.title), systemImage: item.symbol)
                        .font(theme.typography.sidebarItem)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .padding(.horizontal, 12)
                        .background(destination == item ? theme.palette.accent : .clear, in: RoundedRectangle(cornerRadius: theme.metrics.corners.md))
                        .foregroundStyle(destination == item ? theme.palette.accentForeground : theme.palette.primaryText)
                }.buttonStyle(.plain).accessibilityIdentifier("navigation.\(item.rawValue)")
            }
            Spacer()
        }.padding(16).background(theme.palette.sidebarBackground)
    }

    private var navigation: some View { navigation(for: destination) }

    private func navigation(for item: Destination) -> some View {
        NavigationStack {
            Group {
                switch item {
                case .meetings: currentMeeting
                case .history: history
                case .settings: MobileSettingsRoot(asr: asr, privacy: privacy, microphones: microphoneSnapshot.identities, reportError: report)
                }
            }
            .navigationTitle(item == .meetings ? AppBrand.meetingName : PichiLocalization.text(item.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if item == .meetings, coordinator.isQuiescent, !coordinator.isRecording {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { newMeeting() } label: { Label(PichiLocalization.text("New Meeting"), systemImage: "plus") }
                            .accessibilityIdentifier("meeting.new")
                    }
                }
            }
        }
    }

    @ViewBuilder private var currentMeeting: some View {
        if let session = coordinator.currentSession {
            switch coordinator.state {
            case .preparing, .recording, .recordingDegraded, .stopping:
                recording(session)
            case .processing(_, let stage): processing(session, stage: stage)
            case .completed: transcript(session)
            case .interrupted, .failed: recovery(session)
            case .idle: start
            }
        } else { start }
    }

    private var start: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.metrics.spacing.xl) {
                Text(PichiLocalization.text("Be in the conversation.")).font(theme.typography.displayTitle)
                Text(PichiLocalization.text("Record your meeting. Come back to every word."))
                    .font(theme.typography.statement).foregroundStyle(theme.palette.secondaryText)
                VStack(alignment: .leading, spacing: 12) {
                    Text(PichiLocalization.text("No call open.")).font(theme.typography.sectionTitle)
                    Text(PichiLocalization.text("Your mic will record the room."))
                        .foregroundStyle(theme.palette.secondaryText)
                    HStack {
                        Button { beginMeeting() } label: {
                            Label(PichiLocalization.text("Start Recording"), systemImage: "record.circle")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.borderedProminent).disabled(isBusy || !coordinator.isQuiescent)
                            .accessibilityIdentifier("meeting.start")
                        Button { showRecordingSettings = true } label: {
                            Image(systemName: "slider.horizontal.3").frame(minWidth: 44, minHeight: 44)
                        }.accessibilityLabel(PichiLocalization.text("Recording settings"))
                            .accessibilityIdentifier("meeting.settings")
                    }
                    if isBusy { ProgressView().accessibilityIdentifier("meeting.preparing") }
                }.padding(20).background(theme.palette.cardBackground, in: RoundedRectangle(cornerRadius: theme.metrics.corners.lg))
                Label(PichiLocalization.text("Stored on this device. Place the microphone where everyone can be heard."), systemImage: "lock")
                    .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
            }.padding(24).frame(maxWidth: 840, alignment: .leading).frame(maxWidth: .infinity)
        }.accessibilityIdentifier("meeting.ready")
    }

    private func recording(_ session: MeetingSession) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(PichiLocalization.text("Recording"), systemImage: "record.circle")
                    .foregroundStyle(theme.palette.accent)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(MeetingTranscriptExporter.timestampText(session.duration))
                        .monospacedDigit().accessibilityIdentifier("meeting.timer")
                }
            }
            Text(session.title).font(theme.typography.title)
            HStack {
                Label(PichiLocalization.text("Microphone"), systemImage: "mic")
                AudioWaveformBars(color: theme.palette.accent, barCount: 7, barWidth: 3, barSpacing: 3,
                    minHeight: 3, maxHeight: 24,
                    level: { CGFloat(coordinator.trackHealth[.microphone]?.level ?? 0) }, noiseThreshold: 0.02,
                    isAnimating: coordinator.isRecording, isIdleWaveEnabled: false)
                    .foregroundStyle(theme.palette.accent).frame(width: 45, height: 26).accessibilityHidden(true)
            }.font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
            Divider()
            Text(PichiLocalization.text("Live transcript")).font(theme.typography.sectionTitle)
            MeetingLiveBubbleScrollList(rows: MeetingLiveBubbleComposer.rows(for: coordinator.liveTranscript), documentStyle: true)
                .accessibilityIdentifier("meeting.liveTranscript")
            switch coordinator.liveTranscript.availability {
            case .unavailable(let reason), .degraded(let reason):
                Text(MeetingUILocalization.captionAvailability(reason)).font(theme.typography.caption)
                    .foregroundStyle(theme.palette.secondaryText)
            case .available: EmptyView()
            }
            Divider()
            Text(PichiLocalization.text("Speaker labels are added after recording."))
                .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
            Button { run { _ = try await coordinator.stopAndTranscribe() } } label: {
                Label(PichiLocalization.text("Stop & Transcribe"), systemImage: "stop.fill")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }.buttonStyle(.borderedProminent).disabled(isBusy || !coordinator.isRecording)
                .accessibilityIdentifier("meeting.stop")
        }.padding(24).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
            .accessibilityIdentifier("meeting.recording")
    }

    private func processing(_ session: MeetingSession, stage: MeetingProcessingStage) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Label(PichiLocalization.text("Preparing your transcript"), systemImage: "text.alignleft")
                .font(theme.typography.sectionTitle)
            Text(session.title).font(theme.typography.title)
            ProgressView(PichiLocalization.text(stageTitle(stage)))
                .accessibilityIdentifier("meeting.processing")
            Spacer()
        }.padding(24).frame(maxWidth: 840, alignment: .leading).frame(maxWidth: .infinity)
    }

    private func stageTitle(_ stage: MeetingProcessingStage) -> String {
        switch stage {
        case .pending, .saving: return "Saving"
        case .identifyingSpeakers: return "Identifying speakers"
        case .transcribing: return "Transcribing"
        case .finalizing, .completed: return "Finalizing"
        }
    }

    private func recovery(_ session: MeetingSession) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(session.title).font(theme.typography.title)
                if let failure = session.failures.last { Text(failure.message).foregroundStyle(theme.palette.warning) }
                Button(PichiLocalization.text("Retry transcription")) {
                    run { _ = try await coordinator.retryProcessing(sessionID: session.id) }
                }.disabled(isBusy || !coordinator.isQuiescent).accessibilityIdentifier("meeting.retry")
                if !session.transcriptSegments.isEmpty { transcript(session) }
            }.padding(24)
        }
    }

    private var history: some View {
        Group {
            if let session = selectedHistory {
                VStack {
                    Button { selectedHistory = nil } label: {
                        Label(PichiLocalization.text("History"), systemImage: "chevron.left").frame(minHeight: 44)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                    transcript(session)
                }
            } else {
                List {
                    ForEach(sessions.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { session in
                        Button { selectedHistory = session } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(session.title).font(theme.typography.bodyStrong)
                                Text(session.startedAt.formatted(.dateTime.day().month().hour().minute()))
                                    .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }.buttonStyle(.plain).accessibilityIdentifier("history.session.\(session.id)")
                            .swipeActions { Button(PichiLocalization.text("Delete"), role: .destructive) { deleteCandidate = session } }
                    }
                }.searchable(text: $search, prompt: PichiLocalization.text("Search meetings"))
                    .refreshable { await refreshHistory() }.accessibilityIdentifier("history.list")
            }
        }
    }

    private func transcript(_ session: MeetingSession) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(session.title).font(theme.typography.title)
                HStack {
                    Label(MeetingTranscriptExporter.timestampText(session.duration), systemImage: "clock")
                    Text(PichiLocalization.text("In-room meeting"))
                }.font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                HStack {
                    Button { copyTranscript(session) } label: {
                        Label(PichiLocalization.text("Copy"), systemImage: "doc.on.doc").frame(minHeight: 44)
                    }.accessibilityIdentifier("transcript.copy")
                    Menu {
                        Button(PichiLocalization.text("Export as Text")) { exportTranscript(session, json: false) }
                        Button(PichiLocalization.text("Export as JSON")) { exportTranscript(session, json: true) }
                        if session.hasFinalizedAudio && session.retention.audioDeletedAt == nil {
                            if session.hasRetryableAudio {
                                Button(PichiLocalization.text("Retry transcription")) {
                                    playback.stop()
                                    run { _ = try await coordinator.retryProcessing(sessionID: session.id) }
                                }.disabled(!coordinator.isQuiescent)
                            }
                            Button(PichiLocalization.text("Export Audio")) { exportAudio(session) }
                            Button(PichiLocalization.text("Delete Audio"), role: .destructive) {
                                playback.stop()
                                run {
                                    let updated = try await coordinator.deleteAudio(sessionID: session.id)
                                    if selectedHistory?.id == updated.id { selectedHistory = updated }
                                    await refreshHistory()
                                }
                            }
                        }
                        Button(PichiLocalization.text("Rename")) { edit = MeetingEditDraft(session: session, kind: .title, text: session.title) }
                        if coordinator.canUndoCorrection(sessionID: session.id) {
                            Button(PichiLocalization.text("Undo correction")) {
                                run {
                                    let updated = try await coordinator.undoTranscriptCorrection(sessionID: session.id)
                                    if selectedHistory?.id == updated.id { selectedHistory = updated }
                                    await refreshHistory()
                                }
                            }
                        }
                        Button(PichiLocalization.text("Delete Meeting"), role: .destructive) { deleteCandidate = session }
                    } label: { Label(PichiLocalization.text("More"), systemImage: "ellipsis").frame(minHeight: 44) }
                        .accessibilityIdentifier("transcript.more")
                    Spacer()
                }
                Text(PichiLocalization.text("Transcript")).font(theme.typography.sectionTitle)
                Divider()
                if !session.activeSpeakers.isEmpty {
                    Text(PichiLocalization.text("Speaker labels are automatic and may not be exact. Click a name to fix it."))
                        .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                    ForEach(session.activeSpeakers) { speaker in
                        Button(speaker.displayName) {
                            edit = MeetingEditDraft(session: session, kind: .speaker(speaker), text: speaker.displayName)
                        }.frame(minHeight: 44)
                    }
                }
                if let message = playback.errorMessage {
                    Text(PichiLocalization.text(message)).font(theme.typography.caption).foregroundStyle(theme.palette.warning)
                }
                ForEach(session.transcriptSegments.filter { !$0.isEcho }.sorted { $0.start < $1.start }) { segment in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(MeetingTranscriptExporter.timestampText(segment.start.seconds)).monospacedDigit()
                            Text(MeetingTranscriptExporter.speakerLabel(for: segment, in: session,
                                speakerNames: Dictionary(uniqueKeysWithValues: session.activeSpeakers.map { ($0.id, $0.displayName) }),
                                language: PichiLocalization.language)).foregroundStyle(theme.palette.secondaryText)
                            Spacer()
                            if session.hasFinalizedAudio && session.retention.audioDeletedAt == nil {
                                Button { playback.toggle(sessionID: session.id, segmentID: segment.id) } label: {
                                    Image(systemName: playback.activeSegmentID == segment.id ? "pause.fill" : "play.fill")
                                        .frame(minWidth: 44, minHeight: 44)
                                }.disabled(!coordinator.isQuiescent).accessibilityLabel(PichiLocalization.text("Audio"))
                                    .accessibilityIdentifier("transcript.audio.\(segment.id)")
                            }
                            Button { edit = MeetingEditDraft(session: session, kind: .segment(segment), text: segment.text) } label: {
                                Image(systemName: "pencil").frame(minWidth: 44, minHeight: 44)
                            }.accessibilityLabel(PichiLocalization.text("Edit"))
                        }.font(theme.typography.caption)
                        Text(segment.text).font(theme.typography.body).textSelection(.enabled)
                        if playback.activeSegmentID == segment.id {
                            MeetingSegmentAudioPlayer(playback: playback, isLoading: playback.isLoading)
                        }
                    }.accessibilityElement(children: .contain).accessibilityIdentifier("transcript.segment.\(segment.id)")
                }
            }.padding(24).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
        }.accessibilityIdentifier("meeting.transcript")
    }

    private func beginMeeting() {
        run {
            await refreshMicrophones()
            let configuration = try await coordinator.defaultConfiguration(mode: .inRoom,
                title: PichiLocalization.text("In-room meeting"))
            _ = try await coordinator.startRecording(configuration: configuration)
        }
    }

    private func newMeeting() {
        do { try coordinator.resetForNewMeeting(); destination = .meetings } catch { report(error) }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        Task { @MainActor in
            defer { isBusy = false }
            do { try await operation() } catch { report(error) }
        }
    }

    private func report(_ failure: Error) {
        showMicrophoneSettings = false
        if let captureError = failure as? MeetingCaptureError, case .microphonePermissionDenied = captureError {
            showMicrophoneSettings = true
        }
        error = PichiLocalization.text(failure.localizedDescription)
        showError = true
    }
    private func refreshHistory() async {
        await historySnapshot.refresh()
        if let message = historySnapshot.errorMessage { error = message; showError = true; return }
        if let id = selectedHistory?.id { selectedHistory = sessions.first { $0.id == id } }
    }
    private func refreshMicrophones() async {
        do { microphoneSnapshot = try await microphones() } catch { report(error) }
    }

    private func copyTranscript(_ session: MeetingSession) {
        run {
            let output: MeetingSession
            if settings.meetingPIIRedactionEnabled {
                if !(await privacy.isReady) { try await privacy.prepare() }
                output = try await MeetingTranscriptPrivacyPolicy.redactedCopy(session: session, using: privacy)
            } else { output = session }
            UIPasteboard.general.string = MeetingTranscriptExporter.text(for: output)
        }
    }

    private func exportTranscript(_ session: MeetingSession, json: Bool) {
        run {
            guard let fresh = try await store.load(id: session.id) else { throw CocoaError(.fileNoSuchFile) }
            let output: MeetingSession
            if settings.meetingPIIRedactionEnabled {
                if !(await privacy.isReady) { try await privacy.prepare() }
                output = try await MeetingTranscriptPrivacyPolicy.redactedCopy(session: fresh, using: privacy)
            } else { output = fresh }
            let data = json ? try MeetingTranscriptExporter.json(for: output) : Data(MeetingTranscriptExporter.text(for: output).utf8)
            share = try MeetingSharePayload.transcript(data: data, title: output.title, fileExtension: json ? "json" : "txt")
        }
    }

    private func exportAudio(_ session: MeetingSession) {
        run {
            guard let fresh = try await store.load(id: session.id), fresh.retention.audioDeletedAt == nil,
                  fresh.hasFinalizedAudio, let directory = try await store.existingSessionDirectory(for: fresh.id)
            else { throw CocoaError(.fileNoSuchFile) }
            share = try await MeetingSharePayload.audio(session: fresh, directory: directory)
        }
    }
}

struct MeetingEditDraft: Identifiable {
    enum Kind { case segment(MeetingTranscriptSegment), speaker(MeetingSessionSpeaker), title }
    let id = UUID()
    let session: MeetingSession
    let kind: Kind
    let text: String
}

private struct MeetingEditSheet: View {
    let draft: MeetingEditDraft
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    init(draft: MeetingEditDraft, save: @escaping (String) -> Void) {
        self.draft = draft; self.save = save; self._text = State(initialValue: draft.text)
    }
    var body: some View {
        NavigationStack {
            TextEditor(text: $text).padding().accessibilityIdentifier("transcript.edit.text")
                .navigationTitle(PichiLocalization.text("Edit"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(PichiLocalization.text("Cancel")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(PichiLocalization.text("Save")) { save(text); dismiss() }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}

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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var destination = Destination.meetings
    @State private var settingsPath: [MobileSettingsDestination] = []
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var isPreparingPrivacy = false
    @State private var privacyPreparationProgress: Double?
    @State private var privacyPreparationTask: Task<Void, Never>?
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
            if UIDevice.current.userInterfaceIdiom == .pad && geometry.size.width >= 700 {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebar.navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
                } detail: {
                    navigation(for: destination)
                }.navigationSplitViewStyle(.balanced)
            } else {
                TabView(selection: Binding(get: { destination }, set: selectSection)) {
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
            NavigationStack { MobileRecordingSettings(microphones: microphoneSnapshot.identities, isPresentedAsSheet: true) }
        }
        .sheet(item: $edit) { draft in
            MeetingEditSheet(draft: draft, cancel: { edit = nil }) { kind, updated in
                edit = nil
                run {
                    let result: MeetingSession
                    switch kind {
                    case .segment(let segment):
                        result = try await coordinator.editTranscriptText(sessionID: draft.session.id, segmentID: segment.id, text: updated,
                            expectedRevision: segment.revision)
                    case .speaker(let speaker):
                        result = try await coordinator.renameSpeaker(sessionID: draft.session.id, speakerID: speaker.id, to: updated)
                    case .title:
                        result = try await coordinator.renameSession(sessionID: draft.session.id, to: updated)
                    case .paragraph:
                        // The picker opens a revision-checked member editor before saving.
                        throw MeetingDomainError.segmentNotFound
                    }
                    if selectedHistory?.id == result.id { selectedHistory = result }
                    await refreshHistory()
                }
            }
        }
        .sheet(item: $share) { payload in
            VStack(spacing: 0) {
                Text(payload.includesAudio
                    ? PichiLocalization.text("Exported audio includes the original voices and sensitive information. It is outside app retention controls.")
                    : AppBrand.text("Exported transcripts are outside FluidVoice's retention controls and may be indexed or synced by other apps."))
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
                    playback.stop()
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
                Button { selectSection(item) } label: {
                    Label(PichiLocalization.text(item.title), systemImage: item.symbol)
                        .font(theme.typography.sidebarItem)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .padding(.horizontal, 12)
                        .background(destination == item ? theme.palette.accent : .clear, in: RoundedRectangle(cornerRadius: theme.metrics.corners.md))
                        .foregroundStyle(destination == item ? theme.palette.accentForeground : theme.palette.primaryText)
                }.buttonStyle(.plain)
                    .accessibilityIdentifier("navigation.\(item.rawValue)")
                    .accessibilityAddTraits(destination == item ? .isSelected : [])
            }
            Spacer()
        }.padding(16).background(theme.palette.sidebarBackground)
    }

    private func selectSection(_ item: Destination) {
        if destination == item {
            switch item {
            case .settings: settingsPath.removeAll()
            case .history: selectedHistory = nil
            case .meetings: break // Its root is the current meeting, including an active recording.
            }
        } else {
            destination = item
        }
    }

    @ViewBuilder private func navigation(for item: Destination) -> some View {
        // Each section owns its stack. A settings push must never cover another section,
        // and its explicit path survives switching sections or the adaptive layout.
        switch item {
        case .settings:
            NavigationStack(path: $settingsPath) {
                sectionRoot(for: item)
            }
        case .meetings:
            NavigationStack { sectionRoot(for: item) }
        case .history:
            NavigationStack { sectionRoot(for: item) }
        }
    }

    private func sectionRoot(for item: Destination) -> some View {
        Group {
            switch item {
            case .meetings: currentMeeting
            case .history: history
            case .settings:
                MobileSettingsRoot(asr: asr, privacy: privacy, microphones: microphoneSnapshot.identities,
                    isPreparingPrivacy: $isPreparingPrivacy, privacyPreparationProgress: $privacyPreparationProgress,
                    privacyPreparationTask: $privacyPreparationTask, reportError: report)
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

    private var compactHeight: Bool { verticalSizeClass == .compact }

    private var start: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: compactHeight ? theme.metrics.spacing.sm : theme.metrics.spacing.xl) {
                Text(PichiLocalization.text("Be in the conversation.")).font(compactHeight ? theme.typography.title : theme.typography.displayTitle)
                Text(PichiLocalization.text("Record your meeting. Come back to every word."))
                    .font(compactHeight ? theme.typography.body : theme.typography.statement).foregroundStyle(theme.palette.secondaryText)
                VStack(alignment: .leading, spacing: compactHeight ? 8 : 12) {
                    Text(PichiLocalization.text("No call open.")).font(theme.typography.sectionTitle)
                    Text(PichiLocalization.text("Your mic will record the room."))
                        .foregroundStyle(theme.palette.secondaryText)
                    HStack {
                        Button { beginMeeting() } label: {
                            Label(PichiLocalization.text("Start Recording"), systemImage: "record.circle")
                                .foregroundStyle(theme.palette.accentForeground)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.borderedProminent).disabled(isBusy || !coordinator.isQuiescent)
                            .accessibilityIdentifier("meeting.start")
                        Button { showRecordingSettings = true } label: {
                            Image(systemName: "slider.horizontal.3").frame(minWidth: 44, minHeight: 44)
                        }.accessibilityLabel(PichiLocalization.text("Recording settings"))
                            .accessibilityIdentifier("meeting.settings")
                    }
                    if isBusy { ProgressView().accessibilityIdentifier("meeting.preparing") }
                }.padding(compactHeight ? 12 : 20).background(theme.palette.cardBackground, in: RoundedRectangle(cornerRadius: theme.metrics.corners.lg))
                Label(PichiLocalization.text("Stored on this device. Place the microphone where everyone can be heard."), systemImage: "lock")
                    .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                    .accessibilityIdentifier("meeting.storageNote")
            }.padding(compactHeight ? 12 : 24).frame(maxWidth: 840, alignment: .leading).frame(maxWidth: .infinity)
        }.safeAreaPadding(.bottom, compactHeight ? 48 : 0)
            .accessibilityIdentifier("meeting.ready")
    }

    private func recording(_ session: MeetingSession) -> some View {
        GeometryReader { geometry in
            ScrollView {
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
            switch coordinator.liveTranscript.availability {
            case .unavailable(let reason), .degraded(let reason):
                Text(MeetingUILocalization.captionAvailability(reason)).font(theme.typography.caption)
                    .foregroundStyle(theme.palette.secondaryText)
                    .accessibilityIdentifier("meeting.liveAvailability")
            case .available: EmptyView()
            }
            MeetingLiveBubbleScrollList(rows: MeetingLiveBubbleComposer.rows(for: coordinator.liveTranscript),
                                       pending: coordinator.pendingSpeech, documentStyle: true)
                .frame(height: max(200, geometry.size.height - 250))
                .accessibilityIdentifier("meeting.liveTranscript")
            if session.speakerLabelsEnabled != false {
                Text(PichiLocalization.text("Speaker labels are added after recording."))
                    .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
            }
                }.padding(24).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
            }
        }
        .accessibilityIdentifier("meeting.recording")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button { run { _ = try await coordinator.stopAndTranscribe() } } label: {
                Label(PichiLocalization.text("Stop & Transcribe"), systemImage: "stop.fill")
                    .foregroundStyle(theme.palette.accentForeground)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }.buttonStyle(.borderedProminent).disabled(isBusy || !coordinator.isRecording)
                .accessibilityIdentifier("meeting.stop")
                .padding(.horizontal, 24).padding(.vertical, 12)
                .background(theme.palette.toolbarBackground)
        }
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

    private func sessionStatus(_ state: MeetingSessionState) -> String {
        switch state {
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        case .processing: return "Processing"
        case .preparing, .recording, .recordingDegraded, .stopping: return "Recording"
        }
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
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(PichiLocalization.text(session.state == .interrupted
                        ? "Meeting transcription was interrupted" : "Meeting transcription failed"))
                        .font(theme.typography.sectionTitle)
                    if let failure = session.failures.last {
                        Text(PichiLocalization.text(failure.message)).foregroundStyle(theme.palette.warning)
                    }
                    if session.hasRetryableAudio {
                        Button(PichiLocalization.text("Retry transcription")) {
                            playback.stop()
                            run { _ = try await coordinator.retryProcessing(sessionID: session.id); destination = .meetings }
                        }.disabled(isBusy || !coordinator.isQuiescent).accessibilityIdentifier("meeting.retry")
                        if session.audioStorageMode == .retainedFiles {
                            Button(PichiLocalization.text("Start processing again")) {
                                playback.stop()
                                run { _ = try await coordinator.restartProcessing(sessionID: session.id); destination = .meetings }
                            }.disabled(isBusy || !coordinator.isQuiescent).accessibilityIdentifier("meeting.restartProcessing")
                            Text(PichiLocalization.text("Retry continues from the last saved step. Starting again discards processing progress and keeps your audio."))
                                .font(theme.typography.bodySmall).foregroundStyle(theme.palette.secondaryText)
                        }
                    }
                    Button(PichiLocalization.text("New Meeting")) { newMeeting() }
                        .disabled(isBusy || !coordinator.isQuiescent)
                    if session.transcriptSegments.isEmpty {
                        Text(session.title).font(theme.typography.title)
                        Text(PichiLocalization.text(session.hasRetryableAudio ? "Your captured audio is preserved"
                            : "There is no transcript text or saved audio available for this meeting."))
                            .font(theme.typography.bodySmall).foregroundStyle(theme.palette.secondaryText)
                    }
                }.padding(24)
            }.frame(maxHeight: session.transcriptSegments.isEmpty ? .infinity : 240)
            if !session.transcriptSegments.isEmpty { transcript(session) }
        }
    }

    private var history: some View {
        Group {
            if let session = selectedHistory {
                VStack {
                    Button { selectedHistory = nil } label: {
                        Label(PichiLocalization.text("History"), systemImage: "chevron.left").frame(minHeight: 44)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                    if session.state == .failed || session.state == .interrupted { recovery(session) }
                    else { transcript(session) }
                }
            } else {
                List {
                    ForEach(sessions.filter { session in
                        search.isEmpty || session.title.localizedCaseInsensitiveContains(search)
                            || session.activeSpeakers.contains { $0.displayName.localizedCaseInsensitiveContains(search) }
                            || session.capturedApplication?.displayName.localizedCaseInsensitiveContains(search) == true
                    }) { session in
                        Button { selectedHistory = session } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(session.title).font(theme.typography.bodyStrong)
                                HStack {
                                    Text(session.startedAt.formatted(.dateTime.day().month().hour().minute()))
                                    Text(MeetingTranscriptExporter.timestampText(session.duration)).monospacedDigit()
                                }.font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                                HStack {
                                    Text(PichiLocalization.text(sessionStatus(session.state)))
                                    if !session.activeSpeakers.isEmpty {
                                        Text(session.activeSpeakers.count == 1 ? PichiLocalization.text("1 speaker") : PichiLocalization.format("%lld speakers", Int64(session.activeSpeakers.count)))
                                    }
                                }.font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("history.session.\(session.id)")
                            .swipeActions { Button(PichiLocalization.text("Delete"), role: .destructive) { deleteCandidate = session } }
                    }
                }.searchable(text: $search, prompt: PichiLocalization.text("Search meetings"))
                    .refreshable { await refreshHistory() }.accessibilityIdentifier("history.list")
            }
        }
    }

    private func transcript(_ session: MeetingSession) -> some View {
        let names = Dictionary(uniqueKeysWithValues: session.activeSpeakers.map {
            ($0.id, MeetingTranscriptExporter.speakerDisplayName($0, language: PichiLocalization.language))
        })
        let segments = session.transcriptSegments.filter { !$0.isEcho }.enumerated().sorted {
            ($0.element.start, $0.element.end, $0.offset) < ($1.element.start, $1.element.end, $1.offset)
        }.map(\.element)
        let paragraphs = MeetingTranscriptExporter.displayParagraphs(for: segments, in: session)
        return ScrollView {
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
                    if UIDevice.current.userInterfaceIdiom == .phone || horizontalSizeClass == .compact {
                        ScrollView(.horizontal) {
                            HStack(spacing: theme.metrics.spacing.sm) {
                                ForEach(session.activeSpeakers) { speaker in
                                    participantButton(speaker, session: session, expands: false)
                                }
                            }
                        }.scrollIndicators(.hidden).accessibilityIdentifier("transcript.speakers")
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading,
                                  spacing: theme.metrics.spacing.sm) {
                            ForEach(session.activeSpeakers) { speaker in
                                participantButton(speaker, session: session, expands: true)
                            }
                        }.accessibilityIdentifier("transcript.speakers")
                    }
                }
                if let message = playback.errorMessage {
                    Text(PichiLocalization.text(message)).font(theme.typography.caption).foregroundStyle(theme.palette.warning)
                }
                LazyVStack(alignment: .leading, spacing: theme.metrics.spacing.xl) {
                    ForEach(paragraphs) { paragraph in
                        transcriptParagraph(paragraph, session: session, names: names)
                    }
                }
            }.padding(24).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
        }.accessibilityIdentifier("meeting.transcript")
    }

    private func participantButton(_ speaker: MeetingSessionSpeaker, session: MeetingSession, expands: Bool) -> some View {
        Button {
            edit = MeetingEditDraft(session: session, kind: .speaker(speaker), text: speaker.displayName)
        } label: {
            Label(MeetingTranscriptExporter.speakerDisplayName(speaker, language: PichiLocalization.language), systemImage: "person.crop.circle")
                .font(theme.typography.captionStrong)
                .frame(maxWidth: expands ? .infinity : nil, minHeight: 44, alignment: .leading)
        }.disabled(!coordinator.isQuiescent)
            .accessibilityIdentifier("transcript.speaker.\(speaker.id)")
    }

    private func transcriptParagraph(_ paragraph: MeetingTranscriptExporter.DisplayParagraph, session: MeetingSession,
                                     names: [SessionSpeakerID: String]) -> some View {
        let segment = paragraph.firstSegment
        let isAudioExpanded = paragraph.segments.contains { $0.id == playback.activeSegmentID }
        return VStack(alignment: .leading, spacing: theme.metrics.spacing.sm) {
            HStack(alignment: .top, spacing: theme.metrics.spacing.sm) {
                Text(MeetingTranscriptExporter.timestampText(segment.start.seconds))
                    .font(theme.typography.codeCaption).foregroundStyle(theme.palette.secondaryText)
                    .padding(.top, theme.metrics.spacing.sm)
                Text(MeetingTranscriptExporter.speakerLabel(for: paragraph, in: session,
                    speakerNames: names, language: PichiLocalization.language))
                    .font(theme.typography.captionStrong).foregroundStyle(theme.palette.secondaryText)
                    .padding(.top, theme.metrics.spacing.sm)
                Spacer(minLength: 0)
                if session.hasFinalizedAudio && session.retention.audioDeletedAt == nil {
                    Button {
                        if isAudioExpanded { playback.stop() }
                        else { playback.toggle(sessionID: session.id, segmentIDs: paragraph.segments.map(\.id)) }
                    } label: {
                        Image(systemName: isAudioExpanded ? "xmark" : "play.fill")
                            .frame(minWidth: 44, minHeight: 44)
                    }.disabled(!coordinator.isQuiescent).accessibilityLabel(PichiLocalization.text(isAudioExpanded ? "Close audio player" : "Audio"))
                        .accessibilityIdentifier("transcript.audio.\(segment.id)")
                }
                Button {
                    edit = MeetingEditDraft(session: session,
                        kind: paragraph.segments.count == 1 ? .segment(segment) : .paragraph(paragraph.segments),
                        text: paragraph.text)
                } label: {
                    Image(systemName: "pencil").frame(minWidth: 44, minHeight: 44)
                }.disabled(!coordinator.isQuiescent).accessibilityLabel(PichiLocalization.text("Edit"))
                    .accessibilityIdentifier("transcript.edit.\(segment.id)")
            }.buttonStyle(.borderless)
            Text(paragraph.text).font(theme.typography.body).lineSpacing(theme.metrics.spacing.xs)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if isAudioExpanded {
                MeetingSegmentAudioPlayer(playback: playback, isLoading: playback.isLoading)
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("transcript.paragraph.\(paragraph.id)")
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
        playback.stop()
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
    enum Kind { case segment(MeetingTranscriptSegment), paragraph([MeetingTranscriptSegment]), speaker(MeetingSessionSpeaker), title }
    let id = UUID()
    let session: MeetingSession
    let kind: Kind
    let text: String
}

private struct MeetingEditSheet: View {
    let draft: MeetingEditDraft
    let cancel: () -> Void
    let save: (MeetingEditDraft.Kind, String) -> Void
    @Environment(\.theme) private var theme
    var body: some View {
        NavigationStack {
            if case .paragraph(let segments) = draft.kind {
                List(segments) { segment in
                    NavigationLink {
                        MeetingEditTextForm(kind: .segment(segment), text: segment.text, cancel: cancel, save: save)
                    } label: {
                        VStack(alignment: .leading, spacing: theme.metrics.spacing.xs) {
                            Text(MeetingTranscriptExporter.timestampText(segment.start.seconds))
                                .font(theme.typography.codeCaption).foregroundStyle(theme.palette.secondaryText)
                            Text(segment.text).font(theme.typography.body)
                        }.frame(minHeight: 44)
                    }.accessibilityIdentifier("transcript.edit.fragment.\(segment.id)")
                }.navigationTitle(PichiLocalization.text("Transcript text"))
                    .accessibilityIdentifier("transcript.edit.fragments")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(PichiLocalization.text("Cancel"), action: cancel) } }
            } else {
                MeetingEditTextForm(kind: draft.kind, text: draft.text, cancel: cancel, save: save)
            }
        }
    }
}

private struct MeetingEditTextForm: View {
    let kind: MeetingEditDraft.Kind
    let cancel: () -> Void
    let save: (MeetingEditDraft.Kind, String) -> Void
    @Environment(\.theme) private var theme
    @State private var text: String
    init(kind: MeetingEditDraft.Kind, text: String, cancel: @escaping () -> Void,
         save: @escaping (MeetingEditDraft.Kind, String) -> Void) {
        self.kind = kind; self.cancel = cancel; self.save = save; self._text = State(initialValue: text)
    }
    var body: some View {
        TextEditor(text: $text).font(theme.typography.body).padding().accessibilityIdentifier("transcript.edit.text")
            .navigationTitle(PichiLocalization.text("Edit"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(PichiLocalization.text("Cancel"), action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(PichiLocalization.text("Save")) { save(kind, text) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
    }
}

import AVFoundation
import Combine
import UniformTypeIdentifiers
import SwiftUI
import UIKit

/// Platform navigation and transient view state only. The shared coordinator owns every meeting.
struct MobileMeetingRoot: View {
    @ObservedObject var coordinator: MeetingSessionCoordinator
    @ObservedObject var asr: ASRService
    let store: any MeetingSessionStoring
    let privacy: PichiTranscriptPrivacyService
    @ObservedObject var required: MobileRequiredResources
    @ObservedObject var privacyActivation: MobilePrivacyActivation
    let microphones: @Sendable () async throws -> MeetingMicrophoneCatalogSnapshot
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var destination = Destination.meetings
    @State private var settingsPath: [MobileSettingsDestination] = []
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @StateObject private var historySnapshot: MeetingHistorySnapshot
    private var sessions: [MeetingSession] { historySnapshot.sessions }
    // The snapshot owns committed sessions; History's own path keeps only pushed identities.
    @State private var historyPath: [MeetingSessionID] = []
    @State private var copiedSessionID: MeetingSessionID?
    @State private var search = ""
    @State private var isBusy = false
    @State private var error: String?
    @State private var showError = false
    @State private var showMicrophoneSettings = false
    @State private var showRecordingSettings = false
    @State private var microphoneSnapshot = MeetingMicrophoneCatalogSnapshot(identities: [], defaultCoreAudioUID: nil)
    @State private var edit: MeetingEditDraft?
    @State private var speakerAssignment: MeetingSpeakerAssignmentDraft?
    @State private var deletion: Deletion?
    @State private var share: MeetingSharePayload?
    @State private var showPresentationPicker = false
    @State private var presentation: MobilePresentationDocument?
    @StateObject private var presentationLoader = MobilePresentationLoader()
    @State private var recordingScreenAwakeToken: UUID?
    @StateObject private var playback = MeetingSegmentPlayback()
    // Projection is independent of microphone meters, pending audio, playback progress
    // and other frequent view invalidations. Keep one result for the visible transcript.
    @State private var transcriptReadingSource: MeetingTranscriptExporter.ReadingInput?
    @State private var transcriptReading: [MeetingTranscriptExporter.DisplayParagraph] = []



    init(coordinator: MeetingSessionCoordinator, asr: ASRService, store: any MeetingSessionStoring,
         privacy: PichiTranscriptPrivacyService,
         required: MobileRequiredResources, privacyActivation: MobilePrivacyActivation,
         microphones: @escaping @Sendable () async throws -> MeetingMicrophoneCatalogSnapshot) {
        self.coordinator = coordinator; self.asr = asr; self.store = store
        self.privacy = privacy; self.microphones = microphones
        self.required = required; self.privacyActivation = privacyActivation
        self._historySnapshot = StateObject(wrappedValue: MeetingHistorySnapshot(load: { try await store.loadAll() }))
    }

    enum Destination: String, CaseIterable, Identifiable {
        case meetings, history, settings
        var id: String { rawValue }
        var title: String {
            switch self { case .meetings: return "Meetings"; case .history: return "History"; case .settings: return "Settings" }
        }
        // The same symbols as the desktop sidebar sections.
        var symbol: String {
            switch self { case .meetings: return "person.2.fill"; case .history: return "clock.arrow.circlepath"; case .settings: return "gearshape" }
        }
    }

    /// Destructive actions share one confirmation, as on the desktop.
    private enum Deletion {
        case meeting(MeetingSession), audio(MeetingSession)
        var title: String { if case .audio = self { return "Delete Audio?" }; return "Delete Meeting" }
        var action: String { if case .audio = self { return "Delete Audio" }; return "Delete" }
        var message: String {
            if case .audio = self { return "The transcript stays; the audio files are deleted." }
            return "Delete this meeting and its recordings?"
        }
    }

    var body: some View {
        Group {
            if UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular {
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
            NavigationStack { MobileRecordingSettings(microphones: microphoneSnapshot.identities, isPresentedAsSheet: true, required: required) }
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
                    acceptCommittedSession(result)
                }
            }
        }
        .sheet(item: $share) { payload in
            MobileActivitySheet(items: payload.items) { share = nil }
                .onDisappear { payload.cleanup() }
        }
        .sheet(item: $speakerAssignment) { draft in
            MeetingSpeakerAssignmentSheet(draft: draft, cancel: { speakerAssignment = nil }) { segmentIDs, speakerID in
                guard coordinator.isQuiescent, !isBusy else { return }
                speakerAssignment = nil
                run {
                    let result: MeetingSession
                    if let segmentID = segmentIDs.first, segmentIDs.count == 1 {
                        result = try await coordinator.reassignSegment(sessionID: draft.session.id, segmentID: segmentID, to: speakerID)
                    } else {
                        result = try await coordinator.reassignSegments(sessionID: draft.session.id, segmentIDs: segmentIDs, to: speakerID)
                    }
                    acceptCommittedSession(result)
                }
            }
            .disabled(!coordinator.isQuiescent || isBusy)
        }
        .fileImporter(isPresented: $showPresentationPicker, allowedContentTypes: [.pdf]) { result in
            showPresentationPicker = false
            switch result {
            case .success(let url):
                presentationLoader.load(url: url) { result in
                    switch result {
                    case .success(let document): presentation = document
                    case .failure:
                        report(CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey:
                            "The PDF presentation could not be opened. Choose a readable PDF file."]))
                    }
                }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError {
                    report(CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey:
                    "The PDF presentation could not be opened. Choose a readable PDF file."]))
                }
            }
        }
        .fullScreenCover(item: $presentation) { document in
            PDFPresentation(document: document, coordinator: coordinator) { presentation = nil }
        }
        .confirmationDialog(PichiLocalization.text(deletion?.title ?? ""), isPresented: Binding(
            get: { deletion != nil }, set: { if !$0 { deletion = nil } }
        ), titleVisibility: .visible, presenting: deletion) { item in
            Button(PichiLocalization.text(item.action), role: .destructive) {
                deletion = nil
                run {
                    playback.stop()
                    switch item {
                    case .meeting(let session):
                        try await coordinator.deleteSession(id: session.id)
                        if historyPath.contains(session.id) { historyPath.removeAll() }
                        await refreshHistory()
                    case .audio(let session):
                        acceptCommittedSession(try await coordinator.deleteAudio(sessionID: session.id))
                    }
                }
            }
        } message: { item in Text(PichiLocalization.text(item.message)) }
        .task {
            await coordinator.ensureRestored()
            await refreshHistory()
            await refreshMicrophones()
        }
        // The app's UI-ready signal owns the launch sweep; its committed deletions reload History.
        .onChange(of: coordinator.retentionSweepRevision) { _, _ in Task { await refreshHistory() } }
        .onChange(of: coordinator.state) { _, state in
            if coordinator.isRecording { playback.stop() }
            updateRecordingScreenAwake()
            Task { await refreshHistory() }
        }
        .onAppear { updateRecordingScreenAwake() }
        .onChange(of: scenePhase) { _, _ in updateRecordingScreenAwake() }
        .onChange(of: destination) { _, _ in playback.stop(); presentationLoader.cancel() }
        .onChange(of: historyPath) { _, _ in playback.stop(); presentationLoader.cancel() }
        .onDisappear {
            presentationLoader.cancel()
            updateRecordingScreenAwake(isVisible: false)
        }
        .onChange(of: settings.meetingAudioRetentionPolicy) { _, _ in
            Task { await coordinator.sweepExpiredAudio() }
        }
    }

    /// The active recording screen and an active PDF window share one process
    /// timer. Scene/background transitions release only this view's own token.
    private func updateRecordingScreenAwake(isVisible: Bool = true) {
        let shouldStayAwake = isVisible && scenePhase == .active && coordinator.isRecording
        if shouldStayAwake && recordingScreenAwakeToken == nil {
            recordingScreenAwakeToken = MobilePresentationAwakeRegistry.shared.acquire()
        } else if !shouldStayAwake, let token = recordingScreenAwakeToken {
            recordingScreenAwakeToken = nil
            MobilePresentationAwakeRegistry.shared.release(token)
        }
    }

    // Observe the coordinator inside the presented subtree as well, so Stop or
    // failure releases screen ownership even while the recording screen is covered.
    private struct PDFPresentation: View {
        let document: MobilePresentationDocument
        @ObservedObject var coordinator: MeetingSessionCoordinator
        @Environment(\.scenePhase) private var scenePhase
        let close: () -> Void

        var body: some View {
            NavigationStack {
                MobilePresentationPDFView(document: document, isRecording: coordinator.isRecording,
                                          isSceneActive: scenePhase == .active)
                    .ignoresSafeArea(edges: .bottom)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(PichiLocalization.text("Done"), action: close)
                                .accessibilityIdentifier("meeting.presentation.close")
                        }
                    }
            }
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
            case .history: historyPath.removeAll()
            case .meetings: break // Its root is the current meeting, including an active recording.
            }
        } else {
            destination = item
        }
    }

    @ViewBuilder private func navigation(for item: Destination) -> some View {
        // Each section owns its stack. A settings or history push must never cover another
        // section, and its explicit path survives switching sections or the adaptive layout.
        switch item {
        case .settings:
            NavigationStack(path: $settingsPath) {
                sectionRoot(for: item)
            }
        case .meetings:
            NavigationStack { sectionRoot(for: item) }
        case .history:
            NavigationStack(path: $historyPath) { sectionRoot(for: item) }
        }
    }

    private func sectionRoot(for item: Destination) -> some View {
        Group {
            switch item {
            case .meetings: currentMeeting
            case .history: history
            case .settings:
                MobileSettingsRoot(asr: asr, privacy: privacy, microphones: microphoneSnapshot.identities,
                    required: required, privacyActivation: privacyActivation, reportError: report)
            }
        }
        .navigationTitle(item == .meetings ? AppBrand.meetingName : PichiLocalization.text(item.title))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if item == .meetings, coordinator.isRecording || coordinator.isQuiescent {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showPresentationPicker = true } label: {
                        HStack {
                            if presentationLoader.isLoading { ProgressView() }
                            Label(PichiLocalization.text("PDF Presentation"), systemImage: "doc.richtext")
                        }
                    }
                    .disabled(presentationLoader.isLoading)
                    .accessibilityIdentifier("meeting.presentation")
                    .accessibilityHint(PichiLocalization.text("Open a PDF in this app while recording continues."))
                }
            }
            if item == .meetings, coordinator.isQuiescent, !coordinator.isRecording, !isShowingStart {
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

    private var isShowingStart: Bool { coordinator.currentSession == nil || coordinator.state == .idle }
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
                            Label(PichiLocalization.text(isBusy ? "Preparing recording…" : "Start Recording"), systemImage: "record.circle")
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
                VStack(alignment: .leading, spacing: compactHeight ? 8 : 16) {
            HStack {
                Label(PichiLocalization.text(coordinator.state == .stopping(session.id) ? "Stopping..." : "Recording"),
                      systemImage: coordinator.state == .stopping(session.id) ? "stop.circle" : "record.circle")
                    .foregroundStyle(theme.palette.accent)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(MeetingTranscriptExporter.timestampText(coordinator.elapsedTime))
                        .monospacedDigit().accessibilityIdentifier("meeting.timer")
                }
            }
            if !compactHeight {
                Text(session.displayTitle).font(theme.typography.title).lineLimit(2)
            }
            HStack {
                Label(PichiLocalization.text("Microphone"), systemImage: "mic")
                AudioWaveformBars(color: theme.palette.accent, barCount: 7, barWidth: 3, barSpacing: 3,
                    minHeight: 3, maxHeight: 24,
                    level: { CGFloat(coordinator.trackHealth[.microphone]?.level ?? 0) }, noiseThreshold: 0.02,
                    isAnimating: coordinator.isRecording, isIdleWaveEnabled: false)
                    .foregroundStyle(theme.palette.accent).frame(width: 45, height: 26).accessibilityHidden(true)
            }.font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
            if !compactHeight {
                Divider()
                Text(PichiLocalization.text("Live transcript")).font(theme.typography.sectionTitle)
            }
            switch coordinator.liveTranscript.availability {
            case .unavailable(let reason), .degraded(let reason):
                Text(MeetingUILocalization.captionAvailability(reason)).font(theme.typography.caption)
                    .foregroundStyle(theme.palette.secondaryText)
                    .accessibilityIdentifier("meeting.liveAvailability")
            case .available: EmptyView()
            }
            MeetingLiveTranscriptScrollList(snapshot: coordinator.liveTranscript,
                                           pending: coordinator.pendingSpeech, documentStyle: true)
                .id(session.id)
                // This is the recording screen's only vertical scroll owner. Its viewport
                // fills the remaining space; controls never compete for the same gesture.
                .frame(maxHeight: .infinity)
                .layoutPriority(1)
                .accessibilityIdentifier("meeting.liveTranscript")
            if !compactHeight, session.speakerLabelsEnabled != false {
                Text(PichiLocalization.text(session.effectiveSpeakerProcessingMode == .streaming
                    ? "Speaker labels appear after enough speech has been collected."
                    : "Speaker labels are added after recording."))
                    .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
            }
                }.padding(compactHeight ? 12 : 24)
                    .frame(maxWidth: 1000, maxHeight: .infinity, alignment: .topLeading)
                    .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
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
            Text(session.displayTitle).font(theme.typography.title)
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
                    // Without transcript text the title belongs here; otherwise the transcript shows it.
                    if session.transcriptSegments.isEmpty {
                        Text(session.displayTitle).font(theme.typography.title)
                    }
                    Text(PichiLocalization.text(session.state == .interrupted
                        ? "Meeting transcription was interrupted" : "Meeting transcription failed"))
                        .font(theme.typography.sectionTitle)
                    if let failure = session.failures.last {
                        Text(PichiLocalization.text(failure.message)).foregroundStyle(theme.palette.warning)
                    }
                    if session.transcriptSegments.isEmpty {
                        Text(PichiLocalization.text(session.hasRetryableAudio ? "Your captured audio is preserved"
                            : "There is no transcript text or saved audio available for this meeting."))
                            .font(theme.typography.bodySmall).foregroundStyle(theme.palette.secondaryText)
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
                }.padding(24)
            }.frame(maxHeight: session.transcriptSegments.isEmpty ? .infinity : 240)
            if !session.transcriptSegments.isEmpty { transcript(session) }
        }
    }

    private var history: some View {
        let matches = sessions.filter { session in
            search.isEmpty || session.displayTitle.localizedCaseInsensitiveContains(search)
                || session.readableSpeakers.contains { $0.displayName.localizedCaseInsensitiveContains(search) }
                || session.capturedApplication?.displayName.localizedCaseInsensitiveContains(search) == true
        }
        return List(matches) { session in
            Button { historyPath = [session.id] } label: {
                VStack(alignment: .leading, spacing: theme.metrics.spacing.xs) {
                    Text(session.displayTitle).font(theme.typography.bodyStrong)
                    Text(historySummary(session)).font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("history.session.\(session.id)")
                .swipeActions { Button(PichiLocalization.text("Delete"), role: .destructive) { deletion = .meeting(session) } }
        }
        .overlay {
            // The desktop history's empty states and copy.
            if matches.isEmpty, historySnapshot.hasLoaded, historySnapshot.errorMessage == nil {
                ContentUnavailableView(
                    PichiLocalization.text(search.isEmpty ? "No meetings yet" : "No matching meetings"),
                    systemImage: search.isEmpty ? "person.2.wave.2" : "magnifyingglass",
                    description: Text(PichiLocalization.text(search.isEmpty
                        ? "Completed meetings will appear here." : "Try a different title, app, or speaker.")))
            }
        }
        .searchable(text: $search, prompt: PichiLocalization.text("Search meetings"))
        .refreshable { await refreshHistory() }.accessibilityIdentifier("history.list")
        .navigationDestination(for: MeetingSessionID.self) { id in
            if let session = sessions.first(where: { $0.id == id }) {
                Group {
                    if session.state == .failed || session.state == .interrupted { recovery(session) } else { transcript(session) }
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(theme.palette.toolbarBackground, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
            }
        }
    }

    /// One secondary line: date, duration, participants and any unfinished state.
    private func historySummary(_ session: MeetingSession) -> String {
        var parts = [session.startedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(PichiLocalization.locale)),
                     MeetingTranscriptExporter.timestampText(session.duration)]
        if !session.readableSpeakers.isEmpty {
            parts.append(PichiLocalization.format("%lld speakers", Int64(session.readableSpeakers.count)))
        }
        if session.state != .completed { parts.append(PichiLocalization.text(sessionStatus(session.state))) }
        return parts.joined(separator: " · ")
    }

    private func transcript(_ session: MeetingSession) -> some View {
        let speakerIndices = MeetingSpeakerPalette.tintIndices(for: session.speakers)
        let names = Dictionary(uniqueKeysWithValues: session.readableSpeakers.map {
            ($0.id, MeetingTranscriptExporter.speakerDisplayName($0, language: PichiLocalization.language))
        })
        let readingInput = MeetingTranscriptExporter.ReadingInput(session)
        let paragraphs = transcriptReadingSource == readingInput ? transcriptReading : []
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(session.displayTitle).font(theme.typography.title)
                HStack {
                    Label(MeetingTranscriptExporter.timestampText(session.duration), systemImage: "clock")
                    Text(session.startedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(PichiLocalization.locale)))
                }.font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                HStack {
                    // The desktop transcript's copy confirmation.
                    let copied = copiedSessionID == session.id
                    Button { copyTranscript(session) } label: {
                        Label(PichiLocalization.text(copied ? "Copied" : "Copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                            .frame(minHeight: 44)
                    }.accessibilityIdentifier("transcript.copy")
                        .accessibilityLabel(PichiLocalization.text(copied ? "Transcript copied" : "Copy transcript"))
                    Menu {
                        Button(PichiLocalization.text("Export as Text")) { exportTranscript(session, json: false) }
                        Button(PichiLocalization.text("Export as JSON")) { exportTranscript(session, json: true) }
                        Button(PichiLocalization.text("Export Protected Transcript")) { exportProtectedTranscript(session) }
                            .disabled(!MeetingTranscriptExporter.canExportProtectedTranscript(session))
                            .accessibilityIdentifier("transcript.exportProtected")
                        if session.hasFinalizedAudio && session.retention.audioDeletedAt == nil {
                            if session.hasRetryableAudio {
                                Button(PichiLocalization.text("Retry transcription")) {
                                    playback.stop()
                                    run { _ = try await coordinator.retryProcessing(sessionID: session.id) }
                                }.disabled(!coordinator.isQuiescent)
                            }
                            Button(PichiLocalization.text("Export Audio")) { exportAudio(session) }
                            Button(PichiLocalization.text("Delete Audio"), role: .destructive) { deletion = .audio(session) }
                        }
                        Button(PichiLocalization.text("Rename")) { edit = MeetingEditDraft(session: session, kind: .title, text: session.displayTitle) }
                        if coordinator.canUndoCorrection(sessionID: session.id) {
                            Button(PichiLocalization.text("Undo correction")) {
                                run {
                                    let updated = try await coordinator.undoTranscriptCorrection(sessionID: session.id)
                                    acceptCommittedSession(updated)
                                }
                            }.disabled(!coordinator.isQuiescent || isBusy)
                                .accessibilityIdentifier("transcript.undo")
                        }
                        Button(PichiLocalization.text("Delete Meeting"), role: .destructive) { deletion = .meeting(session) }
                    } label: { Label(PichiLocalization.text("More"), systemImage: "ellipsis").frame(minHeight: 44) }
                        .accessibilityIdentifier("transcript.more")
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(AppBrand.text("Exported transcripts are outside FluidVoice's retention controls and may be indexed or synced by other apps."))
                    if session.hasFinalizedAudio && session.retention.audioDeletedAt == nil {
                        Text(PichiLocalization.text("Exported audio includes the original voices and sensitive information. It is outside app retention controls."))
                    }
                }.font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                Text(PichiLocalization.text("Transcript")).font(theme.typography.sectionTitle)
                Divider()
                if !session.readableSpeakers.isEmpty {
                    Text(PichiLocalization.text("Speaker labels are automatic and may not be exact. Click a name to fix it."))
                        .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                    Text(PichiLocalization.text("The You label applies only to this meeting."))
                        .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                    if UIDevice.current.userInterfaceIdiom == .phone || horizontalSizeClass == .compact {
                        ScrollView(.horizontal) {
                            HStack(spacing: theme.metrics.spacing.sm) {
                                ForEach(session.readableSpeakers) { speaker in
                                    participantButton(speaker, session: session, colorIndex: speakerIndices[speaker.id], expands: false)
                                }
                            }
                        }.scrollIndicators(.hidden).accessibilityIdentifier("transcript.speakers")
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), alignment: .leading)], alignment: .leading,
                                  spacing: theme.metrics.spacing.sm) {
                            ForEach(session.readableSpeakers) { speaker in
                                participantButton(speaker, session: session, colorIndex: speakerIndices[speaker.id], expands: true)
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
            .task(id: readingInput) {
                do {
                    let projection = try await MeetingTranscriptExporter.readingParagraphs(for: session)
                    try Task.checkCancellation()
                    transcriptReading = projection
                    transcriptReadingSource = readingInput
                } catch is CancellationError { }
                catch { report(error) }
            }
    }

    private func participantButton(_ speaker: MeetingSessionSpeaker, session: MeetingSession, colorIndex: Int?, expands: Bool) -> some View {
        HStack(spacing: theme.metrics.spacing.xs) {
            Button {
                edit = MeetingEditDraft(session: session, kind: .speaker(speaker), text: speaker.displayName)
            } label: {
                Label(MeetingTranscriptExporter.speakerDisplayName(speaker, language: PichiLocalization.language), systemImage: "person.crop.circle")
                    .font(theme.typography.captionStrong)
                    .foregroundStyle(MeetingSpeakerPalette.labelColor(forSpeakerIndex: colorIndex,
                        theme: theme, colorScheme: colorScheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: expands ? .infinity : nil, minHeight: 44, alignment: .leading)
            }.accessibilityIdentifier("transcript.speaker.\(speaker.id)")
            Menu {
                Button(PichiLocalization.text("Rename Speaker"), systemImage: "pencil") {
                    edit = MeetingEditDraft(session: session, kind: .speaker(speaker), text: speaker.displayName)
                }
                Button(PichiLocalization.text(speaker.isLocalUser ? "Remove You designation" : "Mark as You"),
                       systemImage: speaker.isLocalUser ? "person.crop.circle.badge.minus" : "person.crop.circle.badge.checkmark") {
                    guard coordinator.isQuiescent, !isBusy else { return }
                    run {
                        let updated = try await coordinator.setLocalUserSpeaker(sessionID: session.id,
                            speakerID: speaker.isLocalUser ? nil : speaker.id)
                        acceptCommittedSession(updated)
                    }
                }.accessibilityIdentifier("transcript.participant.\(speaker.isLocalUser ? "removeYou" : "markYou").\(speaker.id)")
            } label: {
                Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(PichiLocalization.text("Participant actions"))
            .accessibilityHint(PichiLocalization.text("The You label applies only to this meeting."))
            .accessibilityIdentifier("transcript.participant.actions.\(speaker.id)")
        }.disabled(!coordinator.isQuiescent || isBusy)
    }

    private func transcriptParagraph(_ paragraph: MeetingTranscriptExporter.DisplayParagraph, session: MeetingSession,
                                     names: [SessionSpeakerID: String]) -> some View {
        let segment = paragraph.firstSegment
        // The reading projection can bridge an unresolved first fragment to its owner.
        // Style that same readable identity without changing the stored attribution.
        let participantIndex = MeetingTranscriptExporter.speakerPresentation(
            for: paragraph, in: session, speakerNames: names).participantIndex
        let isAudioExpanded = paragraph.segments.contains { $0.id == playback.activeSegmentID }
        return VStack(alignment: .leading, spacing: theme.metrics.spacing.sm) {
            HStack(alignment: .top, spacing: theme.metrics.spacing.sm) {
                Text(MeetingTranscriptExporter.timestampText(segment.start.seconds))
                    .font(theme.typography.codeCaption).foregroundStyle(theme.palette.secondaryText)
                    .padding(.top, theme.metrics.spacing.sm)
                if let label = MeetingTranscriptExporter.captionLabel(for: paragraph, in: session,
                    speakerNames: names, language: PichiLocalization.language) {
                    Text(label)
                        .font(theme.typography.captionStrong)
                        .foregroundStyle(MeetingSpeakerPalette.labelColor(forSpeakerIndex: participantIndex,
                            theme: theme, colorScheme: colorScheme))
                        .padding(.top, theme.metrics.spacing.sm)
                }
                Spacer(minLength: 0)
                Button {
                    speakerAssignment = MeetingSpeakerAssignmentDraft(session: session, segments: paragraph.segments)
                } label: {
                    Image(systemName: "person.2")
                        .frame(minWidth: 44, minHeight: 44)
                }.disabled(!coordinator.isQuiescent || isBusy || session.readableSpeakers.isEmpty)
                    .accessibilityLabel(PichiLocalization.text("Change speaker"))
                    .accessibilityIdentifier("transcript.reassign.\(segment.id)")
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
            // Finish preparation before the capture lease can open the microphone.
            try await required.prepare(modelID: settings.selectedSpeechModel.rawValue)
            try await privacyActivation.waitUntilReadyIfRequested()
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
    private func acceptCommittedSession(_ session: MeetingSession) {
        historySnapshot.applyCommitted(session)
    }
    private func refreshHistory() async {
        await historySnapshot.refresh()
        if let message = historySnapshot.errorMessage { error = message; showError = true; return }
        if let id = historyPath.last, !sessions.contains(where: { $0.id == id }) { historyPath.removeAll() }
    }
    private func refreshMicrophones() async {
        do { microphoneSnapshot = try await microphones() } catch { report(error) }
    }

    private func copyTranscript(_ session: MeetingSession) {
        run {
            let output: MeetingSession
            if settings.meetingPIIRedactionRequested {
                let redactor = try settings.transcriptPrivacyRedactor(wrapping: privacy)
                try await redactor.prepareForMeeting()
                output = try await MeetingTranscriptPrivacyPolicy.redactedCopy(session: session, using: redactor)
            } else { output = session }
            UIPasteboard.general.string = MeetingTranscriptExporter.text(for: output)
            copiedSessionID = session.id
            Task {
                try? await Task.sleep(for: .seconds(2))
                if copiedSessionID == session.id { copiedSessionID = nil }
            }
        }
    }

    private func exportTranscript(_ session: MeetingSession, json: Bool) {
        run {
            let redactor = settings.meetingPIIRedactionRequested ? try settings.transcriptPrivacyRedactor(wrapping: privacy) : nil
            guard let fresh = try await store.load(id: session.id) else { throw CocoaError(.fileNoSuchFile) }
            let output: MeetingSession
            if let redactor {
                try await redactor.prepareForMeeting()
                output = try await MeetingTranscriptPrivacyPolicy.redactedCopy(session: fresh, using: redactor)
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

    private func exportProtectedTranscript(_ session: MeetingSession) {
        run {
            guard let fresh = try await store.load(id: session.id) else { throw CocoaError(.fileNoSuchFile) }
            let data = try await MeetingTranscriptExporter.protectedTranscriptJSONForSharing(for: fresh)
            share = try MeetingSharePayload.transcript(data: data, title: fresh.displayTitle, fileExtension: "json")
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
    var body: some View {
        NavigationStack {
            if case .paragraph(let segments) = draft.kind {
                List {
                    MeetingTranscriptMemberLinks(segments: segments, identifierPrefix: "transcript.edit.fragment") { segment in
                        MeetingEditTextForm(kind: .segment(segment), text: segment.text, cancel: cancel, save: save)
                    }
                }.navigationTitle(PichiLocalization.text("Transcript text"))
                    .accessibilityIdentifier("transcript.edit.fragments")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(PichiLocalization.text("Cancel"), action: cancel) } }
            } else {
                MeetingEditTextForm(kind: draft.kind, text: draft.text, cancel: cancel, save: save)
            }
        }
    }
}

/// The reading paragraph keeps its original members for both text and speaker corrections.
/// Choosing a member never applies a change to another paragraph or participant's other turns.
private struct MeetingTranscriptMemberLinks<Destination: View>: View {
    let segments: [MeetingTranscriptSegment]
    let identifierPrefix: String
    @ViewBuilder let destination: (MeetingTranscriptSegment) -> Destination
    @Environment(\.theme) private var theme

    var body: some View {
        ForEach(segments) { segment in
            NavigationLink {
                destination(segment)
            } label: {
                VStack(alignment: .leading, spacing: theme.metrics.spacing.xs) {
                    Text(MeetingTranscriptExporter.timestampText(segment.start.seconds))
                        .font(theme.typography.codeCaption).foregroundStyle(theme.palette.secondaryText)
                    Text(segment.text).font(theme.typography.body)
                }.frame(minHeight: 44)
            }.accessibilityIdentifier("\(identifierPrefix).\(segment.id)")
        }
    }
}

private struct MeetingSpeakerAssignmentDraft: Identifiable {
    let id = UUID()
    let session: MeetingSession
    let segments: [MeetingTranscriptSegment]
}

private struct MeetingSpeakerAssignmentSheet: View {
    let draft: MeetingSpeakerAssignmentDraft
    let cancel: () -> Void
    let assign: ([MeetingTranscriptSegmentID], SessionSpeakerID) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            Group {
                if draft.segments.count > 1 {
                    List {
                        Section {
                            NavigationLink {
                                participantList(for: draft.segments)
                            } label: {
                                Label(PichiLocalization.text("Whole fragment"), systemImage: "text.alignleft")
                                    .font(theme.typography.body)
                                    .frame(minHeight: 44)
                            }.accessibilityIdentifier("transcript.reassign.whole")
                        } footer: {
                            Text(PichiLocalization.text("Change the speaker for this visible fragment only."))
                                .font(theme.typography.caption)
                        }
                        Section(PichiLocalization.text("Individual words or parts")) {
                            MeetingTranscriptMemberLinks(segments: draft.segments, identifierPrefix: "transcript.reassign.fragment") { segment in
                                participantList(for: [segment])
                            }
                        }
                    }
                    .navigationTitle(PichiLocalization.text("Change speaker"))
                    .accessibilityIdentifier("transcript.reassign.scope")
                } else {
                    participantList(for: draft.segments)
                }
            }.toolbar { cancellation }
        }
    }

    private func participantList(for segments: [MeetingTranscriptSegment]) -> some View {
        List {
            Section {
                ForEach(draft.session.readableSpeakers) { speaker in
                    Button {
                        assign(segments.map(\.id), speaker.id)
                    } label: {
                        Label(MeetingTranscriptExporter.speakerDisplayName(speaker, language: PichiLocalization.language),
                              systemImage: "person.crop.circle")
                            .font(theme.typography.body)
                            .frame(minHeight: 44)
                    }.accessibilityIdentifier("transcript.reassign.target.\(speaker.id)")
                }
            } footer: {
                Text(PichiLocalization.text("Only the selected text changes speaker. Other fragments keep their speakers."))
                    .font(theme.typography.caption)
            }
        }
        .navigationTitle(PichiLocalization.text("Select a speaker"))
        .accessibilityIdentifier("transcript.reassign.targets")
    }

    @ToolbarContentBuilder private var cancellation: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(PichiLocalization.text("Cancel"), action: cancel)
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

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
    @ObservedObject private var privateProfile = PrivateProfileService.shared
    @StateObject private var privatePresentation = MobilePrivatePresentationState()
    @StateObject private var accountInteraction: MobileAccountInteraction
    @StateObject private var cloudInteraction: MobileCloudInteraction
    let cloudPublication: PichiCloudPublicationService?
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    private var destination: Destination {
        get { privatePresentation.destination }
        nonmutating set { privatePresentation.destination = newValue }
    }
    private var settingsPath: [MobileSettingsDestination] {
        get { privatePresentation.settingsPath }
        nonmutating set { privatePresentation.settingsPath = newValue }
    }
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @StateObject private var historySnapshot: MeetingHistorySnapshot
    private var sessions: [MeetingSession] { historySnapshot.sessions }
    // The snapshot owns committed sessions; History's own path keeps only pushed identities.
    private var historyPath: [MeetingSessionID] {
        get { privatePresentation.historyPath }
        nonmutating set { privatePresentation.historyPath = newValue }
    }
    private var copiedSessionID: MeetingSessionID? {
        get { privatePresentation.copiedSessionID }
        nonmutating set { privatePresentation.copiedSessionID = newValue }
    }
    private var search: String {
        get { privatePresentation.search }
        nonmutating set { privatePresentation.search = newValue }
    }
    @State private var isDomainBusy = false
    private var isBusy: Bool { isDomainBusy || privatePresentation.publications.busyCount > 0 }
    private var error: String? {
        get { privatePresentation.error }
        nonmutating set { privatePresentation.error = newValue }
    }
    private var showError: Bool {
        get { privatePresentation.showError }
        nonmutating set { privatePresentation.showError = newValue }
    }
    private var showMicrophoneSettings: Bool {
        get { privatePresentation.showMicrophoneSettings }
        nonmutating set { privatePresentation.showMicrophoneSettings = newValue }
    }
    private var showRecordingSettings: Bool {
        get { privatePresentation.showRecordingSettings }
        nonmutating set { privatePresentation.showRecordingSettings = newValue }
    }
    @State private var microphoneSnapshot = MeetingMicrophoneCatalogSnapshot(identities: [], defaultCoreAudioUID: nil)
    private var edit: MeetingEditDraft? {
        get { privatePresentation.edit }
        nonmutating set { privatePresentation.edit = newValue }
    }
    private var participantEdit: MeetingParticipantEditDraft? {
        get { privatePresentation.participantEdit }
        nonmutating set { privatePresentation.participantEdit = newValue }
    }
    private var speakerAssignment: MeetingSpeakerAssignmentDraft? {
        get { privatePresentation.speakerAssignment }
        nonmutating set { privatePresentation.speakerAssignment = newValue }
    }
    private var deletion: Deletion? {
        get { privatePresentation.deletion }
        nonmutating set { privatePresentation.deletion = newValue }
    }
    private var share: MeetingSharePayload? {
        get { privatePresentation.share }
        nonmutating set { privatePresentation.share = newValue }
    }
    private var showPresentationPicker: Bool {
        get { privatePresentation.showPresentationPicker }
        nonmutating set { privatePresentation.showPresentationPicker = newValue }
    }
    private var presentation: MobilePresentationDocument? {
        get { privatePresentation.presentation }
        nonmutating set { privatePresentation.presentation = newValue }
    }
    private var presentationLoader: MobilePresentationLoader { privatePresentation.presentationLoader }
    @State private var recordingScreenAwakeToken: UUID?
    @StateObject private var playback = MeetingSegmentPlayback()
    // Projection is independent of microphone meters, pending audio, playback progress
    // and other frequent view invalidations. Keep one result for the visible transcript.
    private var transcriptReadingSource: MeetingTranscriptExporter.ReadingInput? {
        get { privatePresentation.transcriptReadingSource }
        nonmutating set { privatePresentation.transcriptReadingSource = newValue }
    }
    private var transcriptReading: [MeetingTranscriptExporter.DisplayParagraph] {
        get { privatePresentation.transcriptReading }
        nonmutating set { privatePresentation.transcriptReading = newValue }
    }



    init(coordinator: MeetingSessionCoordinator, asr: ASRService, store: any MeetingSessionStoring,
         privacy: PichiTranscriptPrivacyService,
         required: MobileRequiredResources, privacyActivation: MobilePrivacyActivation,
         accountSession: AccountSessionService? = nil,
         cloudPublication: PichiCloudPublicationService? = nil,
         microphones: @escaping @Sendable () async throws -> MeetingMicrophoneCatalogSnapshot) {
        self.coordinator = coordinator; self.asr = asr; self.store = store
        self.privacy = privacy; self.microphones = microphones
        self.required = required; self.privacyActivation = privacyActivation
        self.cloudPublication = cloudPublication
        self._cloudInteraction = StateObject(wrappedValue: MobileCloudInteraction(session: accountSession ?? AppServices.shared.accountSession))
        self._historySnapshot = StateObject(wrappedValue: MeetingHistorySnapshot(load: { try await store.loadAll() }))
        self._accountInteraction = StateObject(wrappedValue: MobileAccountInteraction(
            session: accountSession ?? AppServices.shared.accountSession,
            requireTransitionAdmission: { try PrivateProfileService.shared.requireTransitionAdmission() }))
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
    private typealias Deletion = MobilePrivatePresentationState.Deletion

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
        .alert(PichiLocalization.text("Error"), isPresented: $privatePresentation.showError) {
            if showMicrophoneSettings {
                Button(PichiLocalization.text("Open Settings")) {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            }
            Button(PichiLocalization.text("OK"), role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .sheet(isPresented: $privatePresentation.showRecordingSettings) {
            NavigationStack { MobileRecordingSettings(microphones: microphoneSnapshot.identities, isPresentedAsSheet: true, required: required) }
        }
        .sheet(item: $privatePresentation.edit) { draft in
            MeetingEditSheet(draft: draft, cancel: { edit = nil }) { kind, updated in
                edit = nil
                run(session: draft.session) {
                    let result: MeetingSession
                    switch kind {
                    case .segment(let segment):
                        result = try await coordinator.editTranscriptText(sessionID: draft.session.id, segmentID: segment.id, text: updated,
                            expectedRevision: segment.revision)
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
        .sheet(item: $privatePresentation.share) { payload in
            MobileActivitySheet(items: payload.items) { share = nil }
                .onDisappear { payload.cleanup() }
        }
        .sheet(item: $privatePresentation.speakerAssignment) { draft in
            MeetingSpeakerAssignmentSheet(draft: draft, cancel: { speakerAssignment = nil }) { segmentIDs, speakerID in
                guard coordinator.isQuiescent, !isBusy else { return }
                speakerAssignment = nil
                run(session: draft.session) {
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
        .fileImporter(isPresented: $privatePresentation.showPresentationPicker, allowedContentTypes: [.pdf]) { result in
            let admission = privatePresentation.presentationPickerAdmission
            privatePresentation.presentationPickerAdmission = nil
            showPresentationPicker = false
            guard let admission, privatePresentation.publications.canPublish(admission) else { return }
            switch result {
            case .success(let url):
                presentationLoader.load(url: url, canPublish: { privatePresentation.publications.canPublish(admission) }) { result in
                    guard privatePresentation.publications.canPublish(admission) else { return }
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
        .fullScreenCover(item: $privatePresentation.presentation) { document in
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
                        guard canPresent(session) else { return }
                        try await coordinator.deleteSession(id: session.id)
                        guard canPresent(session) else { return }
                        if historyPath.contains(session.id) { historyPath.removeAll() }
                        await refreshHistory()
                    case .audio(let session):
                        guard canPresent(session) else { return }
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
        .onChange(of: destination) { previous, selected in
            if previous == .settings, selected != .settings, settingsPath.last == .account {
                accountInteraction.cancelOwnedSignInOnDisappear()
            }
            playback.stop(); presentationLoader.cancel(); participantEdit = nil
        }
        .onChange(of: settingsPath) { previous, selected in
            if previous.last == .account, selected.last != .account {
                accountInteraction.cancelOwnedSignInOnDisappear()
            }
        }
        .onChange(of: historyPath) { _, _ in playback.stop(); presentationLoader.cancel(); participantEdit = nil }
        .onDisappear {
            // A PDF full-screen cover can temporarily hide its presenting root.
            // Retire pending work without dismissing a valid same-profile payload.
            privatePresentation.retirePendingWork()
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
        @ObservedObject private var privateProfile = PrivateProfileService.shared
        let close: () -> Void

        var body: some View {
            NavigationStack {
                Group {
                    if privateProfile.isPrivateDataVisible {
                        MobilePresentationPDFView(document: document, isRecording: coordinator.isRecording,
                                                  isSceneActive: scenePhase == .active)
                    } else {
                        Text(PichiLocalization.text("account.profile.unavailable"))
                    }
                }
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
            NavigationStack(path: $privatePresentation.settingsPath) {
                sectionRoot(for: item)
            }
        case .meetings:
            NavigationStack { sectionRoot(for: item) }
        case .history:
            NavigationStack(path: $privatePresentation.historyPath) { sectionRoot(for: item) }
        }
    }

    private func sectionRoot(for item: Destination) -> some View {
        Group {
            switch item {
            case .meetings: currentMeeting
            case .history:
                if privateProfile.isPrivateDataVisible { history } else { concealedPrivateData }
            case .settings:
                MobileSettingsRoot(accountSession: accountInteraction.session, accountInteraction: accountInteraction,
                    cloudPublication: cloudPublication, cloudInteraction: cloudInteraction,
                    asr: asr, privacy: privacy, microphones: microphoneSnapshot.identities,
                    required: required, privacyActivation: privacyActivation, reportError: report)
            }
        }
        .navigationTitle(item == .meetings ? AppBrand.meetingName : PichiLocalization.text(item.title))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if privateProfile.isPrivateDataVisible, item == .meetings, coordinator.isRecording || coordinator.isQuiescent {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        guard let admission = privatePresentation.publications.admit() else { return }
                        privatePresentation.presentationPickerAdmission = admission
                        showPresentationPicker = true
                    } label: {
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
            if privateProfile.isPrivateDataVisible, item == .meetings, coordinator.isQuiescent, !coordinator.isRecording, !isShowingStart {
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
            case .completed:
                if canPresent(session) { transcript(session) } else { concealedPrivateData }
            case .interrupted, .failed:
                if canPresent(session) { recovery(session) } else { concealedPrivateData }
            case .idle:
                if privateProfile.isPrivateDataVisible { start } else { concealedPrivateData }
            }
        } else if privateProfile.isPrivateDataVisible { start } else { concealedPrivateData }
    }

    private var concealedPrivateData: some View {
        Text(PichiLocalization.text("account.profile.unavailable"))
            .font(theme.typography.body).fixedSize(horizontal: false, vertical: true)
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityIdentifier("meeting.profile.hidden")
    }

    private func canPresent(_ session: MeetingSession) -> Bool {
        let profile = PrivateProfileStorage.current
        guard privateProfile.isPrivateDataVisible, PrivateProfileStorage.isReadable(profile) else { return false }
        return session.profileOwnership?.matches(profile) ?? profile.isGuest
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
            if !compactHeight, canPresent(session) {
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
            if canPresent(session) {
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
            } else {
                concealedPrivateData
            }
                }.padding(compactHeight ? 12 : 24)
                    .frame(maxWidth: 1000, maxHeight: .infinity, alignment: .topLeading)
                    .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting.recording")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button { run(requiresVisibleProfile: false) { _ = try await coordinator.stopAndTranscribe() } } label: {
                Label(PichiLocalization.text("Stop & Transcribe"), systemImage: "stop.fill")
                    .foregroundStyle(theme.palette.accentForeground)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }.buttonStyle(.borderedProminent).disabled(isDomainBusy || !coordinator.isRecording)
                .accessibilityIdentifier("meeting.stop")
                .padding(.horizontal, 24).padding(.vertical, 12)
                .background(theme.palette.toolbarBackground)
        }
    }

    private func processing(_ session: MeetingSession, stage: MeetingProcessingStage) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Label(PichiLocalization.text("Preparing your transcript"), systemImage: "text.alignleft")
                .font(theme.typography.sectionTitle)
            if canPresent(session) { Text(session.displayTitle).font(theme.typography.title) }
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
                            run(session: session) {
                                _ = try await coordinator.retryProcessing(sessionID: session.id)
                                if canPresent(session) { destination = .meetings }
                            }
                        }.disabled(isBusy || !coordinator.isQuiescent).accessibilityIdentifier("meeting.retry")
                        if session.audioStorageMode == .retainedFiles {
                            Button(PichiLocalization.text("Start processing again")) {
                                playback.stop()
                                run(session: session) {
                                    _ = try await coordinator.restartProcessing(sessionID: session.id)
                                    if canPresent(session) { destination = .meetings }
                                }
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
                    if let cloudPublication {
                        MobileCloudRecordingStatus(service: cloudPublication, interaction: cloudInteraction, recordingID: session.id)
                    }
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
        .searchable(text: $privatePresentation.search, prompt: PichiLocalization.text("Search meetings"))
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
        return ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(session.displayTitle).font(theme.typography.title)
                    HStack {
                        Label(MeetingTranscriptExporter.timestampText(session.duration), systemImage: "clock")
                        Text(session.startedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(PichiLocalization.locale)))
                    }.font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                    if let cloudPublication {
                        MobileCloudRecordingStatus(service: cloudPublication, interaction: cloudInteraction,
                            recordingID: session.id, showsActions: true)
                            .padding(.vertical, theme.metrics.spacing.sm)
                    }
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
                                        run(session: session) { _ = try await coordinator.retryProcessing(sessionID: session.id) }
                                    }.disabled(!coordinator.isQuiescent)
                                }
                                Button(PichiLocalization.text("Export Audio")) { exportAudio(session) }
                                Button(PichiLocalization.text("Delete Audio"), role: .destructive) { deletion = .audio(session) }
                            }
                            Button(PichiLocalization.text("Rename")) { edit = MeetingEditDraft(session: session, kind: .title, text: session.displayTitle) }
                            if coordinator.canUndoCorrection(sessionID: session.id) {
                                Button(PichiLocalization.text("Undo correction")) {
                                    run(session: session) {
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
                        // Keep the editor in the vertical transcript scroll hierarchy, rather
                        // than inside the phone's horizontal participant strip.
                        if let draft = participantEdit, draft.sessionID == session.id, draft.paragraphID == nil,
                           let speaker = session.speakers.first(where: { $0.id == draft.speakerID }) {
                            participantEditor(speaker, session: session, draft: draft)
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
                .scrollDismissesKeyboard(.interactively)
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                    guard let draft = participantEdit, draft.sessionID == session.id else { return }
                    withAnimation { reader.scrollTo(draft.id, anchor: .bottom) }
                }
                .task(id: participantEdit?.id) {
                    guard let draft = participantEdit, draft.sessionID == session.id else { return }
                    // Wait for the expanded editor to enter the scroll layout. This task is
                    // cancelled with its view or a different tapped participant.
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    withAnimation { reader.scrollTo(draft.id, anchor: .bottom) }
                }
                .task(id: readingInput) {
                    let job = privatePresentation.publications.start(affectsBusy: false, report: report) { admission in
                        let projection = try await MeetingTranscriptExporter.readingParagraphs(for: session)
                        guard privatePresentation.publications.canPublish(admission) else { return }
                        transcriptReading = projection
                        transcriptReadingSource = readingInput
                    }
                    await withTaskCancellationHandler { await job?.value } onCancel: { job?.cancel() }
                }
        }
    }

    private func participantButton(_ speaker: MeetingSessionSpeaker, session: MeetingSession, colorIndex: Int?, expands: Bool) -> some View {
        Button {
            participantEdit = MeetingParticipantEditDraft(sessionID: session.id, speaker: speaker)
        } label: {
            Text(MeetingTranscriptExporter.speakerDisplayName(speaker, language: PichiLocalization.language))
                .font(theme.typography.captionStrong)
                .foregroundStyle(MeetingSpeakerPalette.labelColor(forSpeakerIndex: colorIndex,
                    theme: theme, colorScheme: colorScheme))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: expands ? .infinity : nil, minHeight: 44, alignment: .leading)
        }.accessibilityIdentifier("transcript.speaker.\(speaker.id)")
            .accessibilityHint(PichiLocalization.text("Speaker name"))
            .disabled(!coordinator.isQuiescent || isBusy)
    }

    /// The same inline editor serves the roster and a fragment's resolved reading owner.
    /// Only the fragment-specific action opens the existing scoped attribution picker.
    private func participantEditor(_ speaker: MeetingSessionSpeaker, session: MeetingSession,
                                   draft: MeetingParticipantEditDraft,
                                   segments: [MeetingTranscriptSegment]? = nil) -> some View {
        MeetingParticipantInlineEditor(name: draft.name, isLocalUser: speaker.isLocalUser,
            save: { name in
                guard coordinator.isQuiescent, !isBusy else { return }
                run(session: session) {
                    let updated = try await coordinator.renameSpeaker(sessionID: session.id, speakerID: speaker.id, to: name)
                    acceptCommittedSession(updated)
                    if canPresent(session) { participantEdit = nil }
                }
            }, cancel: { participantEdit = nil }, designate: {
                guard coordinator.isQuiescent, !isBusy else { return }
                run(session: session) {
                    let updated = try await coordinator.setLocalUserSpeaker(sessionID: session.id,
                        speakerID: speaker.isLocalUser ? nil : speaker.id)
                    acceptCommittedSession(updated)
                    if canPresent(session) { participantEdit = nil }
                }
            }, reassign: segments.map { members in
                {
                    participantEdit = nil
                    speakerAssignment = MeetingSpeakerAssignmentDraft(session: session, segments: members)
                }
            })
            .id(draft.id)
            .disabled(!coordinator.isQuiescent || isBusy)
    }

    private func transcriptParagraph(_ paragraph: MeetingTranscriptExporter.DisplayParagraph, session: MeetingSession,
                                     names: [SessionSpeakerID: String]) -> some View {
        let segment = paragraph.firstSegment
        // The reading projection can bridge an unresolved first fragment to its owner.
        // Style that same readable identity without changing the stored attribution.
        let presentation = MeetingTranscriptExporter.speakerPresentation(for: paragraph, in: session, speakerNames: names)
        let participant = presentation.participantID.flatMap { id in session.speakers.first { $0.id == id } }
        let isAudioExpanded = paragraph.segments.contains { $0.id == playback.activeSegmentID }
        return VStack(alignment: .leading, spacing: theme.metrics.spacing.sm) {
            HStack(alignment: .top, spacing: theme.metrics.spacing.sm) {
                Text(MeetingTranscriptExporter.timestampText(segment.start.seconds))
                    .font(theme.typography.codeCaption).foregroundStyle(theme.palette.secondaryText)
                    .padding(.top, theme.metrics.spacing.sm)
                if let label = MeetingTranscriptExporter.captionLabel(for: paragraph, in: session,
                    speakerNames: names, language: PichiLocalization.language) {
                    Button {
                        if let participant {
                            participantEdit = MeetingParticipantEditDraft(sessionID: session.id,
                                speaker: participant, paragraphID: paragraph.id)
                        } else {
                            speakerAssignment = MeetingSpeakerAssignmentDraft(session: session, segments: paragraph.segments)
                        }
                    } label: {
                        Text(label)
                            .font(theme.typography.captionStrong)
                            .foregroundStyle(MeetingSpeakerPalette.labelColor(forSpeakerIndex: presentation.participantIndex,
                                theme: theme, colorScheme: colorScheme))
                            .frame(minHeight: 44, alignment: .leading)
                    }.disabled(!coordinator.isQuiescent || isBusy)
                        .accessibilityIdentifier("transcript.reassign.\(segment.id)")
                } else if !names.isEmpty {
                    Button(PichiLocalization.text("Change speaker")) {
                        speakerAssignment = MeetingSpeakerAssignmentDraft(session: session, segments: paragraph.segments)
                    }.font(theme.typography.captionStrong)
                        .frame(minHeight: 44)
                        .disabled(!coordinator.isQuiescent || isBusy)
                        .accessibilityIdentifier("transcript.reassign.\(segment.id)")
                }
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
            if let participant, let draft = participantEdit, draft.sessionID == session.id,
               draft.speakerID == participant.id, draft.paragraphID == paragraph.id {
                participantEditor(participant, session: session, draft: draft, segments: paragraph.segments)
            }
            Text(paragraph.text).font(theme.typography.body).lineSpacing(theme.metrics.spacing.xs)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if isAudioExpanded {
                MeetingSegmentAudioPlayer(playback: playback, isLoading: playback.isLoading)
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("transcript.paragraph.\(paragraph.id)")
    }

    private func beginMeeting() {
        guard privateProfile.isPrivateDataVisible, PrivateProfileStorage.acceptsNewWork,
              let admission = privatePresentation.publications.admit() else { return }
        run {
            // Finish preparation before the capture lease can open the microphone.
            try await required.prepare(modelID: settings.selectedSpeechModel.rawValue)
            guard privatePresentation.publications.canPublish(admission) else { return }
            try await privacyActivation.waitUntilReadyIfRequested()
            guard privatePresentation.publications.canPublish(admission) else { return }
            await refreshMicrophones()
            guard privatePresentation.publications.canPublish(admission) else { return }
            let configuration = try await coordinator.defaultConfiguration(mode: .inRoom,
                title: PichiLocalization.text("In-room meeting"))
            guard privatePresentation.publications.canPublish(admission) else { return }
            _ = try await coordinator.startRecording(configuration: configuration)
        }
    }

    private func newMeeting() {
        guard privateProfile.isPrivateDataVisible, PrivateProfileStorage.acceptsNewWork else { return }
        playback.stop()
        do { try coordinator.resetForNewMeeting(); destination = .meetings } catch { report(error) }
    }

    private func run(session: MeetingSession? = nil, requiresVisibleProfile: Bool = true,
                     _ operation: @escaping @MainActor () async throws -> Void) {
        guard (requiresVisibleProfile ? !isBusy : !isDomainBusy) else { return }
        let admission = privatePresentation.publications.admit()
        guard !requiresVisibleProfile || admission != nil else { return }
        if let session, !canPresent(session) { return }
        isDomainBusy = true
        Task { @MainActor in
            defer { isDomainBusy = false }
            if requiresVisibleProfile {
                guard let admission, privatePresentation.publications.canPublish(admission) else { return }
                if let session, !canPresent(session) { return }
            }
            do { try await operation() }
            catch {
                guard let admission, privatePresentation.publications.canPublish(admission) else { return }
                report(error)
            }
        }
    }

    private func runPrivate(_ operation: @escaping @MainActor (MobilePrivatePublicationTasks.Admission) async throws -> Void) {
        guard !isBusy else { return }
        privatePresentation.publications.start(report: report, operation: operation)
    }

    private func report(_ failure: Error) {
        guard privateProfile.isPrivateDataVisible else { return }
        showMicrophoneSettings = false
        if let captureError = failure as? MeetingCaptureError, case .microphonePermissionDenied = captureError {
            showMicrophoneSettings = true
        }
        error = PichiLocalization.text(failure.localizedDescription)
        showError = true
    }
    private func acceptCommittedSession(_ session: MeetingSession) {
        guard canPresent(session) else { return }
        historySnapshot.applyCommitted(session)
    }
    private func refreshHistory() async {
        let job = privatePresentation.publications.start(affectsBusy: false) { admission in
            await historySnapshot.refresh()
            guard privatePresentation.publications.canPublish(admission) else { return }
            if let message = historySnapshot.errorMessage { error = message; showError = true; return }
            if let id = historyPath.last, !sessions.contains(where: { $0.id == id }) { historyPath.removeAll() }
        }
        await withTaskCancellationHandler { await job?.value } onCancel: { job?.cancel() }
    }
    private func refreshMicrophones() async {
        do { microphoneSnapshot = try await microphones() } catch { report(error) }
    }

    private func copyTranscript(_ session: MeetingSession) {
        guard canPresent(session) else { return }
        runPrivate { admission in
            let output: MeetingSession
            if settings.meetingPIIRedactionRequested {
                let redactor = try settings.transcriptPrivacyRedactor(wrapping: privacy)
                try await redactor.prepareForMeeting()
                guard privatePresentation.publications.canPublish(admission) else { return }
                output = try await MeetingTranscriptPrivacyPolicy.redactedCopy(session: session, using: redactor)
            } else { output = session }
            guard privatePresentation.publications.canPublish(admission) else { return }
            UIPasteboard.general.string = MeetingTranscriptExporter.text(for: output)
            copiedSessionID = session.id
            privatePresentation.publications.start(affectsBusy: false) { confirmation in
                try await Task.sleep(for: .seconds(2))
                guard privatePresentation.publications.canPublish(confirmation) else { return }
                if copiedSessionID == session.id { copiedSessionID = nil }
            }
        }
    }

    private func exportTranscript(_ session: MeetingSession, json: Bool) {
        guard canPresent(session) else { return }
        runPrivate { admission in
            let redactor = settings.meetingPIIRedactionRequested ? try settings.transcriptPrivacyRedactor(wrapping: privacy) : nil
            guard let fresh = try await store.load(id: session.id) else { throw CocoaError(.fileNoSuchFile) }
            guard privatePresentation.publications.canPublish(admission) else { return }
            let output: MeetingSession
            if let redactor {
                try await redactor.prepareForMeeting()
                guard privatePresentation.publications.canPublish(admission) else { return }
                output = try await MeetingTranscriptPrivacyPolicy.redactedCopy(session: fresh, using: redactor)
            } else { output = fresh }
            guard privatePresentation.publications.canPublish(admission) else { return }
            let data = json ? try MeetingTranscriptExporter.json(for: output) : Data(MeetingTranscriptExporter.text(for: output).utf8)
            let payload = try MeetingSharePayload.transcript(data: data, title: output.title, fileExtension: json ? "json" : "txt")
            guard privatePresentation.publications.canPublish(admission) else { payload.cleanup(); return }
            share?.cleanup(); share = payload
        }
    }

    private func exportAudio(_ session: MeetingSession) {
        guard canPresent(session) else { return }
        runPrivate { admission in
            guard let fresh = try await store.load(id: session.id), fresh.retention.audioDeletedAt == nil,
                  fresh.hasFinalizedAudio
            else { throw CocoaError(.fileNoSuchFile) }
            guard privatePresentation.publications.canPublish(admission) else { return }
            guard let directory = try await store.existingSessionDirectory(for: fresh.id) else { throw CocoaError(.fileNoSuchFile) }
            guard privatePresentation.publications.canPublish(admission) else { return }
            let payload = try await MeetingSharePayload.audio(session: fresh, directory: directory)
            guard privatePresentation.publications.canPublish(admission) else { payload.cleanup(); return }
            share?.cleanup(); share = payload
        }
    }

    private func exportProtectedTranscript(_ session: MeetingSession) {
        guard canPresent(session) else { return }
        runPrivate { admission in
            guard let fresh = try await store.load(id: session.id) else { throw CocoaError(.fileNoSuchFile) }
            guard privatePresentation.publications.canPublish(admission) else { return }
            let data = try await MeetingTranscriptExporter.protectedTranscriptJSONForSharing(for: fresh)
            guard privatePresentation.publications.canPublish(admission) else { return }
            let payload = try MeetingSharePayload.transcript(data: data, title: fresh.displayTitle, fileExtension: "json")
            guard privatePresentation.publications.canPublish(admission) else { payload.cleanup(); return }
            share?.cleanup(); share = payload
        }
    }
}


/// Per-window private UI values and publication jobs. N2 owns profile selection;
/// this participant only retires transient readers/payloads before replacement.
@MainActor
private final class MobilePrivatePresentationState: ObservableObject, PrivateProfileTransitionParticipant {
    @Published var destination: MobileMeetingRoot.Destination = .meetings
    @Published var settingsPath: [MobileSettingsDestination] = []
    @Published var historyPath: [MeetingSessionID] = []
    @Published var copiedSessionID: MeetingSessionID?
    @Published var search: String = ""
    @Published var error: String?
    @Published var showError: Bool = false
    @Published var showMicrophoneSettings: Bool = false
    @Published var showRecordingSettings: Bool = false
    @Published var edit: MeetingEditDraft?
    @Published var participantEdit: MeetingParticipantEditDraft?
    @Published var speakerAssignment: MeetingSpeakerAssignmentDraft?
    @Published var deletion: Deletion?
    @Published var share: MeetingSharePayload?
    @Published var showPresentationPicker: Bool = false
    @Published var presentation: MobilePresentationDocument?
    @Published var transcriptReadingSource: MeetingTranscriptExporter.ReadingInput?
    @Published var transcriptReading: [MeetingTranscriptExporter.DisplayParagraph] = []
    enum Deletion {
        case meeting(MeetingSession), audio(MeetingSession)
        var title: String { if case .audio = self { return "Delete Audio?" }; return "Delete Meeting" }
        var action: String { if case .audio = self { return "Delete Audio" }; return "Delete" }
        var message: String {
            if case .audio = self { return "The transcript stays; the audio files are deleted." }
            return "Delete this meeting and its recordings?"
        }
    }

    let presentationLoader = MobilePresentationLoader()
    let publications: MobilePrivatePublicationTasks
    var presentationPickerAdmission: MobilePrivatePublicationTasks.Admission?
    private var cleanupTask: Task<Void, Never>?
    private var clearAfterJoin = false
    private var observers = Set<AnyCancellable>()

    init(profiles: PrivateProfileService = .shared) {
        publications = MobilePrivatePublicationTasks(capture: {
            let profile = PrivateProfileStorage.current
            guard profiles.isPrivateDataVisible, !profiles.isTransitioning,
                  PrivateProfileStorage.acceptsNewWork, PrivateProfileStorage.isReadable(profile) else { return nil }
            return .init(profile: profile, projectionRevision: profiles.projectionRevision)
        }, validate: { context in
            profiles.isPrivateDataVisible && !profiles.isTransitioning
                && profiles.projectionRevision == context.projectionRevision
                && PrivateProfileStorage.acceptsNewWork
                && PrivateProfileStorage.current == context.profile
                && PrivateProfileStorage.isReadable(context.profile)
        })
        profiles.register(self)
        profiles.$isPrivateDataVisible.dropFirst().sink { [weak self] visible in
            if !visible { self?.invalidate() }
        }.store(in: &observers)
        profiles.$projectionRevision.dropFirst().sink { [weak self] _ in self?.invalidate() }
            .store(in: &observers)
        publications.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &observers)
        presentationLoader.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &observers)
    }

    func invalidate() {
        clearAfterJoin = true
        clear()
        retirePendingWork()
    }

    func retirePendingWork() {
        publications.cancel(); presentationLoader.cancel()
        copiedSessionID = nil
        guard cleanupTask == nil else { return }
        cleanupTask = Task { @MainActor in
            await self.publications.cancelAndJoin()
            await self.presentationLoader.waitUntilFinished()
            if self.clearAfterJoin { self.clear() }
            self.clearAfterJoin = false
            self.cleanupTask = nil
            self.publications.resume()
        }
    }

    func prepareForPrivateProfileTransition() async throws {
        invalidate()
        await cleanupTask?.value
    }


    private func clear() {
        // Retain the safe account host during its own service-driven concealment.
        // Private settings/history routes and all private values are still retired.
        if destination != .settings || settingsPath.last != .account {
            destination = .meetings; settingsPath = []
        }
        historyPath = []; search = ""
        copiedSessionID = nil; edit = nil; participantEdit = nil; speakerAssignment = nil; deletion = nil
        share?.cleanup(); share = nil
        presentationPickerAdmission = nil; showPresentationPicker = false; presentation = nil
        transcriptReadingSource = nil; transcriptReading = []
        error = nil; showError = false; showMicrophoneSettings = false; showRecordingSettings = false
    }
}

/// A location identifies the tapped label so only that label expands, even when a
/// participant occurs in both the roster and several transcript fragments.
private struct MeetingParticipantEditDraft: Identifiable {
    let id = UUID()
    let sessionID: MeetingSessionID
    let speakerID: SessionSpeakerID
    let paragraphID: MeetingTranscriptSegmentID?
    let name: String

    init(sessionID: MeetingSessionID, speaker: MeetingSessionSpeaker, paragraphID: MeetingTranscriptSegmentID? = nil) {
        self.sessionID = sessionID; self.speakerID = speaker.id; self.paragraphID = paragraphID
        self.name = speaker.displayName
    }
}

private struct MeetingParticipantInlineEditor: View {
    let isLocalUser: Bool
    let save: (String) -> Void
    let cancel: () -> Void
    let designate: () -> Void
    let reassign: (() -> Void)?
    @Environment(\.theme) private var theme
    @State private var name: String
    @FocusState private var isNameFocused: Bool

    init(name: String, isLocalUser: Bool, save: @escaping (String) -> Void,
         cancel: @escaping () -> Void, designate: @escaping () -> Void, reassign: (() -> Void)?) {
        self._name = State(initialValue: name); self.isLocalUser = isLocalUser
        self.save = save; self.cancel = cancel; self.designate = designate; self.reassign = reassign
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.xs) {
            TextField(PichiLocalization.text("Speaker name"), text: $name)
                .font(theme.typography.body)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .frame(minHeight: 44)
                .focused($isNameFocused)
                .submitLabel(.done)
                .onSubmit { if canSave { save(name) } }
                .accessibilityIdentifier("transcript.participant.name")
            HStack(spacing: theme.metrics.spacing.md) {
                Button { save(name) } label: {
                    Text(PichiLocalization.text("Save")).frame(minWidth: 44, minHeight: 44)
                }.disabled(!canSave)
                    .accessibilityIdentifier("transcript.participant.save")
                Button(action: cancel) {
                    Text(PichiLocalization.text("Cancel")).frame(minWidth: 44, minHeight: 44)
                }.accessibilityIdentifier("transcript.participant.cancel")
            }.frame(minHeight: 44)
            Button(action: designate) {
                Text(PichiLocalization.text(isLocalUser ? "Remove You designation" : "This is me"))
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            }.accessibilityIdentifier("transcript.participant.\(isLocalUser ? "removeYou" : "markYou")")
            if let reassign {
                Button(action: reassign) {
                    Text(PichiLocalization.text("Change speaker")).frame(minWidth: 44, minHeight: 44, alignment: .leading)
                }.accessibilityIdentifier("transcript.participant.changeSpeaker")
            }
        }.font(theme.typography.captionStrong)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("transcript.participant.editor")
            .onAppear { isNameFocused = true }
    }
}

struct MeetingEditDraft: Identifiable {
    enum Kind { case segment(MeetingTranscriptSegment), paragraph([MeetingTranscriptSegment]), title }
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
                        Text(MeetingTranscriptExporter.speakerDisplayName(speaker, language: PichiLocalization.language))
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

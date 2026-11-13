import AppKit
import SwiftUI

struct MeetingRecordingCanvas: View {
    let session: MeetingSession
    let trackHealth: [MeetingAudioTrackKind: MeetingTrackHealth]
    let liveTranscript: MeetingLiveTranscriptSnapshot
    var pendingSpeech: MeetingPendingSpeechSnapshot = .empty
    var microphoneMuteState: MeetingMicrophoneMuteState = .notApplicable
    var onToggleMicrophone: (() -> Void)? = nil
    let isStopping: Bool
    let onStop: () -> Void
    var onRename: ((String) -> Void)? = nil
    var errorMessage: String? = nil

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: self.theme.metrics.spacing.md) {
                    Label(
                        self.isStopping ? PichiLocalization.text("Saving recording") : PichiLocalization.text("Recording"),
                        systemImage: self.isStopping ? "stop.circle.fill" : "record.circle.fill"
                    )
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(self.isStopping ? self.theme.palette.warning : self.theme.palette.readableText(Color(nsColor: .systemRed)))
                    Spacer(minLength: 0)
                    Text(Self.durationText(context.date.timeIntervalSince(self.session.startedAt)))
                        .font(self.theme.typography.codeCaption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    PichiLocalization.format("%@, %@ elapsed",
                        PichiLocalization.text(self.isStopping ? "Meeting recording is stopping" : "Meeting recording in progress"),
                        Self.durationText(context.date.timeIntervalSince(self.session.startedAt)))
                )
            }

            if !self.session.isLocalContentConcealed {
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                    MeetingDocumentTitle(title: self.session.displayTitle)
                        .lineLimit(2)
                        .editableTitle(
                            self.session.title,
                            id: String(describing: self.session.id),
                            enabled: !self.isStopping && self.onRename != nil,
                            editorFont: .fluidSystem(.largeTitle, design: .serif).weight(.medium),
                            singleClickEnabled: true,
                            submitUnchanged: true,
                            onRename: { self.onRename?($0) }
                        )
                        .accessibilityIdentifier("meeting-recording-title")
                        .help(self.session.displayTitle)
                    Text(self.sourceSummary)
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .lineLimit(1)
                        .help(self.sourceSummary)
                    if let place = self.session.savedLocationLabel(language: PichiLocalization.language) {
                        Text(verbatim: place)
                            .accessibilityLabel(place)
                            .font(self.theme.typography.caption)
                            .foregroundStyle(self.theme.palette.secondaryText)
                            .lineLimit(2)
                            .help(place)
                            .accessibilityIdentifier("meeting.recording.location")
                    }
                }

            }

            if let errorMessage, !errorMessage.isEmpty {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("meeting-recording-action-error")
            }

            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: self.theme.metrics.spacing.xl) { self.sourceHealth }
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) { self.sourceHealth }
                }
                Divider()
            }

            if self.session.isLocalContentConcealed {
                MeetingLocalContentConcealmentView()
                    .frame(maxHeight: .infinity, alignment: .topLeading)
            } else {
                if let warning = self.session.microphoneEchoWarning {
                    MeetingAudioTranscriptNotice(
                        text: "Some audio may have an echo.",
                        detail: warning,
                        isSubtle: true
                    )
                }
                MeetingLiveTranscriptCard(snapshot: self.liveTranscript, pendingSpeech: self.pendingSpeech)
            }

            Divider()
            FluidGlassControlGroup {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: self.theme.metrics.spacing.lg) {
                        self.recordingFooter
                        Spacer(minLength: 0)
                        self.stopButton
                    }
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                        self.recordingFooter
                        HStack {
                            Spacer(minLength: 0)
                            self.stopButton
                        }
                    }
                }
            }
        }
    }

    private var recordingFooter: some View {
        Text(self.isStopping
            ? PichiLocalization.text("Saving your recording before transcription begins.")
            : PichiLocalization.text(self.session.effectiveSpeakerProcessingMode == .streaming
                ? "Speaker labels appear after enough speech has been collected."
                : "Speaker labels are added after recording."))
            .font(self.theme.typography.caption)
            .foregroundStyle(self.theme.palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var stopButton: some View {
        Button(action: self.onStop) {
            if self.isStopping {
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Saving recording…")
                }
            } else {
                Label("Stop & Transcribe", systemImage: "stop.fill")
            }
        }
        .meetingGlassAction(prominent: true, tone: Color(nsColor: .systemRed))
        .disabled(self.isStopping)
    }

    @ViewBuilder
    private var sourceHealth: some View {
        if self.session.mode == .onlineCall {
            MeetingTrackHealthRow(title: PichiLocalization.text(self.session.effectiveApplicationAudioScope == .systemAudio ? "System audio" : "Meeting audio"), systemImage: "macwindow", health: self.trackHealth[.applicationAudio] ?? .waiting)
        }
        MeetingTrackHealthRow(
            title: PichiLocalization.text("Microphone"), systemImage: "mic",
            health: self.trackHealth[.microphone] ?? .waiting,
            microphoneMuteState: self.session.mode == .onlineCall ? self.microphoneMuteState : .notApplicable,
            onToggleMicrophone: self.isStopping ? nil : self.onToggleMicrophone
        )
    }

    private var sourceSummary: String {
        let microphoneName = self.session.selectedMicrophone.displayName
        guard self.session.mode == .onlineCall else { return microphoneName }
        let applicationName = self.session.capturedApplication?.displayName ?? PichiLocalization.text(self.session.audioSourceDisplayName)
        return "\(applicationName) · \(microphoneName)"
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// Live captions during recording only — rows identify capture source, not a person; the offline
/// diarization pipeline replaces this view's content entirely on completion.
private struct MeetingLiveTranscriptCard: View {
    let snapshot: MeetingLiveTranscriptSnapshot
    var pendingSpeech: MeetingPendingSpeechSnapshot = .empty

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            HStack {
                Text("Live transcript")
                    .font(self.theme.typography.sectionTitle)
                    .foregroundStyle(self.theme.palette.primaryText)
                Spacer()
                FluidGlassControlGroup {
                    Button {
                        MeetingRecordingPillController.shared.expand()
                    } label: {
                        Image(systemName: "captions.bubble")
                    }
                    .meetingGlassAction(circular: true)
                    .help("Show the live captions overlay")
                    .accessibilityLabel("Show live captions overlay")
                }
            }

            if let indicator = self.availabilityIndicator {
                Label(indicator, systemImage: "exclamationmark.circle")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if self.snapshot.utterances.isEmpty && self.snapshot.partials.values.allSatisfy({ $0.text.isEmpty }) && self.pendingSpeech.tokens.isEmpty {
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                    Text(self.availabilityIndicator == nil ? PichiLocalization.text("Listening for conversation") : PichiLocalization.text("Waiting for captions"))
                        .font(self.theme.typography.body)
                        .foregroundStyle(self.theme.palette.secondaryText)
                    Text("Your conversation will appear here as people speak.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.tertiaryText)
                }
                .padding(.top, self.theme.metrics.spacing.sm)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                self.scrollingBubbleList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var availabilityIndicator: String? {
        switch self.snapshot.availability {
        case .available:
            return nil
        case let .unavailable(reason), let .degraded(reason):
            return MeetingUILocalization.captionAvailability(reason)
        }
    }

    private var scrollingBubbleList: some View {
        MeetingLiveTranscriptScrollList(snapshot: self.snapshot, pending: self.pendingSpeech, documentStyle: true)
            .frame(minHeight: 120, maxHeight: .infinity)
    }
}

struct MeetingProcessingCanvas: View {
    let session: MeetingSession
    let stage: MeetingProcessingStage

    @Environment(\.theme) private var theme

    private let stages: [MeetingProcessingStage] = [
        .saving,
        .identifyingSpeakers,
        .transcribing,
        .finalizing,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                ProgressView()
                    .controlSize(.small)
                    .fixedSize()
                Text("Preparing your transcript")
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }

            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                if !self.session.isLocalContentConcealed {
                    MeetingDocumentTitle(title: self.session.displayTitle)
                    if let place = self.session.savedLocationLabel(language: PichiLocalization.language) {
                        Text(verbatim: place)
                            .accessibilityLabel(place)
                            .font(self.theme.typography.caption)
                            .foregroundStyle(self.theme.palette.secondaryText)
                            .lineLimit(2)
                            .help(place)
                            .accessibilityIdentifier("meeting.processing.location")
                    }
                }
                Text("You can close this window. Processing continues on this Mac.")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }

            Divider()
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xxl) {
                ForEach(Array(self.stages.enumerated()), id: \.element) { index, stage in
                    HStack(spacing: self.theme.metrics.spacing.md) {
                        Image(systemName: self.icon(for: stage, index: index))
                            .foregroundStyle(self.color(for: stage, index: index))
                            .font(self.theme.typography.sectionTitle)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                            Text(Self.title(for: stage))
                                .font(self.theme.typography.bodyStrong)
                                .foregroundStyle(self.stage != .completed && index > self.activeIndex
                                    ? self.theme.palette.secondaryText : self.theme.palette.primaryText)
                            if stage == self.stage {
                                Text(Self.detail(for: stage))
                                    .font(self.theme.typography.caption)
                                    .foregroundStyle(self.theme.palette.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(Self.title(for: stage)), \(self.accessibilityStatus(for: stage, index: index))")
                }
            }
            .padding(.vertical, self.theme.metrics.spacing.sm)
        }
    }

    private var activeIndex: Int {
        self.stages.firstIndex(of: self.stage) ?? 0
    }

    private func icon(for stage: MeetingProcessingStage, index: Int) -> String {
        if self.stage == .completed || index < self.activeIndex { return "checkmark.circle.fill" }
        if stage == self.stage { return "circle.dotted" }
        return "circle"
    }

    private func color(for stage: MeetingProcessingStage, index: Int) -> Color {
        if self.stage == .completed || index < self.activeIndex { return self.theme.palette.success }
        if stage == self.stage { return self.theme.palette.accent }
        return self.theme.palette.tertiaryText
    }

    private func accessibilityStatus(for stage: MeetingProcessingStage, index: Int) -> String {
        if self.stage == .completed || index < self.activeIndex { return PichiLocalization.text("complete") }
        if stage == self.stage { return PichiLocalization.text("in progress") }
        return PichiLocalization.text("waiting")
    }

    private static func title(for stage: MeetingProcessingStage) -> String {
        switch stage {
        case .pending: return PichiLocalization.text("Waiting")
        case .saving: return PichiLocalization.text("Saving")
        case .identifyingSpeakers: return PichiLocalization.text("Identifying speakers")
        case .transcribing: return PichiLocalization.text("Transcribing")
        case .finalizing: return PichiLocalization.text("Finalizing")
        case .completed: return PichiLocalization.text("Complete")
        }
    }

    private static func detail(for stage: MeetingProcessingStage) -> String {
        switch stage {
        case .pending: PichiLocalization.text("Your recording is waiting to be processed.")
        case .saving: PichiLocalization.text("Finishing and saving the captured audio.")
        case .identifyingSpeakers: PichiLocalization.text("Finding the different voices in your meeting.")
        case .transcribing: PichiLocalization.text("Turning your conversation into text.")
        case .finalizing: PichiLocalization.text("Putting the transcript and speaker labels together.")
        case .completed: PichiLocalization.text("Your transcript is ready.")
        }
    }
}

/// Escape also dismisses: viewing a past meeting is a detail view, not a mode.
private struct MeetingCloseTranscriptButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            MeetingDocumentActionLabel(title: PichiLocalization.text("Close"), symbol: "xmark")
        }
        .meetingGlassAction()
        .keyboardShortcut(.cancelAction)
        .help("Close this transcript")
        .accessibilityLabel("Close transcript")
    }
}

/// The same label box gives Button and Menu identical native control geometry.
private struct MeetingDocumentActionLabel: View {
    let title: String
    var symbol: String? = nil
    var disclosure = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            if let symbol {
                Image(systemName: symbol).frame(width: 14, height: 14)
            }
            Text(self.title)
            if self.disclosure {
                Image(systemName: "chevron.down")
                    .font(self.theme.typography.captionSmall)
                    .frame(width: 10, height: 14)
            }
        }
        .font(self.theme.typography.bodySmallStrong)
        .frame(height: 20)
        .contentShape(Rectangle())
    }
}

/// A cached reading projection keeps the original correction/playback members while the
/// desktop renders one row per readable turn. Its source stamp rejects a retired session/edit.
nonisolated struct MeetingResultTranscriptProjection: Equatable, Sendable {
    struct Row: Identifiable, Equatable, Sendable {
        let paragraph: MeetingTranscriptExporter.DisplayParagraph
        let presentation: MeetingSpeakerPresentation
        var id: MeetingTranscriptSegmentID { self.paragraph.id }
        var memberIDs: [MeetingTranscriptSegmentID] { self.paragraph.segments.map(\.id) }
    }

    let source: MeetingTranscriptExporter.ReadingInput
    private let readingRows: [Row]
    private let rowsIncludingEchoes: [Row]

    /// Row construction also walks the complete source. Keep it off the UI actor
    /// with contextual grouping, and join cancellation before returning.
    static func make(for session: MeetingSession) async throws -> Self {
        try Task.checkCancellation()
        let work = Task.detached(priority: .userInitiated) {
            let paragraphs = try await MeetingTranscriptExporter.readingParagraphs(for: session)
            try Task.checkCancellation()
            let value = Self(session: session, paragraphs: paragraphs)
            try Task.checkCancellation()
            return value
        }
        return try await withTaskCancellationHandler {
            let value = try await work.value
            try Task.checkCancellation()
            return value
        } onCancel: { work.cancel() }
    }

    init(session: MeetingSession, paragraphs: [MeetingTranscriptExporter.DisplayParagraph]) {
        self.source = MeetingTranscriptExporter.ReadingInput(session)
        let names = Dictionary(uniqueKeysWithValues: session.activeSpeakers.map { ($0.id, $0.displayName) })
        func row(_ paragraph: MeetingTranscriptExporter.DisplayParagraph) -> Row {
            Row(paragraph: paragraph, presentation: MeetingTranscriptExporter.speakerPresentation(
                for: paragraph, in: session, speakerNames: names))
        }
        self.readingRows = paragraphs.map(row)
        // Revealing probable echoes is an evidence view: individual original members keep
        // chronology even when an echo fell inside a normal reading turn. Single-member
        // playback stays valid without inventing grouped intervals around excluded echoes.
        let owners = Dictionary(self.readingRows.flatMap { value in
            value.memberIDs.map { ($0, value.presentation) }
        }, uniquingKeysWith: { first, _ in first })
        self.rowsIncludingEchoes = session.transcriptSegments.enumerated().sorted {
            ($0.element.start, $0.element.end, $0.offset) < ($1.element.start, $1.element.end, $1.offset)
        }.compactMap { _, member in
            let paragraph = MeetingTranscriptExporter.DisplayParagraph(segments: [member])
            if member.isEcho { return row(paragraph) }
            guard let owner = owners[member.id] else { return nil }
            return Row(paragraph: paragraph, presentation: owner)
        }
    }

    func rows(matching source: MeetingTranscriptExporter.ReadingInput, includeEchoes: Bool) -> [Row] {
        guard self.source == source else { return [] }
        return includeEchoes ? self.rowsIncludingEchoes : self.readingRows
    }
}

/// Multi-member reading rows still edit/name one original, revision-checked source member.
/// This draft owns no mutation and can be dismissed without changing transcript evidence.
nonisolated struct MeetingTranscriptMemberSelection: Identifiable {
    enum Purpose { case editText, nameSpeaker }
    let paragraph: MeetingTranscriptExporter.DisplayParagraph
    let purpose: Purpose
    var id: MeetingTranscriptSegmentID { self.paragraph.id }

    func members(matching query: String) -> [MeetingTranscriptSegment] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? self.paragraph.segments : self.paragraph.segments.filter {
            $0.text.localizedCaseInsensitiveContains(query)
        }
    }

    func member(id: MeetingTranscriptSegmentID) -> MeetingTranscriptSegment? {
        self.paragraph.segments.first { $0.id == id }
    }
}

struct MeetingResultCanvas: View {
    let session: MeetingSession
    let isQuiescent: Bool
    let canUndo: Bool
    @State private var showsProbableEchoes = false
    @StateObject private var playback = MeetingSegmentPlayback()
    let onCopyTranscript: (MeetingSession, Bool) -> Void
    let onExportTranscript: (MeetingSession, MeetingTranscriptExportFormat, Bool) -> Void
    let onReassignSegments: ([MeetingTranscriptSegmentID], SessionSpeakerID) -> Void
    var onEditTranscriptSegment: (MeetingTranscriptSegmentID, String, Int) async -> String? = { _, _, _ in "Transcript editing is unavailable." }
    let onNameUnknownSegment: (MeetingTranscriptSegmentID, String) -> Void
    let onUndo: () async -> Bool
    let onRenameSession: (String) -> Void
    var onRetranscribe: ((String) -> Void)? = nil
    let onAssignSpeakers: (MeetingSpeakerEdits) async -> String?
    let onClose: (() -> Void)?
    var summaryASRService: ASRService? = nil
    var isRetranscribing = false

    /// Opens FluidMeet settings on Integrations, so adding an agent is one step from any meeting.
    var onOpenIntegrations: (() -> Void)? = nil
    var onSetLocalUserSpeaker: ((SessionSpeakerID?) -> Void)? = nil

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @Environment(\.undoManager) private var undoManager
    @StateObject private var correctionUndo = MeetingCorrectionUndoRegistration()
    @State private var pendingEditedSegment: MeetingTranscriptSegment?
    @State private var pendingMemberSelection: MeetingTranscriptMemberSelection?
    @State private var selectedMemberAction: (member: MeetingTranscriptSegment, purpose: MeetingTranscriptMemberSelection.Purpose)?
    @State private var readingProjection: MeetingResultTranscriptProjection?
    @State private var pendingNameUnknownSegmentID: MeetingTranscriptSegmentID?
    @State private var pendingUnknownSpeakerName = ""
    @State private var isRenamingSession = false
    @State private var pendingRenameSessionText = ""
    @State private var isChoosingRetranscriptionLanguage = false
    @State private var retranscriptionLanguageCode = ""
    @State private var isShowingAssignSpeakers = false
    @State private var assignSpeakersFocus: SessionSpeakerID?
    @State private var copied = false
    @State private var copyRevision = 0
    @State private var documentSection: MeetingDocumentSection = .transcript
    @ObservedObject private var appServices = AppServices.shared

    static func visibleDocumentSection(selected: MeetingDocumentSection, sessionID: MeetingSessionID,
                                       activeSummarySessionID: MeetingSessionID?) -> MeetingDocumentSection {
        activeSummarySessionID == sessionID ? .summary : selected
    }

    private var visibleDocumentSection: MeetingDocumentSection {
        Self.visibleDocumentSection(selected: self.documentSection, sessionID: self.session.id,
                                    activeSummarySessionID: self.appServices.activeMeetingSummarySession?.id)
    }

    @ObservedObject private var summaryActivity = MeetingSummaryActivityCoordinator.shared

    /// Naming is reached by clicking a speaker's name, so the sheet opens on the one clicked.
    private func presentAssignSpeakers(focusing speakerID: SessionSpeakerID?) {
        guard self.isQuiescent, !self.session.readableSpeakers.isEmpty else { return }
        self.assignSpeakersFocus = speakerID
        self.isShowingAssignSpeakers = true
    }

    private func chipTint(for speaker: MeetingSessionSpeaker) -> Color? {
        self.speakerTints[speaker.id]
    }

    private var speakerTints: [SessionSpeakerID: Color] {
        MeetingSpeakerPalette.tintIndices(for: self.session.speakers).mapValues { index in
            MeetingSpeakerPalette.labelColor(forSpeakerIndex: index, theme: self.theme, colorScheme: self.colorScheme)
        }
    }

    private var hasEchoSegments: Bool {
        self.session.transcriptSegments.contains(where: \.isEcho)
    }

    private func beginMemberAction(_ purpose: MeetingTranscriptMemberSelection.Purpose,
                                   paragraph: MeetingTranscriptExporter.DisplayParagraph) {
        guard self.isQuiescent else { return }
        self.playback.stop()
        if paragraph.segments.count == 1 {
            self.selectMember(paragraph.firstSegment, purpose: purpose)
        } else {
            self.pendingMemberSelection = MeetingTranscriptMemberSelection(paragraph: paragraph, purpose: purpose)
        }
    }

    private func selectMember(_ member: MeetingTranscriptSegment,
                              purpose: MeetingTranscriptMemberSelection.Purpose) {
        guard self.isQuiescent else { return }
        switch purpose {
        case .editText: self.pendingEditedSegment = member
        case .nameSpeaker:
            self.pendingNameUnknownSegmentID = member.id
            self.pendingUnknownSpeakerName = ""
        }
    }

    var body: some View {
        let readingInput = MeetingTranscriptExporter.ReadingInput(self.session)
        let isReadingCurrent = self.readingProjection?.source == readingInput
        let rows = self.readingProjection?.rows(matching: readingInput, includeEchoes: self.showsProbableEchoes) ?? []
        let visibleSpeakerIDs = Set(rows.compactMap { $0.presentation.participantID })
        let activeSpeakers = self.session.readableSpeakers.filter { visibleSpeakerIDs.contains($0.id) }
        // One scroller preserves a readable document at short window heights.
        let document = ScrollView {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xxl) {
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
                    self.documentHeader(hasText: !rows.isEmpty)
                    MeetingDocumentTabs(selection: Binding(get: { self.visibleDocumentSection }, set: { self.documentSection = $0 }), isEnabled: self.summaryActivity.selectionLock == nil)
                }

                if self.visibleDocumentSection == .summary {
                    MeetingSummaryView(session: self.session, asrService: self.summaryASRService, isQuiescent: self.isQuiescent)
                        .id(self.session.id)
                } else {
                    if let warning = self.session.microphoneEchoWarning {
                        MeetingAudioTranscriptNotice(
                            text: "Some audio may have an echo.",
                            detail: warning,
                            isSubtle: true
                        )
                    }
                    if self.session.hasIncompleteTranscriptCoverage {
                        MeetingAudioTranscriptNotice(text: "Some recorded audio was not transcribed.",
                            visibleDetail: MeetingTranscriptExporter.coverageDescription(in: self.session,
                                language: PichiInterfaceLanguage(rawValue: self.locale.identifier) ?? PichiLocalization.language))
                    }
                    if !activeSpeakers.isEmpty {
                        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                            self.speakerStrip(activeSpeakers)
                            if self.session.state == .completed,
                               let note = Self.speakerAccuracyNote(speakerCount: self.session.readableSpeakers.count)
                            {
                                self.speakerAccuracyNoteView(note, speakerCount: self.session.readableSpeakers.count)
                            }
                        }
                    }

                    if let errorMessage = self.playback.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(self.theme.typography.caption)
                            .foregroundStyle(self.theme.palette.warning)
                    }
                    if !isReadingCurrent {
                        ProgressView(PichiLocalization.text("Preparing your transcript"))
                            .padding(.vertical, self.theme.metrics.spacing.sm)
                    } else if rows.isEmpty {
                        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                            Text("No transcript text")
                                .font(self.theme.typography.bodyStrong)
                                .foregroundStyle(self.theme.palette.primaryText)
                            Text(self.emptyTranscriptDescription)
                                .font(self.theme.typography.body)
                                .foregroundStyle(self.theme.palette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, self.theme.metrics.spacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        LazyVStack(alignment: .leading, spacing: self.theme.metrics.spacing.xxl) {
                            ForEach(rows) { row in
                                self.transcriptParagraph(row)
                            }
                        }
                        .padding(.bottom, self.theme.metrics.spacing.xxl)
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        // Separate the document and modifier chains to bound SwiftUI type checking.
        let lifecycle = document.id(self.session.id)
        .onAppear {
            self.documentSection = self.visibleDocumentSection
            self.refreshUndoRegistration()
        }
        .onChange(of: self.appServices.activeMeetingSummarySession?.id) { _, _ in
            self.documentSection = self.visibleDocumentSection
        }
        .onDisappear {
            self.playback.stop()
            self.correctionUndo.detach()
            self.readingProjection = nil
            self.pendingMemberSelection = nil
            self.selectedMemberAction = nil
            self.pendingEditedSegment = nil
        }
        .onChange(of: self.canRegisterUndo) { _, _ in self.refreshUndoRegistration() }
        .onChange(of: self.session.updatedAt) { _, _ in self.refreshUndoRegistration() }
        .onChange(of: self.undoManager) { _, _ in self.refreshUndoRegistration() }
        .onChange(of: self.session.id) { _, _ in
            self.playback.stop()
            self.readingProjection = nil
            self.pendingMemberSelection = nil
            self.selectedMemberAction = nil
            self.pendingEditedSegment = nil
            self.refreshUndoRegistration()
        }
        .onChange(of: self.session.profileOwnership) { _, _ in
            self.playback.stop()
            self.pendingEditedSegment = nil
            self.pendingMemberSelection = nil
            self.selectedMemberAction = nil
            self.pendingNameUnknownSegmentID = nil
            self.isShowingAssignSpeakers = false
            self.isRenamingSession = false
        }
        .onChange(of: self.session.retention.audioDeletedAt) { _, _ in self.playback.stop() }
        .onChange(of: self.isQuiescent) { _, value in if !value { self.playback.stop() } }
        .onChange(of: self.documentSection) { _, _ in self.playback.stop() }
        .onChange(of: self.showsProbableEchoes) { _, _ in self.playback.stop() }
        .onChange(of: readingInput) { _, _ in self.playback.stop() }
        .task(id: readingInput) {
            self.readingProjection = nil
            do {
                let projection = try await MeetingResultTranscriptProjection.make(for: self.session)
                try Task.checkCancellation()
                self.readingProjection = projection
            } catch is CancellationError {
                // The shared reader joins its cancelled worker. A retired result never renders
                // because both publication and the cached source stamp are checked.
            } catch {
                self.readingProjection = nil
            }
        }
        .task(id: self.copyRevision) {
            guard self.copied else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            self.copied = false
        }
        lifecycle.alert(
            "Name Unknown Speaker",
            isPresented: Binding(
                get: { self.pendingNameUnknownSegmentID != nil },
                set: { if !$0 { self.pendingNameUnknownSegmentID = nil } }
            )
        ) {
            TextField("Speaker name", text: self.$pendingUnknownSpeakerName)
            Button("Cancel", role: .cancel) { self.pendingNameUnknownSegmentID = nil }
            Button("Save") {
                if let segmentID = self.pendingNameUnknownSegmentID {
                    self.onNameUnknownSegment(segmentID, self.pendingUnknownSpeakerName)
                }
                self.pendingNameUnknownSegmentID = nil
            }
        } message: {
            Text("This name applies only to this transcript turn.")
        }
        .alert("Rename Meeting", isPresented: self.$isRenamingSession) {
            TextField("Meeting title", text: self.$pendingRenameSessionText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { self.onRenameSession(self.pendingRenameSessionText) }
        } message: {
            Text("Enter a new title for this meeting.")
        }
        .sheet(isPresented: self.$isChoosingRetranscriptionLanguage) {
            MeetingRetranscriptionLanguageSheet(
                languages: MeetingRetranscriptionLanguage.choices,
                currentLanguageCode: self.session.languageCode,
                selection: self.$retranscriptionLanguageCode,
                isBusy: self.isRetranscribing,
                onCancel: { self.isChoosingRetranscriptionLanguage = false },
                onConfirm: {
                    let languageCode = self.retranscriptionLanguageCode
                    self.isChoosingRetranscriptionLanguage = false
                    self.onRetranscribe?(languageCode)
                }
            )
        }
        // Prevents an echo toggle left on for one meeting from leaking into the next.
        .onChange(of: self.session.id) { _, _ in
            self.documentSection = Self.visibleDocumentSection(selected: .transcript, sessionID: self.session.id,
                activeSummarySessionID: self.appServices.activeMeetingSummarySession?.id)
            self.copied = false
            self.showsProbableEchoes = false
            self.isShowingAssignSpeakers = false
            self.isChoosingRetranscriptionLanguage = false
            self.pendingNameUnknownSegmentID = nil
        }
        .sheet(isPresented: self.$isShowingAssignSpeakers) {
            MeetingAssignSpeakersSheet(
                speakers: self.session.readableSpeakers,
                quotesBySpeaker: Dictionary(uniqueKeysWithValues: self.session.readableSpeakers.map {
                    ($0.id, MeetingAssignSpeakersQuoteSource.sampleQuotes(for: $0.id, in: self.session.transcriptSegments))
                }),
                tints: self.speakerTints,
                focusedSpeakerID: self.assignSpeakersFocus,
                onSave: self.onAssignSpeakers,
                onCancel: { self.isShowingAssignSpeakers = false }
            )
        }
        .sheet(item: self.$pendingMemberSelection, onDismiss: {
            let action = self.selectedMemberAction
            self.selectedMemberAction = nil
            if let action { self.selectMember(action.member, purpose: action.purpose) }
        }) { selection in
            MeetingTranscriptMemberPicker(selection: selection, onSelect: { id in
                guard let member = selection.member(id: id), self.isQuiescent else { return }
                self.selectedMemberAction = (member, selection.purpose)
                self.pendingMemberSelection = nil
            }, onCancel: { self.selectedMemberAction = nil; self.pendingMemberSelection = nil })
        }
    }

    private func transcriptParagraph(_ row: MeetingResultTranscriptProjection.Row) -> some View {
        let members = row.memberIDs
        let editing = self.pendingEditedSegment.flatMap { members.contains($0.id) ? $0 : nil }
        let speaker = self.session.activeSpeakers.first { $0.id == row.presentation.participantID }
        let audioExpanded = self.playback.activeSegmentID == row.id
        return MeetingTranscriptSegmentRow(
            paragraph: row.paragraph,
            speakerName: MeetingTranscriptExporter.captionLabel(for: row.presentation,
                language: PichiInterfaceLanguage(rawValue: self.locale.identifier) ?? PichiLocalization.language) ?? "",
            showsSpeakerLabel: row.paragraph.showsSpeakerLabel && row.presentation.hasReadableParticipant,
            isUnknownSpeaker: row.presentation.participantID == nil,
            speakerTint: row.presentation.participantID.flatMap { self.speakerTints[$0] },
            onRenameSpeakerTapped: {
                if let speaker { self.presentAssignSpeakers(focusing: speaker.id) }
                else { self.beginMemberAction(.nameSpeaker, paragraph: row.paragraph) }
            },
            onNameUnknown: { self.beginMemberAction(.nameSpeaker, paragraph: row.paragraph) },
            reassignTargets: self.session.activeSpeakers.filter { $0.id != row.presentation.participantID },
            isQuiescent: self.isQuiescent,
            onReassign: { speakerID in self.onReassignSegments(members, speakerID) },
            canPlayAudio: self.session.retention.audioDeletedAt == nil && self.session.hasFinalizedAudio && self.isQuiescent,
            isAudioExpanded: audioExpanded, playback: self.playback,
            isLoadingAudio: audioExpanded && self.playback.isLoading,
            onPlayAudio: { self.playback.toggle(session: self.session, segmentIDs: members) },
            editingSegment: editing,
            onEditText: { self.beginMemberAction(.editText, paragraph: row.paragraph) },
            onSaveText: { text in
                guard let editing, self.pendingEditedSegment?.id == editing.id else {
                    return PichiLocalization.text("This paragraph is no longer being edited.")
                }
                let error = await self.onEditTranscriptSegment(editing.id, text, editing.revision)
                if error == nil, self.pendingEditedSegment?.id == editing.id { self.pendingEditedSegment = nil }
                return error
            },
            onCancelEditText: { self.pendingEditedSegment = nil }
        )
        .accessibilityIdentifier("transcript.paragraph.\(row.id.uuidString)")
    }

    /// Actions sit beside the title so the header has no empty corner above the tabs.
    private func documentHeader(hasText: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: self.theme.metrics.spacing.lg) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                MeetingDocumentTitle(title: self.session.displayTitle)
                    .editableTitle(
                        self.session.displayTitle,
                        id: "\(self.session.profileOwnership?.profileID ?? MeetingProfileOwnership.guest.profileID):\(self.session.id)",
                        enabled: self.isQuiescent,
                        editorFont: .fluidSystem(.largeTitle, design: .serif).weight(.medium),
                        onRename: self.onRenameSession
                    )
                self.meetingMetadata
                if self.session.state != .completed { self.documentStatus }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            FluidGlassControlGroup {
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    self.transcriptActions(hasText: hasText)
                }
            }
            .fixedSize()
        }
    }

    private var documentStatus: some View {
        Label(self.statusText, systemImage: self.statusIcon)
            .font(self.theme.typography.caption)
            .foregroundStyle(self.statusColor)
            .fixedSize()
    }

    /// Diarization stays dependable up to this many voices; beyond it, speakers merge or split.
    static let reliableSpeakerLimit = 8

    /// Uses the same count as the history row, so both places describe the same number.
    static func speakerAccuracyNote(speakerCount: Int) -> String? {
        guard speakerCount > 0 else { return nil }
        guard speakerCount > self.reliableSpeakerLimit else {
            return PichiLocalization.text("Speaker labels are automatic. Name speakers above; double-click a paragraph to edit its text.")
        }
        return PichiLocalization.format("%lld speakers found. Above %lld, labels are less reliable: one person may show up twice, or two people as one.", speakerCount, self.reliableSpeakerLimit)
    }

    private func speakerAccuracyNoteView(_ note: String, speakerCount: Int) -> some View {
        Label {
            Text(note).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: speakerCount > Self.reliableSpeakerLimit ? "exclamationmark.circle" : "info.circle")
        }
        .font(self.theme.typography.caption)
        .foregroundStyle(self.theme.palette.tertiaryText)
        .accessibilityElement(children: .combine)
    }

    private func speakerStrip(_ speakers: [MeetingSessionSpeaker]) -> some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                Text("Speakers")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.tertiaryText)
                Spacer(minLength: 0)
                Button("Edit speakers", systemImage: "pencil") {
                    self.presentAssignSpeakers(focusing: nil)
                }
                .fluidGlassAction()
                .disabled(!self.isQuiescent)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: self.theme.metrics.spacing.lg) {
                    ForEach(speakers) { speaker in
                        MeetingSpeakerChip(
                            title: self.displayName(for: speaker),
                            systemImage: speaker.isLocalUser
                                ? "person.crop.circle.badge.checkmark" : "person.crop.circle",
                            tint: self.chipTint(for: speaker) ?? self.theme.palette.primaryText,
                            action: { self.presentAssignSpeakers(focusing: speaker.id) }
                        )
                        .disabled(!self.isQuiescent)
                        .contextMenu {
                            if let onSetLocalUserSpeaker = self.onSetLocalUserSpeaker {
                                Button(PichiLocalization.text(speaker.isLocalUser ? "Remove You designation" : "Mark as You"),
                                       systemImage: speaker.isLocalUser ? "person.crop.circle.badge.minus" : "person.crop.circle.badge.checkmark") {
                                    onSetLocalUserSpeaker(speaker.isLocalUser ? nil : speaker.id)
                                }
                                .disabled(!self.isQuiescent)
                                .help(PichiLocalization.text("The You label applies only to this meeting."))
                            }
                        }
                    }
                }
                .padding(.vertical, self.theme.metrics.spacing.xs)
            }
        }
    }

    @ViewBuilder private func transcriptActions(hasText: Bool) -> some View {
        Button {
            self.onCopyTranscript(self.session, self.showsProbableEchoes)
            self.copied = true
            self.copyRevision += 1
        } label: {
            MeetingDocumentActionLabel(title: self.copied ? PichiLocalization.text("Copied") : PichiLocalization.text("Copy"), symbol: self.copied ? "checkmark" : "doc.on.doc")
        }
        .meetingGlassAction()
        .disabled(!hasText || self.documentSection != .transcript)
        .help("Copy transcript")
        .accessibilityLabel(self.copied ? PichiLocalization.text("Transcript copied") : PichiLocalization.text("Copy transcript"))
        Menu {
            Menu("Export", systemImage: "square.and.arrow.up") {
                Button("Text…") { self.onExportTranscript(self.session, .text, self.showsProbableEchoes) }
                Button("Markdown…") { self.onExportTranscript(self.session, .markdown, self.showsProbableEchoes) }
                Button("JSON…") { self.onExportTranscript(self.session, .json, self.showsProbableEchoes) }
            }
            .disabled(!hasText || self.documentSection != .transcript)
            Divider()
            self.renameMeetingAction
            Button("Redo transcript…", systemImage: "arrow.clockwise") {
                self.retranscriptionLanguageCode = self.session.languageCode
                self.isChoosingRetranscriptionLanguage = true
            }
            .disabled(self.onRetranscribe == nil || !self.isQuiescent || !self.session.hasRetryableAudio || self.isRetranscribing)
            Button("Undo correction", systemImage: "arrow.uturn.backward") { Task { _ = await self.onUndo() } }
                .disabled(!self.canUndo || !self.isQuiescent)
            if self.hasEchoSegments {
                Divider()
                Toggle("Show probable echo", isOn: self.$showsProbableEchoes)
            }
            if let onOpenIntegrations {
                Divider()
                Button("Integrations…", systemImage: "link", action: onOpenIntegrations)
            }
            if let onClose {
                Divider()
                Button("Close transcript", systemImage: "xmark", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        } label: {
            MeetingDocumentActionLabel(title: PichiLocalization.text("More"), disclosure: true)
        }
        .fluidGlassMenuAction()
        .meetingHoverFeedback()
        .help("More transcript actions")
        .accessibilityLabel("More transcript actions")
    }

    private var renameMeetingAction: some View {
        Button("Rename meeting…", systemImage: "pencil") {
            self.pendingRenameSessionText = self.session.displayTitle
            self.isRenamingSession = true
        }
        .disabled(!self.isQuiescent)
    }

    private var canRegisterUndo: Bool {
        self.canUndo && self.isQuiescent && self.documentSection == .transcript
            && self.pendingEditedSegment == nil
            && self.pendingNameUnknownSegmentID == nil && !self.isRenamingSession
            && !self.isShowingAssignSpeakers && !self.isChoosingRetranscriptionLanguage
    }

    private func refreshUndoRegistration() {
        self.correctionUndo.refresh(
            manager: self.undoManager,
            sessionID: self.session.id,
            isEnabled: self.canRegisterUndo,
            action: self.onUndo
        )
    }

    private func displayName(for speaker: MeetingSessionSpeaker) -> String {
        MeetingTranscriptExporter.speakerDisplayName(speaker, language: PichiLocalization.language)
    }

    private var meetingMetadata: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            HStack(spacing: self.theme.metrics.spacing.md) {
                Text(self.session.startedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(PichiLocalization.locale)))
                    .accessibilityIdentifier("meeting.metadata.start")
                    .fixedSize()
                    .help(self.session.startedAt.formatted(Date.FormatStyle(date: .complete, time: .shortened).locale(PichiLocalization.locale)))
                Text("·").accessibilityHidden(true)
                Label(Self.durationText(self.session.duration), systemImage: "clock")
                    .fixedSize()
                Text("·").accessibilityHidden(true)
                Label { Text(verbatim: self.sourceName) } icon: {
                    Image(systemName: self.session.mode == .onlineCall ? "macwindow" : "person.2")
                }
                    .lineLimit(1)
                    .help(self.sourceName + "\n" + PichiLocalization.format("microphone: %@", self.session.selectedMicrophone.displayName))
                Text("·").accessibilityHidden(true)
                Label(self.transcriptLanguageName, systemImage: "globe")
                    .lineLimit(1)
                    .help("Transcript language")
            }
            .font(self.theme.typography.caption)
            .foregroundStyle(self.theme.palette.secondaryText)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(self.session.startedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(PichiLocalization.locale))), " +
                    "\(Self.durationText(self.session.duration)), \(self.sourceName), " +
                    PichiLocalization.format("microphone: %@", self.session.selectedMicrophone.displayName) + ", " +
                    PichiLocalization.format("language: %@", self.transcriptLanguageName)
            )
            if let place = self.session.savedLocationLabel(language: PichiLocalization.language) {
                Text(verbatim: place)
                    .accessibilityLabel(place)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(place)
                    .accessibilityIdentifier("meeting.metadata.location")
            }
        }
    }

    private var transcriptLanguageName: String {
        PichiLocalization.locale.localizedString(forIdentifier: self.session.languageCode) ?? MeetingRetranscriptionLanguage.displayName(for: self.session.languageCode)
    }

    private var sourceName: String {
        self.session.capturedApplication?.displayName ?? PichiLocalization.text(self.session.audioSourceDisplayName)
    }

    private var emptyTranscriptDescription: String {
        if self.hasEchoSegments, !self.showsProbableEchoes {
            return PichiLocalization.text("All transcript turns are marked as probable echo. Choose Show probable echo from the More menu to view them.")
        }
        if self.session.retention.audioDeletedAt != nil {
            return PichiLocalization.text("No transcript text is available. The captured audio has been deleted.")
        }
        if self.session.hasRetryableAudio {
            return PichiLocalization.text("No transcript text is available. The captured audio is saved on this Mac.")
        }
        if self.session.hasFinalizedAudio {
            return PichiLocalization.text("No transcript text is available. Some captured audio is saved on this Mac.")
        }
        return PichiLocalization.text("There is no transcript text or saved audio available for this meeting.")
    }

    private var statusText: String {
        switch self.session.state {
        case .completed: PichiLocalization.text("Completed")
        case .failed: PichiLocalization.text("Failed")
        case .interrupted: PichiLocalization.text("Interrupted")
        case .processing: PichiLocalization.text("Processing")
        case .recording, .recordingDegraded, .preparing, .stopping: PichiLocalization.text("Recording")
        }
    }

    private var statusIcon: String {
        switch self.session.state {
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .interrupted: "exclamationmark.circle.fill"
        case .processing: "ellipsis.circle.fill"
        case .recording, .recordingDegraded, .preparing, .stopping: "record.circle.fill"
        }
    }

    private var statusColor: Color {
        switch self.session.state {
        case .completed: self.theme.palette.success
        case .failed: Color(nsColor: .systemRed)
        case .interrupted: self.theme.palette.warning
        case .processing: self.theme.palette.accent
        case .recording, .recordingDegraded, .preparing, .stopping: self.theme.palette.warning
        }
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct MeetingFailureCanvas: View {
    let session: MeetingSession?
    let message: String
    let isRetrying: Bool
    let onRetrySession: (MeetingSession) -> Void
    var onRestartSession: ((MeetingSession) -> Void)? = nil
    let onRevealAudio: (MeetingSession) -> Void
    let onRecordAgain: (MeetingSession) -> Void
    let onClose: (() -> Void)?

    @Environment(\.theme) private var theme

    private var hasRecoverableAudio: Bool {
        self.session?.hasRetryableAudio == true
    }

    var canRestartProcessing: Bool {
        self.hasRecoverableAudio && self.session?.audioStorageMode == .retainedFiles && self.onRestartSession != nil
    }

    func restartProcessing() {
        guard self.canRestartProcessing, !self.isRetrying, let session else { return }
        self.onRestartSession?(session)
    }

    private var title: String {
        guard let session else { return PichiLocalization.text("Meeting setup failed") }
        let lastFailureDomain = session.failures.last?.domain
        if lastFailureDomain == .processing ||
            (session.state == .interrupted && !session.processingAttempts.isEmpty)
        {
            return session.state == .interrupted
                ? PichiLocalization.text("Meeting transcription was interrupted")
                : PichiLocalization.text("Meeting transcription failed")
        }
        if self.hasRecoverableAudio {
            return session.state == .interrupted
                ? PichiLocalization.text("Meeting recording was interrupted")
                : PichiLocalization.text("Meeting recording failed")
        }
        return PichiLocalization.text("Meeting setup failed")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
            HStack(spacing: self.theme.metrics.spacing.lg) {
                Label(self.title, systemImage: "exclamationmark.circle")
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(self.theme.palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let onClose {
                    FluidGlassControlGroup {
                        MeetingCloseTranscriptButton(action: onClose)
                    }
                }
            }
            MeetingDocumentTitle(title: self.session?.displayTitle ?? PichiLocalization.text("Recording setup"))
            Divider()
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
                Text(PichiLocalization.text(self.message))
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.primaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if self.hasRecoverableAudio {
                    Label {
                        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                            Text("Your captured audio is preserved")
                                .font(self.theme.typography.bodyStrong)
                            Text("Retry transcription, or open the audio files on this Mac.")
                                .font(self.theme.typography.caption)
                                .foregroundStyle(self.theme.palette.secondaryText)
                        }
                    } icon: {
                        Image(systemName: "checkmark.shield")
                            .foregroundStyle(self.theme.palette.success)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    if self.canRestartProcessing {
                        Text(PichiLocalization.text("Retry continues from the last saved step. Starting again discards processing progress and keeps your audio."))
                            .font(self.theme.typography.caption)
                            .foregroundStyle(self.theme.palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            FluidGlassControlGroup {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: self.theme.metrics.spacing.sm) { self.recoveryActions }
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) { self.recoveryActions }
                }
            }
        }
    }

    @ViewBuilder
    private var recoveryActions: some View {
        if let session, self.hasRecoverableAudio {
            Button(action: { self.onRetrySession(session) }) {
                if self.isRetrying {
                    HStack(spacing: self.theme.metrics.spacing.sm) {
                        ProgressView().controlSize(.small)
                        Text("Retrying…")
                    }
                } else {
                    Label("Retry transcription", systemImage: "arrow.clockwise")
                }
            }
            .meetingGlassAction(prominent: true)
            .disabled(self.isRetrying)
            if self.canRestartProcessing {
                Button(PichiLocalization.text("Start processing again"), systemImage: "arrow.counterclockwise", action: self.restartProcessing)
                    .meetingGlassAction()
                    .disabled(self.isRetrying)
                    .accessibilityIdentifier("meeting.restartProcessing")
            }
            Button("Show audio", systemImage: "folder", action: { self.onRevealAudio(session) })
                .meetingGlassAction()
        }
        if let session {
            Button("Record again", systemImage: "arrow.counterclockwise.circle") {
                self.onRecordAgain(session)
            }
            .meetingGlassAction(prominent: !self.hasRecoverableAudio)
            .disabled(self.isRetrying)
        }
    }
}

private struct MeetingAudioTranscriptNotice: View {
    let text: String
    var detail: String? = nil
    var isSubtle = false
    var visibleDetail: String? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
            Label(PichiLocalization.text(self.text), systemImage: self.isSubtle ? "info.circle" : "exclamationmark.triangle")
                .foregroundStyle(self.isSubtle ? self.theme.palette.secondaryText : self.theme.palette.warning)
            if let visibleDetail {
                Text(visibleDetail).foregroundStyle(self.theme.palette.secondaryText)
            }
        }
        .font(self.theme.typography.caption)
        .fixedSize(horizontal: false, vertical: true)
        .help(PichiLocalization.text(self.detail ?? self.text))
    }
}

private struct MeetingTrackHealthRow: View {
    let title: String
    let systemImage: String
    let health: MeetingTrackHealth
    var microphoneMuteState: MeetingMicrophoneMuteState = .notApplicable
    var onToggleMicrophone: (() -> Void)? = nil

    @Environment(\.theme) private var theme
    @Environment(\.locale) private var locale

    private var language: PichiInterfaceLanguage { PichiInterfaceLanguage(rawValue: self.locale.identifier) ?? PichiLocalization.language }
    private var mutePresentation: MeetingMicrophoneMutePresentation { .init(state: self.microphoneMuteState) }
    private var statusText: String {
        self.mutePresentation.blocksMicrophone
            ? self.mutePresentation.title(language: self.language)
            : self.health.localizedStatusText(language: self.language)
    }
    private var helpText: String {
        guard self.mutePresentation.isMonitored else { return "\(self.title): \(self.statusText)" }
        let detail = self.mutePresentation.detail(language: self.language)
        return self.mutePresentation.blocksMicrophone ? detail : detail + "\n" + self.statusText
    }

    private var statusColor: Color {
        if self.mutePresentation.blocksMicrophone { return self.theme.palette.readableText(Color(nsColor: .systemRed)) }
        return switch self.health.status {
        case .healthy: self.theme.palette.success
        case .degraded, .unavailable: self.theme.palette.warning
        case .waiting, .stopped: self.theme.palette.secondaryText
        }
    }

    private var statusIcon: String {
        if self.mutePresentation.blocksMicrophone { return "lock.circle.fill" }
        return switch self.health.status {
        case .healthy: "checkmark.circle.fill"
        case .degraded, .unavailable: "exclamationmark.circle.fill"
        case .waiting: "ellipsis.circle"
        case .stopped: "stop.circle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                Label {
                    Text(self.title)
                } icon: {
                    if self.mutePresentation.isMonitored {
                        MeetingMicrophoneMuteIndicator(state: self.microphoneMuteState, onToggle: self.onToggleMicrophone)
                    } else {
                        Image(systemName: self.systemImage)
                    }
                }
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize()
                ProgressView(value: self.mutePresentation.blocksMicrophone ? 0 : min(max(Double(self.health.level), 0), 1))
                    .progressViewStyle(.linear)
                    .frame(width: 44)
                    .accessibilityLabel("\(self.title) level")
                Image(systemName: self.statusIcon)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.statusColor)
                    .accessibilityLabel(self.statusText)
            }
            if !self.mutePresentation.blocksMicrophone, self.health.status == .degraded || self.health.status == .unavailable {
                Text(self.statusText)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.warning)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(self.helpText)
    }
}

extension MeetingTrackHealth {
    /// Fixed capture warnings are UI resources. Unstructured writer errors remain diagnostics.
    /// Rendering never rewrites the English detail retained in the session manifest.
    func localizedStatusText(language: PichiInterfaceLanguage, bundle: Bundle = .main) -> String {
        switch self.status {
        case .waiting: return PichiLocalization.text("Waiting for audio", language: language, bundle: bundle)
        case .healthy: return PichiLocalization.text("Receiving audio", language: language, bundle: bundle)
        case .stopped: return PichiLocalization.text("Stopped", language: language, bundle: bundle)
        case .degraded, .unavailable:
            guard let detail = self.detail else {
                return self.status == .degraded
                    ? PichiLocalization.text("Audio source degraded", language: language, bundle: bundle)
                    : PichiLocalization.text("Audio source unavailable", language: language, bundle: bundle)
            }
            switch detail {
            case "No meeting audio is being captured while your microphone is active.":
                return PichiLocalization.text("No meeting audio is being captured while your microphone is active.", language: language, bundle: bundle)
            case "Capture delivered an invalid audio sample.":
                return PichiLocalization.text("Capture delivered an invalid audio sample.", language: language, bundle: bundle)
            case "Capture delivered audio without a valid presentation timestamp.":
                return PichiLocalization.text("Capture delivered audio without a valid presentation timestamp.", language: language, bundle: bundle)
            case "Capture delivered audio from a retired producer epoch.":
                return PichiLocalization.text("Capture delivered audio from a retired producer epoch.", language: language, bundle: bundle)
            case "Capture audio could not be normalized onto the meeting timeline.":
                return PichiLocalization.text("Capture audio could not be normalized onto the meeting timeline.", language: language, bundle: bundle)
            case "Audio chunk timing was not monotonic.":
                return PichiLocalization.text("Audio chunk timing was not monotonic.", language: language, bundle: bundle)
            default:
                return detail
            }
        }
    }
}

private struct MeetingSpeakerChip: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    @Environment(\.theme) private var theme
    var body: some View {
        Button(action: self.action) {
            HStack(spacing: self.theme.metrics.spacing.xs) {
                Label(self.title, systemImage: self.systemImage)
                Image(systemName: "chevron.right")
                    .font(.fluidSystem(size: 9, weight: .semibold))
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            .font(self.theme.typography.captionStrong)
            .foregroundStyle(self.tint)
        }
        .buttonStyle(.borderless)
        .meetingHoverFeedback()
        .help("Edit speaker names")
        .accessibilityLabel("Edit speaker name: \(self.title)")
    }
}

private struct MeetingTranscriptSegmentRow: View {
    let paragraph: MeetingTranscriptExporter.DisplayParagraph
    let speakerName: String
    let showsSpeakerLabel: Bool
    let isUnknownSpeaker: Bool
    let speakerTint: Color?
    let onRenameSpeakerTapped: (() -> Void)?
    let onNameUnknown: () -> Void
    let reassignTargets: [MeetingSessionSpeaker]
    let isQuiescent: Bool
    let onReassign: (SessionSpeakerID) -> Void
    let canPlayAudio: Bool
    let isAudioExpanded: Bool
    let playback: MeetingSegmentPlayback
    let isLoadingAudio: Bool
    let onPlayAudio: () -> Void
    let editingSegment: MeetingTranscriptSegment?
    let onEditText: () -> Void
    let onSaveText: (String) async -> String?
    let onCancelEditText: () -> Void

    @Environment(\.theme) private var theme

    private var segment: MeetingTranscriptSegment { self.paragraph.firstSegment }
    private var isEditingText: Bool { self.editingSegment != nil }

    var body: some View {
        HStack(alignment: .top, spacing: self.theme.metrics.spacing.lg) {
            Text(MeetingTranscriptExporter.timestampText(self.segment.start.seconds))
                .font(self.theme.typography.codeCaption)
                .foregroundStyle(self.theme.palette.secondaryText)
                .frame(width: 58, alignment: .leading)
                .frame(height: 28)
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    if self.showsSpeakerLabel { self.speakerLabel }
                    Spacer(minLength: self.theme.metrics.spacing.md)
                    Button(PichiLocalization.text("action.edit", defaultValue: "Edit"), systemImage: "pencil") { self.beginEditing() }
                        .fluidGlassAction()
                        .disabled(!self.isQuiescent || self.isEditingText)
                        .help("Edit text, or double-click this paragraph")
                    if self.isUnknownSpeaker {
                        Menu {
                            ForEach(self.reassignTargets) { target in
                                Button(target.displayName) {
                                    self.playback.stop()
                                    self.onReassign(target.id)
                                }
                            }
                            Divider()
                            Button("New speaker…", action: self.onNameUnknown)
                        } label: {
                            Label("Assign speaker", systemImage: "tag")
                        }
                        .fluidGlassAction()
                        .disabled(!self.isQuiescent || self.isEditingText)
                        .help("Tag this unknown paragraph with a speaker")
                        .accessibilityLabel("Assign speaker to unknown paragraph")
                    }
                    Button {
                        if self.isAudioExpanded { self.playback.stop() } else { self.onPlayAudio() }
                    } label: {
                        Label(self.isAudioExpanded ? PichiLocalization.text("Close") : PichiLocalization.text("Audio"), systemImage: self.isAudioExpanded ? "xmark" : "play.fill")
                            .frame(minWidth: 54)
                    }
                    .fluidGlassAction()
                    .disabled(!self.canPlayAudio && !self.isAudioExpanded)
                    .help(self.isAudioExpanded ? PichiLocalization.text("Close audio player") : (self.canPlayAudio ? PichiLocalization.text("Play this speaker chunk") : PichiLocalization.text("Audio unavailable")))
                    .accessibilityLabel(self.isAudioExpanded ? PichiLocalization.text("Close audio player") : PichiLocalization.format("Play audio chunk for %@", self.speakerName))
                }
                .frame(minHeight: 28)
                if let editing = self.editingSegment {
                    MeetingTranscriptTextEditor(
                        text: editing.text,
                        onSave: self.onSaveText,
                        onCancel: self.onCancelEditText
                    )
                    .id(editing.id)
                } else {
                    Text(self.paragraph.text)
                        .font(self.theme.typography.body)
                        .foregroundStyle(self.theme.palette.primaryText)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture(count: 2).onEnded { self.beginEditing() })
                        .accessibilityAction(named: Text("Edit text")) { self.beginEditing() }
                }
                if self.segment.isEcho {
                    Text("Probable echo").font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
                }
                if self.isAudioExpanded {
                    MeetingSegmentAudioPlayer(playback: self.playback, isLoading: self.isLoadingAudio)
                        .frame(maxWidth: 360)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .contextMenu {
            Button("Edit text", systemImage: "pencil") { self.beginEditing() }
                .disabled(!self.isQuiescent || self.isEditingText)
            if let onRenameSpeakerTapped = self.onRenameSpeakerTapped {
                Button("Rename Speaker", systemImage: "person.crop.circle", action: onRenameSpeakerTapped)
                    .disabled(!self.isQuiescent)
            }
            Menu(PichiLocalization.text("Reassign to")) {
                ForEach(self.reassignTargets) { target in
                    Button(MeetingTranscriptExporter.speakerDisplayName(target, language: PichiLocalization.language)) {
                        self.playback.stop()
                        self.onReassign(target.id)
                    }
                    .disabled(!self.isQuiescent)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(MeetingTranscriptExporter.timestampText(self.segment.start.seconds)), \(self.speakerName), \(self.paragraph.text)"
        )
    }

    private func beginEditing() {
        guard self.isQuiescent else { return }
        self.playback.stop()
        self.onEditText()
    }

    private var speakerLabel: some View {
        let name = Text(self.speakerName)
            .foregroundColor(self.nameColor)
            .fontWeight(.semibold)
            .font(self.theme.typography.bodySmallStrong)

        return HStack(spacing: 8) {
            if let onRenameSpeakerTapped = self.onRenameSpeakerTapped {
                Button(action: onRenameSpeakerTapped) {
                    HStack(spacing: 3) {
                        name
                        // Always shown, not hover-only, so the affordance survives an unfocused window.
                        Image(systemName: "chevron.right")
                            .font(.fluidSystem(size: 10, weight: .semibold))
                            .foregroundStyle(self.theme.palette.secondaryText)
                    }
                }
                .buttonStyle(.plain)
                .meetingHoverFeedback(cornerRadius: self.theme.metrics.corners.sm)
                .disabled(!self.isQuiescent)
                // No .help here: the tooltip lands on top of the turn's first line of text.
                .accessibilityLabel("Rename \(self.speakerName)")
                .pointerStyle(.link)
            } else {
                name
            }
        }
    }

    private var nameColor: Color {
        self.speakerTint ?? self.theme.palette.secondaryText
    }
}

private struct MeetingTranscriptMemberPicker: View {
    let selection: MeetingTranscriptMemberSelection
    let onSelect: (MeetingTranscriptSegmentID) -> Void
    let onCancel: () -> Void
    @Environment(\.theme) private var theme
    @State private var query = ""

    private var title: String {
        switch self.selection.purpose {
        case .editText: PichiLocalization.text("Choose text to edit")
        case .nameSpeaker: PichiLocalization.text("Choose a fragment to name")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
            Text(self.title).font(self.theme.typography.bodyStrong)
                .foregroundStyle(self.theme.palette.primaryText)
            TextField(PichiLocalization.text("Search transcript text"), text: self.$query)
                .textFieldStyle(.roundedBorder)
                .font(self.theme.typography.body)
                .accessibilityIdentifier("transcript.memberSearch")
            List(self.selection.members(matching: self.query)) { member in
                Button {
                    self.onSelect(member.id)
                } label: {
                    HStack(alignment: .top, spacing: self.theme.metrics.spacing.md) {
                        Text(MeetingTranscriptExporter.timestampText(member.start.seconds))
                            .font(self.theme.typography.codeCaption)
                            .foregroundStyle(self.theme.palette.secondaryText)
                        Text(member.text).font(self.theme.typography.body)
                            .foregroundStyle(self.theme.palette.primaryText)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, self.theme.metrics.spacing.xs)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("transcript.member.\(member.id.uuidString)")
            }
            .listStyle(.plain)
            HStack {
                Spacer()
                Button(PichiLocalization.text("Cancel"), role: .cancel, action: self.onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(self.theme.metrics.spacing.xl)
        .frame(minWidth: 460, idealWidth: 560, minHeight: 340, idealHeight: 480)
        .background(self.theme.palette.windowBackground)
        .accessibilityIdentifier("transcript.memberPicker")
    }
}

/// Inline member editing: no recording/model work. Keep the draft on save
/// failure; the caller holds the starting segment revision for stale-edit protection.
struct MeetingTranscriptTextEditor: View {
    let onSave: (String) async -> String?
    let onCancel: () -> Void
    @Environment(\.theme) private var theme
    @State private var text: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    init(text: String, onSave: @escaping (String) async -> String?, onCancel: @escaping () -> Void) {
        self._text = State(initialValue: text)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            TextField("Transcript text", text: self.$text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(self.theme.typography.body)
                .foregroundStyle(self.theme.palette.primaryText)
                .lineSpacing(5)
                .lineLimit(1...20)
                .padding(self.theme.metrics.spacing.sm)
                .background(self.theme.palette.cardBackground, in: RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm))
                .overlay {
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm)
                        .strokeBorder(self.theme.palette.accent.opacity(0.45), lineWidth: 1)
                }
                .focused(self.$isFocused)
                .disabled(self.isSaving)
                .accessibilityLabel("Edit transcript paragraph")
                .onSubmit { self.save() }
                .onKeyPress(.return) {
                    self.save()
                    return .handled
                }
                .onExitCommand { if !self.isSaving { self.onCancel() } }
                .task {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    self.isFocused = true
                }
            if let errorMessage {
                Text(PichiLocalization.text(errorMessage))
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.warning)
            }
            HStack(spacing: self.theme.metrics.spacing.sm) {
                Text("Enter to save · Escape to cancel")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                Spacer(minLength: 0)
                FluidGlassControlGroup {
                    HStack(spacing: self.theme.metrics.spacing.sm) {
                        Button("Cancel", action: self.onCancel)
                            .fluidGlassAction()
                            .disabled(self.isSaving)
                        Button(self.isSaving ? PichiLocalization.text("Saving…") : PichiLocalization.text("Save"), action: self.save)
                            .fluidGlassAction(prominent: true)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(self.isSaving || self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appTheme(self.theme)
    }

    private func save() {
        guard !self.isSaving, !self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        self.isSaving = true
        Task { @MainActor in
            self.errorMessage = await self.onSave(self.text)
            self.isSaving = false
            if self.errorMessage != nil { self.isFocused = true }
        }
    }
}

private struct MeetingRetranscriptionLanguageSheet: View {
    let languages: [VoiceEngineLanguage]
    let currentLanguageCode: String
    @Binding var selection: String
    let isBusy: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            Text("Redo transcript")
                .font(self.theme.typography.title)
            Text("Transcribe saved audio again with your latest saved replacements. Keep the current language or choose another. This replaces the transcript.")
                .font(self.theme.typography.body)
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Menu {
                Picker("Language", selection: self.$selection) {
                    ForEach(self.languages) { language in
                        Text(language.localizedDisplayName(locale: PichiLocalization.locale)).tag(language.id)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text(PichiLocalization.locale.localizedString(forIdentifier: self.selection) ?? MeetingRetranscriptionLanguage.displayName(for: self.selection))
            }
            .fluidDropdownStyle(fillsWidth: true)
            .accessibilityLabel("Transcript language")
            .disabled(self.isBusy || self.languages.isEmpty)
            HStack {
                Button("Cancel", action: self.onCancel)
                    .meetingGlassAction()
                    .keyboardShortcut(.cancelAction)
                    .disabled(self.isBusy)
                Spacer()
                Button(PichiLocalization.text(self.isBusy ? "Transcribing…" : "Transcribe"), action: self.onConfirm)
                    .meetingGlassAction(prominent: true)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        self.isBusy || !MeetingRetranscriptionLanguage.canRetranscribe(
                            selection: self.selection,
                            currentLanguageCode: self.currentLanguageCode,
                            allowsSameLanguage: true
                        )
                    )
            }
        }
        .padding(self.theme.metrics.spacing.xl)
        .frame(width: 460)
        .background(self.theme.palette.windowBackground)
        .interactiveDismissDisabled(self.isBusy)
    }
}

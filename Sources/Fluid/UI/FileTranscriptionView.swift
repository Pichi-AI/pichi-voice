import SwiftUI
import UniformTypeIdentifiers

enum FileTranscriptionSearchReveal {
    static func transcriptID(_ target: AppSearchHit.Target?) -> UUID? {
        guard case let .transcript(id) = target else { return nil }
        return id
    }
}

struct FileTranscriptionView: View {
    @ObservedObject var asrService: ASRService
    @ObservedObject private var transcriptionService: FileTranscriptionService
    @ObservedObject private var fileHistoryStore = FileTranscriptionHistoryStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @Binding private var revealTarget: AppSearchHit.Target?
    @State private var selectedFileURL: URL?
    @Environment(\.theme) private var theme
    @Environment(\.locale) private var interfaceLocale

    init(asrService: ASRService, transcriptionService: FileTranscriptionService, revealTarget: Binding<AppSearchHit.Target?> = .constant(nil)) {
        self._revealTarget = revealTarget
        self.asrService = asrService
        _transcriptionService = ObservedObject(wrappedValue: transcriptionService)
    }

    @State private var showingFilePicker = false
    @State private var showingExportDialog = false
    @State private var exportDocument: TranscriptionDocument?
    @State private var showingCopyConfirmation = false
    @State private var isDropTargeted = false
    @State private var dropErrorMessage: String?
    @State private var searchQuery = ""
    @State private var transcriptListWidth: CGFloat = 320
    @State private var splitterDragStart: CGFloat?
    @State private var isSplitterHovered = false
    @State private var pendingDeleteEntry: FileTranscriptionEntry?
    @State private var showingClearConfirmation = false

    private struct RowMetadata {
        let preview: String
        let fullDate: String
    }

    @State private var rowMetadata: [UUID: RowMetadata] = [:]
    @State private var filteredEntries: [FileTranscriptionEntry] = []
    // Only an explicit global-search reveal may move the library viewport.
    @State private var pendingRevealID: UUID?

    private func updateSearchResults(entries: [FileTranscriptionEntry]) {
        let query = self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        self.filteredEntries = query.isEmpty ? entries : entries.filter {
            $0.displayTitle.localizedStandardContains(query) || $0.fileName.localizedStandardContains(query) || $0.text.localizedStandardContains(query)
        }
    }

    private var selectedEntry: FileTranscriptionEntry? {
        let entries = self.filteredEntries
        return entries.first { $0.id == self.fileHistoryStore.selectedEntryID } ?? entries.first
    }

    nonisolated enum ExportFormat: String, CaseIterable, Sendable {
        case text = "Text (.txt)"
        case json = "JSON (.json)"

        var fileExtension: String {
            switch self {
            case .text: return "txt"
            case .json: return "json"
            }
        }
    }

    private var selectedFileIsVideo: Bool {
        guard let fileExtension = (self.selectedFileURL ?? self.transcriptionService.currentFileURL)?
            .pathExtension.lowercased()
        else { return false }
        return UTType(filenameExtension: fileExtension)?.conforms(to: .movie) ?? false
    }

    private var conflictingActivity: ASRExclusiveActivity? {
        guard let activity = self.asrService.activeExclusiveActivity,
              activity != .fileTranscription
        else {
            return nil
        }
        return activity
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: self.theme.metrics.spacing.sm) {
                if let activity = self.conflictingActivity {
                    self.activityConflictCard(activity: activity)
                }
                self.fileSelectionCard
                if self.transcriptionService.isTranscribing {
                    self.progressCard
                }
                if let error = self.transcriptionService.error {
                    self.errorCard(error: error)
                }
                if let message = self.dropErrorMessage {
                    self.dropErrorCard(message: message)
                }
            }
            .padding(FluidPageLayout.inset)

            Divider()
            self.transcriptBrowser
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(self.theme.palette.contentBackground)
        .overlay(alignment: .topTrailing) {
            if self.showingCopyConfirmation {
                Text("Copied!")
                    .font(self.theme.typography.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(self.theme.palette.accent)
                    .foregroundStyle(self.theme.palette.accentForeground)
                    .cornerRadius(8)
                    .padding()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .fileExporter(
            isPresented: self.$showingExportDialog,
            document: self.exportDocument,
            contentType: self.exportDocument?.format == .json ? .json : .plainText,
            defaultFilename: self.exportDocument?.defaultFilename
        ) { exportCompletion in
            switch exportCompletion {
            case .success:
                DebugLogger.shared.info("File exported successfully", source: "FileTranscriptionView")
            case let .failure(error):
                DebugLogger.shared.error("Export failed: \(error)", source: "FileTranscriptionView")
            }
            self.exportDocument = nil
        }
        .onReceive(self.fileHistoryStore.$entries) { entries in
            self.rowMetadata = Dictionary(entries.map { entry in
                (entry.id, self.metadata(for: entry))
            }, uniquingKeysWith: { _, latest in latest })
            self.updateSearchResults(entries: entries)
        }
        .task(id: self.revealTarget) {
            guard let id = FileTranscriptionSearchReveal.transcriptID(self.revealTarget) else { return }
            self.searchQuery = ""
            self.updateSearchResults(entries: self.fileHistoryStore.entries)
            self.fileHistoryStore.selectedEntryID = id
            self.pendingRevealID = self.filteredEntries.contains(where: { $0.id == id }) ? id : nil
            self.revealTarget = nil
        }
        .onChange(of: self.searchQuery) { _, _ in
            self.updateSearchResults(entries: self.fileHistoryStore.entries)
        }
        .onChange(of: self.interfaceLocale) { _, _ in
            self.rowMetadata = Dictionary(self.fileHistoryStore.entries.map { ($0.id, self.metadata(for: $0)) }, uniquingKeysWith: { _, latest in latest })
        }
        .onChange(of: self.transcriptionService.isTranscribing) { _, isTranscribing in
            guard isTranscribing else { return }
            AccessibilityNotification.Announcement(PichiLocalization.text("File transcription started")).post()
        }
        .onChange(of: self.transcriptionService.result?.id) { _, resultID in
            guard resultID != nil else { return }
            self.searchQuery = ""
            AccessibilityNotification.Announcement(PichiLocalization.text("File transcription complete")).post()
        }
        .onChange(of: self.transcriptionService.error) { _, error in
            guard let error, !error.isEmpty else { return }
            AccessibilityNotification.Announcement(PichiLocalization.format("File transcription failed. %@", error)).post()
        }
        .alert("Delete transcript?", isPresented: Binding(
            get: { self.pendingDeleteEntry != nil },
            set: { if !$0 { self.pendingDeleteEntry = nil } }
        )) {
            Button("Cancel", role: .cancel) { self.pendingDeleteEntry = nil }
            Button("Delete", role: .destructive) {
                if let entry = self.pendingDeleteEntry {
                    self.fileHistoryStore.deleteEntry(id: entry.id)
                }
                self.pendingDeleteEntry = nil
            }
        } message: {
            Text("This deletes the saved transcript. Your original audio or video file is kept.")
        }
        .alert("Clear all transcripts?", isPresented: self.$showingClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear all", role: .destructive) { self.fileHistoryStore.clearAll() }
        } message: {
            Text("All saved file transcripts will be permanently deleted. Original files are kept.")
        }
        .onAppear {
            if self.selectedFileURL == nil {
                self.selectedFileURL = self.transcriptionService.currentFileURL
            }
        }
    }

    private func activityConflictCard(activity: ASRExclusiveActivity) -> some View {
        Label(
            PichiLocalization.format("File transcription is paused while %@ is active.", PichiLocalization.text(activity.displayName)),
            systemImage: activity == .meeting ? "person.2.wave.2.fill" : "waveform.badge.mic"
        )
        .font(self.theme.typography.bodySmall)
        .foregroundStyle(self.theme.palette.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg, style: .continuous)
                .fill(self.theme.palette.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.45), lineWidth: 1)
                )
        )
        .accessibilityLabel(
            PichiLocalization.format("File transcription unavailable. Wait for the active %@ to finish.", PichiLocalization.text(activity.displayName))
        )
    }

    // MARK: - File Selection Card

    private var fileSelectionCard: some View {
        VStack(spacing: 16) {
            if let fileURL = selectedFileURL ?? self.transcriptionService.currentFileURL {
                // Show selected file
                HStack {
                    Image(systemName: "doc.fill")
                        .font(.fluidSystem(.title2))
                        .foregroundColor(self.theme.palette.accentText)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(fileURL.lastPathComponent)
                            .font(self.theme.typography.sectionTitle)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text(PichiLocalization.text(self.selectedFileIsVideo ? "Video file" : "Audio file"))
                            .font(self.theme.typography.caption)
                            .foregroundColor(self.theme.palette.secondaryText)
                    }

                    Spacer()

                    FluidGlassControlGroup {
                        HStack(spacing: 8) {
                            Button(action: {
                                self.selectedFileURL = nil
                                self.transcriptionService.reset()
                            }) {
                                Label("Remove file", systemImage: "xmark")
                            }
                            .fluidGlassAction()
                            .disabled(self.transcriptionService.isTranscribing)
                            .help(PichiLocalization.text(self.transcriptionService.isTranscribing ? "Wait for transcription to finish" : "Remove file"))
                            Button(action: {
                                Task {
                                    await self.transcribeFile()
                                }
                            }) {
                                HStack {
                                    Image(systemName: "waveform")
                                    Text(PichiLocalization.text(self.transcriptionService.isTranscribing ? "Transcribing…" : "Transcribe file"))
                                }
                            }
                            .fluidGlassAction(prominent: true)
                            .disabled(
                                self.transcriptionService.isTranscribing ||
                                    self.conflictingActivity != nil
                            )
                            .help(PichiLocalization.text(
                                self.conflictingActivity != nil
                                    ? "Wait for the active transcription to finish"
                                    : "Transcribe the selected file"
                            ))
                        }
                    }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .fill(self.theme.palette.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                                .stroke(self.theme.palette.cardBorder.opacity(0.5), lineWidth: 1)
                        )
                )

                // Speaker labeling options (unavailable on Intel Macs)
                if SpeakerDiarizationService.isSupported {
                    VStack(spacing: 10) {
                        Toggle(isOn: self.$settings.fileTranscriptionSpeakerLabelsEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Label speakers")
                                    .font(self.theme.typography.bodySmall)

                                Text(PichiLocalization.text(self.selectedFileIsVideo
                                    ? "Available for audio files only"
                                    : "Identify who said what (downloads speaker models on first use)"))
                                    .font(self.theme.typography.caption)
                                    .foregroundColor(self.theme.palette.secondaryText)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .toggleStyle(.switch)
                        .accessibilityLabel(PichiLocalization.text("Label speakers"))
                        .disabled(self.selectedFileIsVideo || self.transcriptionService.isTranscribing)

                        if self.settings.fileTranscriptionSpeakerLabelsEnabled, !self.selectedFileIsVideo {
                            HStack {
                                Text("Number of speakers")
                                    .font(self.theme.typography.bodySmall)

                                Spacer()

                                FluidDropdownPicker(
                                    "Number of speakers",
                                    selectedTitle: self.settings.fileTranscriptionExpectedSpeakerCount == 0 ? PichiLocalization.text("Auto") : String(self.settings.fileTranscriptionExpectedSpeakerCount),
                                    selection: self.$settings.fileTranscriptionExpectedSpeakerCount
                                ) {
                                    Text("Auto").tag(0)
                                    ForEach(2...8, id: \.self) { count in
                                        Text("\(count)").tag(count)
                                    }
                                }
                                .fluidDropdownStyle()
                                .frame(width: 110)
                                .disabled(self.transcriptionService.isTranscribing)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                            .fill(self.theme.palette.cardBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                                    .stroke(self.theme.palette.cardBorder.opacity(0.5), lineWidth: 1)
                            )
                    )
                }

            } else {
                HStack(spacing: self.theme.metrics.spacing.lg) {
                    Image(systemName: "doc.badge.plus")
                        .font(self.theme.typography.titleIcon)
                        .foregroundStyle(self.theme.palette.accentText)
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                        Text(PichiLocalization.text(self.isDropTargeted ? "Drop to select file" : "Transcribe a file"))
                            .font(self.theme.typography.sectionTitle)
                        Text("Drop audio or video here, or choose a file.")
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.theme.palette.secondaryText)
                    }
                    Spacer(minLength: 8)
                    Button { self.showingFilePicker = true } label: {
                        Label("Choose file…", systemImage: "plus")
                    }
                    .fluidGlassAction(prominent: true)
                }
                .frame(maxWidth: .infinity)
                .padding(self.theme.metrics.spacing.lg)
                .contentShape(Rectangle())
                .help(PichiLocalization.text(FileTranscriptionService.supportedFormatsDescription))
                .background(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg, style: .continuous)
                        .fill(self.theme.palette.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg, style: .continuous)
                                .stroke(self.theme.palette.cardBorder.opacity(0.45), lineWidth: 1)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
                        .allowsHitTesting(false)
                        .foregroundColor(self.isDropTargeted ? self.theme.palette.accentText : self.theme.palette.cardBorder)
                )
                .onDrop(of: [.fileURL], isTargeted: self.$isDropTargeted) { providers in
                    self.handleDrop(providers: providers)
                }
            }
        }
        .fileImporter(
            isPresented: self.$showingFilePicker,
            allowedContentTypes: FileTranscriptionService.allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                if let url = urls.first {
                    self.selectedFileURL = url
                    self.transcriptionService.reset()
                }
            case let .failure(error):
                DebugLogger.shared.error("File picker error: \(error)", source: "FileTranscriptionView")
            }
        }
    }

    // MARK: - Progress Card

    private var progressCard: some View {
        VStack(spacing: 16) {
            ProgressView(value: self.transcriptionService.progress)
                .progressViewStyle(.linear)

            HStack {
                ProgressView()
                    .controlSize(.small)
                    .fixedSize()

                Text(self.transcriptionService.status.text(language: PichiInterfaceLanguage(rawValue: self.interfaceLocale.identifier) ?? .russian))
                    .font(self.theme.typography.bodySmall)
                    .foregroundColor(self.theme.palette.secondaryText)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg, style: .continuous)
                .fill(self.theme.palette.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.45), lineWidth: 1)
                )
        )
    }

    private var transcriptBrowser: some View {
        GeometryReader { geometry in
            let available = max(0, geometry.size.width - 10)
            let minimum = min(240, available / 2)
            let maximum = max(minimum, available - min(300, available / 2))
            let width = min(max(self.transcriptListWidth, minimum), maximum)
            HStack(spacing: 0) {
                self.transcriptList
                    .frame(width: width)
                self.transcriptDivider(width: width, minimum: minimum, maximum: maximum)
                Group {
                    if let entry = self.selectedEntry {
                        self.transcriptDetail(entry: entry)
                    } else {
                        self.emptyDetail
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func transcriptDivider(width: CGFloat, minimum: CGFloat, maximum: CGFloat) -> some View {
        ZStack {
            self.theme.palette.windowBackground
            Rectangle()
                .fill(self.theme.palette.cardBorder)
                .frame(width: 1)
            Capsule()
                .fill(self.isSplitterHovered || self.splitterDragStart != nil
                    ? self.theme.palette.accent : self.theme.palette.secondaryText.opacity(0.5))
                .frame(width: 3, height: 28)
        }
        .frame(width: 10)
        .contentShape(Rectangle())
        .onHover { hovering in
            self.isSplitterHovered = hovering
            (hovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let start = self.splitterDragStart ?? width
                    self.splitterDragStart = start
                    self.transcriptListWidth = min(max(start + value.translation.width, minimum), maximum)
                }
                .onEnded { _ in self.splitterDragStart = nil }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded { self.transcriptListWidth = 320 })
        .help(PichiLocalization.text("Drag to resize panes. Double-click to reset."))
        .accessibilityElement()
        .accessibilityLabel(PichiLocalization.text("Resize transcript panes"))
        .accessibilityValue(PichiLocalization.format("File list width %lld points", Int(width)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: self.transcriptListWidth = min(width + 40, maximum)
            case .decrement: self.transcriptListWidth = max(width - 40, minimum)
            @unknown default: break
            }
        }
        .onDisappear {
            if self.isSplitterHovered { NSCursor.arrow.set() }
            self.isSplitterHovered = false
            self.splitterDragStart = nil
        }
    }

    // MARK: - Transcript Library

    private var transcriptList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transcripts").font(self.theme.typography.sectionTitle)
                Spacer()
                Text("\(self.filteredEntries.count)")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            .padding(self.theme.metrics.spacing.lg)

            HStack(spacing: self.theme.metrics.spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(self.theme.palette.secondaryText)
                FluidSearchField(title: "Search transcripts…", text: self.$searchQuery)
                    .accessibilityLabel(PichiLocalization.text("Search filenames and transcript text"))
                if !self.searchQuery.isEmpty {
                    Button { self.searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(PichiLocalization.text("Clear search"))
                }
            }
            .font(self.theme.typography.bodySmall)
            .padding(self.theme.metrics.spacing.sm)
            .background(self.theme.palette.cardBackground, in: RoundedRectangle(cornerRadius: self.theme.metrics.corners.md))
            .padding(.horizontal, self.theme.metrics.spacing.md)
            .padding(.bottom, self.theme.metrics.spacing.md)
            Divider()

            if self.filteredEntries.isEmpty {
                VStack(spacing: self.theme.metrics.spacing.sm) {
                    Text(PichiLocalization.text(self.searchQuery.isEmpty ? "No transcripts yet" : "No matching transcripts"))
                        .font(self.theme.typography.bodySmallStrong)
                    Text(PichiLocalization.text(self.searchQuery.isEmpty ? "Transcribe a file to start your library." : "Try a filename or words from the transcript."))
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                .multilineTextAlignment(.center)
                .padding(self.theme.metrics.spacing.lg)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: self.theme.metrics.spacing.xs) {
                            ForEach(self.filteredEntries) { entry in
                                self.transcriptRow(entry: entry).id(entry.id)
                            }
                        }
                        .padding(self.theme.metrics.spacing.sm)
                    }
                    .task(id: self.pendingRevealID) {
                        guard let id = self.pendingRevealID else { return }
                        await Task.yield()
                        guard !Task.isCancelled, self.pendingRevealID == id,
                              self.filteredEntries.contains(where: { $0.id == id }) else { return }
                        proxy.scrollTo(id)
                        self.pendingRevealID = nil
                    }
                }
            }
            Divider()
            HStack {
                Text("Saved on this Mac")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                Spacer()
                Button("Clear all…") { self.showingClearConfirmation = true }
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .buttonStyle(.plain)
                    .disabled(self.fileHistoryStore.entries.isEmpty)
            }
            .padding(self.theme.metrics.spacing.md)
        }
        .background(self.theme.palette.contentBackground)
    }

    private func transcriptRow(entry: FileTranscriptionEntry) -> some View {
        let isSelected = self.selectedEntry?.id == entry.id
        return HStack(spacing: self.theme.metrics.spacing.xs) {
            Button {
                self.pendingRevealID = nil
                self.fileHistoryStore.selectedEntryID = entry.id
            } label: {
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                    Text(entry.displayTitle)
                        .font(self.theme.typography.bodySmallStrong)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    FileTranscriptRelativeDateLabel(entry: entry, locale: self.interfaceLocale)
                        .font(self.theme.typography.captionSmall)
                        .foregroundStyle(self.theme.palette.secondaryText)
                    Text(self.rowMetadata[entry.id]?.preview ?? "")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .lineLimit(1)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(self.theme.metrics.spacing.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .editableTitle(entry.displayTitle, id: entry.id.uuidString, doubleClickEnabled: false) {
                self.fileHistoryStore.renameEntry(id: entry.id, to: $0)
            }
            Button { self.copyToClipboard(entry.text) } label: {
                Image(systemName: "doc.on.doc")
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(PichiLocalization.text("Copy transcript"))
            .accessibilityLabel(PichiLocalization.format("Copy %@", entry.displayTitle))
            .padding(.trailing, self.theme.metrics.spacing.sm)
        }
        .background(
            isSelected ? self.theme.palette.accent.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: self.theme.metrics.corners.md)
        )
        .overlay {
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md)
                .strokeBorder(isSelected ? self.theme.palette.accent.opacity(0.5) : Color.clear)
                .allowsHitTesting(false)
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: self.theme.metrics.spacing.md) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(self.theme.typography.titleIcon)
                .foregroundStyle(self.theme.palette.secondaryText)
            Text(PichiLocalization.text(self.searchQuery.isEmpty ? "Your transcript appears here" : "No matching transcript"))
                .font(self.theme.typography.sectionTitle)
            Text("Select a file on the left to read, copy, or export its transcript.")
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(self.theme.palette.secondaryText)
        }
        .multilineTextAlignment(.center)
        .padding(self.theme.metrics.spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func transcriptDetail(entry: FileTranscriptionEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                Text(entry.displayTitle)
                    .font(self.theme.typography.sectionTitle)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .editableTitle(entry.displayTitle, id: entry.id.uuidString) {
                        self.fileHistoryStore.renameEntry(id: entry.id, to: $0)
                    }
                Text(self.rowMetadata[entry.id]?.fullDate ?? "")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                HStack(spacing: self.theme.metrics.spacing.md) {
                    Label(Duration.seconds(entry.duration).formatted(.time(pattern: .hourMinuteSecond)), systemImage: "clock")
                    if !entry.speakerSegments.isEmpty {
                        Label("Speaker labels", systemImage: "person.2")
                    }
                }
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
                FluidGlassControlGroup {
                    HStack(spacing: self.theme.metrics.spacing.sm) {
                        Button { self.copyToClipboard(entry.text) } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .fluidGlassAction(prominent: true)
                        Menu {
                            ForEach(ExportFormat.allCases, id: \.self) { format in
                                Button(PichiLocalization.text(format.rawValue)) {
                                    do {
                                        self.exportDocument = try TranscriptionDocument(entry: entry, format: format)
                                        self.showingExportDialog = true
                                    } catch {
                                        DebugLogger.shared.error("Export failed: \(error)", source: "FileTranscriptionView")
                                    }
                                }
                            }
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        .fluidGlassMenuAction()
                        Button(role: .destructive) { self.pendingDeleteEntry = entry } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .buttonStyle(FluidOutlinedButtonStyle(height: FluidButtonSize.large.controlHeight, foreground: self.theme.palette.primaryText))
                        .help(PichiLocalization.text("Delete transcript"))
                        .accessibilityLabel(PichiLocalization.text("Delete transcript"))
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(self.theme.metrics.spacing.lg)
            Divider()
            if entry.speakerSegments.isEmpty {
                if let notice = entry.speakerLabelingNotice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .padding(self.theme.metrics.spacing.lg)
                }
                FileTranscriptTextView(entryID: entry.id, text: entry.text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
                        if let notice = entry.speakerLabelingNotice {
                            Label(notice, systemImage: "exclamationmark.triangle")
                                .font(self.theme.typography.caption)
                                .foregroundStyle(self.theme.palette.secondaryText)
                        }
                        ForEach(entry.speakerSegments) { segment in
                            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                                HStack {
                                    Text(segment.speaker).foregroundStyle(self.theme.palette.accentText)
                                    Text(segment.timestampText).foregroundStyle(self.theme.palette.secondaryText)
                                }
                                .font(self.theme.typography.captionStrong)
                                Text(segment.text)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .font(self.theme.typography.body)
                    .textSelection(.enabled)
                    .lineSpacing(4)
                    .padding(self.theme.metrics.spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                .id(entry.id)
            }
        }
        .background(self.theme.palette.windowBackground)
    }

    private func metadata(for entry: FileTranscriptionEntry) -> RowMetadata {
        return RowMetadata(
            preview: entry.previewText,
            fullDate: entry.timestamp.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(self.interfaceLocale))
        )
    }

    // MARK: - Error Card

    private func errorCard(error: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(self.theme.palette.readableText(.red))

            Text(error)
                .font(self.theme.typography.bodySmall)

            Spacer()

            Button("Dismiss") {
                self.transcriptionService.reset()
            }
            .fluidGlassAction()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg, style: .continuous)
                .fill(self.theme.palette.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg, style: .continuous)
                        .stroke(Color.red.opacity(0.4), lineWidth: 1)
                )
        )
    }

    // MARK: - Drop Error Card

    private func dropErrorCard(message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(self.theme.palette.readableText(.red))

            Text(message)
                .font(self.theme.typography.bodySmall)

            Spacer()

            Button("Dismiss") {
                self.dropErrorMessage = nil
            }
            .fluidGlassAction()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg, style: .continuous)
                .fill(self.theme.palette.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg, style: .continuous)
                        .stroke(Color.red.opacity(0.4), lineWidth: 1)
                )
        )
    }

    // MARK: - Helper Functions

    private static let supportedFileExtensions = FileTranscriptionService.supportedFileExtensions

    private static let dropErrorCopy = FileTranscriptionService.dropErrorCopy

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL? = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
            guard let url = url else { return }
            let ext = url.pathExtension.lowercased()
            guard Self.supportedFileExtensions.contains(ext) else {
                DispatchQueue.main.async {
                    self.dropErrorMessage = PichiLocalization.text(Self.dropErrorCopy)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.dropErrorMessage = nil
                    }
                }
                return
            }
            DispatchQueue.main.async {
                self.selectedFileURL = url
                self.transcriptionService.reset()
                self.dropErrorMessage = nil
            }
        }
        return true
    }

    private func transcribeFile() async {
        guard let fileURL = selectedFileURL else { return }

        do {
            _ = try await self.transcriptionService.transcribeFile(fileURL)
        } catch {
            DebugLogger.shared.error("Transcription error: \(error)", source: "FileTranscriptionView")
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        withAnimation {
            self.showingCopyConfirmation = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                self.showingCopyConfirmation = false
            }
        }
    }
}

// MARK: - Document for Export

nonisolated struct TranscriptionDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.plainText, .json]
    }

    let format: FileTranscriptionView.ExportFormat
    let defaultFilename: String
    private let contents: Data

    init(
        entry: FileTranscriptionEntry,
        format: FileTranscriptionView.ExportFormat
    ) throws {
        self.format = format
        self.defaultFilename = "\(entry.displayTitle)_transcript.\(format.fileExtension)"
        let result = entry.toTranscriptionResult()
        switch format {
        case .text: self.contents = result.textExportData
        case .json: self.contents = try result.jsonExportData()
        }
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnknown)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        self.fileWrapper()
    }

    /// The snapshot is already serialized; exporting owns no scratch files.
    func fileWrapper() -> FileWrapper {
        FileWrapper(regularFileWithContents: self.contents)
    }
}

// MARK: - Preview

#Preview {
    let asrService = ASRService()
    FileTranscriptionView(
        asrService: asrService,
        transcriptionService: FileTranscriptionService(asrService: asrService)
    )
    .frame(width: 700, height: 800)
}

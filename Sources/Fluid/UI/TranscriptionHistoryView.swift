import AppKit
import SwiftUI
import UniformTypeIdentifiers

nonisolated struct HistoryPinRevealRequest: Equatable {
    let entryID: UUID
    private let nonce = UUID()

    func target(selectedID: UUID?, visibleIDs: [UUID]) -> UUID? {
        guard selectedID == self.entryID, visibleIDs.contains(self.entryID) else { return nil }
        return self.entryID
    }
}

/// A hidden existing row can be selected from sidebar search even when the list is empty.
nonisolated enum HistorySelectionRevealPolicy {
    static func needsFilterReset(
        requestedID: UUID?,
        selectedID: UUID?,
        allEntries: [TranscriptionHistoryEntry],
        visibleEntries: [TranscriptionHistoryEntry]
    ) -> Bool {
        guard let selectedID, requestedID == selectedID else { return false }
        return !visibleEntries.contains { $0.id == selectedID }
            && allEntries.contains { $0.id == selectedID }
    }
}

struct TranscriptionHistoryView: View {
    @ObservedObject private var historyStore = TranscriptionHistoryStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme
    @Environment(\.locale) private var interfaceLocale

    @ObservedObject private var profiles = PrivateProfileService.shared
    @StateObject private var projection = HistoryPrivateProjection()

    private struct AudioAvailabilityRequest: Equatable {
        let fileNames: [String]
        let revision: UUID
    }

    private var audioAvailabilityRequest: AudioAvailabilityRequest {
        AudioAvailabilityRequest(
            fileNames: self.filteredEntries.compactMap { $0.audio?.fileName },
            revision: self.projection.audioAvailabilityRevision
        )
    }

    /// Lives in the store so the sidebar search can select a row before this view
    /// exists, and the store's delete and clear paths keep it valid.
    private var selectedEntryID: UUID? {
        get { self.projection.isVisible ? self.historyStore.selectedEntryID : nil }
        nonmutating set { if newValue == nil || self.projection.isVisible { self.historyStore.selectedEntryID = newValue } }
    }

    private var filteredEntries: [TranscriptionHistoryEntry] {
        guard self.projection.isVisible else { return [] }
        return self.historyStore.search(query: self.projection.searchQuery, starredOnly: self.projection.pinnedOnly, pinnedFirst: true)
    }

    private var selectedEntry: TranscriptionHistoryEntry? {
        guard let id = selectedEntryID else { return self.filteredEntries.first }
        return self.filteredEntries.first(where: { $0.id == id })
    }

    var body: some View {
        Group {
            if self.projection.isVisible {
                self.historyContent
            } else {
                self.noSelectionView
            }
        }
        .onChange(of: self.profiles.projectionRevision) { _, _ in
            self.projection.clearForProjectionChange()
        }
        .onChange(of: self.profiles.isPrivateDataVisible) { _, visible in
            if !visible { self.projection.clearTransientState() }
        }
        .onDisappear { self.projection.clearTransientState() }
    }

    private var historyContent: some View {
        HSplitView {
            // MARK: - Left Panel: Entry List

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    self.searchBar
                    FluidDropdownPicker(
                        PichiLocalization.text("History filter"),
                        selectedTitle: PichiLocalization.text(self.projection.pinnedOnly ? "Pinned" : "All"),
                        selection: self.$projection.pinnedOnly
                    ) {
                        Text("All").tag(false)
                        Text("Pinned").tag(true)
                    }
                    .fluidDropdownStyle()
                    .fixedSize()
                }
                .padding(12)

                if self.historyStore.isLoading {
                    ProgressView("Loading history…")
                        .padding(12)
                } else if let error = self.historyStore.persistenceError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error)
                            .font(.fluidSystem(.caption))
                        Button("Retry saving history") {
                            guard self.projection.isVisible else { return }
                            self.historyStore.retryPersistence()
                        }
                    }
                    .padding(12)
                }

                Divider()
                    .opacity(0.3)

                // Entry List
                if self.filteredEntries.isEmpty {
                    self.emptyStateView
                } else {
                    self.entryListView
                }

                // Footer with stats and clear button
                self.footerView
                    .disabled(self.historyStore.isLoading)
            }
            .frame(minWidth: 280, idealWidth: 408, maxWidth: 480)
            .background(self.theme.palette.contentBackground)

            // MARK: - Right Panel: Entry Detail

            if let entry = selectedEntry {
                self.entryDetailView(entry)
                    .frame(minWidth: 320)
            } else {
                self.noSelectionView
                    .frame(minWidth: 320)
            }
        }
        .onChange(of: self.historyStore.searchSelectionRequest) { _, _ in
            self.revealExternalSelection()
        }
        .onChange(of: self.filteredEntries.map(\.id)) { _, visibleIDs in
            if let selectedEntryID = self.selectedEntryID, visibleIDs.contains(selectedEntryID) { return }
            self.selectedEntryID = visibleIDs.first
        }
        .onChange(of: self.selectedEntry?.id) { _, _ in
            self.projection.audioEntryID = nil
        }
        .onAppear {
            self.projection.audioAvailabilityRevision = UUID()
            self.revealExternalSelection()
            if self.selectedEntryID == nil {
                self.selectedEntryID = self.filteredEntries.first?.id
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            self.projection.audioAvailabilityRevision = UUID()
        }
        .onChange(of: self.audioAvailabilityRequest, initial: true) { _, request in
            self.projection.scanAudio(fileNames: request.fileNames)
        }
        .alert("Clear All History", isPresented: self.$projection.showClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                guard self.projection.isVisible else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.historyStore.clearAllHistory()
                    self.selectedEntryID = nil
                }
            }
        } message: {
            Text("This will permanently delete all \(self.historyStore.entries.count) transcription entries, including pinned entries. This action cannot be undone.")
        }
        .alert("Report Sent", isPresented: self.$projection.showReportConfirmation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(AppBrand.text("Thank you for helping improve FluidVoice dictation."))
        }
        .alert("Pair Export Failed", isPresented: Binding(
            get: { self.projection.exportError != nil },
            set: { if !$0 { self.projection.exportError = nil } }
        )) {
            Button("OK", role: .cancel) { self.projection.exportError = nil }
        } message: {
            Text(self.projection.exportError ?? "")
        }
        .sheet(item: self.$projection.selectedReportEntry) { _ in
            TranscriptionFeedbackReportSheet(projection: self.projection)
                .environment(\.theme, self.theme)
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.fluidSystem(size: 13, weight: .medium))
                .foregroundStyle(self.theme.palette.secondaryText)

            FluidSearchField(title: "Search transcriptions...", text: self.$projection.searchQuery)
                .font(.fluidSystem(size: 13))

            if !self.projection.searchQuery.isEmpty {
                Button {
                    self.projection.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.fluidSystem(size: 12))
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(self.theme.palette.cardBackground)
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(self.theme.palette.cardBorder.opacity(0.6), lineWidth: 1)))
    }

    // MARK: - Entry List

    private var entryListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(self.filteredEntries) { entry in
                        self.entryRow(entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .onAppear { self.reveal(self.selectedEntryID, with: proxy) }
            .onChange(of: self.historyStore.selectedEntryID) { _, id in self.reveal(id, with: proxy) }
            .onChange(of: self.projection.pinRevealRequest) { _, request in
                guard let request else { return }
                self.projection.start { ticket in
                    // Let reordered rows reach the list before following the selection.
                    await Task.yield()
                    guard self.projection.isCurrent(ticket), self.projection.pinRevealRequest == request else { return }
                    if let id = request.target(selectedID: self.selectedEntryID, visibleIDs: self.filteredEntries.map(\.id)) {
                        proxy.scrollTo(id)
                    }
                    self.projection.pinRevealRequest = nil
                }
            }
        }
    }

    /// Parent-level handling also runs when no list exists to observe the selection.
    private func revealExternalSelection() {
        guard self.projection.isVisible, let request = self.historyStore.searchSelectionRequest else { return }
        defer { self.historyStore.consumeSearchSelectionRequest(request) }
        guard HistorySelectionRevealPolicy.needsFilterReset(
            requestedID: request.entryID,
            selectedID: self.selectedEntryID,
            allEntries: self.historyStore.entries,
            visibleEntries: self.filteredEntries
        ) else { return }
        self.projection.searchQuery = ""
        self.projection.pinnedOnly = false
    }

    /// The parent clears a hidden selection's filters; scroll after that view update.
    private func reveal(_ id: UUID?, with proxy: ScrollViewProxy) {
        guard self.projection.isVisible, let id else { return }
        self.projection.start { ticket in
            await Task.yield()
            guard self.projection.isCurrent(ticket), self.filteredEntries.contains(where: { $0.id == id }) else { return }
            proxy.scrollTo(id)
        }
    }

    private func entryRow(_ entry: TranscriptionHistoryEntry) -> some View {
        let isSelected = self.selectedEntryID == entry.id
        return HistoryHoverRow(isSelected: isSelected) { showsActions in
            ZStack(alignment: .bottomTrailing) {
                Button {
                    self.selectedEntryID = entry.id
                } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            HistoryAppIcon(appName: entry.appName)
                            Spacer(minLength: 4)
                            Text(self.relativeDate(entry.timestamp))
                                .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
                        }
                        .padding(.trailing, 36)
                        .frame(minHeight: 28)
                        Text(entry.previewText)
                            .font(self.theme.typography.body)
                            .lineLimit(2).multilineTextAlignment(.leading)
                        HStack(spacing: 10) {
                            if let model = self.recordedModel(entry) {
                                Label(model, systemImage: "sparkles")
                                    .lineLimit(1).truncationMode(.middle)
                                    .help(PichiLocalization.format("Recorded AI model: %@", model))
                            } else if entry.wasAIProcessed {
                                Label("AI enhanced", systemImage: "sparkles")
                            }
                            if self.hasAudio(entry) {
                                Image(systemName: "waveform").accessibilityLabel(PichiLocalization.text("Saved audio"))
                            }
                            if entry.aiProcessingError != nil {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(self.theme.palette.readableText(self.theme.palette.warning)).help(entry.aiProcessingError ?? "")
                            }
                            Spacer(minLength: 0)
                            if self.settings.showHistoryPerformanceMetrics, let speed = entry.aiTokensPerSecond {
                                Text(TranscriptionHistoryEntry.formattedTokensPerSecond(speed, compact: true))
                                    .font(self.theme.typography.captionStrong)
                                    .foregroundStyle(self.theme.palette.accentText)
                                    .monospacedDigit()
                                    .fixedSize()
                                    .help(PichiLocalization.text("AI generation speed, in tokens per second—not total processing time"))
                            }
                        }
                        .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
                        .padding(.trailing, 76)
                        .frame(minHeight: 28)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    self.selectedEntryID = entry.id
                    self.copyFinalText(entry)
                })
                .help(PichiLocalization.text("Double-click to copy final text"))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityAction(named: Text("Copy final text")) { self.copyFinalText(entry) }
                .accessibilityAction(named: Text("Report issue")) { self.openFeedbackReport(for: entry) }
                .accessibilityAction(named: Text(PichiLocalization.text(entry.isStarred ? "Unpin transcription" : "Pin transcription"))) {
                    self.togglePin(entry)
                }
                HStack(spacing: 8) {
                    Button {
                        self.copyFinalText(entry)
                    } label: {
                        Image(systemName: self.projection.copiedEntryID == entry.id ? "checkmark" : "doc.on.doc")
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(PichiLocalization.text("Copy final text"))
                    .accessibilityLabel(PichiLocalization.text(self.projection.copiedEntryID == entry.id ? "Copied" : "Copy final text"))
                    Button {
                        self.openFeedbackReport(for: entry)
                    } label: {
                        Image(systemName: "flag")
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(PichiLocalization.text("Report an issue with this dictation"))
                    .accessibilityLabel(PichiLocalization.text("Report issue"))
                }
                .font(self.theme.typography.body)
                .labelStyle(.iconOnly)
                .frame(width: 64)
                .foregroundStyle(self.theme.palette.secondaryText)
                .opacity(showsActions ? 1 : 0)
                .allowsHitTesting(showsActions)
                .accessibilityHidden(!showsActions)
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    self.togglePin(entry)
                } label: {
                    Image(systemName: entry.isStarred ? "pin.fill" : "pin")
                        .font(self.theme.typography.body)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(entry.isStarred ? self.theme.palette.accentText : self.theme.palette.secondaryText)
                .help(PichiLocalization.text(entry.isStarred ? "Unpin transcription" : "Pin transcription"))
                .accessibilityLabel(PichiLocalization.text(entry.isStarred ? "Unpin transcription" : "Pin transcription"))
                .accessibilityIdentifier("History.Pin.\(entry.id.uuidString)")
            }
        }
        .padding(12)
        .background(isSelected ? self.theme.palette.elevatedCardBackground : self.theme.palette.cardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(isSelected ? self.theme.palette.accent.opacity(0.6) : self.theme.palette.cardBorder.opacity(0.25)))
        .contextMenu { self.entryActions(entry) }
    }

    @ViewBuilder
    private func entryActions(_ entry: TranscriptionHistoryEntry) -> some View {
        Button {
            self.togglePin(entry)
        } label: {
            Label(PichiLocalization.text(entry.isStarred ? "Unpin" : "Pin"), systemImage: entry.isStarred ? "pin.slash" : "pin")
        }

        Divider()

        Button {
            self.copyFinalText(entry)
        } label: {
            Label(PichiLocalization.text(entry.wasAIProcessed ? "Copy AI Text" : "Copy Text"), systemImage: "doc.on.doc")
        }

        if entry.wasAIProcessed {
            Button {
                self.copyToClipboard(entry.rawText)
            } label: {
                Label("Copy Raw Text", systemImage: "doc.on.doc.fill")
            }

            Button {
                self.copyToClipboard(self.combinedText(for: entry))
            } label: {
                Label("Copy Both", systemImage: "doc.on.doc")
            }
        }

        if self.hasAudio(entry) {
            Divider()

            Button {
                self.exportPair(entry)
            } label: {
                Label("Export Pair...", systemImage: "square.and.arrow.up")
            }

            Button {
                self.revealAudio(entry)
            } label: {
                Label("Reveal Audio", systemImage: "waveform")
            }
        }

        Divider()

        Button {
            self.openFeedbackReport(for: entry)
        } label: {
            Label("Report issue...", systemImage: "flag")
        }

        Divider()

        Button(role: .destructive) {
            guard self.projection.isVisible else { return }
            if self.projection.audioEntryID == entry.id { self.projection.audioEntryID = nil }
            self.historyStore.deleteEntry(id: entry.id)
            if self.selectedEntryID == entry.id {
                self.selectedEntryID = self.filteredEntries.first(where: { $0.id != entry.id })?.id
            }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func togglePin(_ entry: TranscriptionHistoryEntry) {
        guard self.projection.isVisible else { return }
        self.projection.pinRevealRequest = nil
        self.historyStore.toggleStar(id: entry.id)
        guard self.selectedEntryID == entry.id, self.filteredEntries.contains(where: { $0.id == entry.id }) else { return }
        self.projection.pinRevealRequest = HistoryPinRevealRequest(entryID: entry.id)
    }

    // MARK: - Empty State

    private var emptyStateIcon: String {
        if !self.projection.searchQuery.isEmpty { return "magnifyingglass" }
        return self.projection.pinnedOnly ? "pin" : "clock.arrow.circlepath"
    }

    private var emptyStateTitle: String {
        if !self.projection.searchQuery.isEmpty { return "No Results" }
        return self.projection.pinnedOnly ? "No Pinned Transcriptions" : "No History Yet"
    }

    private var emptyStateMessage: String {
        if !self.projection.searchQuery.isEmpty { return "Try a different search term" }
        return self.projection.pinnedOnly
            ? "Pin a transcription to keep it at the top of History"
            : "Your transcriptions will appear here"
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: self.emptyStateIcon)
                .font(.fluidSystem(size: 36, weight: .light))
                .foregroundStyle(self.theme.palette.tertiaryText)

            VStack(spacing: 4) {
                Text(PichiLocalization.text(self.emptyStateTitle))
                    .font(.fluidSystem(size: 14, weight: .semibold))
                    .foregroundStyle(self.theme.palette.secondaryText)

                Text(PichiLocalization.text(self.emptyStateMessage))
                    .font(.fluidSystem(size: 12))
                    .foregroundStyle(self.theme.palette.tertiaryText)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    // MARK: - Footer

    private var footerView: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.3)

            HStack {
                // Stats
                Text(self.filteredEntries.count == 1 ? PichiLocalization.text("1 entry") : PichiLocalization.format("%lld entries", self.filteredEntries.count))
                    .font(.fluidSystem(size: 11, weight: .medium))
                    .foregroundStyle(self.theme.palette.tertiaryText)

                Spacer()

                // Clear All Button
                if !self.historyStore.entries.isEmpty {
                    Button {
                        guard self.projection.isVisible else { return }
                        self.projection.showClearConfirmation = true
                    } label: {
                        Text("Clear All")
                            .font(.fluidSystem(size: 11, weight: .medium))
                            .foregroundStyle(self.theme.palette.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .opacity(0.8)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Entry Detail View

    private func entryDetailView(_ entry: TranscriptionHistoryEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        self.detailHeading(entry)
                        Spacer(minLength: 12)
                        self.detailActions(entry)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 16) {
                        self.detailHeading(entry)
                        self.detailActions(entry)
                    }
                }
                if self.projection.audioEntryID == entry.id {
                    HistoryInlineAudioView(entry: entry)
                        .id(entry.id)
                }
                if let error = entry.aiProcessingError {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("AI enhancement failed—raw transcription was used").font(self.theme.typography.bodyStrong)
                            Text(error).font(self.theme.typography.caption).textSelection(.enabled)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(self.theme.palette.readableText(self.theme.palette.warning))
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(self.theme.palette.cardBackground, in: RoundedRectangle(cornerRadius: 16))
                }
                HistoryTextComparisonView(entry: entry, copy: self.copyToClipboard)
                    .id(entry.id)
                FluidManagementGroup(title: "Processing") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16, alignment: .leading)], alignment: .leading, spacing: 16) {
                        if self.settings.showHistoryPerformanceMetrics {
                            if let duration = entry.parakeetProcessingDurationMilliseconds ?? entry.transcriptionDurationMilliseconds {
                                self.metadataItem(
                                    icon: "waveform",
                                    label: "Transcription",
                                    value: TranscriptionHistoryEntry.formattedDuration(milliseconds: duration)
                                )
                            }
                            if let duration = entry.aiProcessingDurationMilliseconds {
                                self.metadataItem(
                                    icon: "sparkles",
                                    label: "AI cleanup",
                                    value: TranscriptionHistoryEntry.formattedDuration(milliseconds: duration)
                                )
                            }
                            if let speed = entry.aiTokensPerSecond {
                                self.metadataItem(
                                    icon: "speedometer",
                                    label: "AI speed",
                                    value: TranscriptionHistoryEntry.formattedTokensPerSecond(speed, compact: true)
                                )
                            }
                        }
                        self.metadataItem(
                            icon: "sparkles",
                            label: entry.aiProcessingError == nil ? "AI model" : "AI model (failed)",
                            value: self.recordedModel(entry) ?? PichiLocalization.text(entry.wasAIProcessed ? "Not recorded" : "No AI cleanup")
                        )
                    }
                }
                FluidManagementGroup(title: "Details") {
                    LazyVGrid(columns: self.detailColumns, alignment: .leading, spacing: 16) {
                        self.metadataItem(icon: "app", label: "Application", value: entry.appName.isEmpty ? PichiLocalization.text("Unknown") : entry.appName)
                        self.metadataItem(icon: "waveform", label: "Recording", value: self.recordingDurationText(for: entry))
                        self.metadataItem(icon: "internaldrive", label: "Audio size", value: self.audioSizeText(for: entry))
                    }
                }
            }
            .fluidPageContent()
        }
        .background(self.theme.palette.contentBackground)
    }

    private func detailHeading(_ entry: TranscriptionHistoryEntry) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.fluidSystem(size: 24, weight: .medium))
                .foregroundStyle(self.theme.palette.accentText)
                .frame(width: 52, height: 52)
                .background(self.theme.palette.elevatedCardBackground, in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 5) {
                Text("Dictation details").font(self.theme.typography.title)
                Text(entry.timestamp.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(self.interfaceLocale))).font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
            }
        }
    }

    private var detailColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 180), spacing: 16, alignment: .leading)]
    }

    private func recordedModel(_ entry: TranscriptionHistoryEntry) -> String? {
        guard let model = entry.processingModel?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else { return nil }
        return ModelDisplayName.forID(model)
    }

    private func detailActions(_ entry: TranscriptionHistoryEntry) -> some View {
        FluidGlassControlGroup {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { self.detailActionButtons(entry) }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) { self.detailActionButtons(entry) }
            }
        }
    }

    @ViewBuilder
    private func detailActionButtons(_ entry: TranscriptionHistoryEntry) -> some View {
        Button { self.openFeedbackReport(for: entry) } label: {
            Label("Report issue", systemImage: "flag")
                .fixedSize(horizontal: false, vertical: true)
        }
        .fluidGlassAction()
        Button { self.copyFinalText(entry) } label: {
            Label(
                PichiLocalization.text(self.projection.copiedEntryID == entry.id ? "Copied" : "Copy text"),
                systemImage: self.projection.copiedEntryID == entry.id ? "checkmark" : "doc.on.doc"
            )
            .fixedSize(horizontal: false, vertical: true)
        }
        .fluidGlassAction(prominent: true)
        .disabled(entry.clipboardText == nil)
        if self.hasAudio(entry) {
            Button {
                guard self.projection.isVisible else { return }
                self.projection.audioEntryID = self.projection.audioEntryID == entry.id ? nil : entry.id
            } label: {
                Label(PichiLocalization.text(self.projection.audioEntryID == entry.id ? "Close audio" : "Audio"), systemImage: "waveform")
            }
            .fluidGlassAction()
        }
        Menu { self.entryActions(entry) } label: { Image(systemName: "ellipsis") }
            .menuIndicator(.hidden)
            .fluidGlassAction(circular: true)
            .accessibilityLabel(PichiLocalization.text("Dictation actions"))
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = self.interfaceLocale
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func metadataItem(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.fluidSystem(size: 18)).foregroundStyle(self.theme.palette.accentText)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(PichiLocalization.text(label)).font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(value).font(self.theme.typography.bodyStrong).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func copyFinalText(_ entry: TranscriptionHistoryEntry) {
        guard self.projection.isVisible, let text = entry.clipboardText else { return }
        self.copyToClipboard(text)
        self.projection.showCopyFeedback(entryID: entry.id)
    }

    private func copyToClipboard(_ text: String) {
        guard self.projection.isVisible else { return }
        ClipboardAudit.record("ui_copy_begin")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        ClipboardAudit.record("ui_copy_end")
    }

    private func openFeedbackReport(for entry: TranscriptionHistoryEntry) {
        self.projection.openReport(entry)
    }

    private func combinedText(for entry: TranscriptionHistoryEntry) -> String {
        "\(entry.rawText)\n\n\(entry.processedText)"
    }

    private func hasAudio(_ entry: TranscriptionHistoryEntry) -> Bool {
        guard let audio = entry.audio else { return false }
        return self.projection.availableAudioFiles.contains(audio.fileName)
    }

    private func recordingDurationText(for entry: TranscriptionHistoryEntry) -> String {
        guard let audio = entry.audio else { return PichiLocalization.text("Not saved") }
        return String(format: "%.1fs", Double(audio.durationMilliseconds) / 1000.0)
    }

    private func audioSizeText(for entry: TranscriptionHistoryEntry) -> String {
        guard let audio = entry.audio else { return PichiLocalization.text("Not saved") }
        guard self.hasAudio(entry) else { return PichiLocalization.text("Unavailable") }
        return ByteCountFormatter.string(fromByteCount: Int64(audio.byteCount), countStyle: .file)
    }

    private func revealAudio(_ entry: TranscriptionHistoryEntry) {
        guard self.projection.isVisible,
              let url = self.projection.audioStore.audioFileURL(for: entry),
              FileManager.default.fileExists(atPath: url.path)
        else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func exportPair(_ entry: TranscriptionHistoryEntry) {
        self.projection.start { ticket in
            guard self.projection.exportPanel == nil else { return }
            do {
                guard self.hasAudio(entry) else { throw DictationAudioHistoryError.audioMissing }
                let panel = NSSavePanel()
                panel.canCreateDirectories = true
                panel.allowedContentTypes = [.zip]
                panel.nameFieldStringValue = self.projection.audioStore.suggestedPairExportFilename(for: entry)
                self.projection.exportPanel = panel
                defer { if self.projection.exportPanel === panel { self.projection.exportPanel = nil } }
                // The retained task joins the panel's completion after conceal cancels it.
                let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
                    panel.begin { continuation.resume(returning: $0) }
                }
                guard self.projection.isCurrent(ticket), response == .OK, let url = panel.url else { return }
                try self.projection.audioStore.exportPair(entry: entry, to: url)
            } catch {
                guard self.projection.isCurrent(ticket) else { return }
                self.projection.exportError = error.localizedDescription
            }
        }
    }

    // MARK: - No Selection View

    private var noSelectionView: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.quote")
                .font(.fluidSystem(size: 40, weight: .light))
                .foregroundStyle(self.theme.palette.tertiaryText)

            Text("Select a transcription")
                .font(.fluidSystem(size: 14, weight: .medium))
                .foregroundStyle(self.theme.palette.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(self.theme.palette.contentBackground)
    }
}

// MARK: - Joined history projection lifetime

/// One history view owns its transient payloads and readers. Source replacement is
/// composition-owned; this owner never rebinds an old view to a newly selected profile.
@MainActor
final class HistoryPrivateProjection: ObservableObject, PrivateProfileTransitionParticipant {
    struct Ticket {
        let profile: PrivateProfileSnapshot
        let revision: UUID
    }

    @Published var searchQuery = ""
    @Published var pinnedOnly = false
    @Published var pinRevealRequest: HistoryPinRevealRequest?
    @Published var showClearConfirmation = false
    @Published var showReportConfirmation = false
    @Published var selectedReportEntry: TranscriptionHistoryEntry?
    @Published var audioEntryID: UUID?
    @Published var copiedEntryID: UUID?
    @Published var availableAudioFiles: Set<String> = []
    @Published var audioAvailabilityRevision = UUID()
    @Published var exportError: String?
    @Published var inputText = ""
    @Published var outputText = ""
    @Published var processingModel = ""
    @Published var comment = ""
    @Published var isSending = false
    @Published var errorMessage: String?

    let audioStore: DictationAudioHistoryStore
    var exportPanel: NSSavePanel?
    private let profile: PrivateProfileSnapshot
    private let historyStore: TranscriptionHistoryStore
    private let profiles: PrivateProfileService
    private var retired = false
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var audioScanID: UUID?
    private var copyFeedbackID: UUID?
    private var reportTaskID: UUID?
    private var reportRevision = UUID()
    private var concealObserver: AnyCancellable?

    init() {
        self.profile = PrivateProfileStorage.current
        self.audioStore = DictationAudioHistoryStore.scoped(to: self.profile)
        self.historyStore = TranscriptionHistoryStore.shared
        self.profiles = PrivateProfileService.shared
        self.profiles.register(self)
        // Concealment is synchronous, including a later marker-persistence failure.
        // The registered participant separately joins all retained asynchronous work.
        self.concealObserver = NotificationCenter.default.publisher(for: PrivateProfileService.willConceal)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.retired = true
                    self?.clearTransientState(clearSelection: true)
                }
            }
    }

    var isVisible: Bool {
        !self.retired && self.profiles.isPrivateDataVisible && !self.profiles.isTransitioning &&
            PrivateProfileStorage.acceptsNewWork && PrivateProfileStorage.isReadable(self.profile)
    }

    func capture() -> Ticket? {
        guard self.isVisible else { return nil }
        return Ticket(profile: self.profile, revision: self.profiles.projectionRevision)
    }

    func isCurrent(_ ticket: Ticket) -> Bool {
        self.isVisible && ticket.profile == self.profile &&
            ticket.revision == self.profiles.projectionRevision &&
            PrivateProfileStorage.isReadable(ticket.profile) && !Task.isCancelled
    }

    /// Every view-owned task remains retained until completion, including replaced
    /// scans and cancelled feedback sleeps, so transition cleanup can join all of them.
    @discardableResult
    func start(_ work: @escaping @MainActor (Ticket) async -> Void) -> UUID? {
        guard let ticket = self.capture() else { return nil }
        let id = UUID()
        self.tasks[id] = Task { @MainActor in
            if self.isCurrent(ticket) { await work(ticket) }
            self.tasks.removeValue(forKey: id)
        }
        return id
    }

    func scanAudio(fileNames: [String]) {
        if let id = self.audioScanID { self.tasks[id]?.cancel() }
        let audioStore = self.audioStore
        self.audioScanID = self.start { ticket in
            let available = await HistoryAudioAvailability.scan(fileNames: fileNames) {
                audioStore.audioFileExists(fileName: $0)
            }
            guard self.isCurrent(ticket) else { return }
            self.availableAudioFiles = available
            if let selected = self.historyStore.entries.first(where: { $0.id == self.audioEntryID }),
               let audio = selected.audio, !available.contains(audio.fileName) {
                self.audioEntryID = nil
            }
        }
    }

    func showCopyFeedback(entryID: UUID) {
        guard self.isVisible else { return }
        if let id = self.copyFeedbackID { self.tasks[id]?.cancel() }
        self.copiedEntryID = entryID
        self.copyFeedbackID = self.start { ticket in
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            guard self.isCurrent(ticket) else { return }
            self.copiedEntryID = nil
        }
    }

    func openReport(_ entry: TranscriptionHistoryEntry) {
        guard self.isVisible else { return }
        self.closeReport()
        self.inputText = entry.rawText
        self.outputText = entry.processedText
        let model = entry.processingModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.processingModel = model.isEmpty ? "unknown" : model
        self.selectedReportEntry = entry
    }

    func closeReport() {
        if let id = self.reportTaskID { self.tasks[id]?.cancel() }
        self.reportTaskID = nil
        self.reportRevision = UUID()
        self.selectedReportEntry = nil
        self.inputText = ""; self.outputText = ""; self.processingModel = ""; self.comment = ""
        self.isSending = false; self.errorMessage = nil
    }

    func sendReport() {
        guard self.isVisible, !self.isSending, self.selectedReportEntry != nil else { return }
        let payload = TranscriptionFeedbackReporter.Payload(
            rawText: self.inputText.trimmingCharacters(in: .whitespacesAndNewlines),
            processedText: self.outputText.trimmingCharacters(in: .whitespacesAndNewlines),
            processingModel: self.processingModel.trimmingCharacters(in: .whitespacesAndNewlines),
            comments: self.comment.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let reportRevision = self.reportRevision
        self.isSending = true; self.errorMessage = nil
        self.reportTaskID = self.start { ticket in
            do {
                try await TranscriptionFeedbackReporter.submit(payload)
                guard self.isCurrent(ticket), self.reportRevision == reportRevision else { return }
                self.closeReport()
                self.showReportConfirmation = true
            } catch {
                guard self.isCurrent(ticket), self.reportRevision == reportRevision else { return }
                self.errorMessage = error.localizedDescription
                self.isSending = false
            }
        }
    }

    func clearForProjectionChange() {
        self.clearTransientState(clearSelection: true)
    }

    func clearTransientState(clearSelection: Bool = false) {
        for task in self.tasks.values { task.cancel() }
        self.exportPanel?.cancel(nil)
        self.exportPanel = nil
        self.closeReport()
        self.searchQuery = ""; self.pinnedOnly = false; self.pinRevealRequest = nil
        self.showClearConfirmation = false; self.showReportConfirmation = false
        self.availableAudioFiles = []; self.audioEntryID = nil; self.copiedEntryID = nil
        self.exportError = nil
        self.audioAvailabilityRevision = UUID()
        if clearSelection { self.historyStore.selectedEntryID = nil }
    }

    func prepareForPrivateProfileTransition() async throws {
        self.retired = true
        self.clearTransientState(clearSelection: true)
        let pending = Array(self.tasks.values)
        for task in pending { await task.value }
        self.tasks.removeAll()
        self.audioScanID = nil; self.copyFeedbackID = nil; self.reportTaskID = nil
    }
}

// MARK: - History feedback sheet

private struct TranscriptionFeedbackReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.locale) private var interfaceLocale

    @ObservedObject var projection: HistoryPrivateProjection

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Share anonymous datapoint")
                    .font(.fluidSystem(size: 18, weight: .semibold))
                Text("Help improve our model. Only the example shown below will be sent.")
                    .font(.fluidSystem(size: 12))
                    .foregroundStyle(self.theme.palette.secondaryText)
            }

            self.feedbackField(title: "Raw Text", text: self.$projection.inputText, height: 88)
            self.feedbackField(title: "Processed Text", text: self.$projection.outputText, height: 88)
            self.feedbackField(title: "Processing Model", text: self.$projection.processingModel, height: 40)
            self.feedbackField(title: "Comment optional", text: self.$projection.comment, height: 72)

            if let errorMessage = self.projection.errorMessage {
                Text(errorMessage)
                    .font(.fluidSystem(size: 12, weight: .medium))
                    .foregroundStyle(self.theme.palette.readableText(.red))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    self.projection.closeReport()
                    self.dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(self.projection.isSending)

                Button {
                    self.projection.sendReport()
                } label: {
                    HStack(spacing: 8) {
                        if self.projection.isSending {
                            ProgressView()
                                .controlSize(.small)
                                .fixedSize()
                        }
                        Text(PichiLocalization.text(self.projection.isSending ? "Sending..." : "Send Example"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(self.isSendDisabled)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(self.theme.palette.contentBackground)
        .onDisappear { self.projection.closeReport() }
    }

    private var isSendDisabled: Bool {
        self.projection.isSending ||
            (self.projection.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                self.projection.outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ||
            self.projection.processingModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func feedbackField(title: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(PichiLocalization.text(title))
                .font(.fluidSystem(size: 11, weight: .semibold))
                .foregroundStyle(self.theme.palette.secondaryText)
                .textCase(.uppercase)

            TextEditor(text: text)
                .font(.fluidSystem(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: height)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(self.theme.palette.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(self.theme.palette.cardBorder.opacity(0.55), lineWidth: 1)
                        )
                )
        }
    }

}

private struct HistoryHoverRow<Content: View>: View {
    let isSelected: Bool
    @ViewBuilder let content: (Bool) -> Content
    @State private var isHovered = false
    @FocusState private var containsFocus: Bool

    var body: some View {
        self.content(self.isHovered || self.isSelected || self.containsFocus)
            .focused(self.$containsFocus)
            .onHover { self.isHovered = $0 }
    }
}

#Preview {
    TranscriptionHistoryView()
        .frame(width: 800, height: 600)
        .environment(\.theme, AppTheme.dark)
}

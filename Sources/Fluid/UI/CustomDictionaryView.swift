// Existing UI composition; splitting it is outside this integration fix.
// swiftlint:disable file_length
//
//  CustomDictionaryView.swift
//  fluid
//
//  Custom dictionary for correcting commonly misheard words.
//  Created: 2025-12-21
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// This legacy screen still owns several dictionary editors; split them into standalone views incrementally.
// swiftlint:disable:next type_body_length
struct CustomDictionaryView: View {
    private let profile = PrivateProfileStorage.current
    private var isProfileVisible: Bool { PrivateProfileStorage.isReadable(profile) && PrivateProfileStorage.acceptsNewWork }
    var formattingOnly = false
    @State private var isWordDrawerPresented = true
    @State private var wordSearch = ""
    @State private var isDrawerActionsPresented = false
    @State private var newWordFocusRequest = 0
    @State private var drawerDeletion: SettingsStore.CustomDictionaryEntry?
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var appServices: AppServices
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var modelInstallations = SpeechModelInstallationSnapshot.shared
    @State private var pronunciationRevisionNotice: String?
    @State private var pronunciationRevisionNoticeRefresh: UInt64 = 0

    /// A row picked in the sidebar search. Opening it is the reveal; the binding is
    /// cleared so the same row can be picked again later.
    @Binding var revealTarget: AppSearchHit.Target?
    @Binding var trainingRequest: DictionaryWordTrainingRequest?

    init(formattingOnly: Bool = false, revealTarget: Binding<AppSearchHit.Target?>,
         trainingRequest: Binding<DictionaryWordTrainingRequest?> = .constant(nil)) {
        self.formattingOnly = formattingOnly
        self._revealTarget = revealTarget
        self._trainingRequest = trainingRequest
    }

    @State private var entries: [SettingsStore.CustomDictionaryEntry] = SettingsStore.shared.customDictionaryEntries
    @State private var boostTerms: [ParakeetVocabularyStore.VocabularyConfig.Term] = []
    @State private var editingEntry: SettingsStore.CustomDictionaryEntry?

    @State private var boostStatusMessage = "Add custom words for better Parakeet recognition."
    @State private var boostHasError = false
    @State private var vocabBoostingEnabled: Bool = SettingsStore.shared.vocabularyBoostingEnabled
    @State private var isCustomWordsPresented = false
    @State private var isBoostWordEditorPresented = false
    @State private var editingBoostTermIndex: Int?
    @State private var boostTermText = ""
    @State private var boostTermStrength: BoostStrengthPreset = .balanced

    @State private var wizardStep: DictionaryWordWizardStep = .spelling
    @State private var wizardSavedWord = ""
    @State private var trainingReplacement = ""
    @State private var privateTrainingCapture: PrivateDirectDictationCapture?
    @State private var trainingSaveID: UUID?
    @State private var trainingVariants: [String] = []
    @State private var manualTrainingSpellings = Set<String>()
    @AppStorage("DictionarySharedFeatureMatcherEnabled", store: PrivateProfileDefaults.shared) private var pronunciationEnabled = DictionaryMatcherExperiment.defaultEnabled
    @State private var pronunciationMatchingEnabled = SettingsStore.shared.pronunciationMatchingEnabled
    @State private var trainingPronunciationEnrollments: [PronunciationEnrollmentCapture] = []
    @State private var savedPronunciationCount = 0
    @State private var trainingSeedID: UUID?
    @State private var seededReplacementKey: String?
    @State private var trainingSourceNotice: String?
    @State private var trainingAcousticCorrection = false
    @State private var trainingSampleCount = 0
    @State private var lastTrainingOutput = ""
    @State private var trainingAttempts: [String] = []
    @State private var lastTrainingOutputIsCovered = false
    @State private var consecutiveCoveredCaptures = 0
    @State private var trainingStatusMessage = "Type the correct text."
    @State private var trainingHasError = false
    @State private var isTrainingActive = false
    @State private var isTrainingStarting = false
    @State private var isTrainingRecording = false
    @State private var trainingStopRequestedDuringStart = false
    @State private var isTrainingProcessing = false
    @State private var isAutomaticTrainingEnabled = false
    @StateObject private var trainingRestart = DictionaryTrainingRestart()
    @State private var isTrainedReplacementButtonHovered = false
    @State private var isTrainedReplacementGlowExpanded = false
    @State private var replacementConfirmation: ReplacementConfirmation?
    @State private var composerMode: DictionaryComposerMode = .train
    @State private var manualSourceWord = ""
    @State private var manualReturnStep: DictionaryWordWizardStep = .spelling
    @State private var manualTriggerDraft = ""
    @State private var manualReplacement = ""
    @State private var manualEntryFocusRequest = 0
    @FocusState private var manualReplacementFocused: Bool
    @State private var isYourDictionaryPresented = false
    @State private var isPunctuationDictionaryPresented = false
    @State private var punctuationAutoConvertEnabled = SettingsStore.shared.autoConvertPunctuationEnabled
    @State private var punctuationPrefix = SettingsStore.shared.punctuationDictionaryPrefix
    @State private var punctuationRules = SettingsStore.shared.punctuationDictionaryRules
    @State private var formattingActionRules = SettingsStore.shared.spokenFormattingActionRules
    @State private var editingFormattingAction: SettingsStore.SpokenFormattingAction?
    @State private var formattingActionAliasesText = ""
    @State private var isFormattingResetAlertPresented = false
    @State private var isPunctuationInfoExpanded = false
    @State private var isPunctuationRuleEditorPresented = false
    @State private var editingPunctuationRuleID: UUID?
    @State private var punctuationAliasesText = ""
    @State private var punctuationSymbolText = ""
    private var normalizedTrainingReplacement: String {
        self.trainingReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var activePronunciationMatching: Bool {
        self.pronunciationEnabled && SettingsStore.shared.selectedSpeechModel.supportsPronunciationMatching
    }

    private var pronunciationMatchingBinding: Binding<Bool> {
        Binding(
            get: { self.activePronunciationMatching },
            set: { self.pronunciationMatchingEnabled = $0 }
        )
    }

    private var trainingTargetReference: String {
        DictionaryTrainingCopy.target(for: self.normalizedTrainingReplacement)
    }

    private var composerModeDetail: String {
        DictionaryTrainingCopy.composerDetail(mode: self.composerMode, target: self.trainingTargetReference)
    }

    private var canUseTrainingRecorderButton: Bool {
        if self.isAutomaticTrainingEnabled {
            return true
        }
        guard !self.trainingStopRequestedDuringStart, !self.isTrainingProcessing else { return false }
        return self.isTrainingRecording || (self.canRecordTrainingSample || self.canRetryTrainingAfterMaximum)
    }

    private var trainingRecorderIsStop: Bool {
        self.isAutomaticTrainingEnabled || self.isTrainingRecording || self.isTrainingStarting
    }

    private var trainingRecorderButtonTitle: String {
        if self.trainingRecorderIsStop {
            return "Stop"
        }
        return self.canRetryTrainingAfterMaximum ? "Try Again" : "Start"
    }

    private var trainingProgress: DictionaryTrainingProgress {
        DictionaryTrainingProgress(
            spellingCount: self.trainingSampleCount,
            pronunciationCount: self.savedPronunciationCount + self.trainingPronunciationEnrollments.count,
            pronunciationEnabled: self.activePronunciationMatching
        )
    }

    private var trainingFinalOutputIsReady: Bool {
        if self.trainingAcousticCorrection {
            return self.trainingProgress.pronunciationReady ||
                (!self.manualTrainingSpellings.isEmpty && self.trainingProgress.spellingReady)
        }
        return self.trainingProgress.spellingReady || self.trainingProgress.pronunciationReady
    }

    private var trainingAlreadyCorrectWithoutReplacement: Bool {
        !self.trainingProgress.pronunciationReady && self.trainingProgress.spellingAlreadyCorrect(
            variants: self.trainingVariants,
            lastOutput: self.lastTrainingOutput,
            target: self.normalizedTrainingReplacement
        )
    }

    private var trainingReadinessProgress: Int {
        if self.activePronunciationMatching {
            return min(self.savedPronunciationCount + self.trainingPronunciationEnrollments.count, CustomDictionaryTrainingMerge.readyCoveredCount)
        }
        guard !self.trainingAlreadyCorrectWithoutReplacement else {
            return CustomDictionaryTrainingMerge.readyCoveredCount
        }
        guard self.trainingOutputIsCovered else { return 0 }
        return min(self.consecutiveCoveredCaptures, CustomDictionaryTrainingMerge.readyCoveredCount)
    }

    private var trainingOutputIsCovered: Bool {
        self.lastTrainingOutputIsCovered || (self.activePronunciationMatching && !self.trainingPronunciationEnrollments.isEmpty)
    }

    private var trainingFinalOutputText: String {
        guard !self.lastTrainingOutput.isEmpty else { return PichiLocalization.text("Record to check") }
        return self.trainingOutputIsCovered ? self.normalizedTrainingReplacement : self.lastTrainingOutput
    }

    private var canRecordTrainingSample: Bool {
        !self.normalizedTrainingReplacement.isEmpty &&
            !self.isTrainingProcessing &&
            !self.asr.isRunning &&
            self.trainingSampleCount < CustomDictionaryTrainingMerge.maxSamples
    }

    private var canRetryTrainingAfterMaximum: Bool {
        !self.normalizedTrainingReplacement.isEmpty &&
            !self.trainingFinalOutputIsReady &&
            !self.trainingAlreadyCorrectWithoutReplacement &&
            !self.isTrainingRecording &&
            !self.isTrainingProcessing &&
            !self.asr.isRunning &&
            self.trainingSampleCount >= CustomDictionaryTrainingMerge.maxSamples
    }

    private var canAddTrainedReplacement: Bool {
        if self.trainingAcousticCorrection && !self.trainingProgress.pronunciationReady && self.manualTrainingSpellings.isEmpty { return false }
        return !self.normalizedTrainingReplacement.isEmpty &&
            (!self.trainingVariants.isEmpty || self.trainingProgress.pronunciationReady) &&
            !self.isTrainingRecording &&
            !self.isTrainingProcessing &&
            self.trainingFinalOutputIsReady
    }

    private var shouldPulseTrainedReplacementButton: Bool {
        self.shouldEmphasizeTrainedReplacementButton &&
            !self.isTrainedReplacementButtonHovered &&
            !self.reduceMotion
    }

    private var manualTriggers: [String] {
        CustomDictionaryManualEntry.normalizedDraftTriggers(self.manualTriggerDraft)
    }

    private var manualDuplicateTriggers: [String] {
        self.manualTriggers.filter { self.allExistingTriggers().contains($0) }
    }

    private var sanitizedManualReplacement: String {
        CustomDictionaryManualEntry.sanitizedReplacement(self.manualReplacement)
    }

    private var canAddManualReplacement: Bool {
        !self.manualTriggers.isEmpty &&
            !self.sanitizedManualReplacement.isEmpty &&
            self.manualDuplicateTriggers.isEmpty
    }

    private var isManualEntryBlocked: Bool {
        self.isTrainingStarting || self.isTrainingRecording || self.isTrainingProcessing || self.isAutomaticTrainingEnabled
    }

    private var punctuationEditorTitle: String {
        self.editingPunctuationRuleID == nil ? "Add Rule" : "Edit Rule"
    }

    private var normalizedPunctuationAliases: [String] {
        SettingsStore.PunctuationDictionaryRule.normalizedAliases(
            self.punctuationAliasesText.components(separatedBy: .newlines)
        )
    }

    private var normalizedPunctuationSymbol: String? {
        SettingsStore.PunctuationDictionaryRule.normalizedSymbol(self.punctuationSymbolText)
    }

    private var canSavePunctuationRule: Bool {
        !self.normalizedPunctuationAliases.isEmpty && self.normalizedPunctuationSymbol != nil
    }

    private var punctuationPreviewPrefix: String {
        SettingsStore.normalizedPunctuationDictionaryPrefix(self.punctuationPrefix) ?? SettingsStore.defaultPunctuationDictionaryPrefix
    }

    private var boostEditorTitle: String {
        self.editingBoostTermIndex == nil ? "Add Word" : "Edit Word"
    }

    private var normalizedBoostTermText: String {
        self.boostTermText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isBoostTermDuplicate: Bool {
        self.existingBoostTerms(excludingIndex: self.editingBoostTermIndex)
            .contains(self.normalizedBoostTermText.lowercased())
    }

    private var canSaveBoostTerm: Bool {
        !self.normalizedBoostTermText.isEmpty && !self.isBoostTermDuplicate
    }

    private enum DictionaryHeaderControlLayout {
        static let controlsWidth: CGFloat = 194
        static let toggleColumnWidth: CGFloat = 54
        static let actionButtonWidth: CGFloat = 128
        static let actionButtonLabelWidth: CGFloat = 104
        static let controlHeight: CGFloat = 36
    }

    var body: some View {
        Group {
            if self.formattingOnly {
                self.punctuationDictionarySection
            } else {
                HStack(spacing: 0) {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
                            if let notice = self.pronunciationRevisionNotice {
                                Text(notice)
                                    .font(self.theme.typography.caption)
                                    .foregroundStyle(self.theme.palette.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            self.trainReplacementSection
                        }
                        .fluidPageContent(width: .reading, alignment: .center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    self.wordDrawer
                        .frame(width: 240)
                        .frame(maxHeight: .infinity)
                        .transaction { $0.animation = nil }
                        .frame(width: self.isWordDrawerPresented ? 240 : 0, alignment: .trailing)
                        .clipped()
                        .background {
                            Rectangle()
                                .fill(self.theme.palette.sidebarBackground)
                                .ignoresSafeArea(.container, edges: [.top, .bottom])
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(self.theme.palette.separator)
                                .frame(width: 1)
                                .ignoresSafeArea(.container, edges: [.top, .bottom])
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                        .allowsHitTesting(self.isWordDrawerPresented)
                        .disabled(!self.isWordDrawerPresented)
                        .accessibilityElement(children: .contain)
                        .accessibilityHidden(!self.isWordDrawerPresented)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(self.drawerAnimation, value: self.isWordDrawerPresented)
            }
        }
        .fluidPageActions(enabled: !self.formattingOnly) {
            self.dictionaryDrawerToggle
        }
        .dismissTextFocusOnBackgroundTap()
        .task(id: self.revealTarget) {
            self.revealSearchTarget()
        }
        .task(id: self.trainingRequest?.id) {
            await self.consumeTrainingRequest()
        }
        .task(id: self.pronunciationRevisionNoticeRequest) {
            self.pronunciationRevisionNotice = nil
            guard !self.formattingOnly,
                  let descriptor = self.modelInstallations.installedDescriptor(for: self.settings.selectedSpeechModel),
                  descriptor.variant == .mini || descriptor.variant == .pico
            else { return }
            let entryIDs = Set(self.settings.customDictionaryEntries.map(\.id))
            let profiles = await PronunciationDictionaryStore.shared.allProfiles()
            guard !Task.isCancelled,
                  descriptor.pronunciationModelKey == self.modelInstallations.installedDescriptor(for: self.settings.selectedSpeechModel)?.pronunciationModelKey
            else { return }
            self.pronunciationRevisionNotice = DictionaryPronunciationRevisionPolicy.notice(profiles: profiles, descriptor: descriptor, entryIDs: entryIDs)
        }
        .overlay {
            if let confirmation = self.replacementConfirmation {
                ReplacementConfirmationToast(confirmation: confirmation)
                    .padding(self.theme.metrics.spacing.xl)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .sheet(item: self.$editingEntry) { entry in
            EditDictionaryEntrySheet(
                entry: entry,
                existingTriggers: self.allExistingTriggers(excluding: entry.id),
                isCaptureBusy: self.asr.isRunning || self.isTrainingStarting || self.isTrainingRecording || self.isTrainingProcessing || self.isAutomaticTrainingEnabled
            ) { updatedEntry in
                guard self.isProfileVisible else { return }
                let pronunciationStore = PronunciationDictionaryStore.shared
                if let index = self.entries.firstIndex(where: { $0.id == updatedEntry.id }) {
                    self.entries[index] = updatedEntry
                    self.saveEntries()
                    Task {
                        guard self.isProfileVisible else { return }
                        if PronunciationProfileEditPolicy.shouldDiscardProfile(
                            previousReplacement: entry.replacement,
                            updatedReplacement: updatedEntry.replacement
                        ) {
                            try? await pronunciationStore.delete(dictionaryEntryID: updatedEntry.id)
                        } else {
                            try? await pronunciationStore.updateLabel(
                                dictionaryEntryID: updatedEntry.id,
                                label: updatedEntry.replacement
                            )
                        }
                    }
                }
            }
        }
        .onAppear {
            if !self.formattingOnly {
                self.entries = SettingsStore.shared.customDictionaryEntries
                self.loadBoostTerms()
                self.pronunciationMatchingEnabled = SettingsStore.shared.pronunciationMatchingEnabled
            }
            self.punctuationAutoConvertEnabled = SettingsStore.shared.autoConvertPunctuationEnabled
            self.formattingActionRules = SettingsStore.shared.spokenFormattingActionRules
        }
        .onReceive(NotificationCenter.default.publisher(for: .parakeetVocabularyDidChange)) { _ in
            guard !self.formattingOnly else { return }
            self.entries = SettingsStore.shared.customDictionaryEntries
            self.pronunciationRevisionNoticeRefresh &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsBackupDidRestore)) { _ in
            guard !self.formattingOnly else { return }
            self.pronunciationRevisionNoticeRefresh &+= 1
        }
        .onReceive(self.asr.$isDictionaryTrainingCaptureActive.removeDuplicates().dropFirst()) { active in
            guard !self.formattingOnly, !active else { return }
            self.handleTrainingCaptureEndedElsewhere()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            guard self.trainingRestart.isWaiting else { return }
            self.trainingRestart.cancel()
            self.isAutomaticTrainingEnabled = false
        }
        .onChange(of: self.pronunciationEnabled) { _, enabled in
            guard !enabled else { return }
            self.trainingRestart.cancel()
            self.isAutomaticTrainingEnabled = false
            self.trainingPronunciationEnrollments = []
            if self.trainingSaveID != nil {
                self.trainingSaveID = nil
                self.isTrainingProcessing = false
                self.trainingHasError = true
                self.trainingStatusMessage = "Pronunciation learning was turned off. Try saving your spelling corrections again."
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: PrivateProfileService.willConceal)) { _ in
            self.trainingRequest = nil
            if self.trainingSeedID != nil { self.isTrainingProcessing = false }
            self.trainingSeedID = nil
            self.trainingSourceNotice = nil
            self.trainingPronunciationEnrollments = []
            self.savedPronunciationCount = 0
            self.trainingRestart.cancel()
            self.isAutomaticTrainingEnabled = false
            self.editingEntry = nil
            self.isDrawerActionsPresented = false
            self.isCustomWordsPresented = false
            self.isYourDictionaryPresented = false
            self.isPunctuationDictionaryPresented = false
        }
        .onDisappear {
            if self.trainingSeedID != nil { self.isTrainingProcessing = false }
            self.trainingSeedID = nil
            self.trainingRestart.cancel()
            guard self.isProfileVisible, !self.formattingOnly else { return }
            if self.trainingSaveID != nil {
                self.trainingSaveID = nil
                self.isTrainingProcessing = false
            }
            self.isAutomaticTrainingEnabled = false
            DictionaryTrainingEndpointMonitor.shared.stop()
            guard self.isTrainingRecording else { return }
            Task { @MainActor in
                await self.stopTrainingSample()
            }
        }
    }

    // MARK: - Page Header

    private var drawerAnimation: Animation? {
        self.reduceMotion ? nil : .timingCurve(0.22, 0.8, 0.25, 1, duration: 0.34)
    }

    private var dictionaryDrawerToggle: some View {
        Button {
            self.isDrawerActionsPresented = false
            withAnimation(self.drawerAnimation) { self.isWordDrawerPresented.toggle() }
        } label: {
            Label("Your Dictionary", systemImage: self.isWordDrawerPresented ? "rectangle.righthalf.inset.filled" : "sidebar.right")
                .foregroundStyle(self.isWordDrawerPresented ? self.theme.palette.accentText : self.theme.palette.primaryText)
        }

        .accessibilityLabel(PichiLocalization.text(self.isWordDrawerPresented ? "Collapse your dictionary" : "Expand your dictionary"))
        .help(PichiLocalization.text(self.isWordDrawerPresented ? "Collapse your dictionary" : "Expand your dictionary"))
    }

    private var drawerEntries: [SettingsStore.CustomDictionaryEntry] {
        self.entries.filter {
            self.wordSearch.isEmpty || $0.replacement.localizedCaseInsensitiveContains(self.wordSearch)
                || $0.triggers.contains { $0.localizedCaseInsensitiveContains(self.wordSearch) }
        }
    }

    private var wordDrawer: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
            HStack(alignment: .center, spacing: 8) {
                Text("Your dictionary").font(self.theme.typography.sectionTitle)
                Spacer()
                FluidGlassControlGroup {
                    HStack(spacing: 8) {
                        Button(action: self.openNewManualDictionaryEntry) {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 18, height: 18)
                        }
                        .fluidGlassAction(circular: true, quiet: true)
                        .disabled(self.isManualEntryBlocked)
                        .accessibilityLabel("Add word")
                        .help(PichiLocalization.text(self.isManualEntryBlocked ? "Finish the current word recording or save first" : "Add a word manually"))
                        Button { self.isDrawerActionsPresented.toggle() } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 18, height: 18)
                        }
                        .fluidGlassAction(circular: true, quiet: true)
                        .accessibilityLabel("Dictionary actions")
                        .popover(isPresented: self.$isDrawerActionsPresented) {
                            VStack(alignment: .leading, spacing: 12) {
                                Button("Import…") {
                                    self.isDrawerActionsPresented = false
                                    self.importDictionary()
                                }.fluidGlassAction()
                                Button("Export…") {
                                    self.isDrawerActionsPresented = false
                                    self.exportDictionary()
                                }.fluidGlassAction()
                                Divider()
                                Button("Custom Words (Advanced)…") {
                                    self.isDrawerActionsPresented = false
                                    self.presentCustomWords()
                                }.fluidGlassAction()
                            }
                            .padding(16)
                            .foregroundStyle(self.theme.palette.primaryText)
                            .background(self.theme.palette.cardBackground)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(self.theme.palette.secondaryText)
                TextField("Search words", text: self.$wordSearch)
                    .textFieldStyle(.plain)
            }
            .font(self.theme.typography.bodySmall)
            .padding(10)
            .background(self.theme.palette.contentBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(self.theme.palette.cardBorder.opacity(0.4)))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                    ForEach(self.drawerEntries) { entry in
                        DictionaryDrawerEntryRow(
                            entry: entry,
                            isTestDisabled: self.asr.isRunning || self.isManualEntryBlocked,
                            onTest: {
                                guard !self.asr.isRunning, !self.isManualEntryBlocked else { return }
                                self.wizardSavedWord = entry.replacement
                                self.wizardStep = .saved
                                self.isWordDrawerPresented = false
                            },
                            onEdit: { self.editingEntry = entry },
                            onDelete: { self.drawerDeletion = entry }
                        )
                        .contextMenu {
                            Button("Edit…") { self.editingEntry = entry }
                            Button("Record pronunciation") { self.recordMorePronunciations(for: entry) }
                                .disabled(self.isManualEntryBlocked || !self.activePronunciationMatching)
                            Button("Remove word", role: .destructive) { self.drawerDeletion = entry }
                        }
                        Divider().opacity(0.3)
                    }
                    if self.drawerEntries.isEmpty {
                        Text(PichiLocalization.text(self.wordSearch.isEmpty ? "Add a word to see it here." : "No matching words."))
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.theme.palette.secondaryText)
                            .padding(.vertical, self.theme.metrics.spacing.lg)
                    }
                }
            }
            Text(self.wordSearch.isEmpty ? PichiLocalization.format("%lld saved words", self.entries.count) : PichiLocalization.format("%lld of %lld words", self.drawerEntries.count, self.entries.count))
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
        }
        .padding(self.theme.metrics.spacing.lg)
        .padding(.top, 8)
        .alert("Remove word?", isPresented: Binding(
            get: { self.drawerDeletion != nil },
            set: { if !$0 { self.drawerDeletion = nil } }
        )) {
            Button("Cancel", role: .cancel) { self.drawerDeletion = nil }
            Button("Remove", role: .destructive) {
                if let entry = self.drawerDeletion { self.deleteEntry(entry) }
                self.drawerDeletion = nil
            }
        } message: {
            Text("This removes the saved corrections and pronunciation for this word.")
        }
        .popover(isPresented: self.$isCustomWordsPresented) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                Toggle("Custom Words Boosting", isOn: self.$vocabBoostingEnabled)
                    .onChange(of: self.vocabBoostingEnabled) { _, enabled in
                        if self.isProfileVisible { SettingsStore.shared.vocabularyBoostingEnabled = enabled }
                    }
                self.customWordsPopover
            }
            .padding(self.theme.metrics.spacing.md)
            .foregroundStyle(self.theme.palette.primaryText)
            .background(self.theme.palette.cardBackground)
        }
    }

    private func settingsIconTile(systemName: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.82))
                .overlay(
                    LinearGradient(
                        colors: [.white.opacity(0.1), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(self.theme.palette.accent.opacity(0.35), lineWidth: 1)
                )

            Image(systemName: systemName)
                .font(.fluidSystem(size: 15, weight: .semibold))
                .foregroundStyle(self.theme.palette.accentText)
        }
        .frame(width: 34, height: 34)
    }

    private var trainReplacementSection: some View {
        ThemedCard(style: .standard, hoverEffect: false) {
            if self.wizardStep == .manual {
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
                    Button { self.wizardStep = self.manualReturnStep } label: {
                        Label("Back", systemImage: "chevron.left")
                    }.fluidGlassAction()
                    Text("Add a correction").font(self.theme.typography.sectionTitle)
                    Text(AppBrand.text("When FluidVoice types the wrong version, we’ll change it to your word."))
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.theme.palette.secondaryText)
                    self.manualReplacementComposer
                }
            } else {
                if let notice = self.trainingSourceNotice {
                    Text(PichiLocalization.text(notice))
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if self.trainingAcousticCorrection {
                    Text("Pronunciation examples do not create fixed text replacements. Add a spelling manually to request one.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DictionaryWordWizard(
                    word: self.$trainingReplacement,
                    step: self.wizardStep,
                    count: self.trainingSampleCount,
                    heard: self.lastTrainingOutput,
                    variants: self.trainingVariants,
                    busy: self.isTrainingRecording || self.isTrainingProcessing || self.isTrainingStarting || self.trainingRestart.isWaiting,
                    recording: self.isTrainingRecording,
                    processing: self.isTrainingProcessing || self.isTrainingStarting,
                    starting: self.isTrainingStarting,
                    error: self.trainingHasError ? self.trainingStatusMessage : nil,
                    voiceSupported: self.activePronunciationMatching,
                    alreadyCorrect: self.trainingAlreadyCorrectWithoutReplacement,
                    savedWord: self.wizardSavedWord,
                    onContinue: {
                        let captures = self.trainingSampleCount
                        self.wizardStep = captures >= 3 ? .review : .recording
                    },
                    onRecord: {
                        self.wizardStep = .recording
                        Task { await self.startAutomaticTrainingIfIdle() }
                    },
                    onSave: {
                        Task { await self.addTrainedReplacement() }
                    },
                    onBack: { self.wizardStep = .spelling },
                    onNewWord: self.startNewDictionaryWord,
                    onManual: {
                        self.manualReturnStep = self.wizardStep
                        if self.manualSourceWord != self.normalizedTrainingReplacement || self.manualReplacement.isEmpty {
                            self.manualSourceWord = self.normalizedTrainingReplacement
                            self.manualReplacement = self.normalizedTrainingReplacement
                            self.manualTriggerDraft = self.trainingVariants.joined(separator: ", ")
                        }
                        self.wizardStep = .manual
                    },
                    onPracticeMore: {
                        self.trainingReplacement = self.wizardSavedWord
                        self.wizardStep = .recording
                    },
                    onRedo: {
                        guard !self.isTrainingRecording, !self.isTrainingProcessing, !self.isTrainingStarting else { return }
                        self.resetTraining(keepingWord: true)
                        self.wizardStep = .recording
                    },
                    wordFocusRequest: self.newWordFocusRequest,
                    automaticCaptureActive: self.isAutomaticTrainingEnabled,
                    waiting: self.trainingRestart.isWaiting,
                    canSave: self.canAddTrainedReplacement || self.trainingAlreadyCorrectWithoutReplacement,
                    onPauseRecording: { Task { await self.pauseAutomaticTraining() } },
                    onAddSpelling: self.addManualTrainingSpelling,
                    onRemoveSpelling: self.removeTrainingVariant,
                    audioLevels: self.asr.audioLevelPublisher,
                    pronunciationNotice: self.trainingProgress.pronunciationNotice,
                    pronunciationIncomplete: self.activePronunciationMatching && !self.trainingProgress.pronunciationReady,
                    attempts: self.trainingAttempts,
                    savedPronunciationCount: self.savedPronunciationCount
                )
                .onChange(of: self.trainingReplacement) { oldValue, newValue in
                    self.handleTrainingReplacementChange(oldValue: oldValue, newValue: newValue)
                }
                .task { await DictionaryTrainingEndpointMonitor.shared.prepare() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dictionaryComposerModePicker: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            self.dictionaryComposerModeSegmented

            Text(PichiLocalization.text(self.composerModeDetail))
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dictionaryComposerModeSegmented: some View {
        HStack(spacing: 2) {
            ForEach(DictionaryComposerMode.allCases) { mode in
                DictionaryComposerModeTab(
                    mode: mode,
                    isSelected: self.composerMode == mode,
                    isDisabled: self.isTrainingRecording || self.isTrainingProcessing
                ) {
                    self.selectComposerMode(mode)
                }
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private var trainReplacementComposer: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            TextField(AppBrand.text("Type the correct text, e.g. FluidVoice"), text: self.$trainingReplacement)
                .dictionaryInputChrome()
                .disabled(self.isTrainingRecording || self.isTrainingProcessing)
                .onChange(of: self.trainingReplacement) { oldValue, newValue in
                    self.handleTrainingReplacementChange(oldValue: oldValue, newValue: newValue)
                }

            self.voiceMatchingSettingsRow

            self.trainingRecorderPanel

            self.trainingFinalOutputPanel

            if !self.trainingVariants.isEmpty {
                self.trainingHeardSection
            }

            self.trainingFooter

            Spacer(minLength: 0)

            Button {
                Task { await self.addTrainedReplacement() }
            } label: {
                Label(
                    PichiLocalization.text(self.trainedReplacementButtonTitle),
                    systemImage: self.shouldEmphasizeTrainedReplacementButton
                        ? "sparkles"
                        : (self.trainingAlreadyCorrectWithoutReplacement ? "checkmark" : "plus")
                )
                .frame(maxWidth: .infinity)
                .frame(height: 38)
            }
            .fluidButton(self.shouldEmphasizeTrainedReplacementButton ? .accent : .compact, size: .small)
            .disabled(!self.canAddTrainedReplacement)
            .overlay(self.trainedReplacementButtonReadyOutline)
            .shadow(
                color: self.shouldEmphasizeTrainedReplacementButton
                    ? self.theme.palette.accent.opacity(self.isTrainedReplacementGlowExpanded ? 0.34 : 0.14)
                    : .clear,
                radius: self.shouldEmphasizeTrainedReplacementButton
                    ? (self.isTrainedReplacementGlowExpanded ? 18 : 8)
                    : 0,
                x: 0,
                y: 4
            )
            .onHover { self.isTrainedReplacementButtonHovered = $0 }
            .onAppear { self.updateTrainedReplacementGlow() }
            .onChange(of: self.shouldPulseTrainedReplacementButton) { _, _ in
                self.updateTrainedReplacementGlow()
            }
        }
        .task {
            await DictionaryTrainingEndpointMonitor.shared.prepare()
        }
    }

    private var trainedReplacementButtonReadyOutline: some View {
        RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
            .stroke(
                self.shouldEmphasizeTrainedReplacementButton ? self.theme.palette.success.opacity(0.72) : .clear,
                lineWidth: 1.5
            )
            .padding(-3)
            .allowsHitTesting(false)
    }

    private var manualReplacementComposer: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: self.theme.metrics.spacing.md) {
                    self.manualTriggerField
                    self.manualReplacementField
                }

                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                    self.manualTriggerField
                    self.manualReplacementField
                }
            }

            if !self.manualDuplicateTriggers.isEmpty {
                Label("Already used: \(self.manualDuplicateTriggers.joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.warning)
            }

            if !self.manualTriggers.isEmpty || !self.manualReplacement.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(self.manualTriggers, id: \.self) { trigger in
                        DictionaryPreviewChip(text: trigger)
                    }

                    Image(systemName: "arrow.right")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.tertiaryText)

                    Text(CustomDictionaryManualEntry.replacementDisplayText(self.sanitizedManualReplacement))
                        .font(self.theme.typography.captionStrong)
                        .foregroundStyle(self.theme.palette.accentText)
                }
            }

            Spacer(minLength: 0)

            Button {
                self.addManualReplacementIfValid()
            } label: {
                Label("Save correction", systemImage: "checkmark")
            }
            .fluidGlassAction(prominent: true, tone: self.theme.palette.accent)
            .disabled(!self.canAddManualReplacement)
        }
    }

    private var manualTriggerField: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            Text("Replace")
                .font(self.theme.typography.captionStrong)

            TextField("fluid voice, fluid boys", text: self.$manualTriggerDraft)
                .dictionaryInputChrome()
                .accessibilityLabel("Text to replace")
                .onSubmit { self.addManualReplacementIfValid() }

            Text("Separate different versions with commas. Enter only commas to replace comma punctuation.")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
        }
    }

    private var manualReplacementField: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            Text("With")
                .font(self.theme.typography.captionStrong)
            TextField(AppBrand.text("FluidVoice"), text: self.$manualReplacement)
                .dictionaryInputChrome()
                .focused(self.$manualReplacementFocused)
                .accessibilityLabel("Correct spelling")
                .onSubmit { self.addManualReplacementIfValid() }
                .task(id: self.manualEntryFocusRequest) {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    self.manualReplacementFocused = true
                }
            Text("The spelling you want in your transcription.")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
        }
    }

    private var voiceMatchingSettingsRow: some View {
        Text(PichiLocalization.text(self.pronunciationEnabled
            ? "Pronunciation dictionary is on. Voice training uses the fast sound-order matcher."
            : "Voice training is off. Enable “Learn from your pronunciation” in Settings → Experimental."))
            .font(self.theme.typography.caption)
            .foregroundStyle(self.theme.palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var pronunciationRevisionNoticeRequest: String {
        "\(self.settings.selectedSpeechModel.rawValue):\(self.modelInstallations.installedArchiveHashes[self.settings.selectedSpeechModel.id] ?? ""): \(self.pronunciationRevisionNoticeRefresh)"
    }

    private var trainingRecorderPanel: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
            Text(AppBrand.text("Teach FluidVoice your pronunciation"))
                .font(self.theme.typography.bodySmallStrong)

            if self.trainingAlreadyCorrectWithoutReplacement {
                Label("\(self.trainingTargetReference) is already recognized correctly.", systemImage: "checkmark.circle.fill")
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(self.theme.palette.accentText)
            } else if self.trainingFinalOutputIsReady {
                Label(
                    self.activePronunciationMatching
                        ? PichiLocalization.format("Voice profile for %@ captured 3 times.", self.trainingTargetReference)
                        : PichiLocalization.text("The last 3 recordings are covered by this correction."),
                    systemImage: "checkmark.circle.fill"
                )
                .font(self.theme.typography.captionStrong)
                .foregroundStyle(self.theme.palette.accentText)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    self.trainingInstruction(
                        number: 1,
                        text: "Type the correct word you want to teach in the box above."
                    )
                    self.trainingInstruction(
                        number: 2,
                        text: "Press Start once."
                    )
                    self.trainingInstruction(
                        number: 3,
                        text: AppBrand.format("Say %@ naturally, then pause. FluidVoice records and listens again automatically.", self.trainingTargetReference)
                    )
                    self.trainingInstruction(
                        number: 4,
                        text: self.activePronunciationMatching
                            ? "Repeat 3 times to capture pronunciation samples."
                            : "Keep repeating it until the circle reaches 3/3."
                    )
                }
            }

            HStack(spacing: self.theme.metrics.spacing.md) {
                DictionaryTrainingReadinessRing(
                    progress: self.trainingReadinessProgress,
                    total: CustomDictionaryTrainingMerge.readyCoveredCount,
                    isReady: self.trainingFinalOutputIsReady || self.trainingAlreadyCorrectWithoutReplacement,
                    usesVoiceMatching: self.activePronunciationMatching
                )

                Text(self.trainingReadinessCaption)
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(
                        self.trainingFinalOutputIsReady
                            ? self.theme.palette.accent
                            : self.theme.palette.secondaryText
                    )
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                Button {
                    Task { await self.toggleAutomaticTraining() }
                } label: {
                    Label(
                        PichiLocalization.text(self.trainingRecorderButtonTitle),
                        systemImage: self.trainingRecorderIsStop ? "stop.fill" : "mic.fill"
                    )
                }
                .fluidButton(self.trainingRecorderIsStop ? .destructive : .accent, size: .small)
                .disabled(!self.canUseTrainingRecorderButton)
            }
        }
        .padding(self.theme.metrics.spacing.md)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(
                            self.trainingFinalOutputIsReady
                                ? self.theme.palette.accent.opacity(0.26)
                                : self.theme.palette.cardBorder.opacity(0.25),
                            lineWidth: 1
                        )
                )
        )
    }

    private var trainingReadinessCaption: String {
        DictionaryTrainingCopy.readinessCaption(
            target: self.trainingTargetReference,
            isAlreadyCorrect: self.trainingAlreadyCorrectWithoutReplacement,
            isReady: self.trainingFinalOutputIsReady,
            usesVoiceMatching: self.activePronunciationMatching
        )
    }

    private var trainingHeardSection: some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            Text("Captured")
                .font(self.theme.typography.captionStrong)
                .foregroundStyle(self.theme.palette.secondaryText)

            HStack(spacing: 6) {
                ForEach(Array(self.trainingVariants.prefix(5).enumerated()), id: \.element) { index, variant in
                    TrainingVariantChip(number: index + 1, variant: variant) {
                        self.removeTrainingVariant(variant)
                    }
                }

                if self.trainingVariants.count > 5 {
                    Text("+\(self.trainingVariants.count - 5)")
                        .font(self.theme.typography.captionStrong)
                        .foregroundStyle(self.theme.palette.tertiaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(self.theme.palette.cardBackground.opacity(0.65))
                        )
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, self.theme.metrics.spacing.md)
        .padding(.vertical, self.theme.metrics.spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private var trainingFinalOutputPanel: some View {
        HStack(alignment: .center, spacing: self.theme.metrics.spacing.md) {
            VStack(alignment: .leading, spacing: 5) {
                Text(PichiLocalization.text(self.activePronunciationMatching ? "Spelling to save" : "Final output"))
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(self.theme.palette.secondaryText)

                Text(self.activePronunciationMatching ? self.normalizedTrainingReplacement : self.trainingFinalOutputText)
                    .font(self.theme.typography.bodySmallStrong)
                    .foregroundStyle(self.lastTrainingOutput.isEmpty ? self.theme.palette.tertiaryText : self.theme.palette.primaryText)
                    .lineLimit(1)

                if !self.lastTrainingOutput.isEmpty, self.lastTrainingOutput.caseInsensitiveCompare(self.trainingFinalOutputText) != .orderedSame {
                    Text("Heard: \(self.lastTrainingOutput)")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.tertiaryText)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.horizontal, self.theme.metrics.spacing.md)
        .padding(.vertical, self.theme.metrics.spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.42))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(
                            self.trainingFinalOutputIsReady ? self.theme.palette.success.opacity(0.28) : self.theme.palette.cardBorder.opacity(0.22),
                            lineWidth: 1
                        )
                )
        )
    }

    @ViewBuilder
    private var trainingFooter: some View {
        if self.trainingHasError || self.isTrainingActive || !self.trainingVariants.isEmpty {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                if self.trainingHasError {
                    Label(PichiLocalization.text(self.trainingStatusMessage), systemImage: "exclamationmark.triangle.fill")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.warning)
                }

                if self.isTrainingActive || !self.trainingVariants.isEmpty || !self.normalizedTrainingReplacement.isEmpty {
                    Spacer()

                    Button("Clear") {
                        self.resetTraining()
                    }
                    .fluidButton(.compact, size: .compact)
                    .disabled(self.isTrainingRecording || self.isTrainingProcessing)
                } else {
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Your Dictionary

    private var yourDictionarySection: some View {
        ThemedCard(style: .standard, hoverEffect: false) {
            HStack(alignment: .center, spacing: self.theme.metrics.spacing.md) {
                self.settingsIconTile(systemName: "book.closed.fill")

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Your Dictionary")
                            .font(self.theme.typography.sectionTitle)
                        if !self.entries.isEmpty {
                            Text("(\(self.entries.count))")
                                .font(self.theme.typography.captionSmall)
                                .foregroundStyle(self.theme.palette.tertiaryText)
                        }
                    }
                    Text(AppBrand.text("Words and phrases FluidVoice will correct automatically."))
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                self.yourDictionaryControls
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var yourDictionaryControls: some View {
        HStack(alignment: .center, spacing: self.theme.metrics.spacing.md) {
            Button {
                self.presentYourDictionary()
            } label: {
                Label("Modify", systemImage: "slider.horizontal.3")
            }
            .fluidGlassAction()
            .help("Modify dictionary replacements")
            .popover(isPresented: self.$isYourDictionaryPresented, arrowEdge: .top) {
                self.yourDictionaryPopover
            }

            Color.clear
                .frame(width: Self.DictionaryHeaderControlLayout.toggleColumnWidth)
                .accessibilityHidden(true)
        }
        .frame(width: Self.DictionaryHeaderControlLayout.controlsWidth, height: Self.DictionaryHeaderControlLayout.controlHeight, alignment: .leading)
    }

    private var punctuationDictionarySection: some View {
        ThemedCard(style: .standard, hoverEffect: false) {
            HStack(alignment: .center, spacing: self.theme.metrics.spacing.md) {
                self.settingsIconTile(systemName: "textformat")

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Spoken Formatting")
                            .font(self.theme.typography.sectionTitle)
                        Text("\(SettingsStore.SpokenFormattingAction.allCases.count) actions · \(self.punctuationRules.count) punctuation")
                            .font(self.theme.typography.captionSmall)
                            .foregroundStyle(self.theme.palette.tertiaryText)
                    }
                    Text("Use a start word to safely insert formatting actions, punctuation, and symbols.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                self.punctuationDictionaryControls
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var punctuationDictionaryControls: some View {
        HStack(alignment: .center, spacing: self.theme.metrics.spacing.md) {
            Button {
                self.presentPunctuationDictionary()
            } label: {
                Label("Modify", systemImage: "slider.horizontal.3")
                    .frame(width: Self.DictionaryHeaderControlLayout.actionButtonLabelWidth)
            }
            .frame(width: Self.DictionaryHeaderControlLayout.actionButtonWidth)
            .fluidButton(.compact, size: .medium)
            .help("Modify spoken formatting")
            .popover(isPresented: self.$isPunctuationDictionaryPresented, arrowEdge: .top) {
                self.punctuationDictionaryPopover
            }

            self.punctuationDictionaryToggle
        }
        .frame(width: Self.DictionaryHeaderControlLayout.controlsWidth, height: Self.DictionaryHeaderControlLayout.controlHeight, alignment: .leading)
    }

    private var punctuationDictionaryToggle: some View {
        Toggle("Spoken Formatting", isOn: self.$punctuationAutoConvertEnabled)
            .labelsHidden()
            .toggleStyle(.switch)
            .onChange(of: self.punctuationAutoConvertEnabled) { _, newValue in
                if self.isProfileVisible { SettingsStore.shared.autoConvertPunctuationEnabled = newValue }
            }
            .frame(width: Self.DictionaryHeaderControlLayout.toggleColumnWidth, alignment: .trailing)
            .help("Turn Spoken Formatting on or off.")
    }

    private var entriesListView: some View {
        VStack(spacing: self.theme.metrics.spacing.sm) {
            ForEach(self.entries) { entry in
                DictionaryEntryRow(
                    entry: entry,
                    onEdit: {
                        self.closeYourDictionary()
                        self.editingEntry = entry
                    },
                    onDelete: { self.deleteEntry(entry) }
                )
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var yourDictionaryPopover: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            HStack(alignment: .top, spacing: self.theme.metrics.spacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your Dictionary")
                        .font(self.theme.typography.sectionTitle)

                    Text(AppBrand.text("FluidVoice automatically corrects these words and phrases."))
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }

                Spacer()

                Button {
                    self.closeYourDictionary()
                } label: {
                    Image(systemName: "xmark")
                        .font(.fluidSystem(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(SquareIconButtonStyle())
                .help("Close")
            }

            self.yourDictionaryHelpNote

            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Saved Replacements")
                        .font(self.theme.typography.captionStrong)
                    Text("These run automatically after dictation.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }

                if self.entries.isEmpty {
                    self.dictionaryEmptyState(
                        title: "No replacements yet",
                        detail: "Add your first word using the guided steps."
                    )
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        self.entriesListView
                    }
                    .frame(maxHeight: 235)
                }
            }
        }
        .padding(self.theme.metrics.spacing.lg)
        .frame(width: 640, alignment: .leading)
        .foregroundStyle(self.theme.palette.primaryText)
        .background(self.theme.palette.cardBackground)
    }

    private var yourDictionaryHelpNote: some View {
        Label {
            Text("Add a word using the guided steps. You can record your voice or enter a known mistake.")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
        } icon: {
            Image(systemName: "info.circle")
                .font(.fluidSystem(size: 12, weight: .semibold))
                .foregroundStyle(self.theme.palette.accentText)
        }
        .padding(self.theme.metrics.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.25), lineWidth: 1)
                )
        )
    }

    // MARK: - Custom Words

    private var aiPostProcessingSection: some View {
        ThemedCard(style: .standard, hoverEffect: false) {
            HStack(alignment: .center, spacing: self.theme.metrics.spacing.md) {
                self.settingsIconTile(systemName: "character.book.closed")

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Custom Words")
                            .font(self.theme.typography.sectionTitle)
                        if !self.boostTerms.isEmpty {
                            Text("(\(self.boostTerms.count))")
                                .font(self.theme.typography.captionSmall)
                                .foregroundStyle(self.theme.palette.tertiaryText)
                        }
                    }
                    Text("Help the Parakeet voice engine recognize names, products, and uncommon terms.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                self.customWordsControls
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var customWordsControls: some View {
        HStack(alignment: .center, spacing: self.theme.metrics.spacing.md) {
            Button {
                self.presentCustomWords()
            } label: {
                Label("Modify", systemImage: "slider.horizontal.3")
            }
            .fluidGlassAction()
            .disabled(!self.vocabBoostingEnabled)
            .help(PichiLocalization.text(self.vocabBoostingEnabled ? "Modify custom words" : "Turn on Boosting to modify custom words."))
            .popover(isPresented: self.$isCustomWordsPresented, arrowEdge: .top) {
                self.customWordsPopover
            }

            self.customWordsBoostingToggle
        }
        .frame(width: Self.DictionaryHeaderControlLayout.controlsWidth, height: Self.DictionaryHeaderControlLayout.controlHeight, alignment: .leading)
    }

    private var customWordsBoostingToggle: some View {
        Toggle("Custom Words Boosting", isOn: self.$vocabBoostingEnabled)
            .labelsHidden()
            .toggleStyle(.switch)
            .onChange(of: self.vocabBoostingEnabled) { _, newValue in
                if self.isProfileVisible { SettingsStore.shared.vocabularyBoostingEnabled = newValue }
            }
            .frame(width: Self.DictionaryHeaderControlLayout.toggleColumnWidth, alignment: .trailing)
            .help("Improve recognition of your custom words when using Parakeet.")
    }

    private var customWordsPopover: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            HStack(alignment: .top, spacing: self.theme.metrics.spacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom Words")
                        .font(self.theme.typography.sectionTitle)

                    Text("Best for rare names and terms that sound different from everyday words.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }

                Spacer()

                Button {
                    self.closeCustomWords()
                } label: {
                    Image(systemName: "xmark")
                        .font(.fluidSystem(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .fluidGlassAction(circular: true)
                .help("Close")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Use cautiously")
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(self.theme.palette.primaryText)
                Text(AppBrand.text("FluidVoice may sometimes use these words when you meant something similar."))
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if self.isBoostWordEditorPresented {
                self.boostWordEditor
            } else {
                HStack {
                    Button {
                        self.startAddingBoostTerm()
                    } label: {
                        Label("Add Word", systemImage: "plus")
                    }
                    .fluidGlassAction(prominent: true, tone: self.theme.palette.accent)

                    Spacer()
                }
            }

            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Saved Words")
                        .font(self.theme.typography.captionStrong)
                    Text("These words get extra recognition help while Boosting is enabled.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }

                if self.boostTerms.isEmpty {
                    self.dictionaryEmptyState(
                        title: "No custom words yet",
                        detail: "Add a name or term that needs a little extra recognition help."
                    )
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: self.theme.metrics.spacing.sm) {
                            ForEach(Array(self.boostTerms.enumerated()), id: \.offset) { index, term in
                                BoostTermRow(
                                    term: term,
                                    onEdit: {
                                        self.editBoostTerm(at: index)
                                    },
                                    onDelete: {
                                        self.deleteBoostTerm(at: index)
                                    }
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 235)
                }
            }

            if self.boostHasError {
                Label(PichiLocalization.text(self.boostStatusMessage), systemImage: "exclamationmark.triangle.fill")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.warning)
            }
        }
        .padding(self.theme.metrics.spacing.lg)
        .frame(width: 640, alignment: .leading)
        .foregroundStyle(self.theme.palette.primaryText)
        .background(self.theme.palette.cardBackground)
        .onDisappear {
            self.dismissBoostTermEditor()
        }
    }

    private var boostWordEditor: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
            Text(PichiLocalization.text(self.boostEditorTitle))
                .font(self.theme.typography.captionStrong)

            VStack(alignment: .leading, spacing: 6) {
                Text("Word or Phrase")
                    .font(self.theme.typography.captionStrong)
                TextField(AppBrand.text("FluidVoice"), text: self.$boostTermText)
                    .font(self.theme.typography.bodySmall)
                    .dictionaryInputChrome()
                    .onSubmit { self.saveBoostTermIfValid() }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Word Priority")
                    .font(self.theme.typography.captionStrong)
                FluidSegmentedPicker(title: "Word Priority", options: BoostStrengthPreset.allCases.map {
                    (value: $0, title: PichiLocalization.text($0.rawValue))
                }, selection: self.$boostTermStrength)
                Text(PichiLocalization.text(self.boostTermStrength.hint))
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }

            if self.isBoostTermDuplicate {
                Text("This word already exists.")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.warning)
            }

            HStack {
                Spacer()

                Button("Clear") {
                    self.clearBoostTermFields()
                }
                .fluidGlassAction()

                Spacer()

                Button("Cancel") {
                    self.dismissBoostTermEditor()
                }
                .fluidGlassAction()

                Button("Save Word") {
                    self.saveBoostTermIfValid()
                }
                .fluidGlassAction(prominent: true, tone: self.theme.palette.accent)
                .disabled(!self.canSaveBoostTerm)
            }
        }
        .padding(self.theme.metrics.spacing.md)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private var punctuationDictionaryPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: self.theme.metrics.spacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Spoken Formatting")
                            .font(self.theme.typography.sectionTitle)

                        Button {
                            withAnimation(self.reduceMotion ? nil : .easeOut(duration: 0.14)) {
                                self.isPunctuationInfoExpanded.toggle()
                            }
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.fluidSystem(size: 12, weight: .semibold))
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(SquareIconButtonStyle())
                        .help("About spoken formatting")
                        .accessibilityLabel("About spoken formatting")
                    }

                    Text("Use one start word for formatting actions, punctuation, and symbols.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }

                Spacer()

                Button {
                    self.closePunctuationDictionary()
                } label: {
                    Image(systemName: "xmark")
                        .font(.fluidSystem(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(SquareIconButtonStyle())
                .help("Close")
            }
            .padding(.horizontal, self.theme.metrics.spacing.lg)
            .padding(.top, self.theme.metrics.spacing.lg)
            .padding(.bottom, self.theme.metrics.spacing.md)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
                    self.spokenFormattingStatusRow

                    if self.isPunctuationInfoExpanded {
                        self.punctuationDictionaryInfoPanel
                    }

                    HStack(alignment: .top, spacing: self.theme.metrics.spacing.md) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Start Word")
                                .font(self.theme.typography.captionStrong)
                            Text("Say this first so normal words do not change.")
                                .font(self.theme.typography.caption)
                                .foregroundStyle(self.theme.palette.secondaryText)
                            TextField("literal", text: self.$punctuationPrefix)
                                .dictionaryInputChrome()
                                .onSubmit { self.savePunctuationDictionaryPrefix() }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Try Saying")
                                .font(self.theme.typography.captionStrong)
                            Text(AppBrand.text("Examples of what FluidVoice will type."))
                                .font(self.theme.typography.caption)
                                .foregroundStyle(self.theme.palette.secondaryText)
                            self.punctuationTrySayingPreview
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }

                    self.formattingActionsSection
                    self.punctuationRulesSection

                    HStack {
                        Spacer()
                        Button("Reset All Defaults") {
                            self.isFormattingResetAlertPresented = true
                        }
                        .fluidButton(.compact, size: .compact)
                    }
                }
                .padding(.horizontal, self.theme.metrics.spacing.lg)
                .padding(.bottom, self.theme.metrics.spacing.lg)
            }
            .frame(maxHeight: 650)
        }
        .frame(width: 680, alignment: .leading)
        .foregroundStyle(self.theme.palette.primaryText)
        .background(self.theme.palette.cardBackground)
        .onDisappear {
            self.savePunctuationDictionaryPrefix()
        }
        .alert(
            "Reset Spoken Formatting?",
            isPresented: self.$isFormattingResetAlertPresented
        ) {
            Button("Reset All Defaults", role: .destructive) {
                self.resetPunctuationDictionary()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces the start word, formatting action phrases and enabled states, and every punctuation rule with their defaults.")
        }
    }

    private var spokenFormattingStatusRow: some View {
        HStack(spacing: self.theme.metrics.spacing.md) {
            Image(systemName: self.punctuationAutoConvertEnabled ? "checkmark.circle.fill" : "pause.circle.fill")
                .foregroundStyle(
                    self.punctuationAutoConvertEnabled
                        ? self.theme.palette.accent
                        : self.theme.palette.secondaryText
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(PichiLocalization.text(self.punctuationAutoConvertEnabled ? "Spoken Formatting is On" : "Spoken Formatting is Off"))
                    .font(self.theme.typography.bodySmallStrong)
                Text(PichiLocalization.text(
                    self.punctuationAutoConvertEnabled
                        ? "Formatting actions and punctuation will run after the start word."
                        : "Your rules stay saved, but they will not change dictated text."
                ))
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
            }

            Spacer()

            Toggle("Spoken Formatting", isOn: self.$punctuationAutoConvertEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(self.theme.palette.accent)
                .accessibilityLabel("Spoken Formatting")
                .onChange(of: self.punctuationAutoConvertEnabled) { _, newValue in
                    if self.isProfileVisible { SettingsStore.shared.autoConvertPunctuationEnabled = newValue }
                }
        }
        .padding(self.theme.metrics.spacing.md)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private var formattingActionsSection: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Formatting Actions")
                    .font(self.theme.typography.bodySmallStrong)
                Text("Fixed invisible actions with spoken phrases you can personalize.")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }

            VStack(spacing: self.theme.metrics.spacing.sm) {
                ForEach(SettingsStore.SpokenFormattingAction.allCases) { action in
                    self.formattingActionRow(action)
                }
            }

            if let action = self.editingFormattingAction {
                self.formattingActionEditor(action)
            }
        }
    }

    private var punctuationRulesSection: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Punctuation")
                        .font(self.theme.typography.bodySmallStrong)
                    Text("Spoken names that type punctuation or symbols after the start word.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }

                Spacer()

                if !self.isPunctuationRuleEditorPresented {
                    Button {
                        self.startAddingPunctuationRule()
                    } label: {
                        Label("Add Rule", systemImage: "plus")
                    }
                    .fluidButton(.accent, size: .small)
                }
            }

            if self.isPunctuationRuleEditorPresented {
                self.punctuationRuleEditor
            }

            if self.punctuationRules.isEmpty {
                self.dictionaryEmptyState(
                    title: "No punctuation rules",
                    detail: AppBrand.text("Add what you say and what FluidVoice should type.")
                )
            } else {
                LazyVStack(spacing: self.theme.metrics.spacing.sm) {
                    ForEach(self.punctuationRules) { rule in
                        PunctuationDictionaryRuleRow(
                            rule: rule,
                            onEdit: { self.editPunctuationRule(rule) },
                            onDelete: { self.deletePunctuationRule(rule) }
                        )
                    }
                }
            }
        }
    }

    private func formattingActionRow(_ action: SettingsStore.SpokenFormattingAction) -> some View {
        let rule = self.formattingActionRule(for: action)
        return HStack(spacing: self.theme.metrics.spacing.md) {
            Text(action.displaySymbol)
                .font(.fluidSystem(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(self.theme.palette.accentText)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous)
                        .fill(self.theme.palette.contentBackground.opacity(0.7))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(PichiLocalization.text(action.title))
                    .font(self.theme.typography.bodySmallStrong)
                Text(rule.aliases.isEmpty ? PichiLocalization.text("No spoken phrases set") : rule.aliases.joined(separator: ", "))
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: self.theme.metrics.spacing.md)

            Button(PichiLocalization.text("action.edit", defaultValue: "Edit")) {
                self.startEditingFormattingAction(action)
            }
            .fluidButton(.compact, size: .compact)

            Toggle(action.title, isOn: self.formattingActionEnabledBinding(for: action))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(self.theme.palette.accent)
                .disabled(rule.aliases.isEmpty)
                .help(rule.aliases.isEmpty ? PichiLocalization.text("Add a spoken phrase before enabling this action.") : PichiLocalization.format("Enable %@", PichiLocalization.text(action.title)))
        }
        .padding(.horizontal, self.theme.metrics.spacing.md)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private func formattingActionEditor(_ action: SettingsStore.SpokenFormattingAction) -> some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            Text(PichiLocalization.format("Edit %@ Phrases", PichiLocalization.text(action.title)))
                .font(self.theme.typography.captionStrong)
            Text("Enter one phrase per line. Clearing every phrase disables this action.")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)

            TextEditor(text: self.$formattingActionAliasesText)
                .font(self.theme.typography.bodySmall)
                .frame(minHeight: 68, maxHeight: 92)
                .scrollContentBackground(.hidden)
                .dictionaryInputChrome(minHeight: 68)
                .accessibilityLabel(PichiLocalization.format("Spoken phrases for %@", PichiLocalization.text(action.title)))

            HStack {
                Spacer()
                Button("Cancel") {
                    self.dismissFormattingActionEditor()
                }
                .fluidButton(.compact, size: .compact)

                Button("Save Phrases") {
                    self.saveFormattingActionAliases(action)
                }
                .fluidButton(.accent, size: .small)
            }
        }
        .padding(self.theme.metrics.spacing.md)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(self.theme.palette.accent.opacity(0.35), lineWidth: 1)
                )
        )
    }

    private var punctuationDictionaryInfoPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Say the start word first, then a formatting action or punctuation name.")
            Text("When you say \"\(self.punctuationPreviewPrefix) next line\", it starts a new line.")
            Text("When you say \"\(self.punctuationPreviewPrefix) comma\", it types \",\".")
            Text("Add one spoken phrase per line. Formatting actions always keep their fixed output.")
        }
        .font(self.theme.typography.caption)
        .foregroundStyle(self.theme.palette.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
        .padding(self.theme.metrics.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private var punctuationTrySayingPreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            self.punctuationExampleText(
                spoken: "\(self.punctuationPreviewPrefix) comma",
                typed: ","
            )
            self.punctuationExampleText(
                spoken: "\(self.punctuationPreviewPrefix) next line",
                typed: PichiLocalization.text("New Line")
            )
        }
        .font(self.theme.typography.caption)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, self.theme.metrics.spacing.md)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private func punctuationExampleText(spoken: String, typed: String) -> Text {
        Text("When you say ")
            .foregroundStyle(self.theme.palette.secondaryText) +
            Text("\"\(spoken)\"")
            .foregroundStyle(self.theme.palette.accentText) +
            Text(", it types ")
            .foregroundStyle(self.theme.palette.secondaryText) +
            Text("\"\(typed)\"")
            .foregroundStyle(self.theme.palette.accentText)
    }

    private var punctuationRuleEditor: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
            Text(PichiLocalization.text(self.punctuationEditorTitle))
                .font(self.theme.typography.captionStrong)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: self.theme.metrics.spacing.md) {
                    self.punctuationAliasesEditor
                    self.punctuationSymbolEditor
                }

                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                    self.punctuationAliasesEditor
                    self.punctuationSymbolEditor
                }
            }

            HStack {
                Spacer()

                Button("Clear") {
                    self.clearPunctuationRuleFields()
                }
                .fluidButton(.compact, size: .compact)

                Spacer()

                Button("Cancel") {
                    self.dismissPunctuationRuleEditor()
                }
                .fluidButton(.compact, size: .compact)

                Button("Save Rule") {
                    self.savePunctuationRuleIfValid()
                }
                .fluidButton(.accent, size: .small)
                .disabled(!self.canSavePunctuationRule)
            }
        }
        .padding(self.theme.metrics.spacing.md)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private var punctuationAliasesEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What You Say")
                .font(self.theme.typography.captionStrong)
            Text("One way per line, like comma or full stop.")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
            TextEditor(text: self.$punctuationAliasesText)
                .font(self.theme.typography.bodySmall)
                .frame(minHeight: 64, maxHeight: 86)
                .scrollContentBackground(.hidden)
                .dictionaryInputChrome(minHeight: 64)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var punctuationSymbolEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What It Types")
                .font(self.theme.typography.captionStrong)
            TextField(",", text: self.$punctuationSymbolText)
                .font(self.theme.typography.bodySmallStrong)
                .dictionaryInputChrome()
                .frame(width: 92)
            Text("One punctuation symbol, like , or ?.")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
        }
    }

    private func dictionaryEmptyState(
        title: String,
        detail: String,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            Image(systemName: "plus.circle")
                .font(.fluidSystem(.title3))
                .foregroundStyle(self.theme.palette.tertiaryText)

            VStack(alignment: .leading, spacing: 2) {
                Text(PichiLocalization.text(title))
                    .font(self.theme.typography.bodySmallStrong)
                Text(PichiLocalization.text(detail))
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }

            if let action {
                Spacer()

                Button("Add", action: action)
                    .fluidButton(.compact, size: .compact)
            }
        }
        .padding(self.theme.metrics.spacing.md)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.25), lineWidth: 1)
                )
        )
    }

    // MARK: - Actions

    private func saveEntries() {
        guard self.isProfileVisible else { return }
        SettingsStore.shared.customDictionaryEntries = self.entries
        // Invalidate cached regex patterns so changes take effect immediately
        ASRService.invalidateDictionaryCache()
        NotificationCenter.default.post(name: .parakeetVocabularyDidChange, object: nil)
    }

    private func updateTrainedReplacementGlow() {
        guard self.shouldPulseTrainedReplacementButton else {
            withAnimation(.easeOut(duration: 0.16)) {
                self.isTrainedReplacementGlowExpanded = false
            }
            return
        }

        self.isTrainedReplacementGlowExpanded = false
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
            self.isTrainedReplacementGlowExpanded = true
        }
    }

    private func addReplacementEntry(_ entry: SettingsStore.CustomDictionaryEntry) {
        self.entries.insert(entry, at: 0)
        self.saveEntries()
        self.showReplacementConfirmation(
            title: "Replacement added",
            detail: "It is at the top of the list."
        )
    }

    private func selectComposerMode(_ mode: DictionaryComposerMode) {
        guard !self.isTrainingRecording, !self.isTrainingProcessing else { return }
        self.composerMode = mode
    }

    private func addManualReplacementIfValid() {
        guard self.canAddManualReplacement else { return }
        let entry = SettingsStore.CustomDictionaryEntry(
            triggers: self.manualTriggers,
            replacement: self.sanitizedManualReplacement
        )
        self.addReplacementEntry(entry)
        self.wizardSavedWord = entry.replacement
        self.wizardStep = .saved
        self.manualTriggerDraft = ""
        self.manualReplacement = ""
    }

    /// Opens the editor for the row the sidebar search matched, so the screen lands on
    /// that word or rule instead of the top of the dictionary.
    private func revealSearchTarget() {
        switch self.revealTarget {
        case let .dictionaryEntry(id):
            self.entries = SettingsStore.shared.customDictionaryEntries
            self.editingEntry = self.entries.first { $0.id == id }
        case let .vocabulary(text):
            self.presentCustomWords()
            if let index = self.boostTerms.firstIndex(where: { $0.text == text }) {
                self.editBoostTerm(at: index)
            }
        case let .punctuation(id):
            self.presentPunctuationDictionary()
            if let rule = self.punctuationRules.first(where: { $0.id == id }) {
                self.editPunctuationRule(rule)
            }
        default:
            return
        }
        self.revealTarget = nil
    }

    private func consumeTrainingRequest() async {
        guard let request = self.trainingRequest, request.isCurrent, self.isProfileVisible, !self.formattingOnly else { return }
        defer {
            if self.trainingRequest?.id == request.id { self.trainingRequest = nil }
        }
        guard !self.isTrainingRecording, !self.isTrainingStarting, !self.isTrainingProcessing else { return }
        self.resetTraining()
        let target = CustomDictionaryTrainingMerge.normalizedReplacement(request.candidate.correctedText)
        self.seededReplacementKey = target.lowercased()
        self.trainingReplacement = target
        self.trainingAcousticCorrection = true
        self.trainingVariants = CustomDictionaryTrainingMerge.normalizedTriggers(
            from: self.existingTrainingVariants(for: target) + [request.candidate.heardText],
            intendedReplacement: target
        )
        self.wizardStep = .recording
        self.isWordDrawerPresented = true
        self.trainingSourceNotice = "No original pronunciation sample is linked to this selection. Record three new examples."
        if !self.activePronunciationMatching {
            self.trainingSourceNotice = "Pronunciation matching is off or unavailable. Add an exact spelling manually, or enable pronunciation matching."
        }
        guard self.activePronunciationMatching, let evidence = request.candidate.audioEvidence else { return }
        let seedID = request.id
        let generation = DictionaryMatcherExperiment.generation
        self.trainingSeedID = seedID
        self.isTrainingProcessing = true
        defer {
            if self.trainingSeedID == seedID {
                self.trainingSeedID = nil
                self.isTrainingProcessing = false
            }
        }
        do {
            let enrollment = try await self.asr.originalAudioEnrollment(evidence)
            guard !Task.isCancelled, request.isCurrent, self.isProfileVisible,
                  self.trainingSeedID == seedID, generation == DictionaryMatcherExperiment.generation,
                  self.normalizedTrainingReplacement == target,
                  enrollment.modelKey == evidence.modelKey, enrollment.pendingInspection != nil else { return }
            self.trainingPronunciationEnrollments = [enrollment]
            self.trainingSampleCount = 1
            self.trainingAttempts = [evidence.observedText]
            self.lastTrainingOutput = evidence.observedText
            self.lastTrainingOutputIsCovered = true
            await self.refreshSavedPronunciationCount(modelKey: enrollment.modelKey)
            guard !Task.isCancelled, request.isCurrent, self.trainingSeedID == seedID else { return }
            self.trainingSourceNotice = "The original speech fragment is included. Record more examples to finish pronunciation learning."
            if self.trainingProgress.pronunciationReady { self.wizardStep = .review }
        } catch {
            guard !Task.isCancelled, request.isCurrent, self.trainingSeedID == seedID else { return }
            self.trainingSourceNotice = "The original audio could not be used. Record three new pronunciation examples."
        }
    }

    private func refreshSavedPronunciationCount(modelKey: String) async {
        let target = self.normalizedTrainingReplacement
        let profiles = await PronunciationDictionaryStore.shared.profiles(modelKey: modelKey)
        guard !Task.isCancelled, self.isProfileVisible, self.normalizedTrainingReplacement == target,
              self.trainingPronunciationEnrollments.allSatisfy({ $0.modelKey == modelKey }) else { return }
        let entryIDs = Set(SettingsStore.shared.customDictionaryEntries.filter {
            $0.replacement.caseInsensitiveCompare(target) == .orderedSame
        }.map(\.id))
        self.savedPronunciationCount = profiles.first {
            entryIDs.contains($0.dictionaryEntryID) && $0.label.caseInsensitiveCompare(target) == .orderedSame
        }?.enrollments.count ?? 0
    }

    private func presentYourDictionary() {
        self.entries = SettingsStore.shared.customDictionaryEntries
        self.isYourDictionaryPresented = true
    }

    private func closeYourDictionary() {
        self.isYourDictionaryPresented = false
    }

    private func presentPunctuationDictionary() {
        self.punctuationPrefix = SettingsStore.shared.punctuationDictionaryPrefix
        self.punctuationRules = SettingsStore.shared.punctuationDictionaryRules
        self.formattingActionRules = SettingsStore.shared.spokenFormattingActionRules
        self.isPunctuationInfoExpanded = false
        self.dismissFormattingActionEditor()
        self.dismissPunctuationRuleEditor()
        self.isPunctuationDictionaryPresented = true
    }

    private func closePunctuationDictionary() {
        self.savePunctuationDictionaryPrefix()
        self.isPunctuationInfoExpanded = false
        self.isPunctuationDictionaryPresented = false
    }

    private func savePunctuationDictionaryPrefix() {
        guard self.isProfileVisible else { return }
        SettingsStore.shared.punctuationDictionaryPrefix = self.punctuationPrefix
        self.punctuationPrefix = SettingsStore.shared.punctuationDictionaryPrefix
    }

    private func savePunctuationRules() {
        guard self.isProfileVisible else { return }
        SettingsStore.shared.punctuationDictionaryRules = self.punctuationRules
        self.punctuationRules = SettingsStore.shared.punctuationDictionaryRules
    }

    private func formattingActionRule(
        for action: SettingsStore.SpokenFormattingAction
    ) -> SettingsStore.SpokenFormattingActionRule {
        self.formattingActionRules.first { $0.action == action }
            ?? SettingsStore.SpokenFormattingActionRule(action: action, aliases: [], isEnabled: false)
    }

    private func formattingActionEnabledBinding(
        for action: SettingsStore.SpokenFormattingAction
    ) -> Binding<Bool> {
        Binding(
            get: { self.formattingActionRule(for: action).isEnabled },
            set: { isEnabled in
                guard let index = self.formattingActionRules.firstIndex(where: { $0.action == action }) else { return }
                self.formattingActionRules[index].isEnabled = isEnabled
                self.saveFormattingActionRules()
            }
        )
    }

    private func startEditingFormattingAction(_ action: SettingsStore.SpokenFormattingAction) {
        self.editingFormattingAction = action
        self.formattingActionAliasesText = self.formattingActionRule(for: action).aliases.joined(separator: "\n")
    }

    private func dismissFormattingActionEditor() {
        self.editingFormattingAction = nil
        self.formattingActionAliasesText = ""
    }

    private func saveFormattingActionAliases(_ action: SettingsStore.SpokenFormattingAction) {
        let aliases = SettingsStore.PunctuationDictionaryRule.normalizedAliases(
            self.formattingActionAliasesText.components(separatedBy: .newlines)
        )
        guard let index = self.formattingActionRules.firstIndex(where: { $0.action == action }) else { return }
        self.formattingActionRules[index] = SettingsStore.SpokenFormattingActionRule(
            action: action,
            aliases: aliases,
            isEnabled: aliases.isEmpty ? false : self.formattingActionRules[index].isEnabled
        )
        self.saveFormattingActionRules()
        self.dismissFormattingActionEditor()
    }

    private func saveFormattingActionRules() {
        guard self.isProfileVisible else { return }
        SettingsStore.shared.spokenFormattingActionRules = self.formattingActionRules
        self.formattingActionRules = SettingsStore.shared.spokenFormattingActionRules
    }

    private func startAddingPunctuationRule() {
        self.editingPunctuationRuleID = nil
        self.clearPunctuationRuleFields()
        self.isPunctuationRuleEditorPresented = true
    }

    private func savePunctuationRuleIfValid() {
        guard self.canSavePunctuationRule, let symbol = self.normalizedPunctuationSymbol else { return }
        self.savePunctuationDictionaryPrefix()
        let rule = SettingsStore.PunctuationDictionaryRule(
            id: self.editingPunctuationRuleID ?? UUID(),
            aliases: self.normalizedPunctuationAliases,
            symbol: symbol
        )

        if let editingID = self.editingPunctuationRuleID,
           let index = self.punctuationRules.firstIndex(where: { $0.id == editingID })
        {
            self.punctuationRules[index] = rule
        } else {
            self.punctuationRules.insert(rule, at: 0)
        }

        self.savePunctuationRules()
        self.dismissPunctuationRuleEditor()
    }

    private func editPunctuationRule(_ rule: SettingsStore.PunctuationDictionaryRule) {
        self.editingPunctuationRuleID = rule.id
        self.punctuationAliasesText = rule.aliases.joined(separator: "\n")
        self.punctuationSymbolText = rule.symbol
        self.isPunctuationRuleEditorPresented = true
    }

    private func deletePunctuationRule(_ rule: SettingsStore.PunctuationDictionaryRule) {
        self.punctuationRules.removeAll { $0.id == rule.id }
        if self.editingPunctuationRuleID == rule.id {
            self.dismissPunctuationRuleEditor()
        }
        self.savePunctuationRules()
    }

    private func resetPunctuationDictionary() {
        self.punctuationPrefix = SettingsStore.defaultPunctuationDictionaryPrefix
        self.punctuationRules = SettingsStore.defaultPunctuationDictionaryRules
        self.formattingActionRules = SettingsStore.defaultSpokenFormattingActionRules
        self.dismissFormattingActionEditor()
        self.dismissPunctuationRuleEditor()
        self.savePunctuationDictionaryPrefix()
        self.savePunctuationRules()
        self.saveFormattingActionRules()
    }

    private func clearPunctuationRuleFields() {
        self.punctuationAliasesText = ""
        self.punctuationSymbolText = ""
    }

    private func dismissPunctuationRuleEditor() {
        self.editingPunctuationRuleID = nil
        self.clearPunctuationRuleFields()
        self.isPunctuationRuleEditorPresented = false
    }

    private func presentCustomWords() {
        self.loadBoostTerms()
        self.dismissBoostTermEditor()
        self.isCustomWordsPresented = true
    }

    private func closeCustomWords() {
        self.dismissBoostTermEditor()
        self.isCustomWordsPresented = false
    }

    private func startAddingBoostTerm() {
        self.editingBoostTermIndex = nil
        self.clearBoostTermFields()
        self.isBoostWordEditorPresented = true
    }

    private func editBoostTerm(at index: Int) {
        guard self.boostTerms.indices.contains(index) else { return }
        let term = self.boostTerms[index]
        self.editingBoostTermIndex = index
        self.boostTermText = term.text
        self.boostTermStrength = BoostStrengthPreset.nearest(for: term.weight ?? BoostStrengthPreset.balanced.weight)
        self.isBoostWordEditorPresented = true
    }

    private func saveBoostTermIfValid() {
        guard self.canSaveBoostTerm else { return }
        let updatedTerm = ParakeetVocabularyStore.VocabularyConfig.Term(
            text: self.normalizedBoostTermText,
            weight: self.boostTermStrength.weight,
            aliases: []
        )

        if let index = self.editingBoostTermIndex,
           self.boostTerms.indices.contains(index)
        {
            self.boostTerms[index] = ParakeetVocabularyStore.VocabularyConfig.Term(
                text: updatedTerm.text,
                weight: updatedTerm.weight,
                aliases: self.boostTerms[index].aliases
            )
        } else {
            self.boostTerms.append(updatedTerm)
        }

        self.saveBoostTerms()
        self.dismissBoostTermEditor()
    }

    private func clearBoostTermFields() {
        self.boostTermText = ""
        self.boostTermStrength = .balanced
    }

    private func dismissBoostTermEditor() {
        self.editingBoostTermIndex = nil
        self.clearBoostTermFields()
        self.isBoostWordEditorPresented = false
    }

    private func toggleAutomaticTraining() async {
        if self.isAutomaticTrainingEnabled {
            await self.pauseAutomaticTraining()
            return
        }
        await self.startAutomaticTrainingIfIdle()
    }

    private func pauseAutomaticTraining() async {
        self.trainingRestart.cancel()
        self.isAutomaticTrainingEnabled = false
        if self.isTrainingRecording {
            await self.stopTrainingSample()
        }
    }

    private func startAutomaticTrainingIfIdle() async {
        guard !self.isAutomaticTrainingEnabled, !self.isTrainingStarting,
              !self.isTrainingRecording, !self.isTrainingProcessing, !self.trainingRestart.isWaiting
        else { return }
        if self.canRetryTrainingAfterMaximum {
            self.resetTrainingVerificationAttempts()
        }
        guard self.canRecordTrainingSample else { return }
        self.isAutomaticTrainingEnabled = true
        await self.startTrainingSample()
    }

    private func startTrainingSample() async {
        guard self.isProfileVisible, self.isAutomaticTrainingEnabled, self.canRecordTrainingSample else {
            self.isAutomaticTrainingEnabled = false
            return
        }
        let settings = SettingsStore.shared
        guard let capture = try? PrivateDirectDictationCapture(asr: self.asr,
            savesHistory: settings.saveTranscriptionHistory,
            savesAudio: settings.saveAudioWithTranscriptionHistory,
            transcriptionModel: settings.selectedSpeechModel.displayName,
            forDictionaryTraining: true, requiresPronunciation: false,
            captureDictionaryPronunciation: self.activePronunciationMatching) else { return }
        self.privateTrainingCapture = capture
        self.isTrainingActive = true
        self.trainingHasError = false
        self.trainingStatusMessage = ""
        self.trainingStopRequestedDuringStart = false
        self.isTrainingStarting = true
        self.isTrainingRecording = true

        await capture.start()
        self.isTrainingStarting = false
        if capture.isFinished || !self.asr.isRunning {
            self.isTrainingRecording = false
            self.trainingStopRequestedDuringStart = false
            self.isAutomaticTrainingEnabled = false
            self.trainingHasError = true
            self.trainingStatusMessage = "Couldn't start recording. Check microphone access and try again."
            return
        }

        if self.trainingStopRequestedDuringStart {
            await self.finishTrainingSampleStop()
            return
        }
        DictionaryTrainingEndpointMonitor.shared.start(asr: self.asr) {
            self.handleAutomaticTrainingSpeechEnd()
        }
    }

    private func stopTrainingSample() async {
        DictionaryTrainingEndpointMonitor.shared.stop()
        guard self.isTrainingRecording else { return }
        guard !self.trainingStopRequestedDuringStart else { return }

        guard !self.isTrainingStarting, self.asr.isRunning else {
            self.trainingStopRequestedDuringStart = true
            self.trainingHasError = false
            self.trainingStatusMessage = "Stopping..."
            return
        }

        await self.finishTrainingSampleStop()
    }

    /// Our own stop clears `isTrainingRecording` before the recorder stops, so reaching here with it
    /// still set means something else ended the capture, such as Escape. Leave the screen idle.
    private func handleTrainingCaptureEndedElsewhere() {
        guard self.isTrainingRecording, !self.isTrainingStarting, !self.isTrainingProcessing else { return }
        DictionaryTrainingEndpointMonitor.shared.stop()
        self.trainingRestart.cancel()
        self.isAutomaticTrainingEnabled = false
        self.isTrainingRecording = false
        self.trainingStopRequestedDuringStart = false
        self.trainingHasError = true
        self.trainingStatusMessage = "Recording stopped. Press Record to continue."
        DebugLogger.shared.info("DICTIONARY_TRAINING capture ended outside the editor; returning to idle", source: "CustomDictionary")
    }

    private func handleAutomaticTrainingSpeechEnd() {
        guard self.isAutomaticTrainingEnabled, self.isTrainingRecording else { return }
        Task { await self.stopTrainingSample() }
    }

    private func finishTrainingSampleStop() async {
        guard self.isTrainingRecording else { return }
        DictionaryTrainingEndpointMonitor.shared.stop()
        self.isTrainingRecording = false
        self.isTrainingStarting = false
        self.trainingStopRequestedDuringStart = false
        self.isTrainingProcessing = true
        self.trainingHasError = false
        self.trainingStatusMessage = ""

        let pronunciationGeneration = DictionaryMatcherExperiment.generation
        guard let capture = self.privateTrainingCapture else { return }
        let transcript = await capture.stop()
        guard capture.isVisible else {
            await capture.complete()
            if self.privateTrainingCapture?.output.id == capture.output.id { self.privateTrainingCapture = nil }
            self.isTrainingProcessing = false
            self.isAutomaticTrainingEnabled = false
            return
        }
        await self.applyTrainingSample(transcript, pronunciationGeneration: pronunciationGeneration)
        capture.acknowledgeVisibleResult()
        await capture.complete()
        if self.privateTrainingCapture?.output.id == capture.output.id { self.privateTrainingCapture = nil }
        self.continueAutomaticTrainingIfNeeded()
    }

    private func applyTrainingSample(_ transcript: String, pronunciationGeneration: String) async {
        defer { self.isTrainingProcessing = false }
        guard self.isProfileVisible else { return }
        let target = self.normalizedTrainingReplacement
        guard !CustomDictionaryTrainingMerge.isOversizedResponse(transcript, intendedReplacement: self.normalizedTrainingReplacement) else {
            self.isAutomaticTrainingEnabled = false
            self.trainingHasError = true
            self.trainingStatusMessage = PichiLocalization.format("That was longer than expected. Say only “%@”, then pause. This try wasn’t saved.", self.normalizedTrainingReplacement)
            return
        }
        if self.activePronunciationMatching,
           DictionaryMatcherExperiment.generation == pronunciationGeneration,
           CustomDictionaryTrainingMerge.normalizedTrigger(transcript) != nil,
           let enrollment = self.asr.lastDictionaryTrainingResult?.pronunciationEnrollment
        {
            if self.trainingPronunciationEnrollments.allSatisfy({ $0.modelKey == enrollment.modelKey }) {
                self.trainingPronunciationEnrollments.append(enrollment)
                await self.refreshSavedPronunciationCount(modelKey: enrollment.modelKey)
            } else {
                self.trainingHasError = true
                self.trainingStatusMessage = "The speech model changed. Start pronunciation learning again."
                self.isAutomaticTrainingEnabled = false
                return
            }
        }
        guard self.isProfileVisible, self.normalizedTrainingReplacement == target,
              DictionaryMatcherExperiment.generation == pronunciationGeneration else { return }
        self.addTrainingVariant(from: transcript)
        if self.trainingHasError {
            self.isAutomaticTrainingEnabled = false
            return
        }
        if self.trainingFinalOutputIsReady || self.trainingAlreadyCorrectWithoutReplacement {
            self.isAutomaticTrainingEnabled = false
            self.wizardStep = .review
        }
    }

    private var canContinueAutomaticTraining: Bool {
        self.isProfileVisible && NSApp.isActive && self.isAutomaticTrainingEnabled && !self.trainingFinalOutputIsReady &&
            !self.trainingAlreadyCorrectWithoutReplacement &&
            self.trainingSampleCount < CustomDictionaryTrainingMerge.maxSamples
    }

    private func continueAutomaticTrainingIfNeeded() {
        guard self.canContinueAutomaticTraining else {
            self.trainingRestart.cancel()
            self.isAutomaticTrainingEnabled = false
            return
        }
        self.trainingRestart.schedule(canContinue: {
            guard self.canContinueAutomaticTraining else {
                self.isAutomaticTrainingEnabled = false
                return false
            }
            return true
        }) {
            await self.startTrainingSample()
        }
    }

    private func resetTrainingVerificationAttempts() {
        self.trainingSampleCount = 0
        self.trainingAttempts = []
        self.lastTrainingOutput = ""
        self.lastTrainingOutputIsCovered = false
        self.consecutiveCoveredCaptures = 0
        self.trainingStatusMessage = ""
        self.trainingHasError = false
    }

    private func addTrainingVariant(from transcript: String) {
        guard let detected = CustomDictionaryTrainingMerge.normalizedTrigger(transcript) else {
            self.lastTrainingOutput = ""
            self.lastTrainingOutputIsCovered = false
            self.consecutiveCoveredCaptures = 0
            self.trainingHasError = true
            self.trainingStatusMessage = "Nothing heard. Try again."
            return
        }

        self.lastTrainingOutput = detected
        self.trainingSampleCount = min(self.trainingSampleCount + 1, CustomDictionaryTrainingMerge.maxSamples)
        self.trainingAttempts = Array((self.trainingAttempts + [detected]).suffix(CustomDictionaryTrainingMerge.maxSamples))

        if detected.caseInsensitiveCompare(self.normalizedTrainingReplacement) == .orderedSame {
            self.lastTrainingOutputIsCovered = true
            self.consecutiveCoveredCaptures += 1
            self.trainingHasError = false
            if self.consecutiveCoveredCaptures >= CustomDictionaryTrainingMerge.readyCoveredCount {
                self.trainingStatusMessage = self.trainingVariants.isEmpty
                    ? "Looks good already. No replacement needed."
                    : "Looks ready. Add this replacement when you're ready."
            } else {
                self.trainingStatusMessage = "Covered. Try a couple more."
            }
            return
        }

        let wasAlreadyCaptured = self.trainingVariants.contains { $0.caseInsensitiveCompare(detected) == .orderedSame }
        let wasAlreadySaved = self.savedDictionaryCovers(detected)

        if wasAlreadyCaptured || wasAlreadySaved {
            self.lastTrainingOutputIsCovered = true
            self.consecutiveCoveredCaptures += 1
            self.trainingHasError = false
            if self.consecutiveCoveredCaptures >= CustomDictionaryTrainingMerge.readyCoveredCount {
                self.trainingStatusMessage = "Looks ready. Add this replacement when you're ready."
            } else if wasAlreadySaved {
                self.trainingStatusMessage = "Covered by your dictionary."
            } else {
                self.trainingStatusMessage = "Already captured. Try a couple more."
            }
            return
        }

        guard self.trainingVariants.count < CustomDictionaryTrainingMerge.maxSamples else {
            self.lastTrainingOutputIsCovered = false
            self.consecutiveCoveredCaptures = 0
            self.trainingHasError = false
            self.trainingStatusMessage = "Max samples reached. Add it or clear one."
            return
        }

        self.trainingVariants.append(detected)
        self.lastTrainingOutputIsCovered = false
        self.consecutiveCoveredCaptures = 0
        self.trainingHasError = false
        if self.trainingSampleCount >= CustomDictionaryTrainingMerge.maxSamples || self.trainingVariants.count >= CustomDictionaryTrainingMerge.maxSamples {
            self.trainingStatusMessage = "Max samples reached. Add it or clear one."
        } else {
            self.trainingStatusMessage = "New pronunciation captured. Add replacement to cover it."
        }
    }

    private func addTrainedReplacement() async {
        guard self.isProfileVisible, !Task.isCancelled, !self.isTrainingRecording, !self.isTrainingProcessing,
              self.canAddTrainedReplacement || self.trainingAlreadyCorrectWithoutReplacement else { return }
        if self.trainingAlreadyCorrectWithoutReplacement {
            self.trainingHasError = true
            self.trainingStatusMessage = PichiLocalization.format("%@ already recognises this word. Nothing new was saved.", AppBrand.appName)
            return
        }
        self.isTrainingProcessing = true
        let saveID = UUID()
        self.trainingSaveID = saveID
        defer {
            if self.trainingSaveID == saveID {
                self.trainingSaveID = nil
                self.isTrainingProcessing = false
            }
        }
        let profile = self.profile
        guard self.isProfileVisible else { return }
        let pronunciationStore = PronunciationDictionaryStore.shared
        let replacementText = self.normalizedTrainingReplacement
        let enrollments = self.trainingPronunciationEnrollments
        let savePronunciation = self.trainingProgress.pronunciationReady && !enrollments.isEmpty
        let pronunciationGeneration = DictionaryMatcherExperiment.generation
        let speechModel = SettingsStore.shared.selectedSpeechModel
        func selectionIsCurrent() -> Bool {
            PrivateProfileStorage.isReadable(profile) && PrivateProfileStorage.acceptsNewWork &&
                self.trainingSaveID == saveID && !Task.isCancelled &&
                self.normalizedTrainingReplacement == replacementText &&
                self.trainingPronunciationEnrollments == enrollments &&
                SettingsStore.shared.selectedSpeechModel == speechModel &&
                DictionaryMatcherExperiment.generation == pronunciationGeneration
        }
        let filtered = await VoiceTrainingAliasFilter.filter(self.trainingVariants, manuallyConfirmed: self.manualTrainingSpellings)
        let exactTriggers = DictionaryTrainingSpellingPolicy.exactTriggers(
            accepted: filtered.accepted, manuallyConfirmed: self.manualTrainingSpellings,
            acousticCorrection: self.trainingAcousticCorrection
        )
        guard selectionIsCurrent() else { return }
        DebugLogger.shared.info(
            "VOICE_TRAINING_ALIAS_FILTER accepted=\(filtered.accepted.count) rejected=\(filtered.rejected.count)",
            source: "CustomDictionary"
        )
        guard savePronunciation || !exactTriggers.isEmpty else {
            self.trainingHasError = true
            self.trainingStatusMessage = filtered.rejectionMessage
            return
        }

        let originalEntries = SettingsStore.shared.customDictionaryEntries
        let updatedEntries = CustomDictionaryTrainingMerge.mergedEntries(
            current: originalEntries,
            replacement: replacementText,
            triggers: exactTriggers,
            savePronunciation: savePronunciation
        )
        guard savePronunciation || updatedEntries != originalEntries else {
            self.trainingHasError = true
            self.trainingStatusMessage = "These spellings are already covered. Nothing new was saved."
            return
        }
        let entry = updatedEntries.first {
            $0.replacement.caseInsensitiveCompare(replacementText) == .orderedSame
        }
        if savePronunciation, let entry, let modelKey = enrollments.first?.modelKey {
            do {
                let savedProfiles = await pronunciationStore.profiles(modelKey: modelKey)
                guard selectionIsCurrent(), SettingsStore.shared.customDictionaryEntries == originalEntries else { return }
                let saved = savedProfiles.first { $0.dictionaryEntryID == entry.id }?.enrollments ?? []
                let combined = PronunciationDictionaryStore.retainedEnrollments(saved + enrollments)
                let consistent = try await self.asr.validateDictionaryPronunciations(combined)
                guard selectionIsCurrent(), SettingsStore.shared.customDictionaryEntries == originalEntries else { return }
                guard consistent else {
                    self.trainingHasError = true
                    self.trainingStatusMessage = "These recordings do not sound consistent. Record the term again."
                    self.wizardStep = .recording
                    return
                }
                let latestProfiles = await pronunciationStore.profiles(modelKey: modelKey)
                guard selectionIsCurrent(), SettingsStore.shared.customDictionaryEntries == originalEntries else { return }
                guard (latestProfiles.first { $0.dictionaryEntryID == entry.id }?.enrollments ?? []) == saved else {
                    self.trainingHasError = true
                    self.trainingStatusMessage = "Your dictionary changed while saving. Try again."
                    return
                }
                try await pronunciationStore.upsert(
                    dictionaryEntryID: entry.id,
                    label: replacementText,
                    modelKey: modelKey,
                    enrollments: enrollments,
                    automaticMatchingEnabled: true,
                    expectedExistingEnrollments: saved,
                    canPersist: {
                        PrivateProfileStorage.isReadable(profile) && PrivateProfileStorage.acceptsNewWork &&
                            DictionaryMatcherExperiment.sharedFeaturesEnabled &&
                            DictionaryMatcherExperiment.generation == pronunciationGeneration &&
                            SettingsStore.shared.selectedSpeechModel == speechModel &&
                            SettingsStore.shared.customDictionaryEntries == originalEntries
                    }
                )
            } catch {
                guard PrivateProfileStorage.isReadable(profile), PrivateProfileStorage.acceptsNewWork,
                      self.trainingSaveID == saveID, !Task.isCancelled else { return }
                self.trainingHasError = true
                self.trainingStatusMessage = SettingsStore.shared.customDictionaryEntries == originalEntries
                    ? "Couldn't save the voice profile. Try again."
                    : "Your dictionary changed while saving. Try again."
                DebugLogger.shared.error(
                    "Failed to save pronunciation profile: \(error.localizedDescription)",
                    source: "PronunciationMatching"
                )
                return
            }
        }
        guard PrivateProfileStorage.isReadable(profile), PrivateProfileStorage.acceptsNewWork,
              self.trainingSaveID == saveID, !Task.isCancelled else { return }
        // Profile persistence suspends this view. Never publish a snapshot over a newer
        // manual edit, import, or deletion; keep the recordings available for a retry.
        guard SettingsStore.shared.customDictionaryEntries == originalEntries else {
            self.trainingHasError = true
            self.trainingStatusMessage = "Your dictionary changed while saving. Try again."
            return
        }
        self.entries = updatedEntries
        self.saveEntries()
        self.wizardSavedWord = replacementText
        self.resetTraining()
        self.wizardStep = .saved
    }

    private func removeTrainingVariant(_ variant: String) {
        guard !self.isManualEntryBlocked else { return }
        self.trainingVariants.removeAll { $0 == variant }
        self.manualTrainingSpellings.remove(variant)
        self.refreshLastTrainingCoverage()
    }

    private func addManualTrainingSpelling(_ spelling: String) -> String? {
        guard !self.isManualEntryBlocked else { return "Pause learning before editing spellings." }
        guard self.trainingVariants.count < CustomDictionaryTrainingMerge.maxSamples else { return "Remove a spelling before adding another." }
        guard let normalized = CustomDictionaryTrainingMerge.normalizedTrigger(spelling) else { return PichiLocalization.format("Enter the spelling %@ gets wrong.", AppBrand.appName) }
        guard normalized.count <= 160 else { return "Use 160 characters or fewer." }
        guard normalized.caseInsensitiveCompare(self.normalizedTrainingReplacement) != .orderedSame else { return "That is already the correct spelling." }
        if let existing = self.trainingVariants.first(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) {
            if self.trainingAcousticCorrection {
                self.manualTrainingSpellings.insert(existing)
                return nil
            }
            return "That spelling is already in this list."
        }
        guard !self.allExistingTriggers().contains(normalized) else { return "That spelling already belongs to a saved word." }
        self.trainingVariants.append(normalized)
        self.manualTrainingSpellings.insert(normalized)
        self.refreshLastTrainingCoverage()
        return nil
    }

    private func refreshLastTrainingCoverage() {
        guard !self.lastTrainingOutput.isEmpty else {
            self.lastTrainingOutputIsCovered = false
            self.consecutiveCoveredCaptures = 0
            return
        }

        let matchesReplacement = self.lastTrainingOutput.caseInsensitiveCompare(self.normalizedTrainingReplacement) == .orderedSame
        let isStillCaptured = self.trainingVariants.contains {
            $0.caseInsensitiveCompare(self.lastTrainingOutput) == .orderedSame
        }

        if matchesReplacement || isStillCaptured || self.savedDictionaryCovers(self.lastTrainingOutput) {
            self.lastTrainingOutputIsCovered = true
        } else {
            self.lastTrainingOutputIsCovered = false
            self.consecutiveCoveredCaptures = 0
        }
    }

    private func openNewManualDictionaryEntry() {
        guard !self.isManualEntryBlocked else { return }
        self.isDrawerActionsPresented = false
        if self.wizardStep != .manual {
            self.manualReturnStep = self.wizardStep
            self.manualSourceWord = ""
            self.manualReplacement = ""
            self.manualTriggerDraft = ""
            self.wizardStep = .manual
        }
        self.manualEntryFocusRequest &+= 1
    }

    private func startNewDictionaryWord() {
        self.isDrawerActionsPresented = false
        self.resetTraining()
        self.wizardStep = .spelling
        self.newWordFocusRequest &+= 1
    }

    private func recordMorePronunciations(for entry: SettingsStore.CustomDictionaryEntry) {
        guard self.isProfileVisible, !self.isManualEntryBlocked, self.activePronunciationMatching else { return }
        self.resetTraining()
        self.seededReplacementKey = entry.replacement.lowercased()
        self.trainingReplacement = entry.replacement
        self.trainingVariants = entry.triggers
        self.wizardStep = .recording
    }

    private func resetTraining(statusMessage: String = "Type the correct text.", keepingWord: Bool = false) {
        self.trainingRestart.cancel()
        self.trainingSaveID = nil
        self.isAutomaticTrainingEnabled = false
        DictionaryTrainingEndpointMonitor.shared.stop()
        if !keepingWord { self.trainingReplacement = "" }
        self.trainingVariants = []
        self.manualTrainingSpellings = []
        self.trainingPronunciationEnrollments = []
        self.savedPronunciationCount = 0
        self.trainingSeedID = nil
        self.trainingSourceNotice = nil
        if !keepingWord { self.trainingAcousticCorrection = false }
        self.trainingSampleCount = 0
        self.trainingAttempts = []
        self.lastTrainingOutput = ""
        self.lastTrainingOutputIsCovered = false
        self.consecutiveCoveredCaptures = 0
        self.trainingStatusMessage = statusMessage
        self.trainingHasError = false
        self.isTrainingActive = false
        self.isTrainingStarting = false
        self.isTrainingRecording = false
        self.trainingStopRequestedDuringStart = false
        self.isTrainingProcessing = false
    }

    private func handleTrainingReplacementChange(oldValue: String, newValue: String) {
        let oldKey = CustomDictionaryTrainingMerge.normalizedReplacement(oldValue).lowercased()
        let newKey = CustomDictionaryTrainingMerge.normalizedReplacement(newValue).lowercased()
        guard oldKey != newKey else { return }
        if self.seededReplacementKey == newKey {
            self.seededReplacementKey = nil
            return
        }
        self.seededReplacementKey = nil
        self.trainingRestart.cancel()
        self.isAutomaticTrainingEnabled = false

        if self.trainingSaveID != nil {
            self.trainingSaveID = nil
            self.isTrainingProcessing = false
        }

        self.trainingVariants = self.existingTrainingVariants(for: newValue)
        self.manualTrainingSpellings = []
        self.trainingPronunciationEnrollments = []
        self.savedPronunciationCount = 0
        self.trainingSeedID = nil
        self.trainingSourceNotice = nil
        self.trainingSampleCount = 0
        self.trainingAttempts = []
        self.lastTrainingOutput = ""
        self.lastTrainingOutputIsCovered = false
        self.consecutiveCoveredCaptures = 0
        self.isTrainingActive = false
        if newKey.isEmpty {
            self.trainingStatusMessage = "Type the correct text."
        } else if self.trainingVariants.isEmpty {
            self.trainingStatusMessage = ""
        } else {
            self.trainingStatusMessage = PichiLocalization.format(self.trainingVariants.count == 1 ? "Loaded %lld saved capture." : "Loaded %lld saved captures.", self.trainingVariants.count)
        }
        self.trainingHasError = false
    }

    private func existingTrainingVariants(for replacement: String) -> [String] {
        let replacementText = CustomDictionaryTrainingMerge.normalizedReplacement(replacement)
        guard !replacementText.isEmpty else { return [] }

        let triggers = self.entries
            .filter { $0.replacement.caseInsensitiveCompare(replacementText) == .orderedSame }
            .flatMap(\.triggers)

        return CustomDictionaryTrainingMerge.normalizedTriggers(
            from: triggers,
            intendedReplacement: replacementText
        )
    }

    private func savedDictionaryCovers(_ trigger: String) -> Bool {
        guard let triggerKey = CustomDictionaryTrainingMerge.normalizedTrigger(trigger),
              !self.normalizedTrainingReplacement.isEmpty
        else {
            return false
        }

        return self.entries.contains { entry in
            entry.replacement.caseInsensitiveCompare(self.normalizedTrainingReplacement) == .orderedSame &&
                entry.triggers.contains { savedTrigger in
                    guard let savedKey = CustomDictionaryTrainingMerge.normalizedTrigger(savedTrigger) else { return false }
                    return savedKey == triggerKey
                }
        }
    }

    private func showReplacementConfirmation(title: String, detail: String) {
        let confirmation = ReplacementConfirmation(title: title, detail: detail)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)

        withAnimation(self.reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.78)) {
            self.replacementConfirmation = confirmation
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_650_000_000)
            guard self.replacementConfirmation?.id == confirmation.id else { return }
            withAnimation(self.reduceMotion ? nil : .easeOut(duration: 0.16)) {
                self.replacementConfirmation = nil
            }
        }
    }

    private func loadBoostTerms() {
        guard self.isProfileVisible else { return }
        do {
            self.boostTerms = try ParakeetVocabularyStore.shared.loadUserBoostTerms()
            self.boostStatusMessage = PichiLocalization.format("Loaded %lld custom words.", self.boostTerms.count)
            self.boostHasError = false
        } catch {
            self.boostTerms = []
            self.boostStatusMessage = PichiLocalization.format("Couldn't load custom words: %@", error.localizedDescription)
            self.boostHasError = true
        }
    }

    private func saveBoostTerms() {
        guard self.isProfileVisible else { return }
        do {
            try ParakeetVocabularyStore.shared.saveUserBoostTerms(self.boostTerms)
            self.boostStatusMessage = PichiLocalization.format("Saved %lld custom words.", self.boostTerms.count)
            self.boostHasError = false
        } catch {
            self.boostStatusMessage = PichiLocalization.format("Couldn't save custom words: %@", error.localizedDescription)
            self.boostHasError = true
        }
    }

    private func exportDictionary() {
        guard self.isProfileVisible else { return }
        do {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = DictionaryTransferService.shared.suggestedFilename()

            guard panel.runModal() == .OK, self.isProfileVisible, let url = panel.url else { return }

            let document = try DictionaryTransferService.shared.makeExportDocument()
            let data = try DictionaryTransferService.shared.encode(document)
            try data.write(to: url, options: .atomic)

            self.presentInfoAlert(
                title: "Dictionary Exported",
                message: PichiLocalization.format("Saved %lld replacement rules and %lld custom words.", document.replacements.count, document.customWords.count)
            )
        } catch {
            self.presentErrorAlert(title: "Dictionary Export Failed", message: error.localizedDescription)
        }
    }

    private func importDictionary() {
        guard self.isProfileVisible else { return }
        do {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.json]

            guard panel.runModal() == .OK, self.isProfileVisible, let url = panel.url else { return }

            let data = try Data(contentsOf: url)
            let document = try DictionaryTransferService.shared.decode(data)
            guard let mode = self.confirmDictionaryImport(document), self.isProfileVisible else { return }

            let summary = try DictionaryTransferService.shared.restore(document, mode: mode)
            self.entries = SettingsStore.shared.customDictionaryEntries
            self.loadBoostTerms()

            self.presentInfoAlert(
                title: "Dictionary Imported",
                message: PichiLocalization.format("Now using %lld replacement rules and %lld custom words.", summary.replacementCount, summary.customWordCount)
            )
        } catch {
            self.presentErrorAlert(title: "Dictionary Import Failed", message: error.localizedDescription)
        }
    }

    private func confirmDictionaryImport(_ document: DictionaryTransferDocument) -> DictionaryTransferImportMode? {
        let confirm = NSAlert()
        confirm.messageText = PichiLocalization.text("Import this dictionary?")
        confirm.informativeText = PichiLocalization.format("Found %lld replacement rules and %lld custom words.\n\nMerge adds them to your current dictionary. Replace clears the current dictionary first.", document.replacements.count, document.customWords.count)
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: PichiLocalization.text("Merge"))
        confirm.addButton(withTitle: PichiLocalization.text("Replace"))
        confirm.addButton(withTitle: PichiLocalization.text("Cancel"))

        switch confirm.runModal() {
        case .alertFirstButtonReturn:
            return .merge
        case .alertSecondButtonReturn:
            return .replace
        default:
            return nil
        }
    }

    private func presentInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = PichiLocalization.text(title)
        alert.informativeText = PichiLocalization.text(message)
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func presentErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = PichiLocalization.text(title)
        alert.informativeText = PichiLocalization.text(message)
        alert.alertStyle = .critical
        alert.runModal()
    }

    private func deleteBoostTerm(at index: Int) {
        guard self.boostTerms.indices.contains(index) else { return }
        self.boostTerms.remove(at: index)
        if self.editingBoostTermIndex == index {
            self.dismissBoostTermEditor()
        } else if let editingIndex = self.editingBoostTermIndex, index < editingIndex {
            self.editingBoostTermIndex = editingIndex - 1
        }
        self.saveBoostTerms()
    }

    private func deleteEntry(_ entry: SettingsStore.CustomDictionaryEntry) {
        guard self.isProfileVisible else { return }
        let pronunciationStore = PronunciationDictionaryStore.shared
        self.entries.removeAll { $0.id == entry.id }
        self.saveEntries()
        Task {
            guard self.isProfileVisible else { return }
            try? await pronunciationStore.delete(dictionaryEntryID: entry.id)
        }
    }

    /// Returns all existing trigger words for duplicate detection
    private func allExistingTriggers(excluding entryId: UUID? = nil) -> Set<String> {
        var triggers = Set<String>()
        for entry in self.entries where entry.id != entryId {
            for trigger in entry.triggers {
                triggers.insert(trigger.lowercased())
            }
        }
        return triggers
    }

    private func existingBoostTerms(excludingIndex: Int? = nil) -> Set<String> {
        var terms: Set<String> = []
        for (index, term) in self.boostTerms.enumerated() where index != excludingIndex {
            terms.insert(term.text.lowercased())
        }
        return terms
    }
}

private extension CustomDictionaryView {
    var asr: ASRService { self.appServices.asr }

    var trainedReplacementButtonTitle: String {
        self.activePronunciationMatching ? "Save Word"
            : (self.trainingAlreadyCorrectWithoutReplacement ? "Nothing to Save" : "Add Replacement")
    }

    var shouldEmphasizeTrainedReplacementButton: Bool {
        self.trainingFinalOutputIsReady && self.canAddTrainedReplacement
    }

    func trainingInstruction(number: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(self.theme.typography.captionStrong)
                .foregroundStyle(self.theme.palette.accentText)
                .frame(width: 16, alignment: .center)

            Text(PichiLocalization.text(text))
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
        }
    }

    func handlePronunciationMatchingChange(enabled: Bool) {
        self.trainingRestart.cancel()
        guard self.isProfileVisible else { return }
        SettingsStore.shared.pronunciationMatchingEnabled = enabled
        self.isAutomaticTrainingEnabled = false
        DictionaryTrainingEndpointMonitor.shared.stop()
        self.trainingVariants = self.existingTrainingVariants(for: self.trainingReplacement)
        self.manualTrainingSpellings = []
        self.trainingPronunciationEnrollments = []
        self.resetTrainingVerificationAttempts()
        self.trainingStatusMessage = self.normalizedTrainingReplacement.isEmpty
            ? "Type the correct text."
            : ""
    }
}

private struct VoiceMatchingSettingsRow: View {
    @Binding var isEnabled: Bool

    let isDisabled: Bool
    let isAdvancedAvailable: Bool
    let onChange: (Bool) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredMethod: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                self.methodButton(title: "Basic", systemImage: "checkmark", enabledValue: false)
                self.methodButton(title: "Advanced", systemImage: "waveform", enabledValue: true, isResearchPreview: true)
            }

            if self.isEnabled {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "flask.fill")
                        .foregroundStyle(self.theme.palette.accentText)
                    Text(AppBrand.text("Research Preview: Compares how your voice sounds instead of only the words FluidVoice hears. Results may vary."))
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 2)
            } else if !self.isAdvancedAvailable {
                Text("Advanced voice matching requires Parakeet TDT on Apple Silicon.")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .padding(.horizontal, 2)
            }
        }
        .padding(self.theme.metrics.spacing.md)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.42))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.24), lineWidth: 1)
                )
        )
    }

    private func methodButton(
        title: String,
        systemImage: String,
        enabledValue: Bool,
        isResearchPreview: Bool = false
    ) -> some View {
        let isSelected = self.isEnabled == enabledValue
        let isHovered = self.hoveredMethod == enabledValue
        return Button {
            guard !isSelected else { return }
            self.isEnabled = enabledValue
            self.onChange(enabledValue)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                Text(enabledValue ? PichiLocalization.text("dictionary.matching.advanced", defaultValue: title) : PichiLocalization.text(title))
                if isResearchPreview {
                    Text("Research Preview")
                        .font(self.theme.typography.captionSmall)
                        .foregroundStyle(isSelected ? self.theme.palette.accentForeground : self.theme.palette.accentText)
                }
            }
            .font(self.theme.typography.captionStrong)
            .foregroundStyle(isSelected ? self.theme.palette.accentForeground : self.theme.palette.primaryText)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        isSelected
                            ? self.theme.palette.accent
                            : (isHovered
                                ? self.theme.palette.accent.opacity(0.1)
                                : self.theme.palette.cardBackground.opacity(0.5))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(
                                isSelected || isHovered
                                    ? self.theme.palette.accent
                                    : self.theme.palette.primaryText.opacity(0.22),
                                lineWidth: isSelected || isHovered ? 1.25 : 1
                            )
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(self.isDisabled || (enabledValue && !self.isAdvancedAvailable))
        .onHover { hovering in
            let update = { self.hoveredMethod = hovering ? enabledValue : nil }
            if self.reduceMotion {
                update()
            } else {
                withAnimation(.easeOut(duration: 0.14), update)
            }
        }
    }
}

private struct DictionaryInputChrome: ViewModifier {
    let minHeight: CGFloat

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .focused(self.$isFocused)
            .dictionaryDictationInput(focused: self.isFocused)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: self.minHeight)
            .background(self.background)
            .contentShape(RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous))
            .shadow(
                color: self.isFocused ? self.theme.palette.accent.opacity(0.16) : .clear,
                radius: 7
            )
            .onHover { hovering in
                if self.reduceMotion {
                    self.isHovered = hovering
                } else {
                    withAnimation(.easeOut(duration: 0.14)) {
                        self.isHovered = hovering
                    }
                }
            }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous)
            .fill(
                self.isFocused
                    ? self.theme.palette.accent.opacity(0.08)
                    : self.theme.palette.primaryText.opacity(self.isHovered ? 0.075 : 0.055)
            )
            .overlay(
                RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous)
                    .stroke(
                        self.isFocused
                            ? self.theme.palette.accent
                            : self.theme.palette.primaryText.opacity(self.isHovered ? 0.38 : 0.26),
                        lineWidth: self.isFocused ? 1.5 : 1
                    )
            )
    }
}

private extension View {
    func dictionaryInputChrome(minHeight: CGFloat = 34) -> some View {
        self.modifier(DictionaryInputChrome(minHeight: minHeight))
    }

    func dismissTextFocusOnBackgroundTap() -> some View {
        self.background(DictionaryFocusDismissMonitor())
    }
}

private struct DictionaryFocusDismissMonitor: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        FocusDismissView()
    }

    func updateNSView(_: NSView, context _: Context) {}

    private final class FocusDismissView: NSView {
        private var eventMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            self.removeEventMonitor()
            guard self.window != nil else { return }

            self.eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let contentView = self.window?.contentView
                let location = contentView?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
                let hitView = contentView?.hitTest(location)
                if !self.isTextInput(hitView) {
                    self.window?.makeFirstResponder(nil)
                }
                return event
            }
        }

        deinit {
            self.removeEventMonitor()
        }

        private func isTextInput(_ view: NSView?) -> Bool {
            var candidate = view
            while let current = candidate {
                if current is NSTextField || current is NSTextView {
                    return true
                }
                candidate = current.superview
            }
            return false
        }

        private func removeEventMonitor() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}

private enum DictionaryTrainingCopy {
    static func target(for normalizedTarget: String) -> String {
        normalizedTarget.isEmpty ? PichiLocalization.text("the word") : "“\(normalizedTarget)”"
    }

    static func composerDetail(mode: DictionaryComposerMode, target: String) -> String {
        mode == .train && target != PichiLocalization.text("the word") ? PichiLocalization.format("Teach %@ by speaking it.", target) : PichiLocalization.text(mode.detail)
    }

    static func readinessCaption(
        target: String,
        isAlreadyCorrect: Bool,
        isReady: Bool,
        usesVoiceMatching: Bool
    ) -> String {
        if isAlreadyCorrect {
            return PichiLocalization.format("No replacement is needed for %@.", target)
        }
        if isReady {
            return usesVoiceMatching
                ? PichiLocalization.format("3 samples captured for %@. Save, then try it in a sentence.", target)
                : PichiLocalization.text("Ready. The last 3 recordings are covered by this correction.")
        }
        return usesVoiceMatching
            ? PichiLocalization.format("Say %@ 3 times to capture pronunciation samples.", target)
            : PichiLocalization.text("Repeat until 3 recordings in a row need no new corrections.")
    }
}

private enum DictionaryComposerMode: CaseIterable, Identifiable {
    case train
    case manual

    var id: Self { self }

    var title: String {
        switch self {
        case .train:
            return "Train by Voice"
        case .manual:
            return "Add Manually"
        }
    }

    var systemImage: String {
        switch self {
        case .train:
            return "mic.fill"
        case .manual:
            return "keyboard"
        }
    }

    var detail: String {
        switch self {
        case .train:
            return "Teach a word by speaking it."
        case .manual:
            return "Type the misheard text and the spelling you want."
        }
    }
}

private struct DictionaryComposerModeTab: View {
    let mode: DictionaryComposerMode
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                Image(systemName: self.mode.systemImage)
                    .font(.fluidSystem(size: 12, weight: .semibold))
                Text(PichiLocalization.text(self.mode.title))
                    .font(self.theme.typography.bodySmallStrong)
            }
            .foregroundStyle(self.foreground)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 30)
            .padding(.horizontal, self.theme.metrics.spacing.md)
            .background(self.background)
            .contentShape(RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(self.isDisabled)
        .onHover { hovering in
            guard !self.reduceMotion else {
                self.isHovered = hovering
                return
            }
            withAnimation(.easeOut(duration: 0.14)) {
                self.isHovered = hovering
            }
        }
        .accessibilityAddTraits(self.isSelected ? .isSelected : [])
    }

    private var foreground: Color {
        self.isSelected ? self.theme.palette.accentForeground : self.theme.palette.primaryText
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous)
            .fill(
                self.isSelected
                    ? self.theme.palette.accent
                    : (self.isHovered
                        ? self.theme.palette.accent.opacity(0.1)
                        : self.theme.palette.cardBackground.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous)
                    .stroke(
                        self.isSelected || self.isHovered
                            ? self.theme.palette.accent
                            : self.theme.palette.primaryText.opacity(0.22),
                        lineWidth: self.isSelected || self.isHovered ? 1.25 : 1
                    )
            )
    }
}

enum CustomDictionaryManualEntry {
    static func normalizedTrigger(_ text: String) -> String? {
        let trigger = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trigger.isEmpty ? nil : trigger
    }

    static func normalizedTriggers(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var triggers: [String] = []
        triggers.reserveCapacity(values.count)

        for value in values {
            guard let trigger = self.normalizedTrigger(value), !seen.contains(trigger) else { continue }
            seen.insert(trigger)
            triggers.append(trigger)
        }

        return triggers
    }

    static func normalizedDraftTriggers(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if trimmed.allSatisfy({ $0 == "," || $0.isWhitespace }) {
            return self.normalizedTriggers([trimmed])
        }

        return self.normalizedTriggers(trimmed.split(separator: ",").map(String.init))
    }

    /// A replacement that is entirely whitespace (e.g. a pasted newline or space)
    /// is a deliberate payload — keep it verbatim instead of trimming it to empty.
    static func sanitizedReplacement(_ text: String) -> String {
        SettingsStore.CustomDictionaryEntry.sanitizedReplacement(text)
    }

    /// Whitespace-only replacements render as invisible/blank text, so show
    /// them as symbols (⏎ ␣ ⇥) in previews and entry rows.
    static func replacementDisplayText(_ replacement: String) -> String {
        guard !replacement.isEmpty, replacement.allSatisfy(\.isWhitespace) else { return replacement }
        return replacement.map { character -> String in
            if character.isNewline {
                return "⏎"
            }
            if character == "\t" {
                return "⇥"
            }
            return "␣"
        }.joined()
    }
}

nonisolated enum DictionaryPronunciationRevisionPolicy {
    /// Pure UI snapshot: no file access, settings writes or background re-encoding.
    static func notice(
        profiles: [PronunciationDictionaryProfile],
        descriptor: ParakeetSpeechModelCatalog.Descriptor,
        entryIDs: Set<UUID>
    ) -> String? {
        guard descriptor.variant == .mini || descriptor.variant == .pico else { return nil }
        let current = Set(profiles.filter {
            ParakeetSpeechModelCatalog.sharesPronunciationFamily($0.modelKey, with: descriptor.pronunciationModelKey) && $0.isEligibleForMatching
        }.map(\.dictionaryEntryID))
        let outdated = profiles.filter {
            entryIDs.contains($0.dictionaryEntryID) && !current.contains($0.dictionaryEntryID)
                && ($0.modelKey == descriptor.modelID || $0.modelKey.hasPrefix(descriptor.modelID + ":sha256:"))
                && $0.modelKey != descriptor.pronunciationModelKey
        }
        let labels = Array(Set(outdated.map(\.label))).sorted()
        guard !labels.isEmpty else { return nil }
        let words = labels.prefix(3).joined(separator: ", ")
        let additional = labels.count > 3 ? PichiLocalization.format(" and %lld more", labels.count - 3) : ""
        return PichiLocalization.format("Pronunciation recordings for %@%@ need retraining for the updated %@. Your custom words and text corrections remain saved.", words, additional, descriptor.displayName)
    }
}

enum PronunciationProfileEditPolicy {
    static func shouldDiscardProfile(previousReplacement: String, updatedReplacement: String) -> Bool {
        previousReplacement.caseInsensitiveCompare(updatedReplacement) != .orderedSame
    }
}

/// Spelling examples are useful even when voice enrollment is missing or incomplete.
struct DictionaryTrainingProgress {
    let spellingCount: Int
    let pronunciationCount: Int
    let pronunciationEnabled: Bool

    var spellingReady: Bool { self.spellingCount >= CustomDictionaryTrainingMerge.readyCoveredCount }
    var pronunciationReady: Bool {
        self.pronunciationEnabled && self.pronunciationCount >= CustomDictionaryTrainingMerge.readyCoveredCount
    }

    func spellingAlreadyCorrect(variants: [String], lastOutput: String, target: String) -> Bool {
        self.spellingReady && variants.isEmpty && !lastOutput.isEmpty
            && lastOutput.caseInsensitiveCompare(target) == .orderedSame
    }

    var pronunciationNotice: String? {
        guard self.pronunciationEnabled else { return nil }
        let count = min(self.pronunciationCount, CustomDictionaryTrainingMerge.readyCoveredCount)
        if self.spellingReady, !self.pronunciationReady {
            if self.spellingCount >= CustomDictionaryTrainingMerge.maxSamples {
                return PichiLocalization.text("Spelling examples are ready. Pronunciation needs more voice examples. Save spelling corrections only, or redo recordings to try voice learning again.")
            }
            return PichiLocalization.format("Spelling examples are ready. Pronunciation has %lld of 3 voice examples. Record more to finish voice learning, or save spelling corrections only.", count)
        }
        return PichiLocalization.format("Pronunciation: %lld of 3 voice examples", count)
    }
}

enum CustomDictionaryTrainingMerge {
    static let recommendedSamples = 5
    static let maxSamples = 20
    static let readyCoveredCount = 3

    private static let edgePunctuation = CharacterSet(charactersIn: ".,!?;:\"'“”‘’")

    /// Conservative length guard, not a sentence classifier. ASR may split a single name into several words.
    static func isOversizedResponse(_ transcript: String, intendedReplacement: String) -> Bool {
        let targetCount = intendedReplacement.split(whereSeparator: { $0.isWhitespace }).count
        let heardCount = transcript.split(whereSeparator: { $0.isWhitespace }).count
        return heardCount > max(5, targetCount + 3)
    }

    static func normalizedReplacement(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizedTrigger(_ value: String) -> String? {
        let edgeCharacters = CharacterSet.whitespacesAndNewlines.union(self.edgePunctuation)
        let trimmed = value.trimmingCharacters(in: edgeCharacters).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    static func normalizedTriggers(from values: [String], intendedReplacement: String) -> [String] {
        let replacement = self.normalizedReplacement(intendedReplacement)
        var seen: Set<String> = []
        var result: [String] = []
        result.reserveCapacity(values.count)

        for value in values {
            let visibleTrigger = value.trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines.union(self.edgePunctuation)
            )
            guard visibleTrigger != replacement,
                  let trigger = self.normalizedTrigger(value),
                  !seen.contains(trigger)
            else {
                continue
            }
            seen.insert(trigger)
            result.append(trigger)
            if result.count >= self.maxSamples {
                break
            }
        }

        return result
    }

    static func mergedEntries(
        current entries: [SettingsStore.CustomDictionaryEntry],
        replacement: String,
        triggers: [String],
        savePronunciation: Bool = false
    ) -> [SettingsStore.CustomDictionaryEntry] {
        let replacementText = self.normalizedReplacement(replacement)
        var incomingTriggers = self.normalizedTriggers(from: triggers, intendedReplacement: replacementText)
        guard !replacementText.isEmpty else { return entries }
        // Retraining pronunciation must not change existing text correction rules.
        if incomingTriggers.isEmpty, savePronunciation,
           entries.contains(where: { $0.replacement.caseInsensitiveCompare(replacementText) == .orderedSame })
        {
            return entries
        }
        // A spelling-only rule anchors the pronunciation profile without inventing a misheard alias.
        if incomingTriggers.isEmpty, savePronunciation {
            incomingTriggers = [replacementText.lowercased()]
        }
        guard !incomingTriggers.isEmpty else { return entries }

        let matchingIndex = entries.firstIndex {
            $0.replacement.caseInsensitiveCompare(replacementText) == .orderedSame
        }
        let replacementID = matchingIndex.map { entries[$0].id }
        let matchingEntries = entries.filter {
            $0.replacement.caseInsensitiveCompare(replacementText) == .orderedSame
        }
        let existingTriggers = matchingEntries.flatMap(\.triggers)
        var combinedTriggers = self.normalizedTriggers(
            from: existingTriggers + incomingTriggers,
            intendedReplacement: replacementText
        )
        if combinedTriggers.isEmpty, savePronunciation {
            combinedTriggers = [replacementText.lowercased()]
        }
        let triggerKeys = Set(combinedTriggers)

        let mergedEntry = replacementID.map {
            SettingsStore.CustomDictionaryEntry(
                id: $0,
                triggers: combinedTriggers,
                replacement: replacementText
            )
        } ?? SettingsStore.CustomDictionaryEntry(
            triggers: combinedTriggers,
            replacement: replacementText
        )

        var didInsertMergedEntry = false
        var updatedEntries: [SettingsStore.CustomDictionaryEntry] = []
        updatedEntries.reserveCapacity(entries.count + (matchingIndex == nil ? 1 : 0))

        for entry in entries {
            if entry.replacement.caseInsensitiveCompare(replacementText) == .orderedSame {
                if !didInsertMergedEntry {
                    updatedEntries.append(mergedEntry)
                    didInsertMergedEntry = true
                }
                continue
            }

            let remainingTriggers = entry.triggers.filter { trigger in
                guard let key = self.normalizedTrigger(trigger) else { return false }
                return !triggerKeys.contains(key)
            }
            guard !remainingTriggers.isEmpty else { continue }
            updatedEntries.append(
                SettingsStore.CustomDictionaryEntry(
                    id: entry.id,
                    triggers: remainingTriggers,
                    replacement: entry.replacement
                )
            )
        }

        if !didInsertMergedEntry {
            updatedEntries.insert(mergedEntry, at: 0)
        }

        return updatedEntries
    }
}

private struct ReplacementConfirmation: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
}

private struct ReplacementConfirmationToast: View {
    let confirmation: ReplacementConfirmation

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: self.theme.metrics.spacing.sm) {
            ZStack {
                Circle()
                    .fill(self.theme.palette.elevatedCardBackground)
                    .frame(width: 58, height: 58)

                Circle()
                    .stroke(self.theme.palette.accent.opacity(0.24), lineWidth: 1)
                    .frame(width: 58, height: 58)

                Image(systemName: "checkmark")
                    .font(.fluidSystem(size: 25, weight: .bold))
                    .foregroundStyle(self.theme.palette.accentText)
            }

            VStack(spacing: 3) {
                Text(PichiLocalization.text(self.confirmation.title))
                    .font(self.theme.typography.sectionTitle)
                    .foregroundStyle(self.theme.palette.primaryText)
                Text(PichiLocalization.text(self.confirmation.detail))
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(minWidth: 220)
        .padding(.horizontal, self.theme.metrics.spacing.xl)
        .padding(.vertical, self.theme.metrics.spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg, style: .continuous)
                .fill(self.theme.palette.cardBackground.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg, style: .continuous)
                        .stroke(self.theme.palette.accent.opacity(0.3), lineWidth: 1)
                )
                .shadow(
                    color: self.theme.palette.accent.opacity(0.24),
                    radius: 24,
                    x: 0,
                    y: 10
                )
                .shadow(
                    color: Color.black.opacity(0.16),
                    radius: 18,
                    x: 0,
                    y: 8
                )
        )
        .accessibilityElement(children: .combine)
    }
}

private struct DictionaryTrainingReadinessRing: View {
    let progress: Int
    let total: Int
    let isReady: Bool
    let usesVoiceMatching: Bool

    @Environment(\.theme) private var theme

    private var fraction: Double {
        guard self.total > 0 else { return 0 }
        return min(max(Double(self.progress) / Double(self.total), 0), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(self.theme.palette.cardBorder.opacity(0.62), lineWidth: 8)

            Circle()
                .trim(from: 0, to: self.fraction)
                .stroke(
                    self.theme.palette.accent,
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            VStack(spacing: 1) {
                Text("\(self.progress)/\(self.total)")
                    .font(self.theme.typography.sectionTitle)
                    .foregroundStyle(self.isReady ? self.theme.palette.accentText : self.theme.palette.primaryText)
                    .monospacedDigit()

                Text(PichiLocalization.text(self.usesVoiceMatching ? "samples" : "covered"))
                    .font(self.theme.typography.captionSmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
        }
        .frame(width: 92, height: 92)
        .shadow(color: self.isReady ? self.theme.palette.accent.opacity(0.2) : .clear, radius: 10)
        .animation(.easeOut(duration: 0.24), value: self.progress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Training progress")
        .accessibilityValue(PichiLocalization.format("%lld of %lld %@", self.progress, self.total, PichiLocalization.text(self.usesVoiceMatching ? "samples captured" : "recordings covered")))
    }
}

private struct TrainingVariantChip: View {
    let number: Int
    let variant: String
    let onDelete: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Text("\(self.number)")
                .font(self.theme.typography.captionSmall)
                .foregroundStyle(self.theme.palette.accentText)
                .frame(minWidth: 11)

            Text(self.variant)
                .font(self.theme.typography.caption)
                .lineLimit(1)
                .truncationMode(.tail)

            Button(action: self.onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.fluidSystem(size: 11, weight: .semibold))
                    .foregroundStyle(self.theme.palette.tertiaryText)
            }
            .buttonStyle(.plain)
            .help("Remove \(self.variant)")
        }
        .frame(maxWidth: 165)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(self.theme.palette.cardBackground.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.35), lineWidth: 1)
                )
        )
    }
}

private struct DictionaryPreviewChip: View {
    let text: String

    @Environment(\.theme) private var theme

    var body: some View {
        Text(self.text)
            .font(self.theme.typography.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(self.theme.palette.cardBackground.opacity(0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(self.theme.palette.cardBorder.opacity(0.35), lineWidth: 1)
                    )
            )
    }
}

private enum BoostStrengthPreset: String, CaseIterable, Identifiable {
    case mild = "Mild"
    case balanced = "Balanced"
    case strong = "Strong"

    var id: String { self.rawValue }

    var weight: Float {
        switch self {
        case .mild: return 5.0
        case .balanced: return 10.0
        case .strong: return 13.0
        }
    }

    var hint: String {
        switch self {
        case .mild: return "Very light nudge with minimal impact."
        case .balanced: return "Best default for most names and product terms."
        case .strong: return "Use when this word should win more often in noisy audio."
        }
    }

    var badgeColor: Color {
        switch self {
        case .mild: return .blue
        case .balanced: return Color.fluidGreen
        case .strong: return .orange
        }
    }

    static func nearest(for weight: Float) -> Self {
        if weight < 8.5 { return .mild }
        if weight > 11.5 { return .strong }
        return .balanced
    }
}

// MARK: - Boost Term Row

struct BoostTermRow: View {
    let term: ParakeetVocabularyStore.VocabularyConfig.Term
    let onEdit: () -> Void
    let onDelete: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            Text(self.term.text)
                .font(self.theme.typography.bodySmallStrong)

            Spacer()

            if let weight = self.term.weight {
                let strength = BoostStrengthPreset.nearest(for: weight)
                Text(PichiLocalization.text(strength.rawValue))
                    .font(self.theme.typography.bodySmallStrong)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(self.theme.palette.elevatedCardBackground))
                    .overlay(Capsule().stroke(strength.badgeColor.opacity(0.25), lineWidth: 1))
                    .foregroundStyle(self.theme.palette.readableText(strength.badgeColor))
            }

            HStack(spacing: 2) {
                Button {
                    self.onEdit()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.fluidSystem(size: 12, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(SquareIconButtonStyle())
                .help("Configure \(self.term.text)")

                Button(role: .destructive) {
                    self.onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.fluidSystem(size: 12, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(SquareIconButtonStyle(foreground: .red, borderColor: .red))
                .help("Delete \(self.term.text)")
            }
        }
        .padding(.horizontal, self.theme.metrics.spacing.md)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.52))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.28), lineWidth: 1)
                )
        )
    }
}

// MARK: - Dictionary Entry Row

struct DictionaryEntryRow: View {
    let entry: SettingsStore.CustomDictionaryEntry
    let onEdit: () -> Void
    let onDelete: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: self.theme.metrics.spacing.sm) {
            FlowLayout(spacing: 4) {
                ForEach(self.entry.triggers, id: \.self) { trigger in
                    Text(trigger)
                        .font(self.theme.typography.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.tertiaryText)

            Text(CustomDictionaryManualEntry.replacementDisplayText(self.entry.replacement))
                .font(self.theme.typography.bodySmallStrong)
                .foregroundStyle(self.theme.palette.accentText)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                Button {
                    self.onEdit()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.fluidSystem(size: 12, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(SquareIconButtonStyle())
                .help("Configure replacement")

                Button(role: .destructive) {
                    self.onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.fluidSystem(size: 12, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(SquareIconButtonStyle(foreground: .red, borderColor: .red))
                .help("Delete replacement")
            }
        }
        .padding(.horizontal, self.theme.metrics.spacing.md)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.52))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.28), lineWidth: 1)
                )
        )
    }
}

private struct PunctuationDictionaryRuleRow: View {
    let rule: SettingsStore.PunctuationDictionaryRule
    let onEdit: () -> Void
    let onDelete: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: self.theme.metrics.spacing.sm) {
            Text(self.rule.aliases.joined(separator: ", "))
                .font(self.theme.typography.captionStrong)
                .foregroundStyle(self.theme.palette.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.tertiaryText)

            Text(self.rule.symbol)
                .font(self.theme.typography.bodySmallStrong)
                .foregroundStyle(self.theme.palette.accentText)
                .frame(width: 60, alignment: .leading)
                .lineLimit(1)

            HStack(spacing: 2) {
                Button {
                    self.onEdit()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.fluidSystem(size: 12, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(SquareIconButtonStyle())
                .help("Edit punctuation rule")

                Button(role: .destructive) {
                    self.onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.fluidSystem(size: 12, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(SquareIconButtonStyle(foreground: .red, borderColor: .red))
                .help("Delete punctuation rule")
            }
        }
        .padding(.horizontal, self.theme.metrics.spacing.md)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.52))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.28), lineWidth: 1)
                )
        )
    }
}

// MARK: - Add Entry Sheet

struct AddDictionaryEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let existingTriggers: Set<String>
    let onSave: (SettingsStore.CustomDictionaryEntry) -> Void

    @State private var triggersText = ""
    @State private var replacement = ""

    private var duplicateTriggers: [String] {
        self.parseTriggers().filter { self.existingTriggers.contains($0) }
    }

    private var canSave: Bool {
        !self.parseTriggers().isEmpty &&
            !self.replacement.trimmingCharacters(in: .whitespaces).isEmpty &&
            self.duplicateTriggers.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text("Add Dictionary Entry")
                    .font(.fluidSystem(.headline))
                Spacer()
                Button("Cancel") { self.dismiss() }
                    .fluidGlassAction()
                    .keyboardShortcut(.cancelAction)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Triggers input
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Misheard Words (triggers)")
                            .font(.fluidSystem(.subheadline).weight(.medium))
                        Text("Add one version per line. Commas can be saved too.")
                            .font(.fluidSystem(.caption))
                            .foregroundStyle(self.theme.palette.secondaryText)
                        TextEditor(text: self.$triggersText)
                            .font(.fluidSystem(.body))
                            .frame(minHeight: 54, maxHeight: 76)
                            .scrollContentBackground(.hidden)
                            .dictionaryInputChrome(minHeight: 54)

                        // Duplicate warning
                        if !self.duplicateTriggers.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(self.theme.palette.readableText(self.theme.palette.warning))
                                Text("Duplicate triggers: \(self.duplicateTriggers.joined(separator: ", "))")
                                    .foregroundStyle(self.theme.palette.readableText(self.theme.palette.warning))
                            }
                            .font(.fluidSystem(.caption))
                        }
                    }

                    // Replacement input
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Correct Spelling (replacement)")
                            .font(.fluidSystem(.subheadline).weight(.medium))
                        Text("This is what will appear in the final transcription.")
                            .font(.fluidSystem(.caption))
                            .foregroundStyle(self.theme.palette.secondaryText)
                        TextField(AppBrand.text("FluidVoice"), text: self.$replacement)
                            .dictionaryInputChrome()
                            .onSubmit { self.saveIfValid() }
                    }

                    if !self.parseTriggers().isEmpty && !self.replacement.isEmpty {
                        DictionaryReplacementPreview(
                            triggers: self.parseTriggers(),
                            replacement: self.replacement,
                            duplicateTriggers: self.duplicateTriggers
                        )
                    }
                }
                .padding(2)
            }
            .frame(minHeight: 0, maxHeight: .infinity)

            Divider()
            // Save button
            HStack {
                Spacer()
                Button("Add Replacement") { self.saveIfValid() }
                    .fluidGlassAction(prominent: true, tone: self.theme.palette.accent)
                    .disabled(!self.canSave)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(20)
        .frame(minWidth: 400, idealWidth: 480, maxWidth: 560)
        .frame(minHeight: 360, idealHeight: 500, maxHeight: 600)
        .dismissTextFocusOnBackgroundTap()
    }

    private func parseTriggers() -> [String] {
        CustomDictionaryManualEntry.normalizedTriggers(
            self.triggersText.components(separatedBy: .newlines)
        )
    }

    private func saveIfValid() {
        guard self.canSave else { return }

        let entry = SettingsStore.CustomDictionaryEntry(
            triggers: self.parseTriggers(),
            replacement: self.replacement.trimmingCharacters(in: .whitespaces)
        )
        self.onSave(entry)
        self.dismiss()
    }
}

private struct DictionaryReplacementPreview: View {
    @Environment(\.theme) private var theme

    let triggers: [String]
    let replacement: String
    let duplicateTriggers: [String]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow(alignment: .firstTextBaseline) {
                Text("Misheard")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear
                    .gridCellUnsizedAxes([.horizontal, .vertical])
                    .accessibilityHidden(true)
                Text("Corrected")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.fluidSystem(.caption))
            .foregroundStyle(self.theme.palette.secondaryText)

            GridRow(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(self.triggers, id: \.self) { trigger in
                        Text(trigger)
                            .font(.fluidSystem(.body))
                            .foregroundStyle(
                                self.duplicateTriggers.contains(trigger)
                                    ? Color.orange : self.theme.palette.primaryText
                            )
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.right")
                    .font(.fluidSystem(.body).weight(.medium))
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .accessibilityHidden(true)

                Text(CustomDictionaryManualEntry.replacementDisplayText(
                    CustomDictionaryManualEntry.sanitizedReplacement(self.replacement)
                ))
                .font(.fluidSystem(.body).weight(.semibold))
                .foregroundStyle(self.theme.palette.accentText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(self.theme.palette.primaryText.opacity(0.035))
        )
    }
}

// MARK: - Edit Entry Sheet

struct EditDictionaryEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let entry: SettingsStore.CustomDictionaryEntry
    let existingTriggers: Set<String>
    let isCaptureBusy: Bool
    let onSave: (SettingsStore.CustomDictionaryEntry) -> Void

    @State private var triggersText = ""
    @State private var replacement = ""
    @State private var isTestingWord = false
    @State private var isTestBusy = false

    private var duplicateTriggers: [String] {
        self.parseTriggers().filter { self.existingTriggers.contains($0) }
    }

    private var canSave: Bool {
        !self.parseTriggers().isEmpty &&
            !CustomDictionaryManualEntry.sanitizedReplacement(self.replacement).isEmpty &&
            self.duplicateTriggers.isEmpty
    }

    private var hasUnsavedChanges: Bool {
        self.parseTriggers() != self.entry.triggers ||
            CustomDictionaryManualEntry.sanitizedReplacement(self.replacement) != self.entry.replacement
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text("Edit Dictionary Entry")
                    .font(.fluidSystem(.headline))
                Spacer()
                Button("Cancel") { self.dismiss() }
                    .fluidGlassAction()
                    .keyboardShortcut(.cancelAction)
            }

            Divider()

            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Triggers input
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Misheard Words (triggers)")
                                .font(.fluidSystem(.subheadline).weight(.medium))
                            Text("Add one version per line. Commas can be saved too.")
                                .font(.fluidSystem(.caption))
                                .foregroundStyle(self.theme.palette.secondaryText)
                            TextEditor(text: self.$triggersText)
                                .font(.fluidSystem(.body))
                                .frame(minHeight: 54, maxHeight: 76)
                                .scrollContentBackground(.hidden)
                                .dictionaryInputChrome(minHeight: 54)

                            // Duplicate warning
                            if !self.duplicateTriggers.isEmpty {
                                HStack(spacing: 4) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(self.theme.palette.readableText(self.theme.palette.warning))
                                    Text("Duplicate triggers: \(self.duplicateTriggers.joined(separator: ", "))")
                                        .foregroundStyle(self.theme.palette.readableText(self.theme.palette.warning))
                                }
                                .font(.fluidSystem(.caption))
                            }
                        }
                        .disabled(self.isTestBusy)

                        // Replacement input
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Correct Spelling (replacement)")
                                .font(.fluidSystem(.subheadline).weight(.medium))
                            Text("This is what will appear in the final transcription.")
                                .font(.fluidSystem(.caption))
                                .foregroundStyle(self.theme.palette.secondaryText)
                            TextField(AppBrand.text("FluidVoice"), text: self.$replacement)
                                .dictionaryInputChrome()
                                .onSubmit { self.saveIfValid() }
                        }
                        .disabled(self.isTestBusy)

                        if !self.parseTriggers().isEmpty && !self.replacement.isEmpty {
                            DictionaryReplacementPreview(
                                triggers: self.parseTriggers(),
                                replacement: self.replacement,
                                duplicateTriggers: self.duplicateTriggers
                            )
                        }

                        if self.isTestingWord {
                            Divider()
                            DictionaryWordPlayground(
                                word: self.entry.replacement,
                                onPracticeMore: nil,
                                busy: self.$isTestBusy
                            )
                            .id("dictionary-word-test")
                        }
                    }
                    .padding(2)
                }
                .task(id: self.isTestingWord) {
                    guard self.isTestingWord else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    scroll.scrollTo("dictionary-word-test", anchor: .bottom)
                }
            }
            .frame(minHeight: 0, maxHeight: .infinity)

            Divider()
            // Save button
            HStack {
                Button(PichiLocalization.text(self.isTestingWord ? "Hide test" : "Test word")) {
                    self.isTestingWord.toggle()
                }
                .fluidGlassAction(quiet: true)
                .disabled(self.hasUnsavedChanges || self.isCaptureBusy || self.isTestBusy)
                .help(PichiLocalization.text(self.hasUnsavedChanges ? "Save your changes before testing this word." : "Try this word with your dictation shortcut."))
                Spacer()
                Button("Save Changes") { self.saveIfValid() }
                    .fluidGlassAction(prominent: true, tone: self.theme.palette.accent)
                    .disabled(!self.canSave || self.isTestBusy)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(20)
        .frame(minWidth: 400, idealWidth: 480, maxWidth: 560)
        .frame(minHeight: 360, idealHeight: self.isTestingWord ? 680 : 500, maxHeight: self.isTestingWord ? 780 : 600)
        .background(self.theme.palette.windowBackground)
        .appTheme(self.theme)
        .dismissTextFocusOnBackgroundTap()
        .onChange(of: self.hasUnsavedChanges) { _, changed in
            if changed { self.isTestingWord = false }
        }
        .onAppear {
            self.triggersText = self.entry.triggers.joined(separator: "\n")
            self.replacement = self.entry.replacement
        }
    }

    private func parseTriggers() -> [String] {
        CustomDictionaryManualEntry.normalizedTriggers(
            self.triggersText.components(separatedBy: .newlines)
        )
    }

    private func saveIfValid() {
        guard self.canSave, !self.isTestBusy else { return }

        let updatedEntry = SettingsStore.CustomDictionaryEntry(
            id: self.entry.id,
            triggers: self.parseTriggers(),
            replacement: CustomDictionaryManualEntry.sanitizedReplacement(self.replacement)
        )
        self.onSave(updatedEntry)
        self.dismiss()
    }
}

//
//  SettingsSearch.swift
//  fluid
//
//  Search metadata and fuzzy matching for the Settings sidebar.
//

import AppKit
import AVFoundation
import Foundation
import SwiftUI

enum SettingsSearchTarget: Hashable {
    case general
    case launchAtStartup
    case showWindowAtLogin
    case dockVisibility
    case accentColor
    case transcriptionSounds
    case automaticUpdates
    case analyticsPrivacy

    case dictation
    case shortcuts
    case microphonePermission
    case globalHotkey
    case primaryDictationShortcuts
    case commandModeShortcut
    case editModeShortcut
    case cancelRecordingShortcut
    case pasteLastTranscriptionShortcut
    case activationMode
    case holdSpaceToMute
    case copyToClipboard
    case textInsertionMode
    case spokenSend
    case transcriptionHistory
    case audioHistory
    case usageStreak
    case skipSilentRecordings
    case pauseMedia
    case dictionarySuggestions
    case accessibilityPermission
    case textFormatting
    case spokenFormatting
    case fillerWords

    case notifications
    case aiEnhancementFailures
    case microphoneChanges
    case pasteCheck

    case audio
    case inputDevicePriority
    case outputDevice

    case overlay
    case overlaySensitivity
    case overlayPosition
    case transcriptionPreviewLength
    case overlayStyle
    case livePreview
    case bottomOffset

    case dataAndDiagnostics
    case backupAndRestore
    case audioStorage
    case debugLogs
    case experimental
    case returnToStartingField
    case fasterLongDictation
    case dictionaryMatcherExperiments
    case historyPerformance
    case localAPI

    var section: SettingsSection {
        switch self {
        case .general,
             .launchAtStartup,
             .showWindowAtLogin,
             .dockVisibility,
             .accentColor,
             .transcriptionSounds,
             .automaticUpdates:
            return .general

        case .dictation,
             .analyticsPrivacy,
             .microphonePermission,
             .activationMode,
             .holdSpaceToMute,
             .copyToClipboard,
             .textInsertionMode,
             .spokenSend,
             .transcriptionHistory,
             .audioHistory,
             .audioStorage,
             .usageStreak,
             .skipSilentRecordings,
             .pauseMedia,
             .dictionarySuggestions,
             .accessibilityPermission:
            return .dictation

        case .textFormatting, .spokenFormatting, .fillerWords:
            return .dictationFormatting

        case .shortcuts, .globalHotkey, .primaryDictationShortcuts,
             .commandModeShortcut, .editModeShortcut, .cancelRecordingShortcut,
             .pasteLastTranscriptionShortcut:
            return .shortcuts

        case .notifications, .aiEnhancementFailures, .microphoneChanges, .pasteCheck:
            return .notifications

        case .audio, .inputDevicePriority, .outputDevice:
            return .audio

        case .overlay,
             .overlaySensitivity,
             .overlayPosition,
             .transcriptionPreviewLength,
             .overlayStyle,
             .livePreview,
             .bottomOffset:
            return .overlay

        case .dataAndDiagnostics, .backupAndRestore, .debugLogs:
            return .dataAndDiagnostics

        case .experimental, .returnToStartingField, .fasterLongDictation, .dictionaryMatcherExperiments, .historyPerformance, .localAPI:
            return .experimental
        }
    }
}

extension SettingsSection {
    var searchTarget: SettingsSearchTarget {
        switch self {
        case .general: return .general
        case .dictation: return .dictation
        case .dictationFormatting: return .textFormatting
        case .shortcuts: return .shortcuts
        case .notifications: return .notifications
        case .audio: return .audio
        case .overlay: return .overlay
        case .dataAndDiagnostics: return .dataAndDiagnostics
        case .experimental: return .experimental
        }
    }
}

struct SettingsSearchResult: Identifiable, Equatable {
    let target: SettingsSearchTarget
    let score: Int

    var id: SettingsSearchTarget {
        self.target
    }

    var section: SettingsSection {
        self.target.section
    }
}

struct SettingsSearchAvailability {
    let microphoneAuthorized: Bool
    let accessibilityEnabled: Bool
    let savesTranscriptionHistory: Bool
    let savesAudioWithTranscriptionHistory: Bool
    let overlayAtBottom: Bool

    static var current: Self {
        let settings = SettingsStore.shared
        return Self(
            microphoneAuthorized: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            accessibilityEnabled: AXIsProcessTrusted(),
            savesTranscriptionHistory: settings.saveTranscriptionHistory,
            savesAudioWithTranscriptionHistory: settings.saveAudioWithTranscriptionHistory,
            overlayAtBottom: settings.overlayPosition == .bottom
        )
    }

    func includes(_ target: SettingsSearchTarget) -> Bool {
        switch target {
        case .microphonePermission:
            return !self.microphoneAuthorized
        case .accessibilityPermission:
            return !self.accessibilityEnabled
        case .primaryDictationShortcuts,
             .commandModeShortcut,
             .editModeShortcut,
             .cancelRecordingShortcut,
             .pasteLastTranscriptionShortcut,
             .activationMode,
             .copyToClipboard,
             .textInsertionMode,
             .spokenSend,
             .transcriptionHistory,
             .audioHistory,
             .usageStreak,
             .skipSilentRecordings,
             .pauseMedia,
             .dictionarySuggestions,
             .analyticsPrivacy:
            return self.accessibilityEnabled
        case .audioStorage:
            return self.accessibilityEnabled &&
                self.savesTranscriptionHistory &&
                self.savesAudioWithTranscriptionHistory
        case .bottomOffset:
            return self.overlayAtBottom
        default:
            return true
        }
    }
}

enum SettingsSearchIndex {
    private static let queryStopWords: Set<String> = ["and", "for", "from", "in", "of", "or", "the", "to", "with", "и", "для", "из", "в", "на", "или", "с"]

    private struct Entry {
        let target: SettingsSearchTarget
        let title: String
        let terms: [String]
    }

    private struct WeightedField {
        let text: String
        let weight: Int
    }

    private static var entries: [Entry] { [
        .init(target: .general, title: "General", terms: ["app settings preferences"]),
        .init(
            target: .launchAtStartup,
            title: "Launch at startup",
            terms: ["Automatically start FluidVoice when you log in", AppBrand.text("Automatically start FluidVoice when you log in"), "login startup boot open"]
        ),
        .init(
            target: .showWindowAtLogin,
            title: "Show window when launched at login",
            terms: ["starts silently in the menu bar", "login window visibility"]
        ),
        .init(
            target: .dockVisibility,
            title: "Hide from Dock & App Switcher",
            terms: ["menu bar only", "dock icon command tab cmd tab app switcher"]
        ),
        .init(target: .accentColor, title: "Accent Color", terms: ["appearance theme tint colour preset"]),
        .init(
            target: .transcriptionSounds,
            title: "Transcription Sounds",
            terms: ["recording sound cue volume independent mute start end audio"]
        ),
        .init(
            target: .automaticUpdates,
            title: "Automatic Updates",
            terms: ["beta releases check for updates release notes rollback previous builds version popup pop-ups notifications update available"]
        ),
        .init(
            target: .analyticsPrivacy,
            title: "Share Detailed Anonymous Analytics",
            terms: ["Analytics Privacy what we collect telemetry data active use weekly opt out"]
        ),

        .init(target: .dictation, title: "Dictation", terms: ["typing transcription keyboard preferences"]),
        .init(
            target: .microphonePermission,
            title: "Microphone Permission",
            terms: ["mic access authorization privacy grant denied system settings"]
        ),
        .init(target: .shortcuts, title: "Shortcuts", terms: ["keyboard hotkeys Smart Fluid Intelligence", AppBrand.text("keyboard hotkeys Smart Fluid Intelligence")]),
        .init(target: .globalHotkey, title: "Global Hotkey", terms: ["keyboard shortcut activation accessibility"]),
        .init(
            target: .primaryDictationShortcuts,
            title: "Primary Dictation Shortcuts",
            terms: ["keyboard shortcut mouse button record hotkey"]
        ),
        .init(target: .commandModeShortcut, title: "Command Mode", terms: ["voice commands terminal hotkey shortcut"]),
        .init(target: .editModeShortcut, title: "Edit Mode", terms: ["rewrite selected text hotkey shortcut"]),
        .init(
            target: .cancelRecordingShortcut,
            title: "Cancel Recording",
            terms: ["dismiss overlay stop hotkey shortcut"]
        ),
        .init(
            target: .pasteLastTranscriptionShortcut,
            title: "Paste Last Transcription",
            terms: ["reinsert recent text hotkey shortcut clipboard"]
        ),
        .init(target: .activationMode, title: "Activation Mode", terms: ["hold toggle hotkey behavior"]),
        .init(target: .holdSpaceToMute, title: "Hold Space to Mute", terms: ["pause microphone spacebar resume silence"]),
        .init(
            target: .copyToClipboard,
            title: "Copy to Clipboard",
            terms: ["automatically copy transcribed text pasteboard backup"]
        ),
        .init(
            target: .textInsertionMode,
            title: "Text Insertion Mode",
            terms: ["type text copy paste clipboard reliable insertion delivery"]
        ),
        .init(
            target: .spokenSend,
            title: "Spoken Send",
            terms: ["send immediately phrase command enter return submit voice"]
        ),
        .init(
            target: .transcriptionHistory,
            title: "Save Transcription History",
            terms: ["stats tracking privacy remember transcript"]
        ),
        .init(
            target: .audioHistory,
            title: "Save Audio With History",
            terms: ["store microphone recording locally dictation audio"]
        ),
        .init(
            target: .usageStreak,
            title: "Weekends Don't Break Streak",
            terms: ["Saturday Sunday stats usage streak weekday"]
        ),
        .init(
            target: .skipSilentRecordings,
            title: "Skip Silent Recordings",
            terms: ["silence quiet speech avoid transcription"]
        ),
        .init(
            target: .pauseMedia,
            title: "Pause Media During Transcription",
            terms: ["resume music audio video playback recording"]
        ),
        .init(
            target: .dictionarySuggestions,
            title: "Learn from my corrections",
            terms: ["automatic corrections learn words custom dictionary frequency ignore"]
        ),
        .init(
            target: .accessibilityPermission,
            title: "Accessibility Permission",
            terms: ["global hotkey access macOS system settings authorize"]
        ),
        .init(
            target: .textFormatting,
            title: "Text Formatting",
            terms: [
                "Dictation Formatting Lowercase First Letter Remove Trailing Period Slash Commands @ Formatting",
                "Space Between Dictations Smart Capitalization punctuation uppercase symbols mentions",
            ]
        ),

        .init(target: .spokenFormatting, title: "Spoken Formatting", terms: ["punctuation start word symbols new line paragraph"]),
        .init(target: .fillerWords, title: "Remove Filler Words", terms: ["um uh er filler sounds cleanup"]),
        .init(target: .notifications, title: "Notifications", terms: ["alerts warnings"]),
        .init(
            target: .aiEnhancementFailures,
            title: "AI Enhancement Failures",
            terms: ["notify processing error raw transcription alert"]
        ),
        .init(
            target: .microphoneChanges,
            title: "Microphone Changes",
            terms: ["mic device lost changed alert notification"]
        ),
        .init(
            target: .pasteCheck,
            title: "Paste Check",
            terms: ["text wasn't inserted not inserted card clipboard verify delivery failure alert"]
        ),

        .init(target: .audio, title: "Audio", terms: ["sound devices microphone speaker"]),
        .init(
            target: .inputDevicePriority,
            title: "Input Device Priority",
            terms: ["microphone mic order drag reorder default restore removed unavailable active"]
        ),
        .init(
            target: .outputDevice,
            title: "Output Device",
            terms: ["speaker headphones audio system default refresh loading"]
        ),

        .init(target: .overlay, title: "Overlay", terms: ["recording indicator notch pill visualizer"]),
        .init(
            target: .overlaySensitivity,
            title: "Sensitivity",
            terms: ["audio visualizer sound input more less threshold"]
        ),
        .init(
            target: .overlayPosition,
            title: "Overlay Position",
            terms: ["recording indicator screen notch pill bottom location"]
        ),
        .init(
            target: .transcriptionPreviewLength,
            title: "Transcription Preview Length",
            terms: ["recent characters notch pill preview size"]
        ),
        .init(
            target: .overlayStyle,
            title: "Overlay Size & Notch Style",
            terms: ["large compact regular recording indicator presentation layout"]
        ),
        .init(
            target: .livePreview,
            title: "Live Preview",
            terms: ["streaming transcription text while speak overlay"]
        ),
        .init(target: .bottomOffset, title: "Bottom Offset", terms: ["distance from bottom screen pixels position"]),

        .init(
            target: .dataAndDiagnostics,
            title: "Data & Diagnostics",
            terms: ["backup restore debug logs experimental storage troubleshooting"]
        ),
        .init(
            target: .backupAndRestore,
            title: "Backup & Restore",
            terms: ["export import settings prompt profiles history stats API keys"]
        ),
        .init(
            target: .audioStorage,
            title: "Audio Storage",
            terms: ["history budget GB export ZIP delete prune WAV manifest"]
        ),
        .init(
            target: .debugLogs,
            title: "Debug Settings",
            terms: ["Show Debug Logs in App Reveal Log File crash diagnostics troubleshooting"]
        ),
        .init(
            target: .returnToStartingField,
            title: "Return to Starting Field",
            terms: ["experimental dictation paste cursor focus original starting app destination switch apps"]
        ),
        .init(
            target: .fasterLongDictation,
            title: "Faster Long Dictation",
            terms: ["experimental Parakeet reuse live windows remaining tail transcription"]
        ),
        .init(
            target: .experimental,
            title: "Experimental",
            terms: ["preview early access optional features"]
        ),
        .init(
            target: .dictionaryMatcherExperiments,
            title: "Learn from your pronunciation",
            terms: ["pronunciation voice training matching dictionary experimental"]
        ),
        .init(
            target: .historyPerformance,
            title: "Show Performance in History",
            terms: ["timing speed tokens per second ASR cleanup Fluid Intelligence", AppBrand.text("timing speed tokens per second ASR cleanup Fluid Intelligence")]
        ),
        .init(
            target: .localAPI,
            title: "Enable Local API",
            terms: ["experimental loopback http server endpoint port 47733 browser extension integration transcribe"]
        ),
    ] }

    static func results(for query: String) -> [SettingsSearchResult] {
        let normalizedQuery = self.normalize(query)
        guard !normalizedQuery.isEmpty else { return [] }

        let rankedResults: [(index: Int, result: SettingsSearchResult)] = self.entries.enumerated().compactMap { index, entry in
            guard let score = self.score(entry, for: normalizedQuery) else { return nil }
            return (index, SettingsSearchResult(target: entry.target, score: score))
        }

        return rankedResults.sorted { lhs, rhs in
            if lhs.result.score == rhs.result.score {
                return lhs.index < rhs.index
            }
            return lhs.result.score > rhs.result.score
        }
        .map(\.result)
    }

    static func results(
        for query: String,
        availability: SettingsSearchAvailability
    ) -> [SettingsSearchResult] {
        self.results(for: query).filter { availability.includes($0.target) }
    }

    static func title(for target: SettingsSearchTarget) -> String {
        self.entries.first { $0.target == target }?.title ?? target.section.title
    }

    static func matchingSections(for query: String) -> [SettingsSection] {
        let matchingSections = Set(self.results(for: query).map(\.section))
        return SettingsSection.allCases.filter(matchingSections.contains)
    }

    static func preferredSection(
        current: SettingsSection?,
        results: [SettingsSearchResult]
    ) -> SettingsSection? {
        guard !results.isEmpty else { return current }
        if let current, results.contains(where: { $0.section == current }) {
            return current
        }
        return results.first?.section
    }

    private static func score(_ entry: Entry, for query: String) -> Int? {
        let sourceFields = [
            WeightedField(text: entry.title, weight: 100),
            WeightedField(text: entry.target.section.title, weight: 45),
        ] + entry.terms.map { WeightedField(text: $0, weight: 55) }
        // Keep English aliases while matching the labels shown in the selected UI language.
        let localizedFields = sourceFields.compactMap { field -> WeightedField? in
            let localized = PichiLocalization.text(field.text)
            return localized == field.text ? nil : WeightedField(text: localized, weight: field.weight)
        }
        let fields = sourceFields + localizedFields

        let allQueryTokens = self.tokens(in: query)
        let meaningfulQueryTokens = allQueryTokens.filter { !self.queryStopWords.contains($0) }
        let queryTokens = meaningfulQueryTokens.isEmpty ? allQueryTokens : meaningfulQueryTokens
        let compactQuery = self.compact(query)
        let compactCandidates = fields.flatMap { field in
            var candidates = [self.compact(self.normalize(field.text))]
            for token in self.tokens(in: field.text) {
                candidates.append(self.compact(token))
            }
            return candidates
        }
        let hasCompactFuzzyMatch = compactQuery.count >= 4 &&
            compactCandidates.contains(where: { self.isFuzzyMatch(query: compactQuery, candidate: $0) })
        var score = 0

        for queryToken in queryTokens {
            let bestTokenScore = fields.compactMap { field -> Int? in
                self.tokens(in: field.text)
                    .compactMap { self.tokenScore(query: queryToken, candidate: $0) }
                    .max()
                    .map { $0 + field.weight }
            }.max()

            if let bestTokenScore {
                score += bestTokenScore
            } else if !hasCompactFuzzyMatch {
                return nil
            }
        }

        let normalizedTitle = self.normalize(entry.title)
        let normalizedSection = self.normalize(entry.target.section.title)
        score += self.phraseBonus(query: query, candidate: normalizedTitle, exactBonus: 1000)
        score += self.phraseBonus(query: query, candidate: normalizedSection, exactBonus: 400)

        for term in entry.terms {
            score += self.phraseBonus(query: query, candidate: self.normalize(term), exactBonus: 220)
        }
        for field in localizedFields {
            let bonus = field.weight == 100 ? 1000 : (field.weight == 45 ? 400 : 220)
            score += self.phraseBonus(query: query, candidate: self.normalize(field.text), exactBonus: bonus)
        }

        if hasCompactFuzzyMatch {
            score += 180
        }

        return score
    }

    private static func phraseBonus(query: String, candidate: String, exactBonus: Int) -> Int {
        if candidate == query {
            return exactBonus
        }
        if candidate.hasPrefix(query) {
            return exactBonus * 3 / 5
        }
        if query.count >= 3, candidate.contains(query) {
            return exactBonus * 2 / 5
        }
        return 0
    }

    private static func tokenScore(query: String, candidate: String) -> Int? {
        if candidate == query {
            return 120
        }
        if candidate.hasPrefix(query) {
            return 105
        }
        if query.count >= 3, candidate.contains(query) {
            return 90
        }
        if self.isFuzzyMatch(query: query, candidate: candidate) {
            return 70 - (self.editDistance(query, candidate) * 8)
        }
        return nil
    }

    private static func isFuzzyMatch(query: String, candidate: String) -> Bool {
        let tolerance: Int
        switch query.count {
        case 0...3:
            return false
        case 4...6:
            tolerance = 1
        default:
            tolerance = 2
        }

        guard abs(query.count - candidate.count) <= tolerance else { return false }
        return self.editDistance(query, candidate) <= tolerance
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        guard !left.isEmpty else { return right.count }
        guard !right.isEmpty else { return left.count }

        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            current.reserveCapacity(right.count + 1)

            for (rightIndex, rightCharacter) in right.enumerated() {
                current.append(min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                ))
            }
            previous = current
        }
        return previous[right.count]
    }

    private static func normalize(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        let separated = folded.map { character in
            character.isLetter || character.isNumber ? character : " "
        }
        return String(separated)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func tokens(in value: String) -> [String] {
        self.normalize(value).split(separator: " ").map(String.init)
    }

    private static func compact(_ value: String) -> String {
        value.filter { !$0.isWhitespace }
    }
}

/// An `NSSearchField` for a sidebar. Esc clears it. Up, Down and Return are handed
/// to `onCommand` so a results list can be driven from the keyboard, and Cmd+F
/// (`Notification.Name.sidebarSearchFocusRequested`) focuses whichever instance
/// is active.
struct SidebarSearchField: View {
    @Environment(\.theme) private var theme
    @Environment(\.locale) private var interfaceLocale
    @Binding var text: String
    let placeholder: String
    let isActive: Bool
    var onCommand: (Selector) -> Bool = { _ in false }
    @State private var isFocused = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(self.theme.palette.secondaryText)
                .accessibilityHidden(true)
            SidebarSearchInput(
                text: self.$text,
                placeholder: PichiLocalization.text(self.placeholder, locale: self.interfaceLocale),
                isActive: self.isActive,
                font: self.theme.typography.nativeBodyFont,
                textColor: NSColor(self.theme.palette.primaryText),
                placeholderColor: NSColor(self.theme.palette.secondaryText),
                onCommand: self.onCommand,
                isFocused: self.$isFocused
            )
            if !self.text.isEmpty {
                Button {
                    self.text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(.fluidSystem(size: 14))
        .padding(.horizontal, self.theme.metrics.spacing.sm)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous)
                .fill(self.theme.palette.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous)
                .strokeBorder(self.isFocused ? self.theme.palette.accentText : .clear, lineWidth: 2)
                .allowsHitTesting(false)
        )
    }

    static func owns(_ editor: NSTextView, in window: NSWindow) -> Bool {
        SidebarSearchInput.owns(editor, in: window)
    }

    static func resignFocusIfNeeded(from searchField: NSSearchField, isActive: Bool) {
        SidebarSearchInput.resignFocusIfNeeded(from: searchField, isActive: isActive)
    }
}

private final class SidebarSearchNativeField: NSSearchField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { self.onFocus?() }
        return accepted
    }
}

private struct SidebarSearchInput: NSViewRepresentable {
    private static let identifier = NSUserInterfaceItemIdentifier("FluidVoice.SidebarSearchField")

    @Binding var text: String
    let placeholder: String
    let isActive: Bool
    let font: NSFont
    let textColor: NSColor
    let placeholderColor: NSColor
    var onCommand: (Selector) -> Bool = { _ in false }

    @Binding var isFocused: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = SidebarSearchNativeField()
        searchField.onFocus = { [weak coordinator = context.coordinator] in
            coordinator?.parent.isFocused = true
        }
        searchField.delegate = context.coordinator
        self.applyAppearance(to: searchField)
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.controlSize = .large
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        (searchField.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        (searchField.cell as? NSSearchFieldCell)?.cancelButtonCell = nil
        searchField.font = self.font
        searchField.identifier = Self.identifier
        searchField.setAccessibilityLabel(self.placeholder)
        context.coordinator.observeFocusRequests(for: searchField)
        return searchField
    }

    func updateNSView(_ searchField: NSSearchField, context: Context) {
        context.coordinator.parent = self
        // The host resolved this known UI key using its selected locale. Keep it verbatim here.
        self.applyAppearance(to: searchField)
        searchField.setAccessibilityLabel(self.placeholder)
        if searchField.stringValue != self.text {
            searchField.stringValue = self.text
        }
        Self.resignFocusIfNeeded(from: searchField, isActive: self.isActive)
    }

    private func applyAppearance(to searchField: NSSearchField) {
        if searchField.font != self.font { searchField.font = self.font }
        if searchField.textColor != self.textColor { searchField.textColor = self.textColor }
        searchField.placeholderAttributedString = NSAttributedString(
            string: self.placeholder,
            attributes: [.font: self.font, .foregroundColor: self.placeholderColor]
        )
        if let editor = searchField.currentEditor() as? NSTextView {
            editor.textColor = self.textColor
            editor.insertionPointColor = self.textColor
        }
    }

    static func resignFocusIfNeeded(from searchField: NSSearchField, isActive: Bool) {
        guard !isActive,
              searchField.currentEditor() != nil,
              let window = searchField.window
        else { return }

        window.makeFirstResponder(nil)
    }

    static func owns(_ editor: NSTextView, in window: NSWindow) -> Bool {
        guard editor.isFieldEditor, let contentView = window.contentView else { return false }
        var views = [contentView]
        while let view = views.popLast() {
            if let searchField = view as? NSSearchField,
               searchField.identifier == Self.identifier,
               searchField.currentEditor() === editor
            {
                return true
            }
            views.append(contentsOf: view.subviews)
        }
        return false
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SidebarSearchInput
        private var focusObserver: NSObjectProtocol?

        init(_ parent: SidebarSearchInput) {
            self.parent = parent
        }

        deinit {
            self.focusObserver.map(NotificationCenter.default.removeObserver)
        }

        func observeFocusRequests(for searchField: NSSearchField) {
            self.focusObserver = NotificationCenter.default.addObserver(
                forName: .sidebarSearchFocusRequested, object: nil, queue: .main
            ) { [weak self, weak searchField] _ in
                guard let self, self.parent.isActive, let searchField else { return }
                searchField.window?.makeFirstResponder(searchField)
            }
        }

        func controlTextDidBeginEditing(_: Notification) {
            self.parent.isFocused = true
        }

        func controlTextDidEndEditing(_: Notification) {
            self.parent.isFocused = false
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else { return }
            self.parent.text = searchField.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else {
                return self.parent.onCommand(commandSelector)
            }
            textView.string = ""
            control.stringValue = ""
            self.parent.text = ""
            return true
        }
    }
}

extension Notification.Name {
    static let sidebarSearchFocusRequested = Notification.Name("FluidVoice.sidebarSearchFocusRequested")
}

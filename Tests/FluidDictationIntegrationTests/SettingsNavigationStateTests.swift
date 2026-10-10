import AppKit
import Combine
import SwiftUI
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class SettingsNavigationStateTests: XCTestCase {
    func testPresentAndDismissRestoresPreviousAppDestination() {
        var state = SettingsNavigationState()

        state.present(.general, returningTo: .history)

        XCTAssertTrue(state.isPresented)
        XCTAssertEqual(state.selectedSection, .general)
        XCTAssertEqual(state.returnDestination, .history)
        XCTAssertEqual(state.dismiss(), .history)
        XCTAssertFalse(state.isPresented)
    }

    func testSpecificDeepLinkChangesSectionWithoutReplacingReturnDestination() {
        var state = SettingsNavigationState()
        state.present(.general, returningTo: .stats)

        state.present(.audio, returningTo: .customDictionary)

        XCTAssertEqual(state.selectedSection, .audio)
        XCTAssertEqual(state.returnDestination, .stats)
    }

    func testMissingReturnDestinationFallsBackToGettingStarted() {
        var state = SettingsNavigationState()

        state.present(.general, returningTo: nil)

        XCTAssertEqual(state.dismiss(), .welcome)
    }

    func testLeavingForAppDismissesSettings() {
        var state = SettingsNavigationState()
        state.present(.overlay, returningTo: .voiceEngine)

        state.leaveForApp()

        XCTAssertFalse(state.isPresented)
        XCTAssertNil(state.selectedSection)
    }

    func testDetectsWhenNavigationLeavesDictationSettings() {
        var state = SettingsNavigationState()
        state.present(.dictation, returningTo: .welcome)

        XCTAssertTrue(state.isLeaving(.dictation, for: .audio))
        XCTAssertTrue(state.isLeaving(.dictation, for: nil))
        XCTAssertFalse(state.isLeaving(.dictation, for: .dictation))
    }

    func testAIProviderAndCleanupRoutesMapToSeparateSections() {
        XCTAssertEqual(SidebarItem.aiEnhancements.aiEnhancementConfigurationSection, .providers)
        XCTAssertEqual(SidebarItem.cleanupStyles.aiEnhancementConfigurationSection, .advancedPrompts)
    }

    func testUnrelatedRoutesDoNotSelectAIConfigurationSections() {
        XCTAssertNil(SidebarItem.voiceEngine.aiEnhancementConfigurationSection)
        XCTAssertNil(SidebarItem.customDictionary.aiEnhancementConfigurationSection)
    }

    func testInactiveSettingsSearchResignsFirstResponder() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let searchField = NSSearchField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
        window.contentView?.addSubview(searchField)

        XCTAssertTrue(window.makeFirstResponder(searchField))
        XCTAssertNotNil(searchField.currentEditor())

        SidebarSearchField.resignFocusIfNeeded(from: searchField, isActive: false)

        XCTAssertNil(searchField.currentEditor())
    }

    func testNativeSidebarSearchUpdatesLocaleWithoutReplacingFieldEditorOrQuery() async throws {
        for (source, russian) in [("Search", "Поиск"), ("Search Settings", "Поиск по настройкам")] {
            let state = SearchLocaleFixture()
            let host = NSHostingView(rootView: SearchLocaleHost(state: state, source: source))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            let found = try await self.waitForSearch(in: host, placeholder: source, query: state.query)
            let field = try XCTUnwrap(found)
            XCTAssertEqual(field.identifier?.rawValue, "FluidVoice.SidebarSearchField")
            XCTAssertTrue(window.makeFirstResponder(field))
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.setSelectedRange(NSRange(location: 2, length: 3))
            let selection = editor.selectedRange()
            state.locale = Locale(identifier: "ru")
            let updatedField = try await self.waitForSearch(in: host, placeholder: russian, query: state.query)
            let updated = try XCTUnwrap(updatedField)
            XCTAssertTrue(updated === field, "A locale change must update the same native field")
            XCTAssertTrue(updated.currentEditor() === editor)
            XCTAssertEqual(editor.selectedRange(), selection)
            XCTAssertEqual(updated.accessibilityLabel(), russian)
            XCTAssertEqual(updated.stringValue, "Settings Иван")
            XCTAssertEqual(state.query, "Settings Иван", "The query is user data, not a localization key")
            state.locale = Locale(identifier: "en")
            let restoredField = try await self.waitForSearch(in: host, placeholder: source, query: state.query)
            let restored = try XCTUnwrap(restoredField)
            XCTAssertTrue(restored === field)
            XCTAssertEqual(restored.accessibilityLabel(), source)
            XCTAssertEqual(restored.stringValue, "Settings Иван")
        }
    }

    func testNativeTranscriptLocaleChangesOnlyAccessibilityChrome() async throws {
        let state = SearchLocaleFixture()
        let entryID = UUID()
        let text = "Settings. Личная расшифровка остаётся дословной."
        let host = NSHostingView(rootView: TranscriptLocaleHost(state: state, entryID: entryID, text: text))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 180)
        let found = try await self.waitForTranscript(in: host, label: "Transcript")
        let scroll = try XCTUnwrap(found)
        let editor = try XCTUnwrap(scroll.documentView as? NSTextView)
        editor.setSelectedRange(NSRange(location: 10, length: 6))
        let selection = editor.selectedRange()
        let offset = scroll.contentView.bounds.origin
        state.locale = Locale(identifier: "ru")
        let updatedScroll = try await self.waitForTranscript(in: host, label: "Расшифровка")
        let updated = try XCTUnwrap(updatedScroll)
        XCTAssertTrue(updated === scroll)
        XCTAssertTrue(updated.documentView === editor)
        XCTAssertEqual(editor.string, text)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(updated.contentView.bounds.origin, offset)
    }

    func testBrandTypographyRecomputesExistingSemanticRoles() {
        let original = AppTheme.Typography.standard(style: nil)
        let style = BrandStyle(bodyFontDesign: .rounded, titleFontDesign: .serif)
        let changed = AppTheme.Typography.standard(style: style)
        XCTAssertEqual(original.body, .system(size: 14, weight: .regular))
        XCTAssertEqual(changed.body, .system(size: 14, weight: .regular, design: .rounded))
        XCTAssertEqual(changed.title, .system(size: 22, weight: .bold, design: .serif))
        XCTAssertEqual(changed.sectionTitle, .system(size: 15, weight: .semibold, design: .serif))
        XCTAssertEqual(changed.codeCaption, original.codeCaption)
        XCTAssertEqual(changed.metricTiny, original.metricTiny)
        XCTAssertNil(original.inheritedFont)
        XCTAssertEqual(changed.inheritedFont, Font.system(.body, design: .rounded))
    }

    func testNativeSearchBrandTypographyKeepsEditorQueryAndSelection() async throws {
        let state = SearchLocaleFixture()
        let host = NSHostingView(rootView: SearchLocaleHost(state: state, source: "Search"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        let found = try await self.waitForSearch(in: host, placeholder: "Search", query: state.query)
        let field = try XCTUnwrap(found)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 2, length: 3))
        let selection = editor.selectedRange()
        for style in [BrandStyle(bodyFontDesign: .rounded), BrandStyle(bodyFontDesign: .serif), BrandStyle()] {
            state.style = style
            let expected = NSFont.fluidSystemFont(ofSize: 14, style: style)
            for _ in 0..<100 {
                host.layoutSubtreeIfNeeded()
                if field.font == expected { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let updated = try XCTUnwrap(self.descendants(of: NSSearchField.self, in: host).first)
            XCTAssertTrue(updated === field, "Importing typography must preserve the native subtree")
            XCTAssertEqual(updated.font, expected)
            XCTAssertTrue(updated.currentEditor() === editor)
            XCTAssertEqual(editor.font, expected)
            XCTAssertEqual(editor.selectedRange(), selection)
            XCTAssertEqual(updated.stringValue, "Settings Иван")
            XCTAssertEqual(state.query, "Settings Иван")
        }
    }

    private final class SearchLocaleFixture: ObservableObject {
        @Published var locale = Locale(identifier: "en")
        @Published var query = "Settings Иван"
        @Published var style: BrandStyle? = nil
    }

    private struct SearchLocaleHost: View {
        @ObservedObject var state: SearchLocaleFixture
        let source: String
        var body: some View {
            SidebarSearchField(text: self.$state.query, placeholder: self.source, isActive: true)
                .appTheme(AppTheme.adaptive(accent: .purple, colorScheme: .light, package: BrandPackage(profile: .neutral, style: self.state.style)))
                .environment(\.locale, self.state.locale)
        }
    }

    private struct TranscriptLocaleHost: View {
        @ObservedObject var state: SearchLocaleFixture
        let entryID: UUID
        let text: String
        var body: some View {
            FileTranscriptTextView(entryID: self.entryID, text: self.text)
                .environment(\.locale, self.state.locale)
        }
    }

    private func descendants<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        var result = (root as? T).map { [$0] } ?? []
        for child in root.subviews { result += self.descendants(of: type, in: child) }
        return result
    }

    private func waitForSearch(in root: NSView, placeholder: String, query: String) async throws -> NSSearchField? {
        for _ in 0..<100 {
            root.layoutSubtreeIfNeeded()
            if let field = self.descendants(of: NSSearchField.self, in: root).first(where: { $0.placeholderString == placeholder && $0.stringValue == query }) {
                return field
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    private func waitForTranscript(in root: NSView, label: String) async throws -> FileTranscriptScrollView? {
        for _ in 0..<100 {
            root.layoutSubtreeIfNeeded()
            if let scroll = self.descendants(of: FileTranscriptScrollView.self, in: root).first(where: { $0.documentView?.accessibilityLabel() == label }) {
                return scroll
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    func testCommandModeOnlyOwnsRecordingItStarted() {
        XCTAssertTrue(CommandModeRecordingOwnershipPolicy.ownsRecording(after: .started, isRunning: true))
        XCTAssertFalse(CommandModeRecordingOwnershipPolicy.ownsRecording(after: .started, isRunning: false))
        XCTAssertFalse(CommandModeRecordingOwnershipPolicy.ownsRecording(after: .alreadyActive, isRunning: true))
        XCTAssertFalse(CommandModeRecordingOwnershipPolicy.ownsRecording(after: .failed, isRunning: true))
    }

    func testCommandModeDeactivationNeverStopsUnownedRecording() {
        XCTAssertTrue(CommandModeRecordingOwnershipPolicy.shouldStopOnDeactivate(
            ownsRecording: true,
            isRunning: true
        ))
        XCTAssertFalse(CommandModeRecordingOwnershipPolicy.shouldStopOnDeactivate(
            ownsRecording: false,
            isRunning: true
        ))
        XCTAssertFalse(CommandModeRecordingOwnershipPolicy.shouldStopOnDeactivate(
            ownsRecording: true,
            isRunning: false
        ))
        XCTAssertTrue(CommandModeRecordingOwnershipPolicy.shouldStopAfterStart(
            ownsRecording: true,
            isPresentationActive: false
        ))
        XCTAssertFalse(CommandModeRecordingOwnershipPolicy.shouldStopAfterStart(
            ownsRecording: false,
            isPresentationActive: false
        ))
    }

    func testSettingsSectionsHaveStableTitlesAndIcons() {
        XCTAssertEqual(
            SettingsSection.allCases.map(\.title),
            ["General", "Dictation", "Dictation Formatting", "Shortcuts", "Notifications", "Audio", "Overlay", "Data & Diagnostics", "Experimental"]
        )
        XCTAssertTrue(SettingsSection.allCases.allSatisfy { !$0.systemImage.isEmpty })
        XCTAssertEqual(SettingsSection.overlay.systemImage, "rectangle.on.rectangle")
    }

    func testShortcutSearchRoutesToDedicatedPageWithoutMovingDictationOptions() {
        XCTAssertEqual(SettingsSearchIndex.results(for: "Primary Dictation Shortcuts").first?.section, .shortcuts)
        XCTAssertEqual(SettingsSearchIndex.results(for: "Copy to Clipboard").first?.section, .dictation)
        XCTAssertEqual(SettingsSearchTarget.commandModeShortcut.section, .shortcuts)
        var state = SettingsNavigationState()
        state.present(.shortcuts, returningTo: .cleanupStyles)
        XCTAssertTrue(state.isLeaving(.shortcuts, for: .dictation))
        XCTAssertEqual(state.dismiss(), .cleanupStyles)
    }

    func testFormattingSearchRoutesToDedicatedSection() {
        XCTAssertEqual(SettingsSearchIndex.results(for: "Dictation Formatting").first?.section, .dictationFormatting)
        XCTAssertEqual(SettingsSearchIndex.results(for: "Text Formatting").first?.section, .dictationFormatting)
        XCTAssertEqual(SettingsSearchIndex.results(for: "Spoken Formatting").first?.section, .dictationFormatting)
        XCTAssertEqual(SettingsSearchIndex.results(for: "Remove Filler Words").first?.section, .dictationFormatting)
        XCTAssertEqual(SettingsSearchTarget.copyToClipboard.section, .dictation)
        XCTAssertEqual(SettingsSearchTarget.inputDevicePriority.section, .audio)
    }

    func testSettingsSearchRanksExactTitleAheadOfRelatedTerms() {
        let results = SettingsSearchIndex.results(for: "Copy to Clipboard")

        XCTAssertEqual(results.first?.target, .copyToClipboard)
        XCTAssertTrue(results.contains { $0.target == .textInsertionMode })
    }

    func testSettingsSearchNormalizesCaseAndDiacritics() {
        let results = SettingsSearchIndex.results(for: "ACCÉNT COLOR")

        XCTAssertEqual(results.first?.target, .accentColor)
    }

    func testSettingsSearchMatchesPrefixesAliasesAndMultipleWords() {
        XCTAssertEqual(SettingsSearchIndex.results(for: "start").first?.target, .launchAtStartup)
        XCTAssertTrue(SettingsSearchIndex.results(for: "mic").contains { $0.target == .inputDevicePriority })
        XCTAssertEqual(SettingsSearchIndex.results(for: "audio device").first?.section, .audio)
    }

    func testSettingsSearchToleratesRepresentativeTypos() {
        XCTAssertTrue(SettingsSearchIndex.results(for: "microfone").contains { $0.target == .microphonePermission })
        XCTAssertEqual(SettingsSearchIndex.results(for: "clipbord").first?.target, .copyToClipboard)
        XCTAssertEqual(SettingsSearchIndex.results(for: "hot ky").first?.target, .globalHotkey)
    }

    func testSettingsSearchRejectsUnrelatedShortQuery() {
        XCTAssertTrue(SettingsSearchIndex.results(for: "zz").isEmpty)
    }

    func testSettingsSearchKeepsSectionsInNavigationOrder() {
        XCTAssertEqual(
            SettingsSearchIndex.matchingSections(for: "mic"),
            [.dictation, .notifications, .audio]
        )
    }

    func testSettingsSearchPreservesMatchingSectionAndFallsBackToBestResult() {
        let results = SettingsSearchIndex.results(for: "mic")

        XCTAssertEqual(
            SettingsSearchIndex.preferredSection(current: .audio, results: results),
            .audio
        )
        XCTAssertEqual(
            SettingsSearchIndex.preferredSection(current: .general, results: results),
            results.first?.section
        )
        XCTAssertEqual(SettingsSearchIndex.preferredSection(current: .audio, results: []), .audio)
    }

    func testSettingsSearchOmitsTargetsUnavailableInTheCurrentState() {
        let availability = SettingsSearchAvailability(
            microphoneAuthorized: true,
            accessibilityEnabled: true,
            savesTranscriptionHistory: false,
            savesAudioWithTranscriptionHistory: false,
            overlayAtBottom: false
        )

        let permissionTargets = SettingsSearchIndex.results(
            for: "permission",
            availability: availability
        ).map(\.target)

        XCTAssertFalse(permissionTargets.contains(.microphonePermission))
        XCTAssertFalse(permissionTargets.contains(.accessibilityPermission))
        XCTAssertFalse(SettingsSearchIndex.results(
            for: "audio storage",
            availability: availability
        ).contains { $0.target == .audioStorage })
        XCTAssertFalse(SettingsSearchIndex.results(
            for: "bottom offset",
            availability: availability
        ).contains { $0.target == .bottomOffset })
    }

    func testSettingsSearchOmitsControlsHiddenWithoutAccessibility() {
        let availability = SettingsSearchAvailability(
            microphoneAuthorized: true,
            accessibilityEnabled: false,
            savesTranscriptionHistory: true,
            savesAudioWithTranscriptionHistory: true,
            overlayAtBottom: true
        )
        let gatedTargets: [(SettingsSearchTarget, String)] = [
            (.primaryDictationShortcuts, "primary dictation shortcuts"),
            (.commandModeShortcut, "command mode shortcut"),
            (.editModeShortcut, "edit mode shortcut"),
            (.cancelRecordingShortcut, "cancel recording shortcut"),
            (.pasteLastTranscriptionShortcut, "paste last transcription shortcut"),
            (.activationMode, "activation mode"),
            (.copyToClipboard, "copy to clipboard"),
            (.textInsertionMode, "text insertion mode"),
            (.spokenSend, "spoken send"),
            (.transcriptionHistory, "save transcription history"),
            (.audioHistory, "save audio with history"),
            (.audioStorage, "audio storage"),
            (.usageStreak, "usage streak"),
            (.skipSilentRecordings, "skip silent recordings"),
            (.pauseMedia, "pause media during transcription"),
            (.dictionarySuggestions, "dictionary suggestions"),
            (.analyticsPrivacy, "detailed anonymous analytics"),
        ]

        for (target, query) in gatedTargets {
            XCTAssertFalse(
                SettingsSearchIndex.results(for: query, availability: availability)
                    .contains { $0.target == target },
                "\(target) is not rendered without Accessibility permission"
            )
        }
    }
}

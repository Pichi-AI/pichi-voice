#!/usr/bin/env python3
"""Run production Swift method bodies against deterministic, gated dependency fakes.

This avoids loading ASR models or the app UI. It verifies method control flow,
not the real provider, disk store, or SwiftUI integration.
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

repo = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
selected_toolchain = subprocess.check_output(["xcode-select", "-p"], text=True).strip()
developer_dir = os.environ.get("DEVELOPER_DIR", selected_toolchain)
if ".app/Contents/Developer" not in developer_dir or not (Path(developer_dir) / "usr/bin/xcodebuild").is_file():
    raise SystemExit("Set DEVELOPER_DIR to an installed full Xcode before running this test.")
os.environ["DEVELOPER_DIR"] = developer_dir

source = (repo / 'Sources/Fluid/UI/CustomDictionaryView.swift').read_text()
method = source[source.index('    private func addTrainedReplacement() async {'):source.index('    private func removeTrainingVariant(')].replace('private func addTrainedReplacement', 'func addTrainedReplacement')
prefix_save = source[source.index('    private func savePunctuationDictionaryPrefix() {'):source.index('    private func savePunctuationRules() {')].replace('private func savePunctuationDictionaryPrefix', 'func savePunctuationDictionaryPrefix')
progress = source[source.index('struct DictionaryTrainingProgress {'):source.index('enum CustomDictionaryTrainingMerge {')]
readiness = source[source.index('    private var trainingProgress:'):source.index('    private var trainingAlreadyCorrectWithoutReplacement:')]
already_correct = source[source.index('    private var trainingAlreadyCorrectWithoutReplacement:'):source.index('    private var trainingReadinessProgress:')]
can_save = source[source.index('    private var canAddTrainedReplacement:'):source.index('    private var shouldPulseTrainedReplacementButton:')]
merge = source[source.index('enum CustomDictionaryTrainingMerge {'):source.index('private struct ReplacementConfirmation:')]
spelling_policy_source = (repo / 'Sources/Fluid/Services/DictionaryCorrectionEditPolicy.swift').read_text()
# The policy file now also holds the replacement plan and text map (101), which call DictionaryCorrectionEditPolicy
# at the top of the file, so compile the whole file rather than its tail.
spelling_policy = spelling_policy_source
store_source = (repo / 'Sources/Fluid/Services/PronunciationDictionaryStore.swift').read_text()
retained = store_source[store_source.index('    static func retainedEnrollments('):store_source.index('    static func matchingEnrollments(')]
settings = (repo / 'Sources/Fluid/Persistence/SettingsStoreMeetingPreferences.swift').read_text()
entry_start = settings.rfind('\n', 0, settings.index('struct CustomDictionaryEntry:')) + 1
brace = settings.index('{', entry_start)
depth, end = 1, brace + 1
while depth:
    depth += (settings[end] == '{') - (settings[end] == '}')
    end += 1
entry = settings[entry_start:end]
swift = r'''
import Foundation
// Only visual metadata is inert; the production save method and localizer remain unchanged.
nonisolated enum AppBrand { static let appName = "Synthetic Test Voice" }
// The production localizer can read preferences, but this control-flow probe must not.
nonisolated final class UserDefaults: @unchecked Sendable {
    static let standard = UserDefaults()
    func string(forKey key: String) -> String? { nil }
    func set(_ value: Any?, forKey key: String) { fatalError("Unexpected preference write") }
}
final nonisolated class SettingsStore: @unchecked Sendable {
    static let shared = SettingsStore()
    enum SpeechModel { case parakeet, gigaam
        var learnsDictionarySpellingsAutomatically: Bool { self == .parakeet }
    }
    var selectedSpeechModel = SpeechModel.parakeet
    var customDictionaryEntries: [CustomDictionaryEntry] = []
    var punctuationDictionaryPrefix = "original"
    ENTRY
}
nonisolated struct PrivateProfileSnapshot: Equatable, Sendable { let id = UUID() }
nonisolated enum PrivateProfileStorage {
    nonisolated(unsafe) static var current = PrivateProfileSnapshot()
    nonisolated(unsafe) static var acceptsNewWork = true
    static func isReadable(_ profile: PrivateProfileSnapshot) -> Bool { profile == current }
}
nonisolated struct PronunciationEnrollmentCapture: Equatable, Sendable { var modelKey = "test"; var originalAudioID: UUID?; var observedText: String? }
nonisolated struct PronunciationDictionaryProfile: Sendable {
    let dictionaryEntryID: UUID
    let modelKey: String
    let enrollments: [PronunciationEnrollmentCapture]
}
nonisolated enum DictionaryMatcherExperiment {
    nonisolated(unsafe) static var sharedFeaturesEnabled = true
    nonisolated(unsafe) static var generation = UUID().uuidString
}
nonisolated struct VoiceTrainingAliasFilter {
    struct Result {
        let accepted: [String]
        let rejected: [String] = []
        var rejectionMessage: String { "Replacement found these words: “the”. These single words are too broad to replace automatically. Add a manual replacement if intended." }
        init(accepted: [String]) { self.accepted = accepted }
    }
    nonisolated(unsafe) static var response: Result?
    static func filter(_ values: [String], manuallyConfirmed: Set<String> = []) async -> Result { response ?? Result(accepted: values) }
}
final nonisolated class DebugLogger {
    static let shared = DebugLogger()
    func info(_ message: String, source: String) {}
    func error(_ message: String, source: String) {}
}
actor Gate {
    var entered = false
    var waiting: CheckedContinuation<Void, Never>?
    func pause() async { entered = true; await withCheckedContinuation { waiting = $0 } }
    func release() { waiting?.resume(); waiting = nil }
}
actor PronunciationDictionaryStore {
    static let shared = PronunciationDictionaryStore()
    var gate: Gate?
    var lateGate: Gate?
    var forceFailure = false
    var writes: [UUID] = []
    var calls = 0
    var storedProfiles: [PronunciationDictionaryProfile] = []
    func configure(gate: Gate?, lateGate: Gate? = nil, failure: Bool = false, profiles: [PronunciationDictionaryProfile] = []) {
        self.gate = gate; self.lateGate = lateGate; forceFailure = failure; writes = []; calls = 0; storedProfiles = profiles
    }
    func profiles(modelKey: String) -> [PronunciationDictionaryProfile] { storedProfiles.filter { $0.modelKey == modelKey } }
    RETAINED
    func upsert(dictionaryEntryID: UUID, label: String, modelKey: String, enrollments: [PronunciationEnrollmentCapture], automaticMatchingEnabled: Bool, expectedExistingEnrollments: [PronunciationEnrollmentCapture]? = nil, canPersist: @Sendable () -> Bool) async throws {
        calls += 1
        guard canPersist() else { throw CancellationError() }
        if let gate { await gate.pause() }
        guard canPersist(), !forceFailure else { throw CancellationError() }
        if let expectedExistingEnrollments {
            let existing = storedProfiles.first { $0.dictionaryEntryID == dictionaryEntryID && $0.modelKey == modelKey }?.enrollments ?? []
            guard existing == expectedExistingEnrollments else { throw CancellationError() }
        }
        writes.append(dictionaryEntryID)
        if let lateGate { await lateGate.pause() }
    }
}
PROGRESS
MERGE
SPELLING_POLICY
@MainActor final class ASRSaveValidator {
    var validationResult = true
    var validationCalls = 0
    var validatedCaptures: [PronunciationEnrollmentCapture] = []
    func validateDictionaryPronunciations(_ captures: [PronunciationEnrollmentCapture]) async throws -> Bool {
        validationCalls += 1
        validatedCaptures = captures
        return validationResult
    }
}
@MainActor final class SaveHarness {
    let settings = SettingsStore.shared
    let asr = ASRSaveValidator()
    let profile = PrivateProfileStorage.current
    var isProfileVisible: Bool { PrivateProfileStorage.isReadable(profile) && PrivateProfileStorage.acceptsNewWork }
    READINESS
    ALREADY_CORRECT
    CAN_SAVE
    var trainingSampleCount = 3
    var savedPronunciationCount = 0
    var trainingAcousticCorrection = false
    var isTrainingRecording = false
    var isTrainingProcessing = false
    var trainingSaveID: UUID?
    var normalizedTrainingReplacement = "FluidVoice"
    var trainingPronunciationEnrollments = Array(repeating: PronunciationEnrollmentCapture(), count: 3)
    var activePronunciationMatching = true
    var trainingVariants = ["fluid boys"]
    var manualTrainingSpellings = Set<String>()
    var lastTrainingOutput = "fluid boys"
    var pronunciationEnabled = true
    var trainingHasError = false
    var trainingStatusMessage = ""
    var entries: [SettingsStore.CustomDictionaryEntry] = []
    var wizardSavedWord = ""
    enum Step { case recording, review, saved }
    var wizardStep = Step.recording
    var writes = 0
    func saveEntries() { writes += 1; SettingsStore.shared.customDictionaryEntries = entries }
    func resetTraining() { trainingSaveID = nil; isTrainingProcessing = false; trainingPronunciationEnrollments = []; trainingVariants = [] }
    var punctuationPrefix = "old-owner-prefix"
    PREFIX_SAVE
    METHOD
}
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
@main struct Runner {
    @MainActor static func main() async throws {
        typealias Entry = SettingsStore.CustomDictionaryEntry
        var passes = 0
        func baseline() -> [Entry] {
            [Entry(triggers: ["fluid voice"], replacement: "FluidVoice"), Entry(triggers: ["other"], replacement: "Other")]
        }
        func reset(_ entries: [Entry]) -> SaveHarness {
            PrivateProfileStorage.current = PrivateProfileSnapshot()
            PrivateProfileStorage.acceptsNewWork = true
            SettingsStore.shared.customDictionaryEntries = entries
            SettingsStore.shared.selectedSpeechModel = .parakeet
            DictionaryMatcherExperiment.sharedFeaturesEnabled = true
            DictionaryMatcherExperiment.generation = UUID().uuidString
            VoiceTrainingAliasFilter.response = nil
            return SaveHarness()
        }
        func waitForGate(_ gate: Gate) async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while !(await gate.entered) {
                check(ContinuousClock.now < deadline, "Save did not reach its expected persistence boundary within 3 seconds")
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        // A delayed popover dismissal must never write its original owner's prefix into another profile.
        do {
            let view = reset(baseline())
            SettingsStore.shared.punctuationDictionaryPrefix = "current-owner"
            PrivateProfileStorage.acceptsNewWork = false
            view.savePunctuationDictionaryPrefix()
            check(SettingsStore.shared.punctuationDictionaryPrefix == "current-owner", "Concealed dismissal cannot save punctuation")
            PrivateProfileStorage.current = PrivateProfileSnapshot()
            PrivateProfileStorage.acceptsNewWork = true
            view.savePunctuationDictionaryPrefix()
            check(SettingsStore.shared.punctuationDictionaryPrefix == "current-owner", "Old dismissal cannot overwrite the next profile")
            let fresh = reset(baseline())
            fresh.savePunctuationDictionaryPrefix()
            check(SettingsStore.shared.punctuationDictionaryPrefix == fresh.punctuationPrefix, "Visible owner retains normal punctuation save")
            passes += 1
        }
        // Production save and merge retain existing profile UUID and save new entries under the written UUID.
        for existing in [true, false] {
            let original = existing ? baseline() : []
            let view = reset(original)
            await PronunciationDictionaryStore.shared.configure(gate: nil)
            await view.addTrainedReplacement()
            let profiles = await PronunciationDictionaryStore.shared.writes
            check(view.writes == 1 && view.wizardStep == .saved, "Normal save must succeed")
            check(profiles == [SettingsStore.shared.customDictionaryEntries.first!.id], "Profile and text rule UUID must agree")
            if existing { check(profiles.first == original[0].id, "Retraining must preserve original UUID") }
            check(!view.isTrainingProcessing, "Successful save must release processing state")
            passes += 1
        }
        // Deterministic interleavings while production save is suspended in profile persistence.
        for mutation in 0..<6 {
            let original = baseline()
            let view = reset(original)
            let gate = Gate()
            await PronunciationDictionaryStore.shared.configure(gate: gate)
            let save = Task { await view.addTrainedReplacement() }
            try await waitForGate(gate)
            var latest = original
            switch mutation {
            case 0: latest.append(Entry(triggers: ["new"], replacement: "New"))
            case 1: latest.removeLast()
            case 2: latest[1].triggers = ["updated"]
            case 3: latest = [Entry(triggers: ["imported"], replacement: "Imported")]
            case 4: latest.removeFirst()
            default: latest[0].replacement = "Edited"
            }
            SettingsStore.shared.customDictionaryEntries = latest
            await gate.release()
            await save.value
            check(SettingsStore.shared.customDictionaryEntries == latest, "Concurrent edit must survive mutation \(mutation)")
            check(view.writes == 0, "Stale save must never publish its list")
            check(view.trainingHasError && view.trainingStatusMessage.contains("dictionary changed"), "Conflict must show retry")
            check(!view.isTrainingProcessing && view.trainingSaveID == nil, "Conflict must release processing state")
            check(!view.trainingPronunciationEnrollments.isEmpty && !view.trainingVariants.isEmpty, "Conflict must retain captures")
            let writes = await PronunciationDictionaryStore.shared.writes
            check(writes.isEmpty, "Persistence guard must reject changed dictionary")
            passes += 1
        }
        // Conceal and another account cannot complete the original wizard into the new source.
        for replaceProfile in [false, true] {
            let original = baseline()
            let view = reset(original)
            let gate = Gate()
            await PronunciationDictionaryStore.shared.configure(gate: gate)
            let save = Task { await view.addTrainedReplacement() }
            try await waitForGate(gate)
            if replaceProfile { PrivateProfileStorage.current = PrivateProfileSnapshot() }
            else { PrivateProfileStorage.acceptsNewWork = false }
            await gate.release(); await save.value
            let profiles = await PronunciationDictionaryStore.shared.writes
            check(profiles.isEmpty && view.writes == 0, "Stale profile cannot persist a voice or text rule")
            check(SettingsStore.shared.customDictionaryEntries == original, "Profile change preserves the destination dictionary")
            check(view.wizardStep == .recording && !view.trainingHasError, "Conceal suppresses old success and error UI")
            check(!view.trainingPronunciationEnrollments.isEmpty, "Original unsaved samples remain in their original owner")
            passes += 1
        }
        // An edit after the profile write but before the MainActor resumes must still preserve the dictionary.
        do {
            let original = baseline()
            let view = reset(original)
            let lateGate = Gate()
            await PronunciationDictionaryStore.shared.configure(gate: nil, lateGate: lateGate)
            let save = Task { await view.addTrainedReplacement() }
            try await waitForGate(lateGate)
            let latest = [original[1]]
            SettingsStore.shared.customDictionaryEntries = latest
            await lateGate.release(); await save.value
            check(SettingsStore.shared.customDictionaryEntries == latest && view.writes == 0, "Post-write edit must survive")
            check(view.trainingHasError && !view.isTrainingProcessing, "Post-write conflict must be retryable")
            passes += 1
        }
        // Stale failing saves cannot clear or replace the UI state belonging to a newer save.
        do {
            let view = reset(baseline())
            let gate = Gate()
            await PronunciationDictionaryStore.shared.configure(gate: gate, failure: true)
            let save = Task { await view.addTrainedReplacement() }
            try await waitForGate(gate)
            let newSaveID = UUID()
            view.trainingSaveID = newSaveID
            view.trainingStatusMessage = "new save"
            await gate.release(); await save.value
            check(view.trainingSaveID == newSaveID && view.isTrainingProcessing, "Stale failure must preserve newer activity")
            check(view.trainingStatusMessage == "new save" && !view.trainingHasError, "Stale failure must preserve newer UI")
            check(view.writes == 0, "Stale failing save must not write dictionary")
            passes += 1
        }
        // Store failures are visible and leave captures available for retry.
        do {
            let original = baseline()
            let view = reset(original)
            await PronunciationDictionaryStore.shared.configure(gate: nil, failure: true)
            await view.addTrainedReplacement()
            check(view.trainingHasError && !view.isTrainingProcessing && view.trainingSaveID == nil, "Failure must release processing state")
            check(view.writes == 0 && SettingsStore.shared.customDictionaryEntries == original, "Failure must preserve dictionary")
            check(!view.trainingPronunciationEnrollments.isEmpty, "Failure must retain captures")
            passes += 1
        }
        // Existing text-only training remains independent of the profile store.
        do {
            let view = reset([])
            view.activePronunciationMatching = false
            await PronunciationDictionaryStore.shared.configure(gate: nil, failure: true)
            await view.addTrainedReplacement()
            check(view.writes == 1 && view.wizardStep == .saved, "Text-only training must save")
            check(await PronunciationDictionaryStore.shared.writes.isEmpty, "Text-only training must not write profiles")
            passes += 1
        }
        // A provider's negative acoustic verdict must keep the real wizard in
        // recording state without entering either persistence path.
        do {
            let original = baseline()
            let view = reset(original)
            SettingsStore.shared.selectedSpeechModel = .gigaam
            view.wizardStep = .review
            view.asr.validationResult = false
            await PronunciationDictionaryStore.shared.configure(gate: nil)
            await view.addTrainedReplacement()
            let calls = await PronunciationDictionaryStore.shared.calls
            let profiles = await PronunciationDictionaryStore.shared.writes
            check(view.asr.validationCalls == 1, "Acoustic-only save must consult the provider validator")
            check(calls == 0 && profiles.isEmpty && view.writes == 0, "Failed acoustic validation must not write profiles or text rules")
            check(SettingsStore.shared.customDictionaryEntries == original, "Failed validation preserves the dictionary")
            check(view.trainingHasError && view.wizardStep == .recording && view.trainingStatusMessage.contains("do not sound consistent"), "Failed validation must request new recordings")
            check(view.trainingPronunciationEnrollments.count == 3 && !view.isTrainingProcessing && view.trainingSaveID == nil, "Failed validation retains captures and releases busy state")
            passes += 1
        }
        // Three spelling examples may save even when voice enrollment is incomplete.
        // The actual readiness calculation must keep zero, one and two voice examples
        // out of profile persistence, even with pronunciation learning enabled.
        for count in 0..<3 {
            let original = baseline()
            let view = reset(original)
            view.trainingPronunciationEnrollments = Array(repeating: PronunciationEnrollmentCapture(), count: count)
            await PronunciationDictionaryStore.shared.configure(gate: nil, failure: true)
            await view.addTrainedReplacement()
            let calls = await PronunciationDictionaryStore.shared.calls
            let profiles = await PronunciationDictionaryStore.shared.writes
            check(view.writes == 1 && view.wizardStep == .saved, "Incomplete voice enrollment must not block spelling-only save")
            check(calls == 0 && profiles.isEmpty, "Incomplete voice examples must never enter profile persistence")
            check(SettingsStore.shared.customDictionaryEntries.first?.id == original.first?.id, "Spelling fallback retains the existing entry identity")
            check(SettingsStore.shared.customDictionaryEntries.last == original.last, "Spelling fallback preserves unrelated rules")
            check(!view.trainingHasError && !view.isTrainingProcessing && view.trainingSaveID == nil, "Spelling fallback finishes cleanly")
            passes += 1
        }
        // An original corrected occurrence plus two new recordings uses the
        // actual combined-readiness and retention code before provider validation.
        do {
            let original = baseline()
            let view = reset(original)
            SettingsStore.shared.selectedSpeechModel = .gigaam
            view.savedPronunciationCount = 1
            view.trainingPronunciationEnrollments = Array(repeating: PronunciationEnrollmentCapture(), count: 2)
            let saved = PronunciationEnrollmentCapture(originalAudioID: UUID())
            await PronunciationDictionaryStore.shared.configure(gate: nil, profiles: [
                .init(dictionaryEntryID: original[0].id, modelKey: saved.modelKey, enrollments: [saved])
            ])
            await view.addTrainedReplacement()
            let writes = await PronunciationDictionaryStore.shared.writes
            check(view.asr.validationCalls == 1 && view.asr.validatedCaptures.count == 3 && view.asr.validatedCaptures.contains(saved), "Saved original audio must participate in the three-recording validation")
            check(writes == [original[0].id] && view.writes == 1 && view.wizardStep == .saved, "One saved plus two fresh acoustic examples must complete under the existing entry")
            check(SettingsStore.shared.customDictionaryEntries == original, "Acoustic-only training must not silently authorize new global text spellings")
            passes += 1
        }
        // Filtering cannot create a text rule when no safe aliases and no ready voice exist.
        do {
            let original = baseline()
            let view = reset(original)
            view.trainingPronunciationEnrollments = []
            VoiceTrainingAliasFilter.response = .init(accepted: [])
            await PronunciationDictionaryStore.shared.configure(gate: nil)
            await view.addTrainedReplacement()
            let calls = await PronunciationDictionaryStore.shared.calls
            check(view.writes == 0 && calls == 0, "Rejected aliases must not write text rules or profiles")
            check(SettingsStore.shared.customDictionaryEntries == original, "Rejected aliases preserve the dictionary")
            check(view.trainingHasError && view.wizardStep == .recording, "Rejected aliases leave a visible manual fallback")
            check(view.trainingStatusMessage.contains("manual replacement"), "Alias failure explains its actual cause")
            check(!view.trainingVariants.isEmpty && !view.isTrainingProcessing && view.trainingSaveID == nil, "Alias failure retains recordings and releases busy state")
            passes += 1
        }
        // Repeating an existing text correction keeps captures without claiming a new save.
        do {
            let original = baseline()
            let view = reset(original)
            view.activePronunciationMatching = false
            view.trainingPronunciationEnrollments = []
            view.trainingVariants = ["fluid voice"]
            view.wizardStep = .review
            await PronunciationDictionaryStore.shared.configure(gate: nil)
            await view.addTrainedReplacement()
            let calls = await PronunciationDictionaryStore.shared.calls
            check(view.writes == 0 && calls == 0, "Unchanged spelling must not write text rules or voice profiles")
            check(SettingsStore.shared.customDictionaryEntries == original, "Unchanged save must preserve all entries and IDs")
            check(view.wizardStep == .review && view.trainingHasError, "Unchanged spelling must stay in review with feedback")
            check(view.trainingStatusMessage.contains("Nothing new was saved"), "Unchanged spelling must explain the result")
            check(view.trainingVariants == ["fluid voice"], "Unchanged save must retain recordings for retry")
            check(!view.isTrainingProcessing && view.trainingSaveID == nil, "Unchanged save must release its busy state")
            passes += 1
        }
        // Already-correct captures must explain that no new correction was saved.
        do {
            let original = baseline()
            let view = reset(original)
            view.activePronunciationMatching = false
            view.trainingPronunciationEnrollments = []
            view.normalizedTrainingReplacement = "Palermo"
            view.trainingVariants = []
            view.lastTrainingOutput = "palermo"
            view.wizardStep = .review
            await PronunciationDictionaryStore.shared.configure(gate: nil)
            await view.addTrainedReplacement()
            let calls = await PronunciationDictionaryStore.shared.calls
            check(view.writes == 0 && calls == 0, "Already-recognized words must not save text rules or voice profiles")
            check(SettingsStore.shared.customDictionaryEntries == original, "Already-recognized words must preserve the dictionary")
            check(view.wizardStep == .review && view.trainingHasError, "Already-recognized words must stay in review with feedback")
            check(view.trainingStatusMessage.contains("Nothing new was saved"), "Already-recognized words must explain the result")
            check(view.trainingSampleCount == 3 && view.lastTrainingOutput == "palermo", "Already-correct feedback must retain captures")
            check(!view.isTrainingProcessing && view.trainingSaveID == nil, "Already-correct feedback must leave the editor idle")
            passes += 1
        }
        // Existing correct captures must not make Save available during a new recording or save.
        for recording in [true, false] {
            let original = baseline()
            let view = reset(original)
            view.activePronunciationMatching = false
            view.trainingPronunciationEnrollments = []
            view.trainingVariants = []
            view.lastTrainingOutput = "FluidVoice"
            view.isTrainingRecording = recording
            view.isTrainingProcessing = !recording
            await view.addTrainedReplacement()
            check(view.writes == 0 && !view.trainingHasError, "Busy captures must not save or replace their status with no-change feedback")
            check(SettingsStore.shared.customDictionaryEntries == original, "Busy captures must preserve saved entries")
            check(view.isTrainingRecording == recording && view.isTrainingProcessing == !recording, "Busy Save must leave the current recording or save alone")
            passes += 1
        }
        // New voice samples are a real save even when the spelling rules are unchanged.
        do {
            let original = baseline()
            let view = reset(original)
            view.trainingVariants = ["fluid voice"]
            await PronunciationDictionaryStore.shared.configure(gate: nil)
            await view.addTrainedReplacement()
            let profiles = await PronunciationDictionaryStore.shared.writes
            check(profiles == [original[0].id], "Pronunciation-only retraining must still save its profile")
            check(SettingsStore.shared.customDictionaryEntries == original, "Voice-only retraining must preserve text rules")
            check(view.wizardStep == .saved && !view.trainingHasError, "New voice samples must still complete successfully")
            passes += 1
        }
        // In spelling-only mode, inactive voice captures cannot bypass the spelling gate.
        do {
            let original = baseline()
            let view = reset(original)
            view.trainingSampleCount = 2
            view.activePronunciationMatching = false
            await PronunciationDictionaryStore.shared.configure(gate: nil)
            await view.addTrainedReplacement()
            let calls = await PronunciationDictionaryStore.shared.calls
            check(calls == 0 && view.writes == 0 && SettingsStore.shared.customDictionaryEntries == original, "Incomplete spellings must not save")
            check(!view.isTrainingProcessing && view.trainingSaveID == nil && view.wizardStep == .recording, "Rejected save must not advance the wizard or leave it busy")
            passes += 1
        }
        // A new feature generation while the store is suspended rejects old enrollment.
        do {
            let original = baseline()
            let view = reset(original)
            let gate = Gate()
            await PronunciationDictionaryStore.shared.configure(gate: gate)
            let save = Task { await view.addTrainedReplacement() }
            try await waitForGate(gate)
            DictionaryMatcherExperiment.generation = UUID().uuidString
            await gate.release(); await save.value
            let profiles = await PronunciationDictionaryStore.shared.writes
            check(profiles.isEmpty && view.writes == 0 && SettingsStore.shared.customDictionaryEntries == original, "Stale pronunciation generation must not persist")
            check(view.trainingHasError && !view.trainingPronunciationEnrollments.isEmpty, "Generation refusal is retryable and retains captured examples")
            check(!view.isTrainingProcessing && view.trainingSaveID == nil, "Generation refusal must release busy state")
            passes += 1
        }
        // A completion from an older save must not clear or advance a newer save.
        do {
            let original = baseline()
            let view = reset(original)
            let lateGate = Gate()
            await PronunciationDictionaryStore.shared.configure(gate: nil, lateGate: lateGate)
            let save = Task { await view.addTrainedReplacement() }
            try await waitForGate(lateGate)
            let newerID = UUID()
            view.trainingSaveID = newerID
            view.trainingStatusMessage = "New save is running"
            await lateGate.release(); await save.value
            check(view.writes == 0 && SettingsStore.shared.customDictionaryEntries == original, "Stale success must not publish text rules")
            check(view.trainingSaveID == newerID && view.isTrainingProcessing, "Stale success must not release the newer save")
            check(view.trainingStatusMessage == "New save is running" && view.wizardStep == .recording && !view.trainingHasError, "Stale success must preserve newer UI state")
            passes += 1
        }
        // Cancellation after profile completion suppresses dictionary publication and wizard success.
        // This deliberately does not claim cancellation rolls back an already completed profile write.
        do {
            let original = baseline()
            let view = reset(original)
            let lateGate = Gate()
            await PronunciationDictionaryStore.shared.configure(gate: nil, lateGate: lateGate)
            let save = Task { await view.addTrainedReplacement() }
            try await waitForGate(lateGate)
            save.cancel()
            await lateGate.release(); await save.value
            check(view.writes == 0 && SettingsStore.shared.customDictionaryEntries == original, "Cancelled save must not publish dictionary changes")
            check(!view.isTrainingProcessing && view.trainingSaveID == nil && view.wizardStep == .recording && !view.trainingHasError, "Cancelled completion must leave no success, error or busy state")
            check(!view.trainingPronunciationEnrollments.isEmpty, "Cancelled save retains captures for retry")
            passes += 1
        }
        print("PASS \(passes) dictionary save scenarios using the production save method, readiness and merge code")
    }
}
'''.replace('ENTRY', entry).replace('PROGRESS', progress).replace('MERGE', merge).replace('READINESS', readiness).replace('ALREADY_CORRECT', already_correct).replace('CAN_SAVE', can_save).replace('METHOD', method).replace('PREFIX_SAVE', prefix_save).replace('SPELLING_POLICY', spelling_policy).replace('RETAINED', retained)
swift = swift.replace('check(await PronunciationDictionaryStore.shared.writes.isEmpty,', 'let textOnlyWrites = await PronunciationDictionaryStore.shared.writes\n            check(textOnlyWrites.isEmpty,')
isolation_swift = r'''
import Foundation
@MainActor enum SettingsStore {
    ENTRY
}
actor SnapshotReader {
    func validates(_ entries: [SettingsStore.CustomDictionaryEntry]) throws -> Bool {
        let encoded = try JSONEncoder().encode(entries)
        let decoded = try JSONDecoder().decode([SettingsStore.CustomDictionaryEntry].self, from: encoded)
        let canPersist: @Sendable () -> Bool = { decoded == entries }
        return canPersist() && Set(decoded).count == entries.count
    }
}
@main struct IsolationRunner {
    @MainActor static func main() async throws {
        let original = [SettingsStore.CustomDictionaryEntry(triggers: ["fluid voice"], replacement: "FluidVoice")]
        let matches = try await SnapshotReader().validates(original)
        precondition(matches, "Dictionary values must retain identity and content across actors")
        print("PASS dictionary snapshot Codable, Hashable and Equatable under Swift 6 MainActor defaults")
    }
}
'''.replace('ENTRY', entry)
(repo / ".build").mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="dictionary-regression-", dir=repo / ".build") as directory:
    root = Path(directory)
    (root / 'dictionary-proof.swift').write_text(swift)
    for isolation in ([], ['-default-isolation', 'MainActor']):
        executable = root / ('dictionary-proof-main-actor' if isolation else 'dictionary-proof-default')
        subprocess.run([
            'xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5',
            *isolation, '-module-cache-path', str(root / 'ModuleCache'),
            str(repo/'Sources/Fluid/Localization/PichiLocalization.swift'),
            str(root/'dictionary-proof.swift'), '-o', str(executable),
        ], check=True, timeout=60)
        subprocess.run([str(executable)], check=True, timeout=60)
    (root / 'dictionary-isolation.swift').write_text(isolation_swift)
    subprocess.run([
        'xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(root / 'ModuleCache'), '-swift-version', '6',
        '-default-isolation', 'MainActor', '-strict-concurrency=complete', '-warnings-as-errors',
        str(root/'dictionary-isolation.swift'), '-o', str(root/'dictionary-isolation'),
    ], check=True, timeout=60)
    subprocess.run([str(root/'dictionary-isolation')], check=True, timeout=60)

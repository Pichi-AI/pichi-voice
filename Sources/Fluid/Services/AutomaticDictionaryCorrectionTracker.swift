import AppKit
import ApplicationServices
import Foundation

struct DictionarySuggestionPolicyConfig {
    var requiredOccurrences = 2
    var occurrenceWindow: TimeInterval = 7 * 24 * 60 * 60
    var dismissedPairCooldown: TimeInterval = 7 * 24 * 60 * 60
    var maximumSessionIgnores = 3
    var retentionDuration: TimeInterval = 30 * 24 * 60 * 60
    var maximumStoredPairs = 200
}

enum AutomaticDictionarySuggestionOutcome {
    case accepted
    case ignored
    case dismissed
    case timedOut
}

@MainActor
final class AutomaticDictionarySuggestionPolicy {
    // Explicitly nonisolated: on macOS 15.4+ the synthesized main-actor deinit can abort until the OS runtime has the fix (swiftlang/swift#88036).
    nonisolated deinit {}

    static var shared: AutomaticDictionarySuggestionPolicy {
        PrivateProfileObjectCache.value(key: "AutomaticDictionarySuggestionPolicy") {
            let profile = PrivateProfileStorage.current
            return AutomaticDictionarySuggestionPolicy(defaults: PrivateProfileDefaults.bound(to: profile), profile: profile)
        }
    }

    private struct PairRecord: Codable {
        var heardText: String
        var correctedText: String
        var occurrences: [Date] = []
        var lastShownAt: Date?
        var dismissedUntil: Date?
        var isAccepted = false
    }

    private struct PersistedState: Codable {
        var records: [String: PairRecord] = [:]
    }

    private static let defaultsKey = "AutomaticDictionarySuggestionPolicyStateV1"

    private let defaults: UserDefaults
    private let configuration: DictionarySuggestionPolicyConfig
    private let profile: PrivateProfileSnapshot?
    private var retired = false
    private var canAccess: Bool { !self.retired && self.profile.map(PrivateProfileStorage.isReadable) != false }

    func prepareForProfileTransition() {
        self.retired = true
        self.state = PersistedState()
        self.sessionIgnoreCount = 0
    }
    private var state: PersistedState
    private var sessionIgnoreCount = 0

    init(
        defaults: UserDefaults? = nil,
        profile: PrivateProfileSnapshot? = nil,
        configuration: DictionarySuggestionPolicyConfig = .init()
    ) {
        let selected = profile ?? (defaults == nil ? PrivateProfileStorage.current : nil)
        let defaults = defaults ?? PrivateProfileDefaults.bound(to: selected!)
        self.profile = selected
        self.defaults = defaults
        self.configuration = configuration
        if let data = defaults.data(forKey: Self.defaultsKey),
           let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        {
            self.state = state
        } else {
            self.state = PersistedState()
        }
    }

    func shouldShow(
        _ candidate: AutomaticDictionaryCorrectionCandidate,
        requiredOccurrences: Int? = nil,
        now: Date = Date()
    ) -> Bool {
        guard self.canAccess else { return false }
        self.prune(now: now)
        let key = self.key(for: candidate)
        var record = self.state.records[key] ?? PairRecord(
            heardText: candidate.heardText,
            correctedText: candidate.correctedText
        )
        record.occurrences.removeAll { now.timeIntervalSince($0) > self.configuration.occurrenceWindow }
        record.occurrences.append(now)
        self.state.records[key] = record
        self.save()

        let correctedText = self.normalized(candidate.correctedText)
        let occurrenceCount = self.state.records.values
            .filter { self.normalized($0.correctedText) == correctedText }
            .flatMap(\.occurrences)
            .filter { now.timeIntervalSince($0) <= self.configuration.occurrenceWindow }
            .count
        guard !record.isAccepted,
              record.dismissedUntil.map({ $0 <= now }) ?? true,
              occurrenceCount >= (requiredOccurrences ?? self.configuration.requiredOccurrences),
              self.sessionIgnoreCount < self.configuration.maximumSessionIgnores
        else {
            return false
        }
        return true
    }

    func markShown(_ candidate: AutomaticDictionaryCorrectionCandidate, now: Date = Date()) {
        guard self.canAccess else { return }
        let key = self.key(for: candidate)
        guard var record = self.state.records[key] else { return }
        record.lastShownAt = now
        self.state.records[key] = record
        self.save()
    }

    func record(
        _ outcome: AutomaticDictionarySuggestionOutcome,
        for candidate: AutomaticDictionaryCorrectionCandidate,
        now: Date = Date()
    ) {
        guard self.canAccess else { return }
        let key = self.key(for: candidate)
        guard var record = self.state.records[key] else { return }
        switch outcome {
        case .accepted, .ignored:
            record.isAccepted = true
            record.dismissedUntil = nil
        case .dismissed, .timedOut:
            record.dismissedUntil = now.addingTimeInterval(self.configuration.dismissedPairCooldown)
            self.sessionIgnoreCount += 1
        }
        self.state.records[key] = record
        self.save()
    }

    private func key(for candidate: AutomaticDictionaryCorrectionCandidate) -> String {
        "\(self.normalized(candidate.heardText))\u{1F}\(self.normalized(candidate.correctedText))"
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private func prune(now: Date) {
        self.state.records = self.state.records.filter { _, record in
            let latestActivity = ([record.lastShownAt] + record.occurrences.map(Optional.some)).compactMap { $0 }.max()
            return record.isAccepted || latestActivity.map {
                now.timeIntervalSince($0) <= self.configuration.retentionDuration
            } ?? false
        }
        if self.state.records.count > self.configuration.maximumStoredPairs {
            let sortedKeys = self.state.records.keys.sorted {
                (self.state.records[$0]?.lastShownAt ?? .distantPast) >
                    (self.state.records[$1]?.lastShownAt ?? .distantPast)
            }
            let retainedKeys = Set(sortedKeys.prefix(self.configuration.maximumStoredPairs))
            self.state.records = self.state.records.filter { retainedKeys.contains($0.key) }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(self.state) else { return }
        self.defaults.set(data, forKey: Self.defaultsKey)
    }
}

@MainActor
final class AutomaticDictionaryCorrectionTracker {
    static var shared: AutomaticDictionaryCorrectionTracker {
        PrivateProfileObjectCache.value(key: "AutomaticDictionaryCorrectionTracker") { AutomaticDictionaryCorrectionTracker() }
    }

    private struct InsertionSeed {
        let element: AXUIElement
        let pid: pid_t
        let expectedValue: String
        let insertedRange: NSRange
    }

    private struct PendingCorrection {
        let id = UUID()
        let beforeValue: String
        var afterValue: String
        let insertedRange: NSRange
        var correctedRange: NSRange?
        let sourceMap: DictionaryCorrectionTextMap
    }

    private final class CorrectionApproval {
        let id: UUID
        var range: NSRange
        let text: String
        var isValid = true
        var saved: DictionaryAudioLearningService.SavedCorrection?
        init(id: UUID = UUID(), range: NSRange, text: String) { self.id = id; self.range = range; self.text = text }
    }

    private struct PendingRepeat {
        let id = UUID()
        let plan: DictionaryCorrectionReplacementPlan
        let selectionBefore: NSRange
        let selectionAfter: NSRange
    }

    private struct ObservationSession {
        let element: AXUIElement
        let applicationElement: AXUIElement
        let pid: pid_t
        let observesSelectionChanges: Bool
        let observesFocusChanges: Bool
        let learningRecording: DictionaryLearningRecording?
        let historyCorrection: DictationHistoryCorrectionSession?
        let knownCanonicalTerms: [String]
        var lastValue: String
        var insertedRange: NSRange
        var pendingCorrection: PendingCorrection?
        var textMap: DictionaryCorrectionTextMap
        var approvals: [CorrectionApproval] = []
        var acceptedCorrections: [(heard: String, corrected: String, sourceRange: NSRange)] = []
        var pendingRepeat: PendingRepeat?
    }

    private static let maximumFieldLength = 100_000
    private static let verificationAttempts = 20
    private static let verificationDelayNanoseconds: UInt64 = 50_000_000
    nonisolated static func observationDuration(
        hasVoiceSpellings: Bool,
        originalAudioExpiresAt: Date? = nil,
        now: Date = Date()
    ) -> Duration {
        // Kept replacements need confirmation plus edit debounce. Other audio-backed
        // edits remain observable only while their already-retained evidence is fresh.
        if hasVoiceSpellings { return DictionaryVoiceSpellingLearner.confirmationWindow + .seconds(5) }
        guard let originalAudioExpiresAt else { return .seconds(30) }
        return .seconds(min(DictionaryLearningRecording.lifetime, max(0, originalAudioExpiresAt.timeIntervalSince(now))))
    }

    private static let completionSignalDelayNanoseconds: UInt64 = 1_000_000_000
    private static let inactivityFallbackNanoseconds: UInt64 = 3_000_000_000

    private var observer: AXObserver?
    private var session: ObservationSession?
    private var verificationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var evidencePreparationTasks: [UUID: Task<Void, Never>] = [:]
    private var repeatVerificationTask: Task<Void, Never>?
    private var suggestionGeneration = UUID()
    private var correctionRevocations: [UUID: Task<Void, Never>] = [:]
    private let profile = PrivateProfileStorage.current

    private init() {}

    func beginObservingInsertion(
        _ insertedText: String, targetPID: pid_t?, learningRecording: DictionaryLearningRecording? = nil,
        historyCorrection: DictationHistoryCorrectionSession? = nil
    ) {
        guard PrivateProfileStorage.isReadable(profile), PrivateProfileStorage.acceptsNewWork else { return }
        self.cancel()
        guard SettingsStore.shared.automaticDictionaryLearningEnabled || DictionaryMatcherExperiment.collectNegatives,
              !insertedText.isEmpty
        else {
            return
        }

        let knownCanonicalTerms = SettingsStore.shared.customDictionaryEntries.map(\.replacement)
        self.verificationTask = Task { @MainActor [weak self] in
            for _ in 0..<Self.verificationAttempts {
                // Give the paste time to land before probing, and keep the synchronous
                // Accessibility round trips off the main thread so they never delay
                // the event tap that delivers the paste itself.
                try? await Task.sleep(nanoseconds: Self.verificationDelayNanoseconds)
                guard !Task.isCancelled, self != nil else { return }
                let seed = await Self.captureAnchoredInsertionOffMain(
                    insertedText: insertedText,
                    targetPID: targetPID
                )
                guard !Task.isCancelled, let self else { return }
                if let seed {
                    self.installObserver(
                        for: seed,
                        learningRecording: DictionaryMatcherExperiment.sharedFeaturesEnabled ? learningRecording : nil,
                        historyCorrection: historyCorrection,
                        knownCanonicalTerms: knownCanonicalTerms
                    )
                    return
                }
            }
            guard !Task.isCancelled else { return }
            DebugLogger.shared.info("DICTIONARY_CORRECTION observer_skipped reason=unanchored_insertion", source: "DictionaryLearning")
        }
    }

    func cancel() {
        self.suggestionGeneration = UUID()
        self.evidencePreparationTasks.values.forEach { $0.cancel() }
        self.evidencePreparationTasks.removeAll()
        self.stopObservation()
        DictionaryCorrectionOverlayController.shared.hideSuggestion()
    }

    func prepareForPrivateProfileTransition() async {
        let tasks = [verificationTask, timeoutTask, debounceTask, repeatVerificationTask] +
            (Array(self.evidencePreparationTasks.values) + Array(self.correctionRevocations.values)).map(Optional.some)
        cancel()
        for task in tasks { await task?.value }
    }

    func handleObservedValueChange() {
        guard var session = self.session,
              let currentValue = Self.stringValue(of: session.element),
              (currentValue as NSString).length <= Self.maximumFieldLength else { return }

        if let pending = session.pendingRepeat {
            if currentValue == session.lastValue { return } // Cached pre-write AX value.
            session.pendingRepeat = nil
            self.repeatVerificationTask?.cancel()
            self.repeatVerificationTask = nil
            let difference = AutomaticDictionaryCorrectionDetector.textChange(before: pending.plan.text, after: currentValue)
            if pending.plan.confirmsAppliedText(currentValue, differenceFromExpected: difference?.oldRange) {
                guard self.commitRepeat(pending.plan, to: &session) else { self.cancel(); return }
                self.session = session
                if currentValue == session.lastValue {
                    if let selected = Self.selectedRange(of: session.element),
                       selected == pending.selectionBefore || selected == NSRange(location: NSMaxRange(session.insertedRange), length: 0) ||
                       selected == NSRange(location: session.lastValue.utf16.count, length: 0) {
                        _ = Self.setSelectedRange(pending.selectionAfter, of: session.element)
                    }
                    self.propagateAcceptedCorrections()
                    return
                }
            } else {
                // A rejected/normalized write must not end observation of later edits.
                self.session = session
            }
        }
        guard currentValue != session.lastValue,
              let change = AutomaticDictionaryCorrectionDetector.textChange(
                  before: session.lastValue,
                  after: currentValue
              )
        else {
            return
        }

        // Finish a previous word before starting another one. Its immutable snapshot
        // remains valid even when the next keystroke has already reached the editor.
        if let pending = session.pendingCorrection,
           let range = pending.correctedRange,
           !AutomaticDictionaryCorrectionDetector.changeContinuesCandidate(change, after: currentValue, candidateRange: range) {
            self.evaluate(pending)
            guard let active = self.session else { return }
            session = active
        }

        let allowsInsertionAtEnd = AutomaticDictionaryCorrectionDetector.isWordContinuationAtInsertedRangeEnd(
            change,
            after: currentValue,
            insertedRange: session.insertedRange
        )
        let isInside = AutomaticDictionaryCorrectionDetector.isChangeInsideInsertedRange(
            change,
            insertedRange: session.insertedRange,
            allowsInsertionAtEnd: allowsInsertionAtEnd
        )

        // Reject on the edit event, before the debounce can race the confirmation deadline.
        if isInside, let recording = session.learningRecording {
            DictionaryVoiceSpellingLearner.shared.cancel(recordingID: recording.id)
        }

        let sourceMap = session.textMap
        if isInside {
            let local = NSRange(location: change.oldRange.location - session.insertedRange.location, length: change.oldRange.length)
            guard session.textMap.replace(range: local, replacement: (currentValue as NSString).substring(with: change.newRange)) else {
                self.cancel(); return
            }
            for approval in session.approvals where approval.isValid {
                if let moved = DictionaryCorrectionReplacementPlan.confirmedRange(approval.range, text: approval.text,
                    replacing: local, withLength: change.newRange.length, in: session.textMap.text) {
                    approval.range = moved
                } else { self.revoke(approval) }
            }
        }

        if var pending = session.pendingCorrection {
            let continuesCandidate = pending.correctedRange.map {
                AutomaticDictionaryCorrectionDetector.changeContinuesCandidate(
                    change,
                    after: currentValue,
                    candidateRange: $0
                )
            } ?? isInside

            if continuesCandidate {
                pending.afterValue = currentValue
                pending.correctedRange = AutomaticDictionaryCorrectionDetector.correctedTokenRange(
                    before: pending.beforeValue,
                    after: currentValue
                )
                session.pendingCorrection = pending
                session.insertedRange.length = max(
                    0,
                    session.insertedRange.length + change.newRange.length - change.oldRange.length
                )
                self.scheduleCandidateEvaluation(
                    for: pending.id,
                    after: Self.inactivityFallbackNanoseconds
                )
            } else {
                self.scheduleCandidateEvaluation(
                    for: pending.id,
                    after: Self.completionSignalDelayNanoseconds
                )
            }
        } else if isInside {
            let pending = PendingCorrection(
                beforeValue: session.lastValue,
                afterValue: currentValue,
                insertedRange: session.insertedRange,
                correctedRange: AutomaticDictionaryCorrectionDetector.correctedTokenRange(
                    before: session.lastValue,
                    after: currentValue
                ),
                sourceMap: sourceMap
            )
            session.pendingCorrection = pending
            session.insertedRange.length = max(
                0,
                session.insertedRange.length + change.newRange.length - change.oldRange.length
            )
            self.scheduleCandidateEvaluation(
                for: pending.id,
                after: Self.inactivityFallbackNanoseconds
            )
        } else if NSMaxRange(change.oldRange) <= session.insertedRange.location {
            session.insertedRange.location = max(
                0,
                session.insertedRange.location + change.newRange.length - change.oldRange.length
            )
        } else if change.oldRange.location < NSMaxRange(session.insertedRange) {
            self.cancel()
            return
        }

        session.lastValue = currentValue
        self.session = session
    }

    func handleObservedSelectionChange() {
        guard let session = self.session,
              let pending = session.pendingCorrection,
              let correctedRange = pending.correctedRange,
              let selection = Self.selectedRange(of: session.element)
        else {
            return
        }

        let delay = AutomaticDictionaryCorrectionDetector.selectionTouchesCandidate(
            selection,
            candidateRange: correctedRange
        ) ? Self.inactivityFallbackNanoseconds : Self.completionSignalDelayNanoseconds
        self.scheduleCandidateEvaluation(for: pending.id, after: delay)
    }

    func handleObservedFocusChange() {
        guard let session = self.session,
              let pending = session.pendingCorrection,
              let focus = Self.focusedElementAndPID(),
              focus.pid != session.pid || !CFEqual(focus.element, session.element)
        else {
            return
        }
        self.scheduleCandidateEvaluation(
            for: pending.id,
            after: Self.completionSignalDelayNanoseconds
        )
    }

    private nonisolated static let accessibilityProbeQueue = DispatchQueue(
        label: "com.fluidvoice.dictionary-correction.ax-probe",
        qos: .userInitiated
    )

    private nonisolated static func captureAnchoredInsertionOffMain(
        insertedText: String,
        targetPID: pid_t?
    ) async -> InsertionSeed? {
        await withCheckedContinuation { continuation in
            self.accessibilityProbeQueue.async {
                continuation.resume(
                    returning: self.captureAnchoredInsertion(insertedText: insertedText, targetPID: targetPID)
                )
            }
        }
    }

    private nonisolated static func captureAnchoredInsertion(
        insertedText: String,
        targetPID: pid_t?
    ) -> InsertionSeed? {
        guard let focus = focusedElementAndPID(),
              targetPID == nil || focus.pid == targetPID,
              !Self.isSecureTextInput(focus.element),
              let value = stringValue(of: focus.element),
              (value as NSString).length <= Self.maximumFieldLength,
              let selectedRange = Self.selectedRange(of: focus.element),
              selectedRange.length == 0
        else {
            return nil
        }

        let insertedLength = (insertedText as NSString).length
        let start = selectedRange.location - insertedLength
        guard start >= 0 else { return nil }
        let insertedRange = NSRange(location: start, length: insertedLength)
        guard NSMaxRange(insertedRange) <= (value as NSString).length,
              (value as NSString).substring(with: insertedRange) == insertedText
        else {
            return nil
        }

        return InsertionSeed(
            element: focus.element,
            pid: focus.pid,
            expectedValue: value,
            insertedRange: insertedRange
        )
    }

    private func installObserver(
        for seed: InsertionSeed,
        learningRecording: DictionaryLearningRecording?,
        historyCorrection: DictationHistoryCorrectionSession?,
        knownCanonicalTerms: [String]
    ) {
        self.verificationTask = nil
        var createdObserver: AXObserver?
        let createResult = AXObserverCreate(seed.pid, automaticDictionaryAXObserverCallback, &createdObserver)
        guard createResult == .success, let createdObserver else {
            DebugLogger.shared.info("DICTIONARY_CORRECTION observer_skipped reason=observer_creation", source: "DictionaryLearning")
            return
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        let addResult = AXObserverAddNotification(
            createdObserver,
            seed.element,
            kAXValueChangedNotification as CFString,
            context
        )
        guard addResult == .success else {
            DebugLogger.shared.info("DICTIONARY_CORRECTION observer_skipped reason=value_notification", source: "DictionaryLearning")
            return
        }

        let applicationElement = AXUIElementCreateApplication(seed.pid)
        let selectionResult = AXObserverAddNotification(
            createdObserver,
            seed.element,
            kAXSelectedTextChangedNotification as CFString,
            context
        )
        let focusResult = AXObserverAddNotification(
            createdObserver,
            applicationElement,
            kAXFocusedUIElementChangedNotification as CFString,
            context
        )

        self.observer = createdObserver
        self.session = ObservationSession(
            element: seed.element,
            applicationElement: applicationElement,
            pid: seed.pid,
            observesSelectionChanges: selectionResult == .success,
            observesFocusChanges: focusResult == .success,
            learningRecording: learningRecording,
            historyCorrection: historyCorrection,
            knownCanonicalTerms: knownCanonicalTerms,
            lastValue: seed.expectedValue,
            insertedRange: seed.insertedRange,
            pendingCorrection: nil,
            textMap: DictionaryCorrectionTextMap(originalText: (seed.expectedValue as NSString).substring(with: seed.insertedRange))
        )
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(createdObserver), .commonModes)

        if let learningRecording {
            DictionaryVoiceSpellingLearner.shared.propose(learningRecording.alignment.voiceSpellings, recordingID: learningRecording.id)
        }
        let hasOriginalAudio = learningRecording?.samples.isEmpty == false
        let duration = Self.observationDuration(
            hasVoiceSpellings: learningRecording?.alignment.voiceSpellings.isEmpty == false,
            originalAudioExpiresAt: hasOriginalAudio ? learningRecording?.expiresAt : nil
        )
        DebugLogger.shared.info(
            "DICTIONARY_CORRECTION observer_admitted seconds=\(duration.components.seconds) originalAudio=\(hasOriginalAudio)",
            source: "DictionaryLearning"
        )
        self.timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            DebugLogger.shared.info("DICTIONARY_CORRECTION observer_ended reason=expired", source: "DictionaryLearning")
            self?.cancel()
        }
    }

    private func scheduleCandidateEvaluation(for pendingID: UUID?, after delay: UInt64) {
        guard let pendingID else { return }
        self.debounceTask?.cancel()
        self.debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled,
                  let self,
                  let pending = self.session?.pendingCorrection,
                  pending.id == pendingID
            else {
                return
            }
            self.evaluate(pending)
        }
    }

    private func evaluate(_ pending: PendingCorrection) {
        defer { self.propagateAcceptedCorrections() }
        let detected = AutomaticDictionaryCorrectionDetector.candidate(
            before: pending.beforeValue,
            after: pending.afterValue,
            insertedRange: pending.insertedRange,
            allowsInsertionAtEnd: true,
            knownCanonicalTerms: self.session?.knownCanonicalTerms ?? []
        )
        let repeated = AutomaticDictionaryCorrectionDetector.candidate(before: pending.beforeValue, after: pending.afterValue,
            insertedRange: pending.insertedRange, allowsInsertionAtEnd: true)
        let repetitionPlan = repeated.flatMap { value in
            value.sourceUTF16Range.flatMap { DictionaryCorrectionReplacementPlan(sourceText: pending.sourceMap.text,
                range: $0, replacement: value.correctedText) }
        }
        var candidate = repetitionPlan.flatMap {
            AutomaticDictionaryCorrectionDetector.confirmedCandidate(detected, in: $0) ??
                AutomaticDictionaryCorrectionDetector.confirmedCandidate(repeated, in: $0)
        } ?? (repetitionPlan == nil ? detected : nil)
        if let range = candidate?.sourceUTF16Range, let original = pending.sourceMap.originalRange(for: range) {
            candidate?.observationID = "\(self.session?.learningRecording?.id.uuidString ?? self.suggestionGeneration.uuidString):\(original.location):\(original.length)"
        }
        if let candidate {
            DictionaryVoiceSpellingLearner.shared.reject(editedText: candidate.heardText)
        }
        var context: DictionaryLearningCorrectionContext?
        if DictionaryMatcherExperiment.sharedFeaturesEnabled, let recording = self.session?.learningRecording, let range = candidate?.sourceUTF16Range {
            let before = pending.beforeValue as NSString
            let insertion = pending.insertedRange
            if insertion.location >= 0, insertion.location <= before.length,
               insertion.length >= 0, insertion.length <= before.length - insertion.location
            {
                if let original = pending.sourceMap.originalRange(for: range) {
                    context = DictionaryLearningCorrectionContext(
                        recording: recording, deliveredTextBeforeEdit: pending.sourceMap.originalText, selectedUTF16Range: original
                    )
                }
            }
        }
        DebugLogger.shared.info(
            "DICTIONARY_CORRECTION edit_evaluated candidate=\(candidate != nil) originalContext=\(context != nil)",
            source: "DictionaryLearning"
        )
        self.debounceTask?.cancel()
        self.debounceTask = nil
        self.session?.pendingCorrection = nil

        // This is the same explicit user edit as History Save. Mirror it before
        // asynchronous dictionary/audio work, whose failure or Undo must not put
        // the incorrect text back into history.
        if let historyCandidate = candidate ?? repeated, let range = historyCandidate.sourceUTF16Range,
           let originalRange = pending.sourceMap.originalRange(for: range) {
            self.session?.historyCorrection?.apply(originalDeliveredRange: originalRange, replacement: historyCandidate.correctedText)
        }

        if let repeated, let range = repeated.sourceUTF16Range,
           let originalRange = pending.sourceMap.originalRange(for: range) {
            // The same spoken span has one current correction. In particular,
            // restoring the original spelling must not reapply an earlier typo.
            self.session?.acceptedCorrections.removeAll { NSIntersectionRange($0.sourceRange, originalRange).length > 0 }
            self.session?.acceptedCorrections.append((repeated.heardText, repeated.correctedText, originalRange))
            if self.session?.acceptedCorrections.count ?? 0 > 64 { self.session?.acceptedCorrections.removeFirst() }
        }

        if !SettingsStore.shared.automaticDictionaryLearningEnabled,
           let candidate, let context, DictionaryMatcherExperiment.collectNegatives,
           !SettingsStore.shared.shouldShowOnboarding, !AppServices.shared.asr.isRunning,
           !DictionaryCorrectionOverlayController.shared.isPresented,
           let negative = DictionaryNegativeEvidenceResolver.resolve(context: context, heard: candidate.heardText, corrected: candidate.correctedText)
        {
            var prepared = candidate
            prepared.negativeCorrection = negative
            DictionaryCorrectionOverlayController.shared.show(candidate: prepared) { _ in }
            return
        }

        // The edited occurrence is explicit approval, just like inline history Save.
        // Persist original audio before publishing a new acoustic dictionary term.
        if let candidate, let context, SettingsStore.shared.automaticDictionaryLearningEnabled,
           !SettingsStore.shared.shouldShowOnboarding, let sourceRange = candidate.sourceUTF16Range {
            let admitted = self.enqueueCorrection(candidate, context: context,
                range: NSRange(location: sourceRange.location, length: candidate.correctedText.utf16.count))
            if admitted { return }
        }

        guard let candidate else { return }
        guard SettingsStore.shared.automaticDictionaryLearningEnabled,
              !SettingsStore.shared.shouldShowOnboarding
        else {
            DebugLogger.shared.info("DICTIONARY_CORRECTION suggestion_skipped reason=inactive", source: "DictionaryLearning")
            return
        }
        let generation = self.suggestionGeneration
        let preparationID = candidate.id
        guard self.evidencePreparationTasks.count < 32 else { return }
        let approval = CorrectionApproval(id: candidate.id,
            range: NSRange(location: candidate.sourceUTF16Range?.location ?? 0, length: candidate.correctedText.utf16.count),
            text: candidate.correctedText)
        self.session?.approvals.removeAll { !$0.isValid }
        self.session?.approvals.append(approval)
        let revocations = Array(self.correctionRevocations.values)
        self.evidencePreparationTasks[preparationID] = Task { @MainActor [weak self, approval] in
            defer { self?.evidencePreparationTasks.removeValue(forKey: preparationID) }
            for task in revocations { await task.value }
            guard !Task.isCancelled, approval.isValid, let self, self.suggestionGeneration == generation else { return }
            self.saveWordWithoutAudio(candidate, approval: approval)
        }
    }

    private func saveWordWithoutAudio(_ candidate: AutomaticDictionaryCorrectionCandidate, approval: CorrectionApproval) {
        guard approval.isValid, approval.saved == nil, SettingsStore.shared.automaticDictionaryLearningEnabled,
              PrivateProfileStorage.isReadable(self.profile), PrivateProfileStorage.acceptsNewWork else { return }
        if let receipt = DictionaryAudioLearningService.shared.saveCorrectionWithoutAudio(candidate: candidate,
            evidenceID: approval.id, isValid: { approval.isValid }) {
            approval.saved = receipt
            DictionaryCorrectionOverlayController.shared.showSavedCorrection(receipt)
        } else {
            // A genuine save failure is visible, never converted into an Add request.
            DictionaryCorrectionOverlayController.shared.show(candidate: candidate) { _ in }
        }
    }

    private func enqueueCorrection(_ candidate: AutomaticDictionaryCorrectionCandidate,
                                   context: DictionaryLearningCorrectionContext, range: NSRange) -> Bool {
        guard let originalRange = Range(context.selectedUTF16Range, in: context.deliveredTextBeforeEdit),
              let heard = DictionaryCorrectionEditPolicy.acousticSpelling(String(context.deliveredTextBeforeEdit[originalRange])) else { return false }
        // Returning to the original spelling retracts the intermediate learning;
        // it does not authorize a fresh dictionary entry for already-correct ASR.
        guard heard != candidate.correctedText else { return true }
        guard
              let resolved = try? DictionaryLearningAlignmentResolver.resolve(recording: context.recording,
                deliveredTextBeforeEdit: context.deliveredTextBeforeEdit,
                selectedUTF16Range: context.selectedUTF16Range, observedText: heard) else { return false }
        let rawText = context.recording.alignment.words[resolved.sourceWordRange].map(\.text).joined(separator: " ")
        guard let observed = DictionaryCorrectionEditPolicy.acousticSpelling(rawText) else { return false }
        let evidence = DictionaryLearningAudioEvidence(recordingID: resolved.recordingID, modelKey: resolved.modelKey,
            observedText: observed, sourceWordRange: resolved.sourceWordRange, sourceSampleRange: resolved.sourceSampleRange,
            focalSampleRange: resolved.focalSampleRange, samples: resolved.samples, featureFrames: resolved.featureFrames)
        let approval = CorrectionApproval(id: candidate.id, range: range, text: candidate.correctedText)
        self.session?.approvals.removeAll { !$0.isValid }
        self.session?.approvals.append(approval)
        let profile = self.profile
        let corrected = AutomaticDictionaryCorrectionCandidate(heardText: heard, correctedText: candidate.correctedText)
        // Only the bounded resolved clip is retained by the queue, never the full recording.
        let revocations = Array(self.correctionRevocations.values)
        let admitted = DictionaryAudioLearningService.shared.learnCorrection(candidate: corrected, evidence: evidence, evidenceID: approval.id, isValid: {
            approval.isValid && PrivateProfileStorage.isReadable(profile) && PrivateProfileStorage.acceptsNewWork
        }, didSave: { receipt in
            guard approval.isValid else { return }
            approval.saved = receipt
            DictionaryCorrectionOverlayController.shared.showSavedCorrection(receipt)
        }, didFail: { [weak self] in
            self?.saveWordWithoutAudio(candidate, approval: approval)
        }, beforePreparation: {
            for task in revocations { await task.value }
        })
        if !admitted { self.saveWordWithoutAudio(candidate, approval: approval) }
        return true
    }

    private func revoke(_ approval: CorrectionApproval) {
        guard approval.isValid else { return }
        approval.isValid = false
        self.evidencePreparationTasks[approval.id]?.cancel()
        let learning = DictionaryAudioLearningService.shared
        learning.discardPendingEvidence(approval.id)
        DictionaryCorrectionOverlayController.shared.withdrawSavedCorrection(approval.id)
        DictionaryCorrectionOverlayController.shared.withdrawSuggestion(approval.id)
        guard let receipt = approval.saved else { return }
        self.correctionRevocations[approval.id] = Task { @MainActor [weak self] in
            defer { self?.correctionRevocations.removeValue(forKey: approval.id) }
            do { _ = try await learning.undoSavedCorrection(receipt) }
            catch { DebugLogger.shared.warning("Previous correction could not be retracted", source: "DictionaryLearning") }
        }
    }

    private func propagateAcceptedCorrections() {
        guard SettingsStore.shared.automaticDictionaryLearningEnabled,
              PrivateProfileStorage.isReadable(self.profile), PrivateProfileStorage.acceptsNewWork,
              var session = self.session, session.pendingCorrection == nil, session.pendingRepeat == nil,
              let focus = Self.focusedElementAndPID(), focus.pid == session.pid,
              CFEqual(focus.element, session.element), !Self.isSecureTextInput(session.element),
              Self.stringValue(of: session.element) == session.lastValue,
              var selection = Self.selectedRange(of: session.element) else { return }
        var selectedTextSettable = DarwinBoolean(false), valueSettable = DarwinBoolean(false)
        let canWriteSelection = AXUIElementIsAttributeSettable(session.element, kAXSelectedTextAttribute as CFString, &selectedTextSettable) == .success && selectedTextSettable.boolValue
        let canWriteValue = AXUIElementIsAttributeSettable(session.element, kAXValueAttribute as CFString, &valueSettable) == .success && valueSettable.boolValue
        guard canWriteSelection || canWriteValue else {
            DebugLogger.shared.info("DICTIONARY_CORRECTION repeats_skipped reason=no_writable_text_attribute", source: "DictionaryLearning")
            return
        }
        for correction in session.acceptedCorrections {
            guard correction.heard != correction.corrected,
                  let first = DictionaryCorrectionReplacementPlan.exactTermRanges(
                    of: correction.heard, in: session.lastValue, scope: session.insertedRange).first,
                  let plan = DictionaryCorrectionReplacementPlan(sourceText: session.lastValue, range: first,
                    replacement: correction.corrected, scope: session.insertedRange),
                  let restoredSelection = plan.mappedRange(selection) else { continue }
            let delta = plan.text.utf16.count - session.lastValue.utf16.count
            let updatedInsertion = NSRange(location: session.insertedRange.location, length: session.insertedRange.length + delta)
            let replacement = (plan.text as NSString).substring(with: updatedInsertion)
            let target = session.element, targetPID = session.pid, expectedValue = session.lastValue
            let expectedSelection = selection, insertion = session.insertedRange
            var selectionWasChanged = false
            let isCurrent: () -> Bool = {
                guard PrivateProfileStorage.isReadable(self.profile), PrivateProfileStorage.acceptsNewWork,
                      let focus = Self.focusedElementAndPID(), focus.pid == targetPID, CFEqual(focus.element, target),
                      !Self.isSecureTextInput(target), Self.stringValue(of: target) == expectedValue,
                      Self.selectedRange(of: target) == (selectionWasChanged ? insertion : expectedSelection) else { return false }
                return true
            }
            let pending = PendingRepeat(plan: plan, selectionBefore: selection, selectionAfter: restoredSelection)
            session.pendingRepeat = pending
            self.session = session
            let selectedWrite: (() -> Bool)? = canWriteSelection ? {
                guard Self.setSelectedRange(insertion, of: target) else { return false }
                selectionWasChanged = true
                guard isCurrent() else { return false }
                return AXUIElementSetAttributeValue(target, kAXSelectedTextAttribute as CFString, replacement as CFString) == .success
            } : nil
            let valueWrite: (() -> Bool)? = canWriteValue ? {
                AXUIElementSetAttributeValue(target, kAXValueAttribute as CFString, plan.text as CFString) == .success
            } : nil
            let dispatched = DictionaryCorrectionReplacementPlan.dispatchReplacement(isCurrent: isCurrent,
                writeSelectedText: selectedWrite, writeValue: valueWrite)
            guard dispatched else {
                session.pendingRepeat = nil
                self.session = session
                if selectionWasChanged, isCurrent() { _ = Self.setSelectedRange(selection, of: target) }
                DebugLogger.shared.info("DICTIONARY_CORRECTION repeats_skipped reason=write_rejected_or_editor_changed", source: "DictionaryLearning")
                return
            }
            // A successful AX request is not a synchronous value acknowledgement.
            self.handleObservedValueChange()
            self.verifyRepeat(pending.id)
            return
        }
    }

    private func commitRepeat(_ plan: DictionaryCorrectionReplacementPlan, to session: inout ObservationSession) -> Bool {
        let delta = plan.text.utf16.count - session.lastValue.utf16.count
        for edit in plan.ranges.reversed() {
            let local = NSRange(location: edit.location - session.insertedRange.location, length: edit.length)
            guard session.textMap.replace(range: local, replacement: plan.replacement) else { return false }
            for approval in session.approvals where approval.isValid {
                if let moved = DictionaryCorrectionReplacementPlan.confirmedRange(approval.range, text: approval.text,
                    replacing: local, withLength: plan.replacement.utf16.count, in: session.textMap.text) {
                    approval.range = moved
                } else { self.revoke(approval) }
            }
        }
        session.lastValue = plan.text
        session.insertedRange.length += delta
        return true
    }

    private func verifyRepeat(_ id: UUID) {
        guard self.session?.pendingRepeat?.id == id else { return }
        self.repeatVerificationTask?.cancel()
        self.repeatVerificationTask = Task { @MainActor [weak self] in
            for _ in 0..<10 {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                guard let self, self.session?.pendingRepeat?.id == id else { return }
                self.handleObservedValueChange()
            }
            guard let self, let session = self.session, let pending = session.pendingRepeat, pending.id == id else { return }
            // Keep the expected echo for a later notification, but release an
            // unchanged editor selection when the write did not take effect.
            if Self.stringValue(of: session.element) == session.lastValue,
               Self.selectedRange(of: session.element) == session.insertedRange,
               let focus = Self.focusedElementAndPID(), focus.pid == session.pid, CFEqual(focus.element, session.element) {
                _ = Self.setSelectedRange(pending.selectionBefore, of: session.element)
            }
            self.repeatVerificationTask = nil
            DebugLogger.shared.info("DICTIONARY_CORRECTION repeats_waiting_for_editor", source: "DictionaryLearning")
        }
    }

    private nonisolated static func setSelectedRange(_ range: NSRange, of element: AXUIElement) -> Bool {
        var value = CFRange(location: range.location, length: range.length)
        guard let encoded = AXValueCreate(.cfRange, &value) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, encoded) == .success
    }

    private nonisolated static func stringValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    private nonisolated static func isSecureTextInput(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value)
        guard result == .success, let subrole = value as? String else { return false }
        return subrole == (kAXSecureTextFieldSubrole as String) || subrole.localizedCaseInsensitiveContains("secure")
    }

    private nonisolated static func selectedRange(of element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
        guard result == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range),
              range.location != kCFNotFound,
              range.location >= 0,
              range.length >= 0
        else {
            return nil
        }
        return NSRange(location: range.location, length: range.length)
    }

    private nonisolated static func focusedElementAndPID() -> (element: AXUIElement, pid: pid_t)? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        guard result == .success,
              let focusedElement,
              CFGetTypeID(focusedElement) == AXUIElementGetTypeID()
        else {
            return nil
        }

        let element = unsafeBitCast(focusedElement, to: AXUIElement.self)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid > 0 ? (element, pid) : nil
    }

    private func stopObservation() {
        self.repeatVerificationTask?.cancel()
        self.repeatVerificationTask = nil
        if let recording = self.session?.learningRecording {
            DictionaryVoiceSpellingLearner.shared.cancel(recordingID: recording.id)
        }
        self.verificationTask?.cancel()
        self.verificationTask = nil
        self.timeoutTask?.cancel()
        self.timeoutTask = nil
        self.debounceTask?.cancel()
        self.debounceTask = nil
        self.removeObserver()
        self.session = nil
    }

    private func removeObserver() {
        guard let observer = self.observer else { return }
        if let session = self.session {
            AXObserverRemoveNotification(observer, session.element, kAXValueChangedNotification as CFString)
            if session.observesSelectionChanges {
                AXObserverRemoveNotification(
                    observer,
                    session.element,
                    kAXSelectedTextChangedNotification as CFString
                )
            }
            if session.observesFocusChanges {
                AXObserverRemoveNotification(
                    observer,
                    session.applicationElement,
                    kAXFocusedUIElementChangedNotification as CFString
                )
            }
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = nil
    }
}

private let automaticDictionaryAXObserverCallback: AXObserverCallback = { _, _, notification, context in
    guard let context else { return }

    let tracker = Unmanaged<AutomaticDictionaryCorrectionTracker>.fromOpaque(context).takeUnretainedValue()
    Task { @MainActor in
        switch notification as String {
        case kAXValueChangedNotification as String:
            tracker.handleObservedValueChange()
        case kAXSelectedTextChangedNotification as String:
            // Web-backed editors may move the caret without emitting a value-change notification.
            tracker.handleObservedValueChange()
            tracker.handleObservedSelectionChange()
        case kAXFocusedUIElementChangedNotification as String:
            tracker.handleObservedFocusChange()
        default:
            break
        }
    }
}

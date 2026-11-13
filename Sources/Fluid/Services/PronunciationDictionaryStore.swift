import Foundation

nonisolated struct PronunciationEnrollmentCapture: Codable, Equatable, Sendable {
    let values: [Float]
    let sourceFrameCount: Int
    let modelKey: String
    var originalAudioID: UUID?
    var observedText: String?
    var sourceRecordingID: UUID?
    var sourceFocalRange: Range<Int>?
    var extractorVersion: String?
    var capturedAt: Date? = nil
    var inspectionID: UUID?
    // nil identifies legacy enrollment; an empty vector is invalid.
    // swiftlint:disable:next discouraged_optional_collection
    var edgeEmbedding: [Float]?
    var edgeFrameCount: Int?
    // Only held until the profile save. Large evidence is stored separately on disk.
    var pendingInspection: DictionaryAudioInspection? = nil

    private enum CodingKeys: String, CodingKey {
        case values, sourceFrameCount, modelKey, originalAudioID, observedText
        case sourceRecordingID, sourceFocalRange, extractorVersion, capturedAt, inspectionID, edgeEmbedding, edgeFrameCount
    }
}

nonisolated struct PronunciationDictionaryProfile: Codable, Equatable, Identifiable, Sendable {
    let dictionaryEntryID: UUID
    var label: String
    let modelKey: String
    let hiddenSize: Int
    var enrollments: [PronunciationEnrollmentCapture]
    var automaticMatchingEnabled: Bool? = nil
    var matchThreshold: Float? = nil

    var hasOriginalAudio: Bool { self.enrollments.contains { $0.originalAudioID != nil } }
    var isEligibleForMatching: Bool {
        (self.enrollments.count >= 3 || self.hasOriginalAudio) && self.enrollments.count <= 10 &&
            Self.hasConsistentFeatures(self.enrollments, modelKey: self.modelKey, hiddenSize: self.hiddenSize)
    }

    /// Storage validates feature shape and provenance without interpreting a provider's recipe.
    /// The matching adapter additionally validates its exact extractor version and model key.
    static func hasConsistentFeatures(_ captures: [PronunciationEnrollmentCapture], modelKey: String, hiddenSize: Int) -> Bool {
        guard !modelKey.isEmpty, (1...2048).contains(hiddenSize), !captures.isEmpty,
              captures.allSatisfy({
                  $0.modelKey == modelKey && $0.values.count == hiddenSize &&
                      $0.values.allSatisfy(\.isFinite) && $0.sourceFrameCount > 0
              }) else { return false }
        let versions = Set(captures.compactMap(\.extractorVersion))
        return versions.count <= 1 && versions.allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 128 &&
                $0.unicodeScalars.allSatisfy { $0.isASCII && !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }
        }
    }

    var hasTemporalRecordings: Bool {
        self.matchingEnrollments.count >= 3 && self.matchingEnrollments.allSatisfy {
            $0.inspectionID != nil || $0.originalAudioID != nil
        }
    }

    /// Keep stored history chronological while a deliberate re-recording selects
    /// the latest manual references. Reordering history would break future eviction.
    var matchingEnrollments: [PronunciationEnrollmentCapture] {
        PronunciationDictionaryStore.matchingEnrollments(self.enrollments)
    }

    var id: String { "\(self.dictionaryEntryID.uuidString):\(self.modelKey)" }
}

nonisolated enum PronunciationDictionaryStoreError: LocalizedError, Equatable {
    case inconsistentEnrollment
    case staleEvidence
    case outdatedModelRevision

    var errorDescription: String? {
        switch self {
        case .staleEvidence:
            PichiLocalization.text("The dictionary entry changed before audio learning finished.")
        case .inconsistentEnrollment:
            PichiLocalization.text("Pronunciation samples must use the same model and embedding size.")
        case .outdatedModelRevision:
            PichiLocalization.text("These pronunciation recordings use an older voice model. Retrain this word by voice. Your custom words and text corrections remain saved.")
        }
    }
}

actor PronunciationDictionaryStore {
    nonisolated static let didChangeNotification = Notification.Name("PronunciationDictionaryStoreDidChange")
    private static let cache = PrivateProfileStoreCache<PronunciationDictionaryStore>()
    static var shared: PronunciationDictionaryStore {
        cache.value { profile in PronunciationDictionaryStore(
            fileURL: profile.rootDirectory.appendingPathComponent("pronunciation-dictionary-v1.json"), profile: profile) }
    }

    private struct Document: Codable, Sendable {
        let version: Int
        var profiles: [PronunciationDictionaryProfile]
    }

    private let fileURL: URL
    private var document: Document?
    private var revisions: [UUID: UUID] = [:]
    private var replacementGeneration = UUID()

    private let profile: PrivateProfileSnapshot?
    private var retired = false
    private var canAccess: Bool { !self.retired && self.profile.map(PrivateProfileStorage.isReadable) != false }

    /// Only a provider admitted while this exact profile is visible receives this
    /// bounded read lease. Ordinary store/UI reads still require current visibility.
    nonisolated final class CaptureRead: @unchecked Sendable {
        let profile: PrivateProfileSnapshot
        /// Shared matching is best-effort within the unchanged capture reference budget.
        let omittedSharedProfileCount: Int
        private let leaseID: UUID
        private let lock = NSLock()
        private var selectedProfiles: [PronunciationDictionaryProfile]
        private var inspections: [UUID: DictionaryCaptureEvidenceFile]
        private var originals: [UUID: DictionaryCaptureEvidenceFile]
        private var selectedReferences: [String: [PronunciationEnrollmentCapture]]
        private var closed = false

        var isOpen: Bool {
            self.lock.lock(); defer { self.lock.unlock() }
            return !self.closed
        }

        fileprivate init(profile: PrivateProfileSnapshot, leaseID: UUID,
                         profiles: [PronunciationDictionaryProfile], omittedSharedProfileCount: Int = 0,
                         inspections: [UUID: DictionaryCaptureEvidenceFile],
                         originals: [UUID: DictionaryCaptureEvidenceFile],
                         selectedReferences: [String: [PronunciationEnrollmentCapture]]) {
            self.profile = profile
            self.omittedSharedProfileCount = omittedSharedProfileCount
            self.leaseID = leaseID
            self.selectedProfiles = profiles
            self.inspections = inspections
            self.originals = originals
            self.selectedReferences = selectedReferences
        }

        var profiles: [PronunciationDictionaryProfile] {
            self.lock.lock(); defer { self.lock.unlock() }
            return self.closed ? [] : self.selectedProfiles
        }

        func matchingEnrollments(for profile: PronunciationDictionaryProfile) -> [PronunciationEnrollmentCapture] {
            self.lock.lock(); defer { self.lock.unlock() }
            return self.closed ? [] : self.selectedReferences[profile.id] ?? []
        }

        func inspection(for id: UUID) throws -> DictionaryAudioInspection {
            self.lock.lock(); defer { self.lock.unlock() }
            guard !self.closed, let file = self.inspections[id] else {
                throw PronunciationDictionaryStoreError.staleEvidence
            }
            return try file.read { data in
                let value = try PropertyListDecoder().decode(DictionaryAudioInspection.self, from: data)
                guard value.isValid else { throw PronunciationDictionaryStoreError.inconsistentEnrollment }
                return value
            }
        }

        /// Optional learned evidence may be absent or corrupt. A closed lease or
        /// cancelled task remains an error and cannot be downgraded to a miss.
        func optionalInspection(for id: UUID) throws -> DictionaryAudioInspection? {
            self.lock.lock(); defer { self.lock.unlock() }
            guard !self.closed else { throw PronunciationDictionaryStoreError.staleEvidence }
            guard let file = self.inspections[id] else { return nil }
            do {
                return try file.read { data in
                    let value = try PropertyListDecoder().decode(DictionaryAudioInspection.self, from: data)
                    guard value.isValid else { throw PronunciationDictionaryStoreError.inconsistentEnrollment }
                    return value
                }
            } catch is CancellationError { throw CancellationError() }
            catch PronunciationDictionaryStoreError.staleEvidence { throw PronunciationDictionaryStoreError.staleEvidence }
            catch { return nil }
        }

        func originalAudioSamples(for capture: PronunciationEnrollmentCapture, entryID: UUID) throws -> [Float] {
            self.lock.lock(); defer { self.lock.unlock() }
            guard !self.closed, let id = capture.originalAudioID, let file = self.originals[id],
                  self.selectedProfiles.contains(where: {
                      $0.dictionaryEntryID == entryID && self.selectedReferences[$0.id]?.contains(capture) == true
                  }) else { throw PronunciationDictionaryStoreError.staleEvidence }
            return try file.read { try PronunciationDictionaryStore.decodeOriginalAudio($0, capture: capture, entryID: entryID) }
        }

        func close(leaseID: UUID) {
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.leaseID == leaseID else { return }
            self.closeFiles()
        }

        private func closeFiles() {
            self.closed = true
            for file in self.inspections.values { file.close() }
            for file in self.originals.values { file.close() }
            self.inspections.removeAll()
            self.originals.removeAll()
            self.selectedProfiles.removeAll()
            self.selectedReferences.removeAll()
        }

        deinit { self.closeFiles() }
    }

    /// Mandatory exact-model reads preserve their original 128-profile capacity. Shared-family
    /// expansion is optional: 128 words / 1024 candidates total, adding no variant beyond eight
    /// candidates per word while leaving the original exact list untouched. The same 384 unique
    /// references and 16 MB metadata limits remain in force. Invalid, unavailable or
    /// excess optional candidates are omitted before the immutable snapshot is created. One
    /// fallback per otherwise unrepresented word precedes extra variants for an admitted word.
    nonisolated func admitCaptureRead(leaseID: UUID, modelKey: String, entryIDs: Set<UUID>,
                                     includingSharedFamilies: Bool = false, maximumReferencesPerProfile: Int = 3,
                                     referenceSelection: @Sendable (PronunciationDictionaryProfile) -> [PronunciationEnrollmentCapture] = { $0.matchingEnrollments }) throws -> CaptureRead {
        try Task.checkCancellation()
        guard (3...10).contains(maximumReferencesPerProfile) else {
            throw PronunciationDictionaryStoreError.inconsistentEnrollment
        }
        guard let profile = self.profile, PrivateProfileStorage.isReadable(profile),
              PrivateProfileStorage.acceptsNewWork else { throw PronunciationDictionaryStoreError.staleEvidence }
        var exact: [PronunciationDictionaryProfile] = []
        var shared: [PronunciationDictionaryProfile] = []
        var sharedCandidateCount = 0
        if let metadata = try DictionaryCaptureEvidenceFile(url: self.fileURL, maximumBytes: 16_000_000, profile: profile) {
            defer { metadata.close() }
            let selection = try metadata.read { data in
                let document = try JSONDecoder().decode(Document.self, from: data)
                guard document.version == 1 else { throw PronunciationDictionaryStoreError.inconsistentEnrollment }
                func isValid(_ item: PronunciationDictionaryProfile) -> Bool {
                    item.enrollments.count <= 10 && PronunciationDictionaryProfile.hasConsistentFeatures(
                        item.enrollments, modelKey: item.modelKey, hiddenSize: item.hiddenSize
                    )
                }
                let exact = document.profiles.filter { $0.modelKey == modelKey && entryIDs.contains($0.dictionaryEntryID) }
                guard exact.count <= 128, exact.allSatisfy(isValid) else {
                    throw PronunciationDictionaryStoreError.inconsistentEnrollment
                }
                var selectedEntries = Set(exact.map(\.dictionaryEntryID))
                var candidatesPerEntry = Dictionary(grouping: exact, by: \.dictionaryEntryID).mapValues(\.count)
                var selectedIDs = Set(exact.map(\.id))
                var shared: [PronunciationDictionaryProfile] = []
                var candidateCount = 0
                if includingSharedFamilies {
                    for item in document.profiles where item.modelKey != modelKey && entryIDs.contains(item.dictionaryEntryID) &&
                        ParakeetSpeechModelCatalog.sharesPronunciationFamily(item.modelKey, with: modelKey)
                    {
                        try Task.checkCancellation()
                        candidateCount += 1
                        guard isValid(item), item.isEligibleForMatching, exact.count + shared.count < 1024,
                              (candidatesPerEntry[item.dictionaryEntryID] ?? 0) < 8,
                              selectedEntries.contains(item.dictionaryEntryID) || selectedEntries.count < 128,
                              selectedIDs.insert(item.id).inserted else { continue }
                        selectedEntries.insert(item.dictionaryEntryID)
                        candidatesPerEntry[item.dictionaryEntryID, default: 0] += 1
                        shared.append(item)
                    }
                }
                return (exact, shared, candidateCount)
            }
            exact = selection.0; shared = selection.1; sharedCandidateCount = selection.2
        }
        var inspections: [UUID: DictionaryCaptureEvidenceFile] = [:]
        var originals: [UUID: DictionaryCaptureEvidenceFile] = [:]
        var selectedReferences: [String: [PronunciationEnrollmentCapture]] = [:]
        var transferred = false
        defer {
            if !transferred {
                for file in inspections.values { file.close() }
                for file in originals.values { file.close() }
            }
        }
        func pinReferences(_ selected: PronunciationDictionaryProfile, captures: [PronunciationEnrollmentCapture], optional: Bool, append: Bool = false) throws -> Bool {
            try Task.checkCancellation()
            guard captures.allSatisfy({ selected.enrollments.contains($0) }) else {
                if optional { return false }
                throw PronunciationDictionaryStoreError.inconsistentEnrollment
            }
            let neededInspections = Set(captures.compactMap(\.inspectionID)).subtracting(inspections.keys)
            let neededOriginals = Set(captures.filter { $0.inspectionID == nil }.compactMap(\.originalAudioID)).subtracting(originals.keys)
            guard inspections.count + originals.count + neededInspections.count + neededOriginals.count <= 384 else {
                if optional { return false }
                throw PronunciationDictionaryStoreError.inconsistentEnrollment
            }
            var addedInspections: [UUID: DictionaryCaptureEvidenceFile] = [:]
            var addedOriginals: [UUID: DictionaryCaptureEvidenceFile] = [:]
            var committed = false
            defer {
                if !committed {
                    for file in addedInspections.values { file.close() }
                    for file in addedOriginals.values { file.close() }
                }
            }
            for capture in captures {
                if let id = capture.inspectionID, inspections[id] == nil, addedInspections[id] == nil {
                    if let file = try DictionaryCaptureEvidenceFile(url: self.inspectionURL(id), maximumBytes: 24_000_000, profile: profile) {
                        addedInspections[id] = file
                    } else if optional { return false }
                } else if capture.inspectionID == nil, let id = capture.originalAudioID,
                          originals[id] == nil, addedOriginals[id] == nil
                {
                    if let file = try DictionaryCaptureEvidenceFile(url: self.audioURL(id), maximumBytes: 2_000_000, profile: profile) {
                        addedOriginals[id] = file
                    } else if optional { return false }
                }
            }
            for (id, file) in addedInspections { inspections[id] = file }
            for (id, file) in addedOriginals { originals[id] = file }
            if append { selectedReferences[selected.id, default: []] += captures }
            else { selectedReferences[selected.id] = captures }
            committed = true
            return true
        }
        var exactSelections: [[PronunciationEnrollmentCapture]] = []
        for selected in exact {
            let captures = referenceSelection(selected)
            guard captures.count <= maximumReferencesPerProfile, captures.allSatisfy({ selected.enrollments.contains($0) }) else {
                throw PronunciationDictionaryStoreError.inconsistentEnrollment
            }
            exactSelections.append(captures)
            _ = try pinReferences(selected, captures: Array(captures.prefix(3)), optional: false)
        }
        var profiles = exact
        var admittedEntries = Set(exact.map(\.dictionaryEntryID))
        var attempted = Set<Int>()
        func admitOptional(_ index: Int) throws {
            attempted.insert(index)
            do {
                let candidate = shared[index]
                let captures = referenceSelection(candidate)
                guard captures.count <= maximumReferencesPerProfile else { return }
                if try pinReferences(candidate, captures: captures, optional: true) {
                    profiles.append(candidate)
                    admittedEntries.insert(candidate.dictionaryEntryID)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { /* An optional family reference cannot invalidate the mandatory exact snapshot. */ }
        }
        for index in shared.indices where !admittedEntries.contains(shared[index].dictionaryEntryID) {
            try admitOptional(index)
        }
        for index in shared.indices where !attempted.contains(index) { try admitOptional(index) }
        // Mandatory exact baselines are all pinned before any optional extras.
        // Admit extras individually so a missing file or full budget cannot
        // prevent a different profile's baseline from being captured.
        for (index, selected) in exact.enumerated() {
            for capture in exactSelections[index].dropFirst(3) {
                do { _ = try pinReferences(selected, captures: [capture], optional: true, append: true) }
                catch is CancellationError { throw CancellationError() }
                catch PronunciationDictionaryStoreError.staleEvidence { throw PronunciationDictionaryStoreError.staleEvidence }
                catch { /* Unusable optional evidence never blocks dictation. */ }
            }
        }
        guard PrivateProfileStorage.isReadable(profile), PrivateProfileStorage.acceptsNewWork else {
            throw PronunciationDictionaryStoreError.staleEvidence
        }
        try Task.checkCancellation()
        let result = CaptureRead(profile: profile, leaseID: leaseID, profiles: profiles,
            omittedSharedProfileCount: sharedCandidateCount - (profiles.count - exact.count),
            inspections: inspections, originals: originals, selectedReferences: selectedReferences)
        transferred = true
        return result
    }

    init(fileManager: FileManager = .default) {
        let profile = PrivateProfileStorage.current
        self.profile = profile
        self.fileURL = profile.rootDirectory.appendingPathComponent("pronunciation-dictionary-v1.json")
    }

    init(fileURL: URL, profile: PrivateProfileSnapshot? = nil) {
        self.fileURL = fileURL
        self.profile = profile
    }

    /// Actor serialization joins synchronous disk operations before retirement returns.
    func prepareForProfileTransition() {
        self.retired = true
        self.document = nil
        self.revisions.removeAll()
        self.replacementGeneration = UUID()
    }

    private func requireAccess() throws {
        guard self.canAccess else { throw PronunciationDictionaryStoreError.staleEvidence }
    }

    func allProfiles() -> [PronunciationDictionaryProfile] {
        guard self.canAccess else { return [] }
        self.loadIfNeeded()
        return self.document?.profiles ?? []
    }

    func profiles(modelKey: String) -> [PronunciationDictionaryProfile] {
        guard self.canAccess else { return [] }
        self.loadIfNeeded()
        return self.document?.profiles.filter { $0.modelKey == modelKey } ?? []
    }

    /// Read-only family fallback. Keep checkpoint identities and stored recordings intact.
    /// One profile per word prevents another model's version competing with its own word.
    func sharedProfiles(modelKey: String, hiddenSize: Int?) -> [PronunciationDictionaryProfile] {
        guard self.canAccess else { return [] }
        self.loadIfNeeded()
        return Self.selectSharedProfiles(self.document?.profiles ?? [], modelKey: modelKey, hiddenSize: hiddenSize)
    }

    nonisolated static func selectSharedProfiles(
        _ profiles: [PronunciationDictionaryProfile], modelKey: String, hiddenSize: Int?
    ) -> [PronunciationDictionaryProfile] {
        let eligible = profiles.filter {
            $0.isEligibleForMatching && (hiddenSize == nil || $0.hiddenSize == hiddenSize) &&
                ($0.modelKey == modelKey || ParakeetSpeechModelCatalog.sharesPronunciationFamily($0.modelKey, with: modelKey))
        }.sorted {
            let leftExact = $0.modelKey == modelKey, rightExact = $1.modelKey == modelKey
            if leftExact != rightExact { return leftExact }
            if $0.enrollments.count != $1.enrollments.count { return $0.enrollments.count > $1.enrollments.count }
            return $0.id < $1.id
        }
        var seen = Set<UUID>()
        return eligible.filter { seen.insert($0.dictionaryEntryID).inserted }
    }

    func enrollmentCount(
        dictionaryEntryID: UUID,
        modelKey: String
    ) -> Int {
        guard self.canAccess else { return 0 }
        self.loadIfNeeded()
        return self.document?.profiles.first {
            $0.dictionaryEntryID == dictionaryEntryID && $0.modelKey == modelKey
        }?.enrollments.count ?? 0
    }

    func upsert(
        dictionaryEntryID: UUID,
        label: String,
        modelKey: String,
        enrollments: [PronunciationEnrollmentCapture],
        automaticMatchingEnabled: Bool = false,
        expectedExistingEnrollments: [PronunciationEnrollmentCapture]? = nil,
        canPersist: @Sendable () -> Bool = { true }
    ) throws {
        try self.requireAccess()
        guard canPersist() else { throw CancellationError() }
        guard let first = enrollments.first, !first.values.isEmpty else { return }
        guard PronunciationDictionaryProfile.hasConsistentFeatures(enrollments, modelKey: modelKey, hiddenSize: first.values.count) else {
            throw PronunciationDictionaryStoreError.inconsistentEnrollment
        }
        self.loadIfNeeded()
        var profiles = self.document?.profiles ?? []
        let existingIndex = profiles.firstIndex(where: {
            $0.dictionaryEntryID == dictionaryEntryID && $0.modelKey == modelKey
        })
        let existingEnrollments = existingIndex.map { profiles[$0].enrollments } ?? []
        if let expectedExistingEnrollments, existingEnrollments != expectedExistingEnrollments {
            throw PronunciationDictionaryStoreError.staleEvidence
        }
        var occurrences = Set(existingEnrollments.compactMap(Self.occurrenceKey))
        var prepared = enrollments.filter { capture in
            guard let key = Self.occurrenceKey(capture) else { return true }
            return occurrences.insert(key).inserted
        }
        guard !prepared.isEmpty else { return }
        var writtenInspectionIDs: [UUID] = []
        do {
            for index in prepared.indices {
                guard canPersist() else { throw CancellationError() }
                guard let evidence = prepared[index].pendingInspection else { continue }
                guard evidence.isValid, evidence.duration <= 15,
                      evidence.frames.allSatisfy({ $0.hiddenSize == first.values.count })
                else { throw PronunciationDictionaryStoreError.inconsistentEnrollment }
                let id = UUID()
                let url = self.inspectionURL(id)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                try encoder.encode(evidence).write(to: url, options: .atomic)
                writtenInspectionIDs.append(id)
                prepared[index].inspectionID = id
                prepared[index].pendingInspection = nil
            }
        } catch {
            for id in writtenInspectionIDs {
                try? FileManager.default.removeItem(at: self.inspectionURL(id))
            }
            throw error
        }
        var didPersist = false
        defer {
            if !didPersist {
                for id in writtenInspectionIDs {
                    try? FileManager.default.removeItem(at: self.inspectionURL(id))
                }
            }
        }
        let combinedEnrollments = existingEnrollments + prepared
        guard PronunciationDictionaryProfile.hasConsistentFeatures(combinedEnrollments, modelKey: modelKey, hiddenSize: first.values.count) else {
            throw PronunciationDictionaryStoreError.inconsistentEnrollment
        }
        let profile = PronunciationDictionaryProfile(
            dictionaryEntryID: dictionaryEntryID,
            label: label,
            modelKey: modelKey,
            hiddenSize: first.values.count,
            enrollments: Self.retainedEnrollments(combinedEnrollments),
            automaticMatchingEnabled: automaticMatchingEnabled || existingIndex.map { profiles[$0].automaticMatchingEnabled == true } == true,
            matchThreshold: existingIndex.flatMap { profiles[$0].matchThreshold }
        )
        if let index = existingIndex {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        guard canPersist() else { throw CancellationError() }
        try self.persist(Document(
            version: 1,
            profiles: profiles
        ))
        didPersist = true
        let retained = Set(profile.enrollments.compactMap(\.inspectionID))
        for id in writtenInspectionIDs where !retained.contains(id) {
            try? FileManager.default.removeItem(at: self.inspectionURL(id))
        }
    }

    /// Keep trained references when automatically learned examples reach the history limit.
    nonisolated private static func occurrenceKey(_ capture: PronunciationEnrollmentCapture) -> String? {
        guard let id = capture.sourceRecordingID, let range = capture.sourceFocalRange else { return nil }
        return "\(id):\(range.lowerBound):\(range.upperBound)"
    }

    static func retainedEnrollments(_ captures: [PronunciationEnrollmentCapture]) -> [PronunciationEnrollmentCapture] {
        let protected = Set(captures.indices.filter { captures[$0].originalAudioID == nil }.suffix(3))
        let candidates = captures.indices.filter { !protected.contains($0) }.reversed()
        var seen = Set<String>(), distinct: [Int] = [], repeated: [Int] = []
        for index in candidates {
            let observed = captures[index].observedText ?? ""
            let text = observed.count <= 80 ? observed : ""
            let latin = text.applyingTransform(.toLatin, reverse: false) ?? text
            let key = (latin.applyingTransform(.stripCombiningMarks, reverse: false) ?? latin)
                .lowercased().filter { $0.isLetter || $0.isNumber }
            if captures[index].originalAudioID != nil && !key.isEmpty && seen.insert(key).inserted {
                distinct.append(index)
            } else { repeated.append(index) }
        }
        // Retain the newest representative of each observed spelling first;
        // use remaining slots for the newest repeats or legacy references.
        let selected = protected.union((distinct + repeated).prefix(10 - protected.count))
        // Manual references first so the matcher can keep its existing calibration.
        return selected.sorted { lhs, rhs in
            let leftManual = captures[lhs].originalAudioID == nil
            let rightManual = captures[rhs].originalAudioID == nil
            return leftManual == rightManual ? lhs < rhs : leftManual
        }.map { captures[$0] }
    }

    static func matchingEnrollments(_ captures: [PronunciationEnrollmentCapture]) -> [PronunciationEnrollmentCapture] {
        let manual = Array(captures.filter { $0.originalAudioID == nil }.suffix(3))
        let original = captures.filter { $0.originalAudioID != nil }.suffix(3 - manual.count)
        return manual + original
    }

    /// Validated focal audio for legacy and new automatically learned references.
    func originalAudioSamples(for capture: PronunciationEnrollmentCapture, entryID: UUID) throws -> [Float] {
        try self.requireAccess()
        guard let id = capture.originalAudioID else { throw PronunciationDictionaryStoreError.inconsistentEnrollment }
        let url = self.audioURL(id)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 2_000_000 else { throw PronunciationDictionaryStoreError.inconsistentEnrollment }
        return try Self.decodeOriginalAudio(Data(contentsOf: url), capture: capture, entryID: entryID)
    }

    nonisolated private static func decodeOriginalAudio(_ data: Data, capture: PronunciationEnrollmentCapture, entryID: UUID) throws -> [Float] {
        guard let id = capture.originalAudioID else { throw PronunciationDictionaryStoreError.inconsistentEnrollment }
        let record = try JSONDecoder().decode(OriginalAudioRecord.self, from: data)
        guard record.version == 1, record.sampleRate == 16_000, record.encoding == "float32-little-endian",
              record.entryID == entryID, record.evidenceID == id, record.modelKey == capture.modelKey,
              record.pcmFloat32.count % MemoryLayout<Float>.size == 0,
              record.pcmFloat32.count <= 238_080 * MemoryLayout<Float>.size
        else {
            throw PronunciationDictionaryStoreError.inconsistentEnrollment
        }
        let samples = record.pcmFloat32.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: MemoryLayout<Float>.size).map { bytes.loadUnaligned(fromByteOffset: $0, as: Float.self) }
        }
        let range = record.focalSampleRange
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= samples.count,
              samples.allSatisfy(\.isFinite) else { throw PronunciationDictionaryStoreError.inconsistentEnrollment }
        return Array(samples[range])
    }

    /// Reads only the selected example. Legacy profiles explicitly have no evidence.
    func inspection(for id: UUID) throws -> DictionaryAudioInspection {
        try self.requireAccess()
        let url = self.inspectionURL(id)
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = attributes.fileSize, size <= 24_000_000 else {
            throw PronunciationDictionaryStoreError.inconsistentEnrollment
        }
        let value = try PropertyListDecoder().decode(DictionaryAudioInspection.self, from: Data(contentsOf: url))
        guard value.isValid else { throw PronunciationDictionaryStoreError.inconsistentEnrollment }
        return value
    }

    /// UI playback uses the exact persisted enrollment and only its trained cut.
    /// A stale sheet cannot read an unrelated or replaced recording by UUID alone.
    func savedAudioSamples(for capture: PronunciationEnrollmentCapture, dictionaryEntryID: UUID, expectedProfileLabel: String) throws -> [Float] {
        try self.requireAccess()
        self.loadIfNeeded()
        guard let stored = self.document?.profiles.first(where: {
            $0.dictionaryEntryID == dictionaryEntryID && $0.modelKey == capture.modelKey && $0.label == expectedProfileLabel
        }), stored.enrollments.filter({ $0 == capture }).count == 1 else {
            throw PronunciationDictionaryStoreError.staleEvidence
        }
        if capture.originalAudioID != nil {
            return try self.originalAudioSamples(for: capture, entryID: dictionaryEntryID)
        }
        guard let id = capture.inspectionID else { throw PronunciationDictionaryStoreError.inconsistentEnrollment }
        let audio = try self.inspection(for: id)
        let lower = max(0, min(audio.recordedSampleCount, Int(audio.selectedStart * 16_000)))
        let upper = min(audio.recordedSampleCount, Int(audio.selectedEnd * 16_000))
        guard lower < upper else { throw PronunciationDictionaryStoreError.inconsistentEnrollment }
        return Array(audio.samples[lower..<upper])
    }

    /// Remove one exact enrollment, retaining its word, other models and examples.
    /// Persist owns orphan cleanup, so files shared by retained examples survive.
    func removeSavedSample(_ capture: PronunciationEnrollmentCapture, dictionaryEntryID: UUID, expectedProfileLabel: String) throws {
        try Task.checkCancellation()
        try self.requireAccess()
        self.loadIfNeeded()
        var profiles = self.document?.profiles ?? []
        guard let profileIndex = profiles.firstIndex(where: {
            $0.dictionaryEntryID == dictionaryEntryID && $0.modelKey == capture.modelKey && $0.label == expectedProfileLabel
        }) else { throw PronunciationDictionaryStoreError.staleEvidence }
        let matches = profiles[profileIndex].enrollments.indices.filter { profiles[profileIndex].enrollments[$0] == capture }
        guard matches.count == 1, let captureIndex = matches.first else { throw PronunciationDictionaryStoreError.staleEvidence }
        profiles[profileIndex].enrollments.remove(at: captureIndex)
        if profiles[profileIndex].enrollments.isEmpty { profiles.remove(at: profileIndex) }
        try Task.checkCancellation()
        try self.persist(Document(version: 1, profiles: profiles))
        self.revisions[dictionaryEntryID] = UUID()
    }

    nonisolated private func inspectionURL(_ id: UUID) -> URL {
        self.fileURL.deletingLastPathComponent().appendingPathComponent("pronunciation-inspection", isDirectory: true)
            .appendingPathComponent(id.uuidString).appendingPathExtension("plist")
    }

    /// Updates only this word's matching level; preserves recordings and text rules.
    func setMatchThreshold(_ threshold: Float, dictionaryEntryID: UUID) throws {
        try self.requireAccess()
        guard threshold.isFinite, (0.4...0.95).contains(threshold) else {
            throw PronunciationDictionaryStoreError.inconsistentEnrollment
        }
        self.loadIfNeeded()
        var profiles = self.document?.profiles ?? []
        guard profiles.contains(where: { $0.dictionaryEntryID == dictionaryEntryID }) else {
            throw PronunciationDictionaryStoreError.staleEvidence
        }
        for index in profiles.indices where profiles[index].dictionaryEntryID == dictionaryEntryID {
            profiles[index].matchThreshold = threshold
        }
        try self.persist(Document(version: 1, profiles: profiles))
    }

    func replaceAllProfiles(_ profiles: [PronunciationDictionaryProfile]) throws {
        try self.requireAccess()
        guard profiles.allSatisfy({ profile in
            PronunciationDictionaryProfile.hasConsistentFeatures(profile.enrollments, modelKey: profile.modelKey, hiddenSize: profile.hiddenSize)
        }) else {
            throw PronunciationDictionaryStoreError.inconsistentEnrollment
        }
        try self.persist(Document(
            version: 1,
            profiles: profiles
        ))
        self.replacementGeneration = UUID()
    }

    func updateLabel(
        dictionaryEntryID: UUID,
        label: String
    ) throws {
        self.revisions[dictionaryEntryID] = UUID()
        self.loadIfNeeded()
        var profiles = self.document?.profiles ?? []
        var changed = false
        for index in profiles.indices where profiles[index].dictionaryEntryID == dictionaryEntryID {
            profiles[index].label = label
            changed = true
        }
        if changed {
            try self.persist(Document(
                version: 1,
                profiles: profiles
            ))
        }
    }

    func delete(dictionaryEntryID: UUID) throws {
        try self.requireAccess()
        self.revisions[dictionaryEntryID] = UUID()
        self.loadIfNeeded()
        var profiles = self.document?.profiles ?? []
        let audioIDs = profiles.filter { $0.dictionaryEntryID == dictionaryEntryID }
            .flatMap(\.enrollments).compactMap(\.originalAudioID)
        profiles.removeAll { $0.dictionaryEntryID == dictionaryEntryID }
        try self.persist(Document(
            version: 1,
            profiles: profiles
        ))
        for id in audioIDs {
            try? FileManager.default.removeItem(at: self.audioURL(id))
        }
    }

    struct Revision: Equatable, Sendable {
        let entry: UUID
        let generation: UUID
    }

    func revision(for entryID: UUID) -> Revision {
        let revision = self.revisions[entryID] ?? UUID()
        self.revisions[entryID] = revision
        return Revision(
            entry: revision,
            generation: self.replacementGeneration
        )
    }

    /// Audio is written first; only the atomic profile write activates it for matching.
    /// An interrupted write can leave an inactive audio file, never a partial active enrollment.
    @discardableResult
    func learnOriginalAudio(
        entryID: UUID,
        label: String,
        evidenceID: UUID,
        evidence: DictionaryLearningAudioEvidence,
        capture: PronunciationEnrollmentCapture,
        expectedRevision: Revision,
        canPersist: @Sendable () -> Bool = { true }
    ) throws -> Bool {
        try self.requireAccess()
        guard canPersist() else { throw CancellationError() }
        guard self.revision(for: entryID) == expectedRevision else {
            throw PronunciationDictionaryStoreError.staleEvidence
        }
        self.loadIfNeeded()
        guard capture.modelKey == evidence.modelKey, !capture.values.isEmpty,
              capture.values.allSatisfy(\.isFinite), capture.sourceFrameCount > 0,
              !evidence.samples.isEmpty, evidence.samples.count <= 238_080,
              evidence.samples.allSatisfy(\.isFinite),
              evidence.focalSampleRange.lowerBound >= 0,
              evidence.focalSampleRange.upperBound <= evidence.samples.count,
              !evidence.focalSampleRange.isEmpty,
              evidence.sourceSampleRange.lowerBound >= 0,
              evidence.sourceSampleRange.upperBound <= DictionaryLearningRecording.maximumSamples,
              evidence.sourceSampleRange.count == evidence.samples.count
        else { throw PronunciationDictionaryStoreError.inconsistentEnrollment }
        let focalRange = (evidence.sourceSampleRange.lowerBound + evidence.focalSampleRange.lowerBound)..<(evidence.sourceSampleRange.lowerBound + evidence.focalSampleRange.upperBound)
        for profile in self.document?.profiles ?? [] {
            if profile.dictionaryEntryID == entryID, profile.label.caseInsensitiveCompare(label) != .orderedSame {
                throw PronunciationDictionaryStoreError.staleEvidence
            }
            for prior in profile.enrollments {
                let sameOccurrence = prior.sourceRecordingID == evidence.recordingID && prior.sourceFocalRange == focalRange
                if prior.originalAudioID == evidenceID {
                    guard profile.dictionaryEntryID == entryID, profile.modelKey == capture.modelKey, sameOccurrence else {
                        throw PronunciationDictionaryStoreError.inconsistentEnrollment
                    }
                    return false
                }
                if profile.dictionaryEntryID == entryID, profile.modelKey == capture.modelKey, sameOccurrence { return false }
            }
        }
        let record = OriginalAudioRecord(
            version: 1,
            sampleRate: 16_000,
            encoding: "float32-little-endian",
            entryID: entryID,
            intendedText: label,
            evidenceID: evidenceID,
            recordingID: evidence.recordingID,
            modelKey: evidence.modelKey,
            observedText: evidence.observedText,
            sourceSampleRange: evidence.sourceSampleRange,
            focalSampleRange: evidence.focalSampleRange,
            sourceWordRange: evidence.sourceWordRange,
            pcmFloat32: evidence.samples.withUnsafeBytes { Data($0) }
        )
        let url = self.audioURL(evidenceID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(record).write(
            to: url,
            options: .atomic
        )
        var enrolled = capture
        enrolled.extractorVersion = capture.extractorVersion ?? "parakeet-encoder-mean-l2-v1"
        enrolled.originalAudioID = evidenceID
        enrolled.observedText = evidence.observedText
        enrolled.sourceRecordingID = evidence.recordingID
        enrolled.sourceFocalRange = focalRange
        do {
            try self.upsert(
                dictionaryEntryID: entryID,
                label: label,
                modelKey: capture.modelKey,
                enrollments: [enrolled],
                canPersist: canPersist
            )
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return true
    }

    func removeOriginalAudio(evidenceID: UUID) throws {
        try self.requireAccess()
        self.loadIfNeeded()
        var profiles = self.document?.profiles ?? []
        let affectedEntries = Set(profiles.filter { $0.enrollments.contains { $0.originalAudioID == evidenceID } }.map(\.dictionaryEntryID))
        for index in profiles.indices {
            profiles[index].enrollments.removeAll { $0.originalAudioID == evidenceID }
        }
        profiles.removeAll { $0.enrollments.isEmpty }
        try self.persist(Document(
            version: 1,
            profiles: profiles
        ))
        for entryID in affectedEntries { self.revisions[entryID] = UUID() }
        try? FileManager.default.removeItem(at: self.audioURL(evidenceID))
    }

    private struct OriginalAudioRecord: Codable {
        let version: Int
        let sampleRate: Int
        let encoding: String
        let entryID: UUID
        let intendedText: String
        let evidenceID: UUID
        let recordingID: UUID
        let modelKey: String
        let observedText: String
        let sourceSampleRange: Range<Int>
        let focalSampleRange: Range<Int>
        let sourceWordRange: Range<Int>
        let pcmFloat32: Data
    }

    nonisolated private func audioURL(_ id: UUID) -> URL {
        self.fileURL.deletingLastPathComponent().appendingPathComponent(
            "pronunciation-audio",
            isDirectory: true
        )
        .appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func loadIfNeeded() {
        guard self.canAccess else { return }
        guard self.document == nil else { return }
        guard let data = try? Data(contentsOf: self.fileURL),
              let decoded = try? JSONDecoder().decode(
                  Document.self,
                  from: data
              ),
              decoded.version == 1
        else {
            self.document = Document(
                version: 1,
                profiles: []
            )
            return
        }
        self.document = decoded
        self.removeOrphanedAudio()
        self.removeOrphanedInspections()
    }

    /// A crash before the profile commit leaves an inactive clip; discard it after loading valid metadata.
    private func removeOrphanedAudio() {
        let referenced = Set((self.document?.profiles ?? []).flatMap(\.enrollments).compactMap(\.originalAudioID))
        let directory = self.audioURL(UUID()).deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in files where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !referenced.contains(id) else { continue }
            // Another app process may be between its audio write and profile commit.
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate, modified.timeIntervalSinceNow < -60
            else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func removeOrphanedInspections() {
        let referenced = Set((self.document?.profiles ?? []).flatMap(\.enrollments).compactMap(\.inspectionID))
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: self.inspectionURL(UUID()).deletingLastPathComponent(), includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in files where file.pathExtension == "plist" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !referenced.contains(id),
                  let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate, modified.timeIntervalSinceNow < -60
            else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func persist(_ updated: Document) throws {
        try self.requireAccess()
        try FileManager.default.createDirectory(
            at: self.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(updated).write(
            to: self.fileURL,
            options: .atomic
        )
        let oldIDs = Set((self.document?.profiles ?? []).flatMap(\.enrollments).compactMap(\.originalAudioID))
        let oldInspectionIDs = Set((self.document?.profiles ?? []).flatMap(\.enrollments).compactMap(\.inspectionID))
        let newInspectionIDs = Set(updated.profiles.flatMap(\.enrollments).compactMap(\.inspectionID))
        self.document = updated
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        for id in oldInspectionIDs.subtracting(newInspectionIDs) {
            try? FileManager.default.removeItem(at: self.inspectionURL(id))
        }
        let newIDs = Set(updated.profiles.flatMap(\.enrollments).compactMap(\.originalAudioID))
        for id in oldIDs.subtracting(newIDs) {
            try? FileManager.default.removeItem(at: self.audioURL(id))
        }
    }
}

import Foundation

/// Metadata can be shown in settings. The local signature itself never enters a meeting,
/// processing checkpoint, transcript export, telemetry or support log.
nonisolated struct MeetingOwnerVoiceProfileMetadata: Equatable, Sendable {
    let generation: UUID
    let enrolledAt: Date
}

nonisolated struct MeetingOwnerVoiceProfileSnapshot: Equatable, Sendable {
    let metadata: MeetingOwnerVoiceProfileMetadata
    let encoderFingerprint: String
    let embeddings: [[Float]]
}

/// Opaque candidate produced only after local quality checks. Contains no PCM.
nonisolated struct MeetingOwnerVoiceProfileDraft: Sendable {
    fileprivate let snapshot: MeetingOwnerVoiceProfileSnapshot
    fileprivate let serviceRevision: UUID
}

nonisolated enum MeetingOwnerVoiceProfileError: Error {
    case invalidAudio, insufficientSpeech, inconsistentVoice, invalidProfile, staleDraft, busy
}

/// Explicit owner identity is a cross-recording decision, separate from anonymous within-
/// meeting clustering. Saved recipes retain their original strict policy; two plausible
/// owner identities still remain unconfirmed under every policy.
nonisolated enum MeetingOwnerVoiceVerifier {
    /// Bind only an unambiguous encoder input/result pair. The adapter stores these scalar
    /// lengths atomically with that encoded profile; embeddings alone cannot prove duration.
    static func clipFramesByToken(
        samples: [MeetingSpeakerVoiceSamples], profiles: [MeetingSpeakerVoiceProfile]
    ) -> [MeetingBackendSpeakerToken: [Int]] {
        guard samples.count <= MeetingSpeakerVoiceSamples.maximumProfiles,
              profiles.count <= MeetingSpeakerVoiceSamples.maximumProfiles else { return [:] }
        let inputs = Dictionary(grouping: samples, by: \.token)
        let outputs = Dictionary(grouping: profiles, by: \.token)
        var frames: [MeetingBackendSpeakerToken: [Int]] = [:]
        for profile in profiles {
            guard outputs[profile.token]?.count == 1, let matches = inputs[profile.token], matches.count == 1,
                  matches[0].clips.count == 2 else { continue }
            frames[profile.token] = matches[0].clips.map(\.count)
        }
        return frames
    }

    /// An omitted competitor is unavailable evidence, not evidence that the remaining
    /// profile is the owner. Keep this input/result boundary separate from scoring.
    static func hasCompleteEncoderResults(
        samples: [MeetingSpeakerVoiceSamples], profiles: [MeetingSpeakerVoiceProfile]
    ) -> Bool {
        let expected = Set(samples.map(\.token))
        let returned = Set(profiles.map(\.token))
        return !samples.isEmpty && samples.count <= MeetingSpeakerVoiceSamples.maximumProfiles
            && samples.count == profiles.count && expected.count == samples.count
            && returned.count == profiles.count && expected == returned
            && self.clipFramesByToken(samples: samples, profiles: profiles).count == samples.count
            && profiles.allSatisfy { MeetingSpeakerVoiceMatcher.distance($0, $0) != nil }
    }

    nonisolated enum Policy: Equatable, Sendable {
        case legacy
        case streamingV2
        case streamingV4
        var maximumReferenceDistance: Float { self == .legacy ? 0.25 : 0.65 }
        var maximumQuerySelfDistance: Float { self == .legacy ? 0.25 : 0.45 }
        var ambiguityMargin: Float { 0.10 }

        var diagnosticName: String {
            switch self {
            case .legacy: "legacy"
            case .streamingV2: "streamingV2"
            case .streamingV4: "streamingV4"
            }
        }
    }

    /// Attempt-local scalar evidence only. Never includes tokens, profile metadata or vectors.
    /// The callback is synchronous and optional so callers keep the existing decision API.
    nonisolated struct Diagnostics: Sendable {
        nonisolated enum Outcome: String, Sendable {
            case missingOwner, invalidOwner, duplicateTokens, invalidLinks
            case noValidCandidates, referenceDistance, winnerMargin, insufficientEvidence, confirmed
        }
        nonisolated struct Query: Sendable {
            nonisolated enum Gate: String, Sendable { case invalidQuery, querySelfDistance, invalidReferenceDistance, measured }
            let ordinal: Int
            let selfDistance: Float?
            let referenceDistance: Float?
            let gate: Gate
            let clipCount: Int?
            /// Bounded scalar metadata from this profile's encoded cache entry, never PCM.
            let clipFrames: [Int]?
            let hasFullEvidence: Bool
        }
        let policy: Policy
        let profileCount: Int
        var outcome: Outcome = .noValidCandidates
        var validProfileCount = 0
        var rejectedProfileCount = 0
        var validGroupCount = 0
        var rejectedGroupCount = 0
        var queries: [Query] = []
        var bestReferenceDistance: Float?
        var runnerReferenceDistance: Float?
        var winnerMargin: Float?

        /// At most 128 evaluated observations, identified only by their input-array ordinal.
        /// Skipped observations were not measured after an earlier linked observation failed.
        var diagnosticFields: String {
            func scalar(_ value: Float?) -> String { value.map { String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), Double($0)) } ?? "unavailable" }
            let rows = self.queries.sorted { $0.ordinal < $1.ordinal }.map {
                "\($0.ordinal):\($0.gate.rawValue):self=\(scalar($0.selfDistance)):reference=\(scalar($0.referenceDistance))"
                    + ":clips=\($0.clipCount.map(String.init) ?? "unavailable"):frames=\($0.clipFrames.map { $0.map(String.init).joined(separator: "+") } ?? "unavailable"):full=\($0.hasFullEvidence)"
            }.joined(separator: ",")
            return "policy=\(self.policy.diagnosticName) outcome=\(self.outcome.rawValue)"
                + " profileCount=\(self.profileCount) validProfiles=\(self.validProfileCount) rejectedProfiles=\(self.rejectedProfileCount)"
                + " skippedProfiles=\(self.profileCount - self.validProfileCount - self.rejectedProfileCount)"
                + " validGroups=\(self.validGroupCount) rejectedGroups=\(self.rejectedGroupCount)"
                + " reportedQueries=\(self.queries.count) omittedQueries=\(self.validProfileCount + self.rejectedProfileCount - self.queries.count)"
                + " querySelfLimit=\(scalar(self.policy.maximumQuerySelfDistance)) referenceLimit=\(scalar(self.policy.maximumReferenceDistance))"
                + " marginLimit=\(scalar(self.policy.ambiguityMargin)) bestReference=\(scalar(self.bestReferenceDistance))"
                + " runnerReference=\(scalar(self.runnerReferenceDistance)) winnerMargin=\(scalar(self.winnerMargin)) queries=[\(rows)]"
        }
    }

    static func confirmedTokens(
        owner: MeetingOwnerVoiceProfileSnapshot?, profiles: [MeetingSpeakerVoiceProfile],
        identityLinks: [MeetingSpeakerIdentityLink] = [], policy: Policy = .legacy,
        clipFramesByToken: [MeetingBackendSpeakerToken: [Int]] = [:]
    ) -> Set<MeetingBackendSpeakerToken> {
        self.confirmedTokens(owner: owner, profiles: profiles, identityLinks: identityLinks, policy: policy,
                             clipFramesByToken: clipFramesByToken, diagnostics: nil)
    }

    static func confirmedTokens(
        owner: MeetingOwnerVoiceProfileSnapshot?, profiles: [MeetingSpeakerVoiceProfile],
        identityLinks: [MeetingSpeakerIdentityLink] = [], policy: Policy = .legacy,
        clipFramesByToken: [MeetingBackendSpeakerToken: [Int]] = [:],
        diagnostics: ((Diagnostics) -> Void)?
    ) -> Set<MeetingBackendSpeakerToken> {
        var report = Diagnostics(policy: policy, profileCount: profiles.count)
        func finish(_ outcome: Diagnostics.Outcome, tokens: Set<MeetingBackendSpeakerToken> = []) -> Set<MeetingBackendSpeakerToken> {
            if let diagnostics { report.outcome = outcome; diagnostics(report) }
            return tokens
        }
        func measure(_ ordinal: Int, _ token: MeetingBackendSpeakerToken, _ consistency: Float?, _ distance: Float?, _ gate: Diagnostics.Query.Gate) {
            if gate == .measured { report.validProfileCount += 1 } else { report.rejectedProfileCount += 1 }
            if diagnostics != nil, report.queries.count < MeetingSpeakerVoiceSamples.maximumProfiles {
                let frames = clipFramesByToken[token]
                report.queries.append(.init(ordinal: ordinal, selfDistance: consistency, referenceDistance: distance, gate: gate,
                    clipCount: frames?.count, clipFrames: frames.map { Array($0.prefix(2)) }, hasFullEvidence: frames == [80_000, 80_000]))
            }
        }
        guard let owner else { return finish(.missingOwner) }
        guard MeetingOwnerVoiceProfileStore.isValid(owner) else { return finish(.invalidOwner) }
        if policy != .legacy {
            let tokens = Set(profiles.map(\.token))
            guard tokens.count == profiles.count else { return finish(.duplicateTokens) }
            guard MeetingSpeakerVoiceMatcher.validLinks(identityLinks, allowedTokens: tokens) else { return finish(.invalidLinks) }
        }
        let canonicalByToken = Dictionary(identityLinks.map { ($0.token, $0.canonicalToken) }, uniquingKeysWith: { a, _ in a })
        let groups = Dictionary(grouping: profiles.enumerated()) { canonicalByToken[$0.element.token] ?? $0.element.token }
        var measures: [(MeetingBackendSpeakerToken, Float)] = []
        for (canonical, observations) in groups {
            var worst: Float = 0
            var valid = true
            for (ordinal, observation) in observations {
                guard let consistency = MeetingSpeakerVoiceMatcher.distance(observation, observation) else {
                    measure(ordinal, observation.token, nil, nil, .invalidQuery); valid = false; break
                }
                guard consistency <= policy.maximumQuerySelfDistance else {
                    measure(ordinal, observation.token, consistency, nil, .querySelfDistance); valid = false; break
                }
                guard let distance = MeetingSpeakerVoiceMatcher.distance(
                    observation, MeetingSpeakerVoiceProfile(token: observation.token, embeddings: owner.embeddings)
                ) else { measure(ordinal, observation.token, consistency, nil, .invalidReferenceDistance); valid = false; break }
                measure(ordinal, observation.token, consistency, distance, .measured)
                worst = max(worst, distance)
            }
            if valid { measures.append((canonical, worst)) } else { report.rejectedGroupCount += 1 }
        }
        measures.sort { $0.1 < $1.1 }
        report.validGroupCount = measures.count
        report.bestReferenceDistance = measures.first?.1
        report.runnerReferenceDistance = measures.dropFirst().first?.1
        if measures.count > 1 { report.winnerMargin = measures[1].1 - measures[0].1 }
        guard let winner = measures.first else { return finish(.noValidCandidates) }
        guard winner.1 <= policy.maximumReferenceDistance else { return finish(.referenceDistance) }
        guard measures.count == 1 || measures[1].1 - winner.1 >= policy.ambiguityMargin else { return finish(.winnerMargin) }
        let tokens = Set(profiles.filter { (canonicalByToken[$0.token] ?? $0.token) == winner.0 }.map(\.token))
        // Rank every valid competitor before applying maturity to the winning identity. A
        // short better match or close rival must never promote a worse mature candidate.
        if policy == .streamingV4 {
            guard tokens.allSatisfy({ clipFramesByToken[$0] == [80_000, 80_000] }) else { return finish(.insufficientEvidence) }
        }
        return finish(.confirmed, tokens: tokens)
    }
}

/// One private local file, bounded to two reference embeddings. Atomic replacement means a
/// running runtime can take one immutable snapshot while settings replace/delete the profile.
nonisolated struct MeetingOwnerVoiceProfileStore: Sendable {
    let fileURL: URL
    static let maximumBytes = 16_384
    static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent(AppBrand.storageNamespace, isDirectory: true)
            .appendingPathComponent("OwnerVoice", isDirectory: true).appendingPathComponent("profile.json")
    }
    static var encoderFingerprint: String {
        "\(MeetingSpeakerVoiceModelArtifacts.revision):\(MeetingSpeakerVoiceModelArtifacts.packageName):mono16000:two-disjoint-3to10s:v1:"
            + MeetingSpeakerVoiceModelArtifacts.files.map(\.digest).joined(separator: ":")
    }
    init(fileURL: URL = Self.defaultURL) { self.fileURL = fileURL }

    private struct Record: Codable {
        let schema: Int
        let generation: UUID
        let enrolledAt: Date
        let encoderFingerprint: String
        let embeddings: [[Float]]
    }
    static func isValid(_ snapshot: MeetingOwnerVoiceProfileSnapshot) -> Bool {
        guard snapshot.encoderFingerprint == self.encoderFingerprint,
              snapshot.metadata.enrolledAt.timeIntervalSince1970.isFinite,
              snapshot.embeddings.count == 2,
              snapshot.embeddings.allSatisfy({ $0.count == 256 && $0.allSatisfy(\.isFinite) }) else { return false }
        let token = MeetingBackendSpeakerToken(analysisEpochID: .init(trackID: snapshot.metadata.generation, ordinal: 0), label: "owner")
        let profile = MeetingSpeakerVoiceProfile(token: token, embeddings: snapshot.embeddings)
        return MeetingSpeakerVoiceMatcher.distance(profile, profile).map { $0 <= MeetingSpeakerVoiceMatcher.maximumDistance } ?? false
    }
    func load() throws -> MeetingOwnerVoiceProfileSnapshot? {
        guard self.fileURL.isFileURL else { throw MeetingOwnerVoiceProfileError.invalidProfile }
        let properties: [FileAttributeKey: Any]
        do { properties = try FileManager.default.attributesOfItem(atPath: self.fileURL.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        guard properties[.type] as? FileAttributeType == .typeRegular,
              let size = properties[.size] as? NSNumber, size.intValue > 0,
              size.intValue <= Self.maximumBytes else { throw MeetingOwnerVoiceProfileError.invalidProfile }
        let data = try Data(contentsOf: self.fileURL)
        guard data.count <= Self.maximumBytes else { throw MeetingOwnerVoiceProfileError.invalidProfile }
        let record = try JSONDecoder().decode(Record.self, from: data)
        let snapshot = MeetingOwnerVoiceProfileSnapshot(
            metadata: .init(generation: record.generation, enrolledAt: record.enrolledAt),
            encoderFingerprint: record.encoderFingerprint, embeddings: record.embeddings
        )
        guard record.schema == 1, Self.isValid(snapshot) else { throw MeetingOwnerVoiceProfileError.invalidProfile }
        return snapshot
    }
    func save(_ snapshot: MeetingOwnerVoiceProfileSnapshot) throws {
        guard self.fileURL.isFileURL, Self.isValid(snapshot) else { throw MeetingOwnerVoiceProfileError.invalidProfile }
        let directory = self.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directoryProperties = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard directoryProperties[.type] as? FileAttributeType == .typeDirectory else { throw MeetingOwnerVoiceProfileError.invalidProfile }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if let existing = try? FileManager.default.attributesOfItem(atPath: self.fileURL.path) {
            guard existing[.type] as? FileAttributeType == .typeRegular else { throw MeetingOwnerVoiceProfileError.invalidProfile }
        }
        let record = Record(schema: 1, generation: snapshot.metadata.generation, enrolledAt: snapshot.metadata.enrolledAt,
                            encoderFingerprint: snapshot.encoderFingerprint, embeddings: snapshot.embeddings)
        let data = try JSONEncoder().encode(record)
        guard data.count <= Self.maximumBytes else { throw MeetingOwnerVoiceProfileError.invalidProfile }
        #if os(iOS)
        try data.write(to: self.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: self.fileURL, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.fileURL.path)
        var resource = self.fileURL
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try resource.setResourceValues(values)
    }
    func delete() throws {
        if FileManager.default.fileExists(atPath: self.fileURL.path) { try FileManager.default.removeItem(at: self.fileURL) }
    }
}

/// The shared enrollment lifecycle. UI owns the existing audio-activity lease throughout this
/// operation. Resource preparation uses the existing store, inference the existing voice encoder.
/// Cancellation waits for the actual native inference to drain before the lease can be released.
actor MeetingOwnerVoiceProfileService {
    static let shared = MeetingOwnerVoiceProfileService()
    typealias PrepareResources = @Sendable () async throws -> Void
    typealias Encode = @Sendable ([MeetingSpeakerVoiceSamples]) throws -> [MeetingSpeakerVoiceProfile]
    private let store: MeetingOwnerVoiceProfileStore
    private let prepareResources: PrepareResources
    private let encode: Encode
    private let executor = TranscriptionExecutor()
    private var revision = UUID()
    private var busy = false

    init(store: MeetingOwnerVoiceProfileStore = .init(),
         prepareResources: @escaping PrepareResources = { try await MeetingDiarizationModelStore.shared.prepare(dependencies: [.voiceMatching]) },
         encode: @escaping Encode = { try MeetingSpeakerVoiceEncoder.encode(samples: $0) }) {
        self.store = store; self.prepareResources = prepareResources; self.encode = encode
    }
    func metadata() throws -> MeetingOwnerVoiceProfileMetadata? { try self.store.load()?.metadata }
    func snapshot() throws -> MeetingOwnerVoiceProfileSnapshot? { try self.store.load() }
    func prepare(samples: [Float], sampleRate: Double = 16_000) async throws -> MeetingOwnerVoiceProfileDraft {
        guard !self.busy else { throw MeetingOwnerVoiceProfileError.busy }
        self.busy = true; defer { self.busy = false }
        let initialRevision = self.revision
        try Task.checkCancellation()
        guard sampleRate == 16_000, (96_000...320_000).contains(samples.count), samples.allSatisfy(\.isFinite) else {
            throw MeetingOwnerVoiceProfileError.invalidAudio
        }
        let epoch = MeetingAnalysisEpochID(trackID: UUID(), ordinal: 0)
        let excerpts = MeetingSpeakerVoiceSamples.collect(epoch: epoch, samples: samples,
            segments: [.init(slotIndex: 0, start: 0, end: Double(samples.count) / sampleRate)])
        guard excerpts.count == 1, excerpts[0].clips.allSatisfy({ clip in
            let mean = clip.reduce(Double.zero) { $0 + Double($1) } / Double(clip.count)
            let variance = clip.reduce(Double.zero) { $0 + pow(Double($1) - mean, 2) } / Double(clip.count)
            return variance >= 0.0042 * 0.0042 && clip.filter { abs($0) >= 0.99 }.count < clip.count / 20
        }) else { throw MeetingOwnerVoiceProfileError.insufficientSpeech }
        try await self.prepareResources()
        try Task.checkCancellation()
        let encode = self.encode
        let profiles = try await self.executor.runBlocking { try encode(excerpts) }
        try Task.checkCancellation()
        guard initialRevision == self.revision else { throw MeetingOwnerVoiceProfileError.staleDraft }
        guard profiles.count == 1 else { throw MeetingOwnerVoiceProfileError.insufficientSpeech }
        let snapshot = MeetingOwnerVoiceProfileSnapshot(metadata: .init(generation: UUID(), enrolledAt: Date()),
            encoderFingerprint: MeetingOwnerVoiceProfileStore.encoderFingerprint, embeddings: profiles[0].embeddings)
        guard MeetingOwnerVoiceProfileStore.isValid(snapshot) else { throw MeetingOwnerVoiceProfileError.inconsistentVoice }
        return MeetingOwnerVoiceProfileDraft(snapshot: snapshot, serviceRevision: initialRevision)
    }
    @discardableResult func save(_ draft: MeetingOwnerVoiceProfileDraft) throws -> MeetingOwnerVoiceProfileMetadata {
        guard draft.serviceRevision == self.revision else { throw MeetingOwnerVoiceProfileError.staleDraft }
        try Task.checkCancellation()
        try self.store.save(draft.snapshot)
        self.revision = UUID()
        return draft.snapshot.metadata
    }
    func delete() throws {
        try self.store.delete()
        self.revision = UUID()
    }
}

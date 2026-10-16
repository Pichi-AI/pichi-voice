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

/// Conservative verification against an explicitly enrolled reference. Existing attempt-local
/// clustering thresholds are reused unchanged; two voices proposing the owner stay unknown.
nonisolated enum MeetingOwnerVoiceVerifier {
    static func confirmedTokens(
        owner: MeetingOwnerVoiceProfileSnapshot?, profiles: [MeetingSpeakerVoiceProfile],
        identityLinks: [MeetingSpeakerIdentityLink] = []
    ) -> Set<MeetingBackendSpeakerToken> {
        guard let owner, MeetingOwnerVoiceProfileStore.isValid(owner) else { return [] }
        let canonicalByToken = Dictionary(identityLinks.map { ($0.token, $0.canonicalToken) }, uniquingKeysWith: { a, _ in a })
        let groups = Dictionary(grouping: profiles) { canonicalByToken[$0.token] ?? $0.token }
        var measures: [(MeetingBackendSpeakerToken, Float)] = []
        for (canonical, observations) in groups {
            var worst: Float = 0
            var valid = true
            for observation in observations {
                guard let consistency = MeetingSpeakerVoiceMatcher.distance(observation, observation),
                      consistency <= MeetingSpeakerVoiceMatcher.maximumDistance,
                      let distance = MeetingSpeakerVoiceMatcher.distance(
                        observation, MeetingSpeakerVoiceProfile(token: observation.token, embeddings: owner.embeddings)
                      ) else { valid = false; break }
                worst = max(worst, distance)
            }
            if valid { measures.append((canonical, worst)) }
        }
        measures.sort { $0.1 < $1.1 }
        guard let winner = measures.first, winner.1 <= MeetingSpeakerVoiceMatcher.maximumDistance,
              measures.count == 1 || measures[1].1 - winner.1 >= MeetingSpeakerVoiceMatcher.ambiguityMargin else { return [] }
        return Set(profiles.filter { (canonicalByToken[$0.token] ?? $0.token) == winner.0 }.map(\.token))
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

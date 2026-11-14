import Foundation

// Synthetic infrastructure only. Store, profile, defaults and disk implementations are real.
nonisolated final class DebugLogger: Sendable {
    static let shared = DebugLogger()
    static let diagnosticsEnabled = false
    func debug(_ message: String, source: String) {}
    func info(_ message: String, source: String) {}
    func warning(_ message: String, source: String) {}
    func error(_ message: String, source: String) {}
}

@MainActor final class SettingsStore {
    static let shared = SettingsStore()
    var dictionaryCorrectionArchiveEnabled = false
    var audioHistoryBudgetBytes: Int64 { 1_000_000 }
    var weekendsDontBreakStreak: Bool { false }
}

nonisolated struct ASRWordTiming: Sendable { let text: String; let start: Double; let end: Double }
nonisolated struct SpeakerTranscriptSegment: Codable, Equatable, Sendable { let text: String }
nonisolated struct SpeakerTranscriptGap: Codable, Equatable, Sendable { let text: String }
nonisolated struct TranscriptionResult: Sendable {
    let id: UUID
    let text: String
    let confidence: Float
    let duration: TimeInterval
    let processingTime: TimeInterval
    let fileName: String
    let timestamp: Date
    let speakerSegments: [SpeakerTranscriptSegment]
    let speakerLabelingNotice: String?
    let speakerLabelingGaps: [SpeakerTranscriptGap]
}

nonisolated enum ParakeetSpeechModelCatalog {
    // Synthetic family policy for store-lifetime probes; actual catalog policy has native coverage.
    static func sharesPronunciationFamily(_ source: String, with target: String) -> Bool {
        [source, target].allSatisfy { $0.hasPrefix("synthetic-family-") }
    }
    static func descriptor(forInstalledPronunciationModelKey key: String) -> Bool? { true }
    static func isOutdatedCompactPronunciationModelKey(_ key: String) -> Bool { false }
}

nonisolated enum DictionaryMatchPlaygroundError: Error { case unavailable(String) }

#if !DICTIONARY_CORRECTION_REAL_CANDIDATE
nonisolated struct AutomaticDictionaryCorrectionCandidate {
    let heardText: String
    let correctedText: String
}
#endif

// No inference, model preparation or audio capture occurs in this probe.
nonisolated struct MeetingAnalysisEpochID: Codable, Hashable, Sendable { let trackID: UUID; let ordinal: Int }
nonisolated struct MeetingBackendSpeakerToken: Codable, Hashable, Sendable {
    let analysisEpochID: MeetingAnalysisEpochID
    let label: String
}
nonisolated struct MeetingSpeakerIdentityLink: Sendable {
    let token: MeetingBackendSpeakerToken
    let canonicalToken: MeetingBackendSpeakerToken
}
nonisolated struct MeetingNemotronSpeakerSegment: Sendable { let slotIndex: Int; let start: Double; let end: Double }
nonisolated struct MeetingSpeakerVoiceProfile: Sendable {
    let token: MeetingBackendSpeakerToken
    let embeddings: [[Float]]
}
nonisolated struct MeetingSpeakerVoiceSamples: Sendable {
    let token: MeetingBackendSpeakerToken
    let clips: [[Float]]
    static let maximumProfiles = 128
    static func collect(epoch: MeetingAnalysisEpochID, samples: [Float], segments: [MeetingNemotronSpeakerSegment]) -> [Self] {
        [.init(token: .init(analysisEpochID: epoch, label: "synthetic"),
            clips: [Array(samples.prefix(samples.count / 2)), Array(samples.suffix(samples.count / 2))])]
    }
}
nonisolated enum MeetingSpeakerVoiceMatcher {
    static let maximumDistance: Float = 0.25
    static func distance(_ lhs: MeetingSpeakerVoiceProfile, _ rhs: MeetingSpeakerVoiceProfile) -> Float? { 0 }
    static func validLinks(_ links: [MeetingSpeakerIdentityLink], allowedTokens: Set<MeetingBackendSpeakerToken>) -> Bool { true }
}
nonisolated enum MeetingSpeakerVoiceModelArtifacts {
    static let revision = "synthetic"
    static let packageName = "synthetic"
    struct FileProof { let digest: String }
    static let files = [FileProof(digest: "synthetic")]
}
nonisolated enum MeetingSpeakerVoiceEncoder {
    static func encode(samples: [MeetingSpeakerVoiceSamples]) throws -> [MeetingSpeakerVoiceProfile] {
        fatalError("Model inference is outside this synthetic storage probe")
    }
}
actor MeetingDiarizationModelStore {
    static let shared = MeetingDiarizationModelStore()
    enum Dependency { case voiceMatching }
    func prepare(dependencies: [Dependency]) throws {
        fatalError("Model preparation is outside this synthetic storage probe")
    }
}

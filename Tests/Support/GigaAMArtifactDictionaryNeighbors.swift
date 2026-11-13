import Foundation
import PichiGigaAM

// Inert neighbors for compiling the complete production provider in the artifact
// ownership probe. No dictionary read, acoustic extraction or inference is part
// of this probe; accidental entry to those paths fails instead of faking success.
@MainActor final class SettingsStore {
    static let shared = SettingsStore()
    struct CustomDictionaryEntry: Sendable { let id: UUID; let replacement: String }
    let customDictionaryEntries: [CustomDictionaryEntry] = []
}
nonisolated enum DictionaryMatcherExperiment {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var enabled = false
        var generation = "artifact-ownership-inert-dictionary"
    }
    private static let state = State()
    static var sharedFeaturesEnabled: Bool {
        get { state.lock.withLock { state.enabled } }
        set { state.lock.withLock { state.enabled = newValue } }
    }
    static let compareNegatives = false
    static var generation: String {
        get { state.lock.withLock { state.generation } }
        set { state.lock.withLock { state.generation = newValue } }
    }
}
nonisolated struct DictionaryAcousticEvidence: Sendable {
    let id: UUID; let entryID: UUID; let label: String; let profileKey: String; let modelKey: String
    let sourceWordRange: Range<Int>; let frames: DictionaryMatchFrames
    var matchFrameRange: Range<Int>? = nil
}
nonisolated struct DictionaryMatchFrames: Sendable {
    let hiddenSize: Int; let values: [Float]
    var isValid: Bool { preconditionFailure("Artifact ownership tests must never validate matching features") }
}
nonisolated enum DictionaryNegativeEvidenceResolver {
    static func profileKey(_ profile: PronunciationDictionaryProfile) -> String {
        preconditionFailure("Artifact ownership tests must never hash pronunciation profiles")
    }
}
nonisolated struct PrivateProfileSnapshot: Sendable {}
nonisolated enum PrivateProfileStorage {
    static func isReadable(_ profile: PrivateProfileSnapshot) -> Bool {
        preconditionFailure("Artifact ownership tests must never check private profile access")
    }
}
nonisolated enum DictionaryMatchPlaygroundError: Error { case unavailable(String) }
nonisolated enum PronunciationDictionaryStoreError: Error { case inconsistentEnrollment }
nonisolated struct PronunciationDictionaryProfile: Sendable {
    let dictionaryEntryID: UUID = UUID()
    let modelKey = ""
    let hiddenSize = 0
    let enrollments: [PronunciationEnrollmentCapture]
    var matchingEnrollments: [PronunciationEnrollmentCapture] { Array(enrollments.prefix(3)) }
}

actor PronunciationDictionaryStore {
    static let shared = PronunciationDictionaryStore()
    nonisolated final class CaptureRead: @unchecked Sendable {
        var profile: PrivateProfileSnapshot {
            preconditionFailure("Artifact ownership tests must never read private profile metadata")
        }
        var profiles: [PronunciationDictionaryProfile] {
            preconditionFailure("Artifact ownership tests must never read private profile metadata")
        }
        var isOpen: Bool { preconditionFailure("This probe never admits dictionary evidence") }
        func close(leaseID: UUID) { preconditionFailure("This probe never admits dictionary evidence") }
        func matchingEnrollments(for profile: PronunciationDictionaryProfile) -> [PronunciationEnrollmentCapture] {
            preconditionFailure("Artifact ownership tests must never read pronunciation references")
        }
    }
    nonisolated func admitCaptureRead(leaseID: UUID, modelKey: String, entryIDs: Set<UUID>,
        includingSharedFamilies: Bool = false, maximumReferencesPerProfile: Int = 3,
        referenceSelection: @Sendable (PronunciationDictionaryProfile) -> [PronunciationEnrollmentCapture] = { $0.matchingEnrollments }) throws -> CaptureRead {
        preconditionFailure("Artifact ownership tests must never read private dictionaries")
    }
    func inspection(for id: UUID) async throws -> DictionaryAudioInspection {
        preconditionFailure("Artifact ownership tests must never read pronunciation audio")
    }
}
actor DictionaryNegativeExampleStore {
    static let shared = DictionaryNegativeExampleStore()
    nonisolated final class CaptureRead: @unchecked Sendable {
        var profile: PrivateProfileSnapshot { preconditionFailure("This probe never admits negative evidence") }
        var isOpen: Bool { preconditionFailure("This probe never admits negative evidence") }
        func close(leaseID: UUID) { preconditionFailure("This probe never admits negative evidence") }
    }
    nonisolated func admitCaptureRead(leaseID: UUID, modelKey: String, entryIDs: Set<UUID>) throws -> CaptureRead {
        preconditionFailure("Artifact ownership tests must never read negative audio")
    }
}

nonisolated enum GigaAMDictionaryAcoustics {
    struct Snapshot: Sendable {
        let modelKey: String
        let generation: String
        let enabled: Bool
        let entries: [SettingsStore.CustomDictionaryEntry]
        let pronunciation: PronunciationDictionaryStore.CaptureRead?
        let negatives: DictionaryNegativeExampleStore.CaptureRead?
    }
    struct Word: Sendable {}
    struct Output: Sendable { let text: String; let evidence: [DictionaryAcousticEvidence] }
    static func activeCaptures(_ captures: [PronunciationEnrollmentCapture]) -> [PronunciationEnrollmentCapture] {
        preconditionFailure("Artifact ownership tests must never select pronunciation references")
    }
    // ACTUAL_LEGACY_MODEL_KEY
    static func referenceCacheKey(_ snapshot: Snapshot, stableNegativeEvidence: Bool = false) -> String {
        preconditionFailure("Artifact ownership tests must never prepare dictionary references")
    }
    static func preparedWords(_ snapshot: Snapshot) async throws -> [Word] {
        preconditionFailure("Artifact ownership tests must never prepare dictionary references")
    }
    static func correct(transcript: GigaAMTranscript, samples: [Float], snapshot: Snapshot, words: [Word]) async throws -> Output {
        preconditionFailure("Artifact ownership tests must never perform acoustic matching")
    }
    static func enrollment(samples: [Float], modelKey: String, words: [ASRWordTiming], focalRange: Range<Int>? = nil) async throws -> PronunciationEnrollmentCapture? {
        preconditionFailure("Artifact ownership tests must never create pronunciation recordings")
    }
}

nonisolated enum GigaAMEncoderDictionaryStorage {
    // ACTUAL_ENCODER_MODEL_KEY
    static func retainedCaptures(_ captures: [PronunciationEnrollmentCapture]) -> [PronunciationEnrollmentCapture] {
        preconditionFailure("Artifact ownership tests must never select learned encoder references")
    }
    static func admittedReferenceKey(_ read: PronunciationDictionaryStore.CaptureRead?) -> String {
        preconditionFailure("Artifact ownership tests must never key learned encoder references")
    }
    static func canCache(_ preparation: GigaAMEncoderDictionary.Preparation) -> Bool {
        preconditionFailure("Artifact ownership tests must never cache learned encoder references")
    }
    static func preparedWords(_ snapshot: GigaAMDictionaryAcoustics.Snapshot) async throws -> GigaAMEncoderDictionary.Preparation {
        preconditionFailure("Artifact ownership tests must never prepare learned encoder references")
    }
    static func enrollment(samples: [Float], modelKey: String, featureFrames: [DictionaryLearningFeatureFrames],
                           words: [ASRWordTiming], focalRange: Range<Int>? = nil) async throws -> PronunciationEnrollmentCapture? {
        preconditionFailure("Artifact ownership tests must never create learned encoder evidence")
    }
    static func validate(captures: [PronunciationEnrollmentCapture], modelKey: String, store: PronunciationDictionaryStore) async throws -> Bool {
        preconditionFailure("Artifact ownership tests must never validate pronunciation samples")
    }
}
nonisolated enum GigaAMEncoderDictionary {
    struct PreparedTerm: Sendable {}
    // ACTUAL_ENCODER_PREPARATION
    struct AcceptedSpan: Sendable {
        let entryID: UUID; let label: String; let wordRange: ClosedRange<Int>; let frameRange: Range<Int>; let frameOffset: Int
        var absoluteFrameRange: Range<Int> { (frameOffset + frameRange.lowerBound)..<(frameOffset + frameRange.upperBound) }
    }
    struct Output: Sendable { let text: String; let accepted: [AcceptedSpan] }
    static func correct(transcript: GigaAMTranscript, windows: [GigaAMEncoderWindow], modelKey: String,
                        words: [PreparedTerm], entries: [SettingsStore.CustomDictionaryEntry]) async throws -> Output {
        preconditionFailure("Artifact ownership tests must never match learned encoder templates")
    }
}

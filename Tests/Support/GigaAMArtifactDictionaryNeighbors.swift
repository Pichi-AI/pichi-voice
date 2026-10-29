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
    static let sharedFeaturesEnabled = false
    static let compareNegatives = false
    static let generation = "artifact-ownership-inert-dictionary"
}
nonisolated struct DictionaryAcousticEvidence: Sendable {}
nonisolated enum DictionaryMatchPlaygroundError: Error { case unavailable(String) }
nonisolated struct PronunciationDictionaryProfile: Sendable {
    let enrollments: [PronunciationEnrollmentCapture]
    var matchingEnrollments: [PronunciationEnrollmentCapture] { Array(enrollments.prefix(3)) }
}

actor PronunciationDictionaryStore {
    static let shared = PronunciationDictionaryStore()
    nonisolated final class CaptureRead: @unchecked Sendable {
        func close(leaseID: UUID) { preconditionFailure("This probe never admits dictionary evidence") }
        func matchingEnrollments(for profile: PronunciationDictionaryProfile) -> [PronunciationEnrollmentCapture] {
            preconditionFailure("Artifact ownership tests must never read pronunciation references")
        }
    }
    nonisolated func admitCaptureRead(leaseID: UUID, modelKey: String, entryIDs: Set<UUID>,
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
    static func modelKey(fingerprint: String) -> String { "inert-dictionary/" + fingerprint }
    static func referenceCacheKey(_ snapshot: Snapshot) -> String {
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

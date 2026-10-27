import CryptoKit
import Foundation

/// Stable presentation/storage codes. Interface copy belongs to the shared String Catalog.
nonisolated enum PichiPublicationWithholdingReason: String, Codable, CaseIterable, Error, Sendable {
    case notCompleted
    case redactionNotEnabled
    case originalTextRetained
    case completenessUnknown
    case incompleteTranscript
    case emptyTranscript
    case excludedIntervals
    case invalidTranscript
    case exportLimitExceeded
}

/// The text-only portion of a publication admission. Account ownership, recording-time
/// consent and destination must be checked by the shared publication operation before this
/// value can enter its durable outbox. This type neither discovers nor loads any profile.
nonisolated struct PichiProtectedPublicationSource: Equatable, Sendable {
    let sessionID: MeetingSessionID
    let transcriptBytes: Data
    let sourceSHA256: String
    let localSourceSHA256: String

    private init(session: MeetingSession, transcriptBytes: Data) throws {
        self.sessionID = session.id
        self.localSourceSHA256 = try Self.localFingerprint(for: session)
        self.transcriptBytes = transcriptBytes
        self.sourceSHA256 = SHA256.hash(data: transcriptBytes)
            .map { String(format: "%02x", $0) }.joined()
    }

    /// A local revision fingerprint uses stored domain values, not localized display
    /// titles. Changing interface language or time zone cannot strand accepted cleanup.
    static func localFingerprint(for session: MeetingSession) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(LocalRevision(session: session))
        guard bytes.count <= 64 * 1_024 * 1_024 else { throw PichiPublicationWithholdingReason.exportLimitExceeded }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// The caller supplies the snapshot reloaded after terminal persistence through N2's
    /// immutable owner boundary. No current settings or mutable selection are consulted.
    /// Protected manual export remains less restrictive: cloud analysis cannot silently
    /// accept a source whose recognition coverage is incomplete or unknown.
    static func prepare(for session: MeetingSession) throws -> Self {
        try Task.checkCancellation()
        guard session.state == .completed, session.endedAt != nil else {
            throw PichiPublicationWithholdingReason.notCompleted
        }
        guard session.piiRedactionEnabled == true else {
            throw PichiPublicationWithholdingReason.redactionNotEnabled
        }
        guard session.transcriptSegments.allSatisfy({ $0.originalText == nil }) else {
            throw PichiPublicationWithholdingReason.originalTextRetained
        }
        guard let isComplete = session.transcriptIsComplete else {
            throw PichiPublicationWithholdingReason.completenessUnknown
        }
        guard isComplete else {
            throw PichiPublicationWithholdingReason.incompleteTranscript
        }
        // The coordinator persists nil for a known-complete result without gaps. It is
        // the explicit completeness flag above, not absence of gaps, that proves coverage.
        guard session.transcriptCoverageGaps?.isEmpty != false else {
            throw PichiPublicationWithholdingReason.excludedIntervals
        }
        guard session.transcriptSegments.allSatisfy({
            $0.isEcho || $0.completeness == .complete || $0.completeness == .noSpeech
        }) else {
            throw PichiPublicationWithholdingReason.incompleteTranscript
        }

        let bytes: Data
        do {
            bytes = try MeetingTranscriptExporter.protectedTranscriptJSON(for: session)
        } catch MeetingTranscriptExporter.PortableExportError.limitExceeded {
            throw PichiPublicationWithholdingReason.exportLimitExceeded
        } catch MeetingTranscriptExporter.PortableExportError.invalidTranscript {
            throw PichiPublicationWithholdingReason.invalidTranscript
        } catch MeetingTranscriptExporter.PortableExportError.protectedTranscriptRequired {
            // Defensive mapping if the exporter's existing privacy gate becomes stricter.
            throw PichiPublicationWithholdingReason.invalidTranscript
        }
        try Task.checkCancellation()
        do { _ = try PichiProtectedPublicationPayload.validate(bytes) }
        catch PichiProtectedPublicationPayload.Failure.emptyTranscript { throw PichiPublicationWithholdingReason.emptyTranscript }
        catch PichiProtectedPublicationPayload.Failure.limitExceeded { throw PichiPublicationWithholdingReason.exportLimitExceeded }
        catch PichiProtectedPublicationPayload.Failure.invalidTranscript { throw PichiPublicationWithholdingReason.invalidTranscript }
        let source = try Self(session: session, transcriptBytes: bytes)
        try Task.checkCancellation()
        return source
    }
    /// Only user content and canonical source bindings govern deletion. Retention,
    /// update clocks, health and diagnostic events are automatic maintenance.
    private nonisolated struct LocalRevision: Encodable {
        let id: MeetingSessionID
        let owner: MeetingProfileOwnership?
        let title: String
        let defaultTitleBase: String?
        let location: MeetingLocation?
        let languageCode: String
        let mode: MeetingCaptureMode
        let startedAt: Date
        let endedAt: Date?
        let state: MeetingSessionState
        let speakers: [MeetingSessionSpeaker]
        let segments: [MeetingTranscriptSegment]
        let coverage: [MeetingTranscriptCoverageGap]?
        let sidecar: MeetingResultSidecarReference?
        let complete: Bool?
        let postProcessing: MeetingPostProcessingArtifact?
        let backendID: String?
        let artifactFingerprint: String?
        let audioStorageMode: MeetingAudioStorageMode?
        let speakerLabelsEnabled: Bool?
        let speakerProcessingMode: MeetingSpeakerProcessingMode?
        let piiRedactionEnabled: Bool?
        let encryptedPersistence: Bool?
        let timeDomain: MeetingTranscriptTimeDomain?
        init(session: MeetingSession) {
            id = session.id; owner = session.profileOwnership
            title = session.title; defaultTitleBase = session.defaultTitleBase; location = session.location
            languageCode = session.languageCode; mode = session.mode
            startedAt = session.startedAt; endedAt = session.endedAt; state = session.state
            speakers = session.speakers; segments = session.transcriptSegments
            coverage = session.transcriptCoverageGaps; sidecar = session.resultSidecarReference
            complete = session.transcriptIsComplete; postProcessing = session.postProcessing
            backendID = session.recordingBackendID; artifactFingerprint = session.recordingASRArtifactFingerprint
            audioStorageMode = session.audioStorageMode; speakerLabelsEnabled = session.speakerLabelsEnabled
            speakerProcessingMode = session.speakerProcessingMode; piiRedactionEnabled = session.piiRedactionEnabled
            encryptedPersistence = session.requiresEncryptedPersistence; timeDomain = session.transcriptTimeDomain
        }
    }

}

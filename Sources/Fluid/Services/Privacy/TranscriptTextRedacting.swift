import Foundation

/// Privacy transformation at the transcript publication boundary. The caller
/// freezes one implementation per meeting attempt and applies it before live
/// display, checkpoints, canonical persistence, search or export. An error must
/// never cause fallback publication of the original text.
nonisolated protocol TranscriptTextRedacting: Sendable {
    /// Stable model/rules identity for retained working-state restoration. An adapter without
    /// this identity remains usable, but cannot advertise resumable sensitive-text processing.
    nonisolated var checkpointIdentity: String? { get }
    /// Idempotent readiness for this exact attempt capability. Pipeline entry points call it
    /// before publication, including a retained-audio retry after a fresh application launch.
    func prepareForMeeting() async throws
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction
}

struct TranscriptRedactedSpan: Sendable, Equatable {
    /// UTF-16 offsets in the original input, not the shortened redacted result.
    let range: NSRange
    let replacement: String
}

struct TranscriptTextRedaction: Sendable, Equatable {
    let text: String
    let spans: [TranscriptRedactedSpan]
    /// Optional adapter-approved prefix in the original UTF-16 input. This is
    /// display-only eligibility from the same evaluation, never a durable flush.
    /// Unsupported redactors leave it nil; empty spans do not authorize preview.
    let provisionalSafeUTF16: Int?
    init(text: String, spans: [TranscriptRedactedSpan], provisionalSafeUTF16: Int? = nil) {
        self.text = text; self.spans = spans; self.provisionalSafeUTF16 = provisionalSafeUTF16
    }
}

extension TranscriptTextRedacting {
    nonisolated var checkpointIdentity: String? { nil }
    /// Already-ready transformers and simple rule-only adapters have no resource lifecycle.
    func prepareForMeeting() async throws {}
    func redact(_ text: String) async throws -> String {
        try await redactWithSpans(text).text
    }
}

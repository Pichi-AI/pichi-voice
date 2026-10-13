import Foundation

/// Privacy transformation at the transcript publication boundary. The caller
/// freezes one implementation per meeting attempt and applies it before live
/// display, checkpoints, canonical persistence, search or export. An error must
/// never cause fallback publication of the original text.
protocol TranscriptTextRedacting: Sendable {
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
}

extension TranscriptTextRedacting {
    func redact(_ text: String) async throws -> String {
        try await redactWithSpans(text).text
    }
}

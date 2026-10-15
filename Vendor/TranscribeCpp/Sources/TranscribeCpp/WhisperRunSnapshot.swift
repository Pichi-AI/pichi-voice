import CTranscribe

/// Scalar decoding diagnostics copied from one Whisper encoder window.
/// These times describe encoder slices, not word or segment boundaries.
/// No native pointers, audio buffers or text are retained by this value.
public struct WhisperChunkTrace: Sendable, Equatable {
    public let t0Ms: Int64
    public let t1Ms: Int64
    public let temperature: Float
    public let avgLogprob: Float
    public let compressionRatio: Float
    public let noSpeechProbability: Float
    public let fallbacks: Int32
    public let noSpeechTriggered: Bool

    init(_ c: transcribe_whisper_chunk_trace) {
        t0Ms = c.t0_ms
        t1Ms = c.t1_ms
        temperature = c.temperature_used
        avgLogprob = c.avg_logprob
        compressionRatio = c.compression_ratio
        noSpeechProbability = c.no_speech_prob
        fallbacks = c.n_fallbacks
        noSpeechTriggered = c.no_speech_triggered
    }
}

/// Owned transcript and quality trace from the same successful native run.
public struct WhisperRunSnapshot: Sendable, Equatable {
    public let transcript: Transcript
    public let chunks: [WhisperChunkTrace]
}

/// Bound allocation even if a runtime reports a malformed trace count.
/// 4096 thirty-second windows cover over 34 hours of one offline run.
func validatedWhisperChunkCount(_ count: Int32) throws -> Int {
    guard (0...4096).contains(count) else {
        throw TranscribeError.other(status: 0, message: "invalid Whisper chunk trace count")
    }
    return Int(count)
}

import Foundation

/// Model-owned contracts for additional GGUF families handled by the existing native adapter.
/// File sizes describe storage only. Device/runtime acceptance is measured separately.
nonisolated enum TranscribeSpeechModelCatalog {
    struct Descriptor: Sendable {
        let fileName: String
        let repository: String
        let revision: String
        let expectedBytes: Int64
        let sha256: String
        let maximumChunkSamples: Int
        let contextTokens: Int32

        var downloadURL: URL? {
            URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(fileName)")
        }

        func validateArtifact(at url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.int64Value == self.expectedBytes,
                  try ParakeetArchiveInstaller.sha256(of: url) == self.sha256 else {
                throw ArtifactError.integrityMismatch
            }
        }
    }

    enum ArtifactError: Error { case integrityMismatch }

    static let qwenLanguageCodes: Set<String> = [
        "zh", "en", "yue", "ar", "de", "fr", "es", "pt", "id", "it", "ko", "ru", "th", "vi", "ja",
        "tr", "hi", "ms", "nl", "sv", "da", "fi", "pl", "cs", "fil", "fa", "el", "hu", "mk", "ro",
    ]

    static let qwen06Q4 = Descriptor(
        fileName: "Qwen3-ASR-0.6B-Q4_K_M.gguf",
        repository: "handy-computer/Qwen3-ASR-0.6B-gguf",
        revision: "7e7c69a577fa2725dfedbe34b5e999336e30a19b",
        expectedBytes: 589_560_480,
        sha256: "5b58f32a58ffa2c8783e0b0963485623e286e6272d953dfc9e28bc3447dee0c0",
        maximumChunkSamples: 30 * 16_000,
        contextTokens: 2_048
    )

    static func descriptor(for model: SettingsStore.SpeechModel) -> Descriptor? {
        model == .qwen3Asr06BQ4 ? self.qwen06Q4 : nil
    }

    static func requiresAutomaticLanguage(_ model: SettingsStore.SpeechModel) -> Bool {
        self.descriptor(for: model) != nil || model == .qwen3Asr17B
    }
}

/// Bounds the native prompt/cache independently of a caller's file or capture buffer.
/// Each completed chunk is final text only. No word/segment timestamps are inferred.
nonisolated struct TranscribeAudioChunkPolicy: Sendable {
    let maximumSamples: Int

    func transcribe(_ samples: [Float], validate: () throws -> Void = {}, operation: ([Float]) async throws -> ASRTranscriptionResult) async throws -> ASRTranscriptionResult {
        precondition(self.maximumSamples > 0)
        var parts: [String] = []
        var confidence: Float = 1
        var offset = 0
        repeat {
            try Task.checkCancellation()
            try validate()
            let end = min(samples.count, offset + self.maximumSamples)
            let result = try await operation(Array(samples[offset..<end]))
            try Task.checkCancellation()
            try validate()
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { parts.append(text) }
            confidence = min(confidence, result.confidence)
            offset = end
        } while offset < samples.count
        return ASRTranscriptionResult(text: parts.joined(separator: " "), confidence: parts.isEmpty ? 0 : confidence)
    }
}

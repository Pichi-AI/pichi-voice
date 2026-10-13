import Foundation

/// Public, on-device cleanup model registered at the existing private-AI boundary.
nonisolated struct S1MiniProviderFeature: PrivateAIProviderFeatureProviding {
    static let shared = Self()
    static let revision = "34add00a48a2e5d24e5a4ee5405a99620a3a240c"
    static let modelDescriptor = PrivateAIRegisteredModel(
        displayName: "S1-mini by Superwhisper",
        detail: "Clean up dictation locally on your Mac.",
        isEnabled: true,
        parameterCount: "0.6B",
        recommendedMemoryGB: 4,
        artifact: PrivateAIModelArtifact(
            identifier: "s1-mini-q4-k-m",
            filename: "s1-mini-q4_k_m.gguf",
            downloadURL: URL(string: "https://huggingface.co/superwhisper/s1-mini-GGUF/resolve/\(Self.revision)/s1-mini-q4_k_m.gguf"),
            sha256: "3b41ebe2502cbd03e811d5d16b022f5ab551eda58d62597d152f89535003c634",
            byteCount: 484_219_808,
            version: Self.revision
        ),
        presentation: PrivateAIModelPresentation(
            summary: "Compact on-device cleanup",
            useCase: "Clean up dictation locally on your Mac.",
            language: nil
        )
    )

    let isAvailable = true
    let providerID = "s1-mini"
    let providerName = "S1-mini by Superwhisper"
    let promptSelectionID = "__S1_MINI__"
    let defaultModelID = Self.modelDescriptor.id
    let selectedModelDefaultsKey = "S1MiniSelectedModelID"
    let localModelPathDefaultsKey = "S1MiniLocalModelPath"
    let prefixCacheDefaultsKey = "S1MiniPrefixKVCacheEnabled"
    let boostDefaultsKey = "S1MiniBoostEnabled"
    let modelDirectoryName = "S1Mini"
    var supportedBackends: [SettingsStore.PrivateAIBackendPreference] { [.llama] }
    var defaultBackend: SettingsStore.PrivateAIBackendPreference { .llama }
    let supportsBoost = false
    let supportsPrefixCache = false
    let includesUpcomingModels = false

    func recommendedModelID() async -> String { self.defaultModelID }
    func modelIDs() -> [String] { [self.defaultModelID] }
    func modelIDs(for task: PrivateAIModelTask) -> [String] { task == .dictation ? self.modelIDs() : [] }
    func model(id: String) -> PrivateAIRegisteredModel? {
        self.canonicalModelID(for: id) == nil ? nil : Self.modelDescriptor
    }
    func canonicalModelID(for value: String) -> String? {
        let id = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return id == self.defaultModelID ? self.defaultModelID : nil
    }
    func isKnownModelID(_ value: String) -> Bool { self.canonicalModelID(for: value) != nil }
    func localModelURL(for model: PrivateAIRegisteredModel, directoryURL: URL) -> URL {
        directoryURL
            .appendingPathComponent(model.id, isDirectory: true)
            .appendingPathComponent(Self.revision, isDirectory: true)
            .appendingPathComponent(model.artifact.filename)
    }
}

/// This prompt is an inference contract, not configurable interface copy.
nonisolated enum S1MiniPrompt {
    static let system = "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text."
    static let controls = "[Styling: semi-formal] [Structure: prose] [Context: general]\n"
    static let assistantPrefix = "<|im_start|>assistant\n<think>\n\n</think>\n\n"

    static func make(transcript: String) -> String {
        "<|im_start|>system\n" + self.system + "<|im_end|>\n" +
            "<|im_start|>user\n" + self.controls + self.escapeTranscript(transcript) + "<|im_end|>\n" +
            self.assistantPrefix
    }

    private static func escapeTranscript(_ transcript: String) -> String {
        // A literal token spelling in dictated text must not create a new ChatML role.
        transcript.replacingOccurrences(of: "<|", with: "<\u{200B}|")
            .replacingOccurrences(of: "<think>", with: "<\u{200B}think>")
            .replacingOccurrences(of: "</think>", with: "<\u{200B}/think>")
    }
}

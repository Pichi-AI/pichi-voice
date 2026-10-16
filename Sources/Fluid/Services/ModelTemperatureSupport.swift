import Foundation

/// Remembers, per provider endpoint and model ID, whether a model accepts the `temperature` parameter.
///
/// Filled from provider `/models` listings (see `ModelRepository.fetchModels`) and from
/// HTTP 400 rejections at request time (see `LLMClient.call`), so new models work without
/// editing the name list in `SettingsStore.isTemperatureUnsupported`. Keyed by endpoint too:
/// two providers can serve the same model ID (e.g. "llama3") with different parameter support.
final nonisolated class ModelTemperatureSupport: @unchecked Sendable {
    static let shared = ModelTemperatureSupport(defaults: .standard)

    // Older case-folded keys could alias distinct paths/models and are not safe
    // to migrate into this exact capability namespace.
    private static let defaultsKey = "ModelTemperatureSupportByEndpointV2"

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// `true` = accepts `temperature`, `false` = rejects it, `nil` = unknown.
    func isSupported(_ model: String, baseURL: String) -> Bool? {
        self.lock.withLock { self.stored()[Self.key(model, baseURL: baseURL)] }
    }

    func record(_ entries: [String: Bool], baseURL: String) {
        guard !entries.isEmpty else { return }
        self.lock.withLock {
            var stored = self.stored()
            for (model, supported) in entries {
                stored[Self.key(model, baseURL: baseURL)] = supported
            }
            self.defaults.set(stored, forKey: Self.defaultsKey)
        }
    }

    /// Reads temperature support from a `/models` response. Models without usable metadata are omitted.
    /// - OpenRouter lists accepted request parameters in `supported_parameters`.
    /// - Anthropic has no sampling capability, but every model that dropped `budget_tokens`
    ///   thinking (`capabilities.thinking.types.enabled`) also dropped `temperature`.
    static func entries(fromModelsResponse json: [String: Any]) -> [String: Bool] {
        guard let models = json["data"] as? [[String: Any]] else { return [:] }
        var entries: [String: Bool] = [:]
        for model in models {
            guard let id = model["id"] as? String else { continue }
            if let parameters = model["supported_parameters"] as? [String] {
                entries[id] = parameters.contains("temperature")
            } else if let capabilities = model["capabilities"] as? [String: Any],
                      let thinking = capabilities["thinking"] as? [String: Any],
                      let types = thinking["types"] as? [String: Any],
                      let budgetThinking = types["enabled"] as? [String: Any],
                      let supported = budgetThinking["supported"] as? Bool
            {
                entries[id] = supported
            }
        }
        return entries
    }

    private func stored() -> [String: Bool] {
        self.defaults.dictionary(forKey: Self.defaultsKey) as? [String: Bool] ?? [:]
    }

    private static func key(_ model: String, baseURL: String) -> String {
        var endpoint = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if var components = URLComponents(string: endpoint) {
            components.scheme = components.scheme?.lowercased()
            components.host = components.host?.lowercased()
            while components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath.removeLast() }
            endpoint = components.string ?? endpoint
        }
        return String(decoding: try! JSONEncoder().encode([endpoint, model.trimmingCharacters(in: .whitespacesAndNewlines)]), as: UTF8.self)
    }
}

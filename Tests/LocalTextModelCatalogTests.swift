import Foundation

// This harness uses production catalog parsing and selection policy without a
// running model server, model weights, personal settings or credentials.
enum PrivateFeatures { static let privateAIProvider = false }
enum PrivateAIModelTask { case dictation }
struct PrivateAIProviderFeature {
    static let shared = PrivateAIProviderFeature()
    let providerID = "private-test"
    let providerName = "Private test"
    func modelIDs() -> [String] { [] }
    func modelIDs(for _: PrivateAIModelTask) -> [String] { [] }
}

@main enum LocalTextModelCatalogTests {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        self.checks += 1
    }

    static func main() throws {
        let url = URL(fileURLWithPath: "Sources/Fluid/Models/local-text-models.json")
        let catalog = LocalTextModelCatalog.load(from: url)
        self.check(catalog.models.count == 10, "Expected the reviewed candidate catalog")
        self.check(catalog.models(for: "unrelated-server").isEmpty, "Tags cannot be applied to a different provider")
        self.check(LocalTextModelCatalog.load(from: nil).models.isEmpty, "A missing resource must not invent defaults")
        let compact = catalog.models.first { $0.id == "qwen3.5-2b" }!
        self.check(compact.installedID(in: ["qwen3.5:9b"]) == nil, "A similar tag does not prove installation")
        self.check(compact.installedID(in: ["qwen3.5:2b-q4_K_M"]) == "qwen3.5:2b-q4_K_M", "Preserve the exact discovered quantization ID")
        self.check(catalog.displayName(for: "my-local-model:latest", providerID: "ollama") == "my-local-model:latest", "Unknown discovered models remain data")
        self.check(catalog.displayName(for: "qwen3.5:4b", providerID: "unrelated-server") == "qwen3.5:4b", "Friendly names must respect the provider")
        let russianProfiles = ["gigachat3.1-lightning", "yandexgpt5-lite", "t-lite-it-2.1"]
        for id in russianProfiles {
            let model = catalog.models.first { $0.id == id }!
            self.check(model.installedID(in: Array(model.aliases.reversed())) == model.aliases.first,
                       "Prefer the stable bounded serving profile when both aliases are discovered")
            self.check(model.installedID(in: [model.aliases.last!]) == model.aliases.last,
                       "Keep an existing compatible dated installation available")
        }
        let yandex = catalog.models.first { $0.id == "yandexgpt5-lite" }!
        self.check(yandex.installedID(in: ["pichi-rf/yandexgpt5-lite-instruct-q4km:20261010"]) == nil,
                   "A raw template that drops system instructions is not a compatible catalog profile")

        let models = ["huge-model:latest", "small-model:latest"]
        self.check(ModelRepository.selectionAfterRefresh(preferred: "", models: models, isLocal: true).isEmpty, "Discovery must not select the first large local model")
        self.check(ModelRepository.selectionAfterRefresh(preferred: "missing-model", models: models, isLocal: true) == "missing-model", "A temporarily missing local model must not replace explicit intent")
        self.check(ModelRepository.selectionAfterRefresh(preferred: "small-model:latest", models: models, isLocal: true) == "small-model:latest", "Keep an explicit local choice")
        self.check(ModelRepository.selectionAfterRefresh(preferred: "small-model:latest", models: models, isLocal: false) == "small-model:latest", "Retain upstream remote selection")
        self.check(ModelRepository.selectionAfterRefresh(preferred: "missing", models: models, isLocal: false) == "huge-model:latest", "Retain upstream remote fallback")

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        var data = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        data["version"] = 2
        try JSONSerialization.data(withJSONObject: data).write(to: temporary)
        self.check(LocalTextModelCatalog.load(from: temporary).models.isEmpty, "Unknown schema versions must not silently load")
        data["version"] = 1
        var descriptors = data["models"] as! [[String: Any]]
        descriptors.append(descriptors[0])
        data["models"] = descriptors
        try JSONSerialization.data(withJSONObject: data).write(to: temporary)
        self.check(LocalTextModelCatalog.load(from: temporary).models.isEmpty, "Duplicate IDs must not make ambiguous SwiftUI rows")
        descriptors.removeLast()
        descriptors[1]["aliases"] = descriptors[0]["aliases"]
        data["models"] = descriptors
        try JSONSerialization.data(withJSONObject: data).write(to: temporary)
        self.check(LocalTextModelCatalog.load(from: temporary).models.isEmpty, "Duplicate provider aliases must not label the wrong model")
        print("Local text model catalog: \(self.checks) checks passed")
    }
}

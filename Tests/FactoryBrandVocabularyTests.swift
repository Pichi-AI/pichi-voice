import Foundation

/// Logger stub only: the actual vocabulary implementation is compiled for these pure-data checks.
final class DebugLogger {
    static let shared = DebugLogger()
    func debug(_ message: String, source: String) {}
}

@main
struct FactoryBrandVocabularyTests {
    static func main() throws {
        let bundled = try String(contentsOfFile: "Sources/Fluid/Resources/parakeet_custom_vocabulary.default.json", encoding: .utf8)
        for name in ["Pichi Voice", "Сбер Голос", "Альфа-Банк Голос", "100%@ Voice", "Voice \"quoted\""] {
            let factory = try ParakeetVocabularyStore.brandedFactoryDefaultJSON(bundled, appName: name)
            let config = try ParakeetVocabularyStore.shared.validateJSON(factory)
            precondition(config.terms.count == 1 && config.terms[0].text == name)
            precondition(config.terms[0].aliases.isEmpty)
            precondition(!factory.contains("FluidVoice") && !factory.contains("fluid boys"))
        }
        let userJSON = """
        {"terms":[{"text":"FluidVoice","weight":10,"aliases":["fluid voice"]},{"text":"FluidAudio","weight":2}]}
        """
        let user = try ParakeetVocabularyStore.shared.validateJSON(userJSON)
        precondition(user.terms[0].text == "FluidVoice" && user.terms[0].aliases == ["fluid voice"], "Stored user data must not receive brand substitution")
        let originalFactory = try ParakeetVocabularyStore.brandedFactoryDefaultJSON(userJSON, appName: "Partner Voice")
        let migratedFactory = try ParakeetVocabularyStore.shared.validateJSON(originalFactory)
        precondition(migratedFactory.terms[0].text == "Partner Voice" && migratedFactory.terms[1].text == "FluidAudio", "Only the factory product word may change; model/vendor names stay data")
        let fallback = try ParakeetVocabularyStore.shared.validateJSON(ParakeetVocabularyStore.defaultTemplateJSON())
        precondition(fallback.terms[0].text == AppBrand.appName)
        print("Factory vocabulary brand placeholders and unchanged user words passed")
    }
}

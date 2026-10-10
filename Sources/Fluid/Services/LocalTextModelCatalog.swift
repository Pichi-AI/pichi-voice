import Foundation

/// Publisher metadata only. Availability comes from the selected server and
/// evaluation results do not follow a mutable model tag automatically.
nonisolated struct LocalTextModelCatalog: Decodable, Sendable {
    nonisolated struct Model: Decodable, Identifiable, Sendable {
        let id: String
        let title: String
        let providerID: String
        let aliases: [String]
        let sourceURL: URL

        func installedID(in models: [String]) -> String? {
            self.aliases.first { models.contains($0) }
        }
    }

    let version: Int
    let models: [Model]

    static func load(from url: URL?) -> Self {
        guard let url, let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(Self.self, from: data), catalog.version == 1,
              Set(catalog.models.map(\.id)).count == catalog.models.count,
              catalog.models.allSatisfy({ !$0.id.isEmpty && !$0.title.isEmpty && !$0.providerID.isEmpty
                  && !$0.aliases.isEmpty && $0.aliases.allSatisfy({ !$0.isEmpty })
                  && $0.sourceURL.scheme == "https" && $0.sourceURL.host != nil
                  && $0.sourceURL.user == nil && $0.sourceURL.password == nil }),
              Set(catalog.models.flatMap { model in model.aliases.map { model.providerID + "|" + $0 } }).count
                  == catalog.models.reduce(0, { $0 + $1.aliases.count })
        else { return .init(version: 1, models: []) }
        return catalog
    }

    func models(for providerID: String) -> [Model] {
        self.models.filter { $0.providerID == providerID }
    }

    func displayName(for modelID: String, providerID: String) -> String {
        guard let model = self.models(for: providerID).first(where: { $0.aliases.contains(modelID) }) else { return modelID }
        return "\(model.title) (\(modelID))"
    }
}

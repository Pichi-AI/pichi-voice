import Foundation

/// The signed bundle supplies component names and documents; the viewer has no model-specific routes.
nonisolated struct MobileLicensesCatalog: Decodable {
    struct Group: Decodable, Identifiable {
        let id: String
        let titleKey: String
        let footerKey: String?
        let components: [Component]
    }

    struct Component: Decodable, Identifiable {
        let id: String
        let name: String
        let license: String
        let documents: [Document]
    }

    struct Document: Decodable, Identifiable {
        let titleKey: String
        let file: String
        var id: String { file }
    }

    let formatVersion: Int
    let groups: [Group]

    enum ReadError: Error { case invalidCatalog, missingDocument, invalidText }

    static func load(bundle: Bundle = .main) throws -> Self {
        let data = try resource("MobileLicenses.json", bundle: bundle, maximumBytes: 65_536)
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        guard catalog.formatVersion == 1, !catalog.groups.isEmpty, catalog.groups.count <= 16 else {
            throw ReadError.invalidCatalog
        }
        var groupIDs = Set<String>()
        var componentIDs = Set<String>()
        for group in catalog.groups {
            guard !group.id.isEmpty, groupIDs.insert(group.id).inserted, !group.titleKey.isEmpty,
                  !group.components.isEmpty, group.components.count <= 128 else { throw ReadError.invalidCatalog }
            for component in group.components {
                guard componentIDs.insert(component.id).inserted, !component.id.isEmpty,
                      !component.name.isEmpty, !component.license.isEmpty,
                      !component.documents.isEmpty, component.documents.count <= 16 else { throw ReadError.invalidCatalog }
                var documentIDs = Set<String>()
                for document in component.documents {
                    guard documentIDs.insert(document.id).inserted, !document.titleKey.isEmpty,
                          validFilename(document.file) else { throw ReadError.invalidCatalog }
                }
            }
        }
        return catalog
    }

    static func text(for document: Document, bundle: Bundle = .main) throws -> String {
        let data = try resource(document.file, bundle: bundle, maximumBytes: 262_144)
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { throw ReadError.invalidText }
        return text
    }

    private static func validFilename(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 160 && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\\")
            && name.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func resource(_ filename: String, bundle: Bundle, maximumBytes: Int) throws -> Data {
        guard validFilename(filename),
              let url = bundle.url(forResource: filename, withExtension: nil, subdirectory: "Notices") else {
            throw ReadError.missingDocument
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var result = Data()
        while let chunk = try handle.read(upToCount: min(32_768, maximumBytes + 1 - result.count)), !chunk.isEmpty {
            result.append(chunk)
            guard result.count <= maximumBytes else { throw ReadError.invalidText }
        }
        return result
    }
}

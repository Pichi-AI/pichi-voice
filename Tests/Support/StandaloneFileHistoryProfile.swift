import Foundation

// Immutable installation metadata for the in-memory rename probe. The profile,
// defaults and history implementations are production sources. No directory is
// created, installed data read or credential service accessed by this fixture.
nonisolated enum AppBrand {
    static let storageNamespace = "synthetic.file-history-values"
    static let keychainService = "synthetic.file-history-values.credentials"
    static let applicationSupportDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("synthetic-file-history-values-" + UUID().uuidString, isDirectory: true)
}

import Foundation
import SwiftUI
import UIKit

/// Native Share / Save to Files presentation for the shared exporters.
struct MeetingSharePayload: Identifiable {
    nonisolated private static let directoryPrefix = "meeting-share-"

    let id = UUID()
    let items: [Any]
    let directory: URL
    let includesAudio: Bool

    static func transcript(data: Data, title: String, fileExtension: String) throws -> Self {
        let directory = try makePrivateDirectory()
        let url = directory.appendingPathComponent(MeetingAudioExporter.sanitizedExportName(title)).appendingPathExtension(fileExtension)
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return Self(items: [url], directory: directory, includesAudio: false)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    static func audio(session: MeetingSession, directory source: URL) async throws -> Self {
        let directory = try makePrivateDirectory()
        do {
            let exported = try await MeetingAudioExporter.export(of: session, from: source, into: directory)
            let urls = try FileManager.default.contentsOfDirectory(at: exported, includingPropertiesForKeys: nil)
            guard !urls.isEmpty else { throw CocoaError(.fileNoSuchFile) }
            return Self(items: urls, directory: directory, includesAudio: true)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    /// Call once at cold startup, before staging any new shares. Enumerate only
    /// direct children so unrelated temporary trees are never inspected.
    nonisolated static func cleanupAbandonedShares(in root: URL = FileManager.default.temporaryDirectory) throws {
        guard root.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let manager = FileManager.default
        let rootAttributes = try manager.attributesOfItem(atPath: root.path)
        guard rootAttributes[.type] as? FileAttributeType == .typeDirectory else {
            // In particular, do not enumerate through a symbolic link supplied as the root.
            throw CocoaError(.fileReadInvalidFileName)
        }

        var enumerationError: Error?
        guard let entries = manager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else { throw CocoaError(.fileReadUnknown) }

        for case let entry as URL in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(directoryPrefix),
                  let id = UUID(uuidString: String(name.dropFirst(directoryPrefix.count))),
                  name.caseInsensitiveCompare(directoryPrefix + id.uuidString) == .orderedSame
            else { continue }
            let attributes = try manager.attributesOfItem(atPath: entry.path)
            // attributesOfItem examines the link itself, not its destination.
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { continue }
            try manager.removeItem(at: entry)
        }
        if let enumerationError { throw enumerationError }
    }

    private static func makePrivateDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(directoryPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication, .posixPermissions: 0o700])
        var protected = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protected.setResourceValues(values)
        return directory
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

/// Present as the sole SwiftUI sheet content; UIKit owns activity presentation.
struct MobileActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    let completion: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in completion() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

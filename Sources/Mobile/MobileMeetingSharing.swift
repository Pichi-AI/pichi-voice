import Foundation
import SwiftUI
import UIKit

/// Native Share / Save to Files presentation for the shared exporters.
struct MeetingSharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
    let directory: URL

    static func transcript(data: Data, title: String, fileExtension: String) throws -> Self {
        let directory = try makePrivateDirectory()
        let url = directory.appendingPathComponent(MeetingAudioExporter.sanitizedExportName(title)).appendingPathExtension(fileExtension)
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return Self(items: [url], directory: directory)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    static func audio(session: MeetingSession, directory source: URL) async throws -> Self {
        let directory = try makePrivateDirectory()
        do {
            let exported = try await MeetingAudioExporter.export(of: session, from: source, into: directory)
            let urls = try FileManager.default.contentsOfDirectory(at: exported, includingPropertiesForKeys: nil)
            guard !urls.isEmpty else { throw CocoaError(.fileNoSuchFile) }
            return Self(items: urls, directory: directory)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    private static func makePrivateDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication, .posixPermissions: 0o700])
        var protected = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protected.setResourceValues(values)
        return directory
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

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

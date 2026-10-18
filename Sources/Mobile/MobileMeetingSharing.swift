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

/// The native activity controller extends its content to the container edges.
/// Own its containment here so the retention caption uses the actual window's
/// safe area instead of being pulled underneath the status bar by that child.
struct MobileActivitySheet<Caption: View>: UIViewControllerRepresentable {
    let items: [Any]
    let completion: () -> Void
    @ViewBuilder let caption: () -> Caption

    func makeUIViewController(context: Context) -> MobileActivityContainer<Caption> {
        MobileActivityContainer(items: items, caption: caption(), completion: completion)
    }

    func updateUIViewController(_ controller: MobileActivityContainer<Caption>, context: Context) {
        controller.captionHost.rootView = caption()
    }
}

final class MobileActivityContainer<Caption: View>: UIViewController {
    let captionHost: UIHostingController<Caption>
    private let activityController: UIActivityViewController

    init(items: [Any], caption: Caption, completion: @escaping () -> Void) {
        captionHost = UIHostingController(rootView: caption)
        captionHost.sizingOptions = [.intrinsicContentSize]
        activityController = UIActivityViewController(activityItems: items, applicationActivities: nil)
        activityController.completionWithItemsHandler = { _, _, _, _ in completion() }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        captionHost.view.backgroundColor = .clear
        for child in [captionHost as UIViewController, activityController] {
            addChild(child)
            view.addSubview(child.view)
            child.view.translatesAutoresizingMaskIntoConstraints = false
            child.didMove(toParent: self)
        }
        captionHost.view.setContentCompressionResistancePriority(.required, for: .vertical)
        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            captionHost.view.topAnchor.constraint(equalTo: safeArea.topAnchor),
            captionHost.view.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            captionHost.view.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            activityController.view.topAnchor.constraint(equalTo: captionHost.view.bottomAnchor),
            activityController.view.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            activityController.view.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            activityController.view.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor)
        ])
    }
}

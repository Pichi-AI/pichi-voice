import Darwin
import Foundation

/// Only Apple tools are executed. No executable from the downloaded image is run.
nonisolated enum UpdateDMGStager {
    static let maximumAppBytes: Int64 = 4 * 1024 * 1024 * 1024
    struct Operations: Sendable {
        var run: @Sendable (String, [String], URL, Bool) throws -> Void = UpdateDMGStager.run
        var isMounted: @Sendable (URL, URL) throws -> Bool = UpdateDMGStager.isMounted
        var copy: @Sendable (URL, URL) throws -> Void = { source, destination in
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    static func stage(image: URL, root: URL, appName: String, operations: Operations = .init()) throws -> URL {
        let mount = root.appendingPathComponent("mount", isDirectory: true)
        let app = root.appendingPathComponent(appName, isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
        var attached = false
        do {
            try Task.checkCancellation()
            // The caller owns the empty mountpoint. Detach is attempted even if attach
            // was cancelled after the kernel mounted the image but before hdiutil returned.
            attached = true
            try operations.run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, image.path], root, true)
            try Task.checkCancellation()
            let apps = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                .filter { $0.pathExtension.lowercased() == "app" }
            guard apps.count == 1, let source = apps.first, source.lastPathComponent == appName,
                  try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
                  try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
            else { throw SimpleUpdateError.notAnAppBundle }
            try self.requireBoundedBundle(source)
            try operations.copy(source, app)
            try Task.checkCancellation()
            try operations.run("/usr/bin/hdiutil", ["detach", mount.path], root, false)
            attached = false
            try FileManager.default.removeItem(at: mount)
            return app
        } catch {
            let original = error
            if attached {
                do { try operations.run("/usr/bin/hdiutil", ["detach", mount.path], root, false) }
                catch {
                    let detachError = error
                    do {
                        // An attach rejected before mounting also makes detach fail.
                        // Confirm that case before allowing the caller to remove scratch.
                        if try operations.isMounted(root, mount) {
                            throw Failure(retainedRoot: root, underlying: detachError)
                        }
                    } catch let failure as Failure { throw failure }
                    catch { throw Failure(retainedRoot: root, underlying: error) }
                }
            }
            throw original
        }
    }

    static func isMounted(root: URL, mount: URL) throws -> Bool {
        var parent = stat()
        var child = stat()
        guard lstat(root.path, &parent) == 0, parent.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw CocoaError(.fileReadUnknown)
        }
        if lstat(mount.path, &child) != 0 {
            if errno == ENOENT { return false }
            throw CocoaError(.fileReadUnknown)
        }
        guard child.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw CocoaError(.fileReadUnknown) }
        // A hdiutil image has its own device. The ordinary empty mountpoint is
        // on the staging directory's device after a rejected attach/detach.
        return child.st_dev != parent.st_dev
    }

    private static func requireBoundedBundle(_ app: URL) throws {
        var failure: Error?
        guard let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], errorHandler: { _, error in
            failure = error
            return false
        }) else { throw SimpleUpdateError.notAnAppBundle }
        var bytes: Int64 = 0
        var count = 0
        for case let file as URL in files {
            try Task.checkCancellation()
            count += 1
            guard count <= 100_000 else { throw SimpleUpdateError.notAnAppBundle }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true { bytes += Int64(values.fileSize ?? 0) }
            guard bytes <= self.maximumAppBytes else { throw SimpleUpdateError.notAnAppBundle }
        }
        if let failure { throw failure }
    }

    struct Failure: LocalizedError {
        let retainedRoot: URL
        let underlying: Error
        var mayBeMounted: Bool = true
        var errorDescription: String? { "The update image could not be detached. Retained staging: \(retainedRoot.path). \(underlying.localizedDescription)" }
    }

    /// Bounded, joined subprocess lifetime. Cancellation never abandons a mounted image.
    static func run(_ executable: String, _ arguments: [String], _ root: URL, _ cancellable: Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(120)
        var cancelled = false
        while process.isRunning {
            if (cancellable && Task.isCancelled) || Date() >= deadline {
                cancelled = cancellable && Task.isCancelled
                process.terminate()
                let grace = Date().addingTimeInterval(2)
                while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                if cancelled { throw CancellationError() }
                throw URLError(.timedOut)
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SimpleUpdateError.unzipFailed }
    }
}

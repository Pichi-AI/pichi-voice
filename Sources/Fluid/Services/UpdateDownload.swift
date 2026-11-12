import CryptoKit
import Darwin
import Foundation

nonisolated enum UpdateDownload {
    static let maximumBytes: Int64 = 2 * 1024 * 1024 * 1024

    /// Public release metadata is bounded independently from the disk payload.
    static func metadata(_ request: URLRequest, session: URLSession) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      http.expectedContentLength <= 8 * 1024 * 1024 else { throw SimpleUpdateError.invalidResponse }
                var data = Data()
                for try await byte in bytes {
                    guard data.count < 8 * 1024 * 1024 else { throw SimpleUpdateError.invalidResponse }
                    data.append(byte)
                    if data.count.isMultiple(of: 65_536) { try Task.checkCancellation() }
                }
                try Task.checkCancellation()
                return data
            }
            group.addTask { try await Task.sleep(for: .seconds(45)); throw URLError(.timedOut) }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Stream to a private file with a byte bound and a total deadline, using the
    /// injected session so cancellation, redirects and HTTP failures remain testable.
    static func fetch(_ selection: UpdateReleaseSelection, session: URLSession, to destination: URL) async throws {
        var request = URLRequest(url: selection.assetURL)
        request.timeoutInterval = 60
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [request] in
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      http.expectedContentLength <= maximumBytes,
                      http.url?.scheme == "https"
                else { throw SimpleUpdateError.invalidResponse }
                FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
                let file = try FileHandle(forWritingTo: destination)
                defer { try? file.close() }
                var count: Int64 = 0
                var buffer = Data()
                var digest = SHA256()
                for try await byte in bytes {
                    count += 1
                    guard count <= maximumBytes else { throw SimpleUpdateError.downloadFailed }
                    buffer.append(byte)
                    if buffer.count == 65_536 {
                        try Task.checkCancellation()
                        digest.update(data: buffer)
                        try file.write(contentsOf: buffer)
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
                try Task.checkCancellation()
                digest.update(data: buffer)
                try file.write(contentsOf: buffer)
                guard count > 0 else { throw SimpleUpdateError.downloadFailed }
                if let expected = selection.digest {
                    let actual = "sha256:" + digest.finalize().map { String(format: "%02x", $0) }.joined()
                    guard expected.lowercased() == actual else { throw SimpleUpdateError.downloadFailed }
                }
            }
            group.addTask { try await Task.sleep(for: .seconds(1200)); throw URLError(.timedOut) }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}

extension UpdateDownload {
    /// One reclaimable workspace per installation, including across app restarts.
    /// A process-shared lock prevents a second app instance from deleting live work.
    final nonisolated class Workspace: @unchecked Sendable {
        let directory: URL
        private let descriptor: Int32

        static func open(installation: URL, namespace: String, temporaryDirectory: URL = FileManager.default.temporaryDirectory) throws -> Workspace {
            let identity = Data((namespace + "\n" + installation.standardizedFileURL.path + "\n").utf8)
            let key = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
            let directory = temporaryDirectory.appendingPathComponent("PichiVoiceUpdate-" + key, isDirectory: true)
            let lockURL = directory.appendingPathExtension("lock")
            let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
            var lockStatus = stat()
            guard fstat(descriptor, &lockStatus) == 0, lockStatus.st_uid == geteuid(), lockStatus.st_nlink == 1,
                  lockStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(descriptor)
                throw SimpleUpdateError.updateAlreadyInProgress
            }
            do {
                let manager = FileManager.default
                let marker = directory.appendingPathComponent("ownership")
                if manager.fileExists(atPath: directory.path) {
                    var rootStatus = stat()
                    var markerStatus = stat()
                    var mountStatus = stat()
                    let mount = directory.appendingPathComponent("mount")
                    guard lstat(directory.path, &rootStatus) == 0, rootStatus.st_uid == geteuid(),
                          rootStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                          lstat(marker.path, &markerStatus) == 0, markerStatus.st_uid == geteuid(),
                          markerStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), markerStatus.st_size == identity.count,
                          try Data(contentsOf: marker) == identity,
                          lstat(mount.path, &mountStatus) != 0 || (mountStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) && mountStatus.st_dev == rootStatus.st_dev)
                    else { throw SimpleUpdateError.stagingCleanupFailed(directory.path) }
                    try manager.removeItem(at: directory)
                }
                try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try identity.write(to: marker, options: .atomic)
                return Workspace(directory: directory, descriptor: descriptor)
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        }

        private init(directory: URL, descriptor: Int32) {
            self.directory = directory
            self.descriptor = descriptor
        }
        deinit { Darwin.close(self.descriptor) }
    }
}

import CryptoKit
import Foundation

nonisolated enum S1MiniError: LocalizedError {
    case unknownModel, missingModel, integrity, verification, unsupportedTask, unsafeDirectory, incompleteOutput

    var errorDescription: String? {
        let key: String = switch self {
        case .unknownModel: "The selected S1-mini model is not available."
        case .missingModel: "Model file is not installed."
        case .integrity: "The S1-mini file failed its integrity check. Download it again."
        case .verification: "S1-mini could not verify its native runtime."
        case .unsupportedTask: "S1-mini is available for dictation cleanup only."
        case .unsafeDirectory: "The S1-mini model folder is not safe to modify."
        case .incompleteOutput: "S1-mini did not finish cleaning this dictation within its output limit."
        }
        return PichiLocalization.text(key)
    }
}

/// Installs one pinned artifact as a complete directory, including its integrity receipt.
/// No user-selected file is moved, replaced or returned as a removable app-owned file.
nonisolated struct S1MiniModelStore: Sendable {
    typealias Download = @Sendable (URL, Int64, @escaping @Sendable (Int64, Int64) -> Void) async throws -> (URL, URLResponse)
    let directoryURL: URL
    let model: PrivateAIRegisteredModel
    let download: Download

    init(
        directoryURL: URL,
        model: PrivateAIRegisteredModel = S1MiniProviderFeature.modelDescriptor,
        download: @escaping Download = Self.downloadArtifact
    ) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.model = model
        self.download = download
    }

    private struct Receipt: Codable, Equatable {
        let modelID: String
        let version: String
        let sha256: String
        let byteCount: Int64
    }

    var modelURL: URL {
        self.directoryURL.appendingPathComponent(self.model.id, isDirectory: true)
            .appendingPathComponent(self.model.artifact.version ?? "pinned", isDirectory: true)
            .appendingPathComponent(self.model.artifact.filename)
    }
    var receiptURL: URL { self.modelURL.deletingLastPathComponent().appendingPathComponent("installation.json") }

    func isInstalled() -> Bool {
        guard Self.hasExpectedFileSize(self.modelURL, bytes: self.model.artifact.byteCount),
              Self.isRegularFile(self.receiptURL),
              let attributes = try? FileManager.default.attributesOfItem(atPath: self.receiptURL.path),
              let receiptSize = attributes[.size] as? NSNumber, receiptSize.intValue <= 4096,
              let bytes = try? Data(contentsOf: self.receiptURL), bytes.count <= 4096,
              let receipt = try? JSONDecoder().decode(Receipt.self, from: bytes),
              let expected = self.expectedReceipt
        else { return false }
        return receipt == expected
    }

    var removableURLs: [URL] {
        // Refuse even listing symlinked installation paths for the common removal service.
        guard self.modelURL.resolvingSymlinksInPath().standardizedFileURL == self.modelURL,
              self.receiptURL.resolvingSymlinksInPath().standardizedFileURL == self.receiptURL
        else { return [] }
        return [self.modelURL, self.receiptURL].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func prepare(progressHandler: PrivateAIModelDownloadProgressHandler?) async throws -> URL {
        try Task.checkCancellation()
        if self.isInstalled() {
            try self.validate(self.modelURL)
            return self.modelURL
        }
        guard let source = self.model.artifact.downloadURL,
              let byteCount = self.model.artifact.byteCount, byteCount > 0,
              let receipt = self.expectedReceipt
        else { throw S1MiniError.unknownModel }
        try self.validateOwnedDirectory()
        let fm = FileManager.default
        try fm.createDirectory(at: self.directoryURL, withIntermediateDirectories: true)
        try self.validateOwnedDirectory()
        let stage = self.directoryURL.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }

        // An AsyncStream owns progress delivery. Drain its single consumer before returning,
        // so cancellation cannot leave detached callbacks updating a later UI operation.
        let progress = AsyncStream<PrivateAIModelDownloadProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let progressTask = Task {
            for await value in progress.stream { await progressHandler?(value) }
        }
        do {
            progress.continuation.yield(.init(initialExpectedBytes: byteCount))
            let (temporaryURL, response) = try await self.download(source, byteCount) { written, expected in
                progress.continuation.yield(PrivateAIModelDownloadProgress(
                    bytesWritten: 0,
                    totalBytesWritten: written,
                    totalBytesExpected: expected > 0 ? expected : byteCount
                ))
            }
            defer { try? fm.removeItem(at: temporaryURL) }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            try Task.checkCancellation()
            let stagedModel = stage.appendingPathComponent(self.model.artifact.filename)
            try fm.moveItem(at: temporaryURL, to: stagedModel)
            try self.validate(stagedModel)
            try JSONEncoder().encode(receipt).write(to: stage.appendingPathComponent("installation.json"), options: .atomic)
            try Task.checkCancellation()
            try self.publish(stage)
            progress.continuation.finish()
            await progressTask.value
            return self.modelURL
        } catch {
            progress.continuation.finish()
            await progressTask.value
            throw error
        }
    }

    func validate(_ url: URL) throws {
        try Task.checkCancellation()
        guard Self.hasExpectedFileSize(url, bytes: self.model.artifact.byteCount),
              let hash = self.model.artifact.sha256,
              try Self.sha256(url) == hash
        else { throw S1MiniError.integrity }
        try Task.checkCancellation()
    }

    static func hasExpectedFileSize(_ url: URL, bytes: Int64?) -> Bool {
        guard let bytes, self.isRegularFile(url),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber
        else { return false }
        return size.int64Value == bytes
    }

    static func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    static func sha256(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private var expectedReceipt: Receipt? {
        guard let version = self.model.artifact.version,
              let sha256 = self.model.artifact.sha256,
              let byteCount = self.model.artifact.byteCount
        else { return nil }
        return Receipt(modelID: self.model.id, version: version, sha256: sha256, byteCount: byteCount)
    }

    private func validateOwnedDirectory() throws {
        // Parent directory and future target must retain the app's original ownership boundary.
        guard self.directoryURL.resolvingSymlinksInPath().standardizedFileURL == self.directoryURL,
              self.modelURL.resolvingSymlinksInPath().standardizedFileURL == self.modelURL
        else { throw S1MiniError.unsafeDirectory }
    }

    private func publish(_ stage: URL) throws {
        try self.validateOwnedDirectory()
        let fm = FileManager.default
        let target = self.modelURL.deletingLastPathComponent()
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = self.directoryURL.appendingPathComponent(".replaced-\(UUID().uuidString)", isDirectory: true)
        let replacesExisting = fm.fileExists(atPath: target.path)
        if replacesExisting { try fm.moveItem(at: target, to: backup) }
        do {
            try fm.moveItem(at: stage, to: target)
            if replacesExisting { try? fm.removeItem(at: backup) }
        } catch {
            if replacesExisting { try? fm.moveItem(at: backup, to: target) }
            throw error
        }
    }

    private static func downloadArtifact(
        _ url: URL, maximumBytes: Int64, onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> (URL, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        return try await ProgressiveFileDownloader.download(
            from: url, configuration: configuration, maximumBytes: maximumBytes, onProgress: onProgress
        )
    }
}

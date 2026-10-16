import Foundation

/// One private CoreML compilation derivative for one frozen Nemotron runtime. FluidAudio
/// recompiles a package on each load; passing this owned .mlmodelc leaves its model loading,
/// sequential residency and diarizer cleanup unchanged. No model references live here.
actor MeetingNemotronCompiledModelOwner {
    typealias Compiler = @Sendable (URL, URL) async throws -> Void
    typealias Recheck = @Sendable (MeetingNemotronModelArtifact) throws -> MeetingNemotronModelArtifact

    private nonisolated struct Operation: Sendable {
        let id: UUID
        let task: Task<URL, Error>
    }
    private let directory: URL
    private let compile: Compiler
    private var boundArtifact: MeetingNemotronModelArtifact?
    private var compiledURL: URL?
    private var operation: Operation?
    private var closed = false

    init(baseDirectory: URL = FileManager.default.temporaryDirectory, compile: @escaping Compiler) {
        self.directory = baseDirectory.appendingPathComponent("meeting-nemotron-compiled-" + UUID().uuidString, isDirectory: true)
        self.compile = compile
    }

    deinit { try? FileManager.default.removeItem(at: self.directory) }

    func compiledModel(for artifact: MeetingNemotronModelArtifact, recheck: @escaping Recheck) async throws -> URL {
        try Task.checkCancellation()
        guard !self.closed else { throw CancellationError() }
        if let boundArtifact, boundArtifact != artifact {
            throw MeetingNemotronModelReadinessError.artifactChanged(path: artifact.packageURL.path)
        }
        // Reuse never substitutes a derivative fingerprint for the pinned original package.
        guard try recheck(artifact) == artifact else {
            throw MeetingNemotronModelReadinessError.artifactChanged(path: artifact.packageURL.path)
        }
        if let suppliedCompiledURL = artifact.compiledModelURL {
            // The immutable bundle also owns its pinned host projection and silence embedding.
            // It is installed storage, not our derivative: never remove it on cleanup.
            try Self.validateDerivative(at: suppliedCompiledURL)
            self.boundArtifact = artifact
            try Task.checkCancellation()
            return suppliedCompiledURL
        }
        if let compiledURL {
            try Self.validateDerivative(at: compiledURL)
            try Task.checkCancellation()
            return compiledURL
        }
        let selected: Operation
        if let operation { selected = operation }
        else {
            self.boundArtifact = artifact
            let directory = self.directory
            let compile = self.compile
            // This private actor is not the UI actor. Inherit the request's TaskLocal
            // correlation while keeping its compiler work and cancellation joined.
            let task = Task(priority: .userInitiated) {
                let target = directory.appendingPathComponent("Nemotron.mlmodelc", isDirectory: true)
                var published = false
                defer { if !published { try? FileManager.default.removeItem(at: directory) } }
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                try await compile(artifact.packageURL, target)
                try Task.checkCancellation()
                guard try recheck(artifact) == artifact else {
                    throw MeetingNemotronModelReadinessError.artifactChanged(path: artifact.packageURL.path)
                }
                try Self.validateDerivative(at: target)
                try Task.checkCancellation()
                published = true
                return target
            }
            selected = Operation(id: UUID(), task: task)
            self.operation = selected
        }
        do {
            // A cancelled waiter still joins a native compiler that may ignore cancellation.
            let url = try await withTaskCancellationHandler {
                try await selected.task.value
            } onCancel: { selected.task.cancel() }
            try Task.checkCancellation()
            guard !self.closed else { throw CancellationError() }
            if let compiledURL { return compiledURL }
            guard self.operation?.id == selected.id else { throw CancellationError() }
            self.compiledURL = url
            self.operation = nil
            return url
        } catch {
            // A later cancelled waiter cannot delete a derivative already handed to a load.
            if self.operation?.id == selected.id {
                self.operation = nil
                try? FileManager.default.removeItem(at: self.directory)
            }
            throw error
        }
    }

    /// Terminal cleanup is idempotent and joins compilation before deleting its private output.
    /// The runtime is retained by its joined phase work; deinit is the normal attempt cleanup.
    func cancelAndCleanup() async {
        self.closed = true
        let operation = self.operation
        operation?.task.cancel()
        _ = await operation?.task.result
        self.operation = nil
        self.compiledURL = nil
        try? FileManager.default.removeItem(at: self.directory)
    }

    private nonisolated static func validateDerivative(at url: URL) throws {
        let manager = FileManager.default
        guard url.pathExtension.lowercased() == "mlmodelc",
              let attributes = try? manager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              let entries = manager.enumerator(at: url, includingPropertiesForKeys: nil) else {
            throw MeetingNemotronModelReadinessError.invalidModelPackage(reason: "compiledDerivativeInvalid")
        }
        var files = 0
        var bytes: Int64 = 0
        for case let entry as URL in entries {
            let attributes = try manager.attributesOfItem(atPath: entry.path)
            guard let type = attributes[.type] as? FileAttributeType,
                  type == .typeDirectory || type == .typeRegular else {
                throw MeetingNemotronModelReadinessError.invalidModelPackage(reason: "compiledDerivativeContainsLink")
            }
            if type == .typeRegular {
                files += 1
                bytes += (attributes[.size] as? NSNumber)?.int64Value ?? 0
                guard files <= 4_096, bytes <= 1_000_000_000 else {
                    throw MeetingNemotronModelReadinessError.invalidModelPackage(reason: "compiledDerivativeBudgetExceeded")
                }
            }
        }
        guard files > 0 else {
            throw MeetingNemotronModelReadinessError.invalidModelPackage(reason: "compiledDerivativeEmpty")
        }
    }
}

import Combine
import CryptoKit
import Foundation

/// Optional capture activity resources use the existing downloader and explicit Settings
/// operation. Recording only opens a validated local artifact, never starts installation.
@MainActor
final class MeetingSpeechActivityResources: ObservableObject {
    static let shared = MeetingSpeechActivityResources()
    @Published private(set) var isPreparing = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var isReady = false
    private var operation: Task<Void, Error>?

    func prepare() async throws {
        if let operation { return try await operation.value }
        isPreparing = true
        let operation = Task {
            let admission = try await MeetingModelResidencyCoordinator.shared.beginOperationRetiringIdle(owner: "speech-activity-resources", modelID: "installed-activity-model")
            defer { MeetingModelResidencyCoordinator.shared.endOperation(admission) }
            try await MeetingSileroActivityArtifacts.install { value in
                Task { @MainActor in self.progress = value }
            }
            self.isReady = true
        }
        self.operation = operation
        defer { self.operation = nil; self.isPreparing = false }
        try await operation.value
    }

    func refresh() async {
        self.isReady = await Task.detached(priority: .utility) { (try? MeetingSileroActivityArtifacts.validate()) != nil }.value
    }
}

/// Audited 256ms aggregate-output graph. Its artifact identity stays in the adapter,
/// independent of generic capture, placeholder and ASR coverage contracts.
nonisolated enum MeetingSileroActivityArtifacts {
    static let revision = "b419383c55c110e2c9271fa6ee0ea83d03c70d96"
    static let package = "silero-vad-unified-256ms-v6.0.0.mlmodelc"
    static let files: [(String, Int, String)] = [
        ("analytics/coremldata.bin", 243, "30945d54e32c3f15ec35dc6ee32128a27a6cdc03b0a12ffab04434069c49dfb5"),
        ("coremldata.bin", 625, "0c3063bd09ba71c26ede0308d7c33591d0770e971a3fcc603ccad7ba1e8fb88d"),
        ("metadata.json", 3335, "e00405801b86542dbb722a2ec2fff285e539836990f4fdc6aa321ce1105eb32c"),
        ("model.mil", 176918, "4f93e2b5920e851fbc0be1c21a2a76e170124467ed7b01125190aa32e795f8af"),
        ("weights/weight.bin", 882304, "853cf34740d3f5061f977ebe2976f7c921b064261c9c4753b3a1196f2dba42b4"),
    ]
    static var directory: URL {
        AppBrand.modelsDirectory.appendingPathComponent("silero-vad-coreml", isDirectory: true)
            .appendingPathComponent(package, isDirectory: true)
    }

    static func open() throws -> any MeetingSpeechActivityFrameModel {
        try validate()
        return try MeetingLocalSileroActivityModel(modelURL: directory)
    }

    static func validateRootContainment() throws {
        let root = AppBrand.modelsDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        guard directory.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root + "/") else {
            throw MeetingLocalSileroActivityModel.Failure.schema
        }
    }

    static func validate() throws {
        try validateRootContainment()
        try validate(at: directory)
    }

    static func validate(at directory: URL) throws {
        for relative in ["", "analytics", "weights"] {
            let url = relative.isEmpty ? directory : directory.appendingPathComponent(relative)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw MeetingLocalSileroActivityModel.Failure.schema }
        }
        for (path, count, digest) in files {
            let url = directory.appendingPathComponent(path)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == count else { throw MeetingLocalSileroActivityModel.Failure.schema }
            let data = try Data(contentsOf: url)
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest else { throw MeetingLocalSileroActivityModel.Failure.schema }
        }
    }

    static func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        try validateRootContainment()
        if await Task.detached(priority: .utility, operation: { (try? validate()) != nil }).value { return }
        let root = directory.deletingLastPathComponent()
        let stage = root.appendingPathComponent(".activity-" + revision + ".staging", isDirectory: true)
        let downloader = await HuggingFaceModelDownloader(owner: "FluidInference", repo: "silero-vad-coreml", revision: revision,
            requiredItems: [.init(path: package, isDirectory: true)])
        try await downloader.ensureModelsPresent(at: stage) { value, _ in progress(value) }
        let source = stage.appendingPathComponent(package, isDirectory: true)
        let validation = Task.detached(priority: .utility) { try validate(at: source) }
        do { try await validation.value }
        catch { try? FileManager.default.removeItem(at: stage); throw error }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            _ = try FileManager.default.replaceItemAt(directory, withItemAt: source)
        } else { try FileManager.default.moveItem(at: source, to: directory) }
        try? FileManager.default.removeItem(at: stage)
    }
}

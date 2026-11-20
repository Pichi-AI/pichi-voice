import Combine
import Foundation

/// The one step of a model installation that needs ordinary model admission: changing installed
/// storage. A transfer into a staging folder reads and writes nothing a running model uses, so it
/// holds no admission; local summaries, processing and dictation restoration stay possible while it
/// runs. Publication retires an idle preload, then holds the admission until the step has joined.
/// A meeting attempt that started during the transfer makes publication fail with the coordinator's
/// existing busy error, and the staged files stay for the retry.
nonisolated struct MeetingModelPublicationGate: Sendable {
    let owner: String
    let modelID: String
    let residency: MeetingModelResidencyCoordinator

    /// Runs `step` off the main actor under admission. Cancellation reaches the step, and the
    /// admission is released only after it has returned or thrown.
    func publish<T: Sendable>(_ step: @escaping @Sendable () throws -> T) async throws -> T {
        let admission = try await self.residency.beginOperationRetiringIdle(owner: self.owner, modelID: self.modelID)
        do {
            let work = Task.detached(priority: .utility) { try step() }
            let value = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            await self.residency.endOperation(admission)
            return value
        } catch {
            await self.residency.endOperation(admission)
            throw error
        }
    }
}

/// Downloads and installs the Nemotron 3 Diarization package from Hugging Face.
///
/// Recorded-audio processing and opt-in streaming share this installation owner. Capture
/// preparation selects the registered immutable profile before admitting audio. One attempt
/// runs at a time per profile; callers share its result and failures permit a fresh retry.
@MainActor
final class MeetingDiarizationModelStore: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case downloading(fraction: Double)
        case ready(MeetingNemotronModelArtifact)
        case failed(message: String)
    }

    /// Carries the same plain message the settings row shows, so a meeting whose processing
    /// waited on a failed download explains itself instead of showing a raw network code.
    struct DownloadError: LocalizedError {
        let message: String
        var errorDescription: String? { self.message }
    }

    static let shared = MeetingDiarizationModelStore()
    private static var profileStores: [MeetingNemotronModelProfile: MeetingDiarizationModelStore] = [:]

    /// Settings and capture preparation observe the same existing operation owner per profile.
    static func shared(for profile: MeetingNemotronModelProfile) -> MeetingDiarizationModelStore {
        if profile == .fast32SplitW8A8 { return self.shared }
        if let store = self.profileStores[profile] { return store }
        let store = MeetingDiarizationModelStore(profile: profile)
        self.profileStores[profile] = store
        return store
    }

    static let repositoryOwner = "FluidInference"
    static let repositoryName = "nemotron-3-diarization-coreml"
    /// Pinned so a later push to the repository can never change an installed app's model.
    static let repositoryRevision = MeetingNemotronModelProfile.repositoryRevision

    // This author-compiled graph has no metadata.json. Declare the pinned files rather
    // than applying the downloader's generic compiled-directory completeness contract.
    static let requiredDownloadItems = MeetingDiarizationModelStore.requiredDownloadItems(for: .fast32SplitW8A8)

    nonisolated static func requiredDownloadItems(for profile: MeetingNemotronModelProfile) -> [HuggingFaceModelDownloader.ModelItem] {
        profile.remoteFilePaths.map { .init(path: $0, isDirectory: false) }
    }

    typealias Validate = @Sendable () throws -> MeetingNemotronModelArtifact
    /// The install step transfers files without admission and calls `publication.publish` around
    /// the code that changes installed storage.
    typealias Install = @Sendable (_ progress: @escaping @Sendable (Double) -> Void,
                                   _ publication: MeetingModelPublicationGate) async throws -> MeetingNemotronModelArtifact
    typealias InstallVoice = @Sendable (_ progress: @escaping @Sendable (Double) -> Void,
                                        _ publication: MeetingModelPublicationGate) async throws -> Void

    @Published private(set) var state: State = .idle
    @Published private(set) var voiceMatchingReady = false
    nonisolated let supportsOwnerVoiceVerification: Bool
    private var attempt: Task<MeetingNemotronModelArtifact, Error>?
    private var voiceAttempt: Task<Void, Error>?
    private let validateVoice: @Sendable () throws -> Void
    private let installVoice: InstallVoice
    private let residency: MeetingModelResidencyCoordinator
    private let canDownload: @Sendable () -> Bool
    private let validate: Validate
    private let install: Install

    init(
        supportsOwnerVoiceVerification: Bool = true,
        canDownload: @escaping @Sendable () -> Bool = MeetingDiarizationModelStore.usesDefaultLocation,
        validate: @escaping Validate = {
            let package = MeetingNemotronModelLocator().resolvedPackageURL()
            _ = try MeetingModelInstaller.validatedSilenceEmbedding(
                at: MeetingModelInstaller.silenceEmbeddingURL(besides: package)
            )
            return try MeetingModelInstaller.validate(package)
        },
        install: @escaping Install = MeetingDiarizationModelStore.downloadAndInstall,
        validateVoice: @escaping @Sendable () throws -> Void = MeetingSpeakerVoiceModelArtifacts.validate,
        installVoice: @escaping InstallVoice = MeetingSpeakerVoiceModelArtifacts.ensureInstalled,
        residency: MeetingModelResidencyCoordinator? = nil
    ) {
        self.residency = residency ?? .shared
        self.supportsOwnerVoiceVerification = supportsOwnerVoiceVerification
        self.canDownload = canDownload
        self.validate = validate
        self.install = install
        self.validateVoice = validateVoice
        self.installVoice = installVoice
    }

    /// Explicit candidate stores share validation, progress, cancellation and publication
    /// with production setup. No user preference or default store is changed by creating one.
    convenience init(profile: MeetingNemotronModelProfile) {
        self.init(
            supportsOwnerVoiceVerification: profile.supportsOwnerVoiceVerification,
            canDownload: { MeetingNemotronModelLocator(profile: profile).resolvedPackageURL().standardizedFileURL
                == MeetingNemotronModelLocator.defaultPackageURL(profile: profile).standardizedFileURL },
            validate: {
                let package = MeetingNemotronModelLocator(profile: profile).resolvedPackageURL()
                _ = try MeetingModelInstaller.validatedSilenceEmbedding(
                    at: MeetingModelInstaller.silenceEmbeddingURL(besides: package))
                return try MeetingModelInstaller.validate(package, profile: profile)
            },
            install: { progress, publication in
                try await Self.downloadAndInstall(profile: profile, progress: progress, publication: publication)
            }
        )
    }

    /// Starts a check, and a download when needed, without waiting for it.
    func prepareInBackground() {
        #if DEBUG
        // A view that appears in a hosted unit test (the settings sheet, the meetings view) would start the
        // real download of the pinned model into the test home, and the task outlives the test: its
        // publication would take the ordinary model admission, so a test that needs an exclusive attempt
        // at that moment fails with "busy". Hosted tests own their model operations and call
        // prepare/ensureInstalled themselves. A UI-test application runs in another process, where XCTestCase is not loaded.
        if NSClassFromString("XCTestCase") != nil { return }
        #endif
        Task { _ = try? await self.ensureInstalled() }
    }

    /// Returns the installed model, downloading it first when it is missing or damaged.
    @discardableResult
    func ensureInstalled(includingVoiceEncoder: Bool = false) async throws -> MeetingNemotronModelArtifact {
        let installed = try await self.ensureSeparationInstalled()
        if includingVoiceEncoder { try await self.ensureVoiceMatchingInstalled() }
        return installed
    }

    func prepare(dependencies: Set<MeetingDiarizationDependency>) async throws {
        guard !dependencies.isEmpty else { return }
        if dependencies.contains(.speakerSeparation) {
            _ = try await self.ensureInstalled(includingVoiceEncoder: dependencies.contains(.voiceMatching))
        } else if dependencies.contains(.voiceMatching) { try await self.ensureVoiceMatchingInstalled() }
    }

    var allSpeakerResourcesReady: Bool {
        if case .ready = self.state { return self.voiceMatchingReady }
        return false
    }

    private func ensureVoiceMatchingInstalled() async throws {
        if let voiceAttempt { return try await voiceAttempt.value }
        let task = Task { @MainActor in
            defer { self.voiceAttempt = nil }
            let validate = self.validateVoice
            if (try? await Task.detached(priority: .utility, operation: validate).value) != nil {
                self.voiceMatchingReady = true
                return
            }
            self.voiceMatchingReady = false
            let prior = self.state
            self.state = .downloading(fraction: 0)
            do {
                // The transfer holds no model admission; only publication does (see the gate).
                try await self.installVoice({ fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.voiceAttempt != nil, !self.voiceMatchingReady,
                              case .downloading = self.state else { return }
                        self.state = .downloading(fraction: fraction)
                    }
                }, self.publication(modelID: "voice-matching"))
                try await Task.detached(priority: .utility, operation: validate).value
                self.voiceMatchingReady = true
                self.state = prior
            } catch {
                self.state = .failed(message: Self.userMessage(for: error))
                throw DownloadError(message: Self.userMessage(for: error))
            }
        }
        self.voiceAttempt = task
        try await task.value
    }

    private func ensureSeparationInstalled() async throws -> MeetingNemotronModelArtifact {
        if let attempt { return try await attempt.value }
        let attempt = Task { @MainActor in
            // Cleared before the result is delivered, so a caller reacting to a failure can
            // immediately start a fresh attempt.
            defer { self.attempt = nil }
            return try await self.run()
        }
        self.attempt = attempt
        return try await attempt.value
    }

    private func run() async throws -> MeetingNemotronModelArtifact {
        self.state = .checking
        let validate = self.validate
        if let installed = try? await Task.detached(priority: .utility, operation: validate).value {
            self.state = .ready(installed)
            return installed
        }
        guard CPUArchitecture.isAppleSilicon else {
            self.state = .failed(message: "Speaker labels need an Apple silicon Mac.")
            throw MeetingParakeetNemotronRuntimeError.unsupportedArchitecture
        }
        guard self.canDownload() else {
            let error = MeetingNemotronModelReadinessError.invalidModelPackage(reason: "developmentOverrideInvalid")
            self.state = .failed(message: AppBrand.text("The development model path is missing or invalid. Remove the override and restart FluidVoice."))
            throw error
        }

        self.state = .downloading(fraction: 0)
        // A valid installed readiness check never retires a matching recording preload, and neither
        // does the transfer. Publication, the actual artifact mutation, yields the idle lease and holds
        // the ordinary admission only while it changes installed storage.
        do {
            let installed = try await self.install({ fraction in
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.state else { return }
                    self.state = .downloading(fraction: fraction)
                }
            }, self.publication(modelID: "speaker-separation"))
            self.state = .ready(installed)
            return installed
        } catch {
            DebugLogger.shared.error(
                "Speaker model download failed: \(error.localizedDescription)",
                source: "MeetingDiarizationModelStore"
            )
            let message = Self.userMessage(for: error)
            self.state = .failed(message: message)
            throw DownloadError(message: message)
        }
    }

    private func publication(modelID: String) -> MeetingModelPublicationGate {
        MeetingModelPublicationGate(owner: "speaker-resources", modelID: modelID, residency: self.residency)
    }

    nonisolated static func usesDefaultLocation() -> Bool {
        MeetingNemotronModelLocator().resolvedPackageURL().standardizedFileURL
            == MeetingNemotronModelLocator.defaultPackageURL().standardizedFileURL
    }

    /// Downloads into a stable staging folder, so an interrupted download resumes file by file,
    /// then hands the package to the checksum-pinned installer.
    nonisolated static func downloadAndInstall(
        progress: @escaping @Sendable (Double) -> Void, publication: MeetingModelPublicationGate
    ) async throws -> MeetingNemotronModelArtifact {
        try await self.downloadAndInstall(to: MeetingNemotronModelLocator.defaultPackageURL(),
                                          progress: progress, publication: publication)
    }

    nonisolated static func downloadAndInstall(
        profile: MeetingNemotronModelProfile, progress: @escaping @Sendable (Double) -> Void,
        publication: MeetingModelPublicationGate
    ) async throws -> MeetingNemotronModelArtifact {
        try await self.downloadAndInstall(to: MeetingNemotronModelLocator.defaultPackageURL(profile: profile),
                                          profile: profile, progress: progress, publication: publication)
    }

    /// The existing install operation can target an explicitly owned store. Test and
    /// mobile preflight use the same pinned download and publication as desktop setup.
    nonisolated static func downloadAndInstall(
        to destination: URL, profile: MeetingNemotronModelProfile = .fast32SplitW8A8,
        progress: @escaping @Sendable (Double) -> Void, publication: MeetingModelPublicationGate
    ) async throws -> MeetingNemotronModelArtifact {
        let staging = self.stagingURL(for: destination, profile: profile)
        let downloader = await HuggingFaceModelDownloader(
            owner: Self.repositoryOwner,
            repo: Self.repositoryName,
            revision: Self.repositoryRevision,
            requiredItems: Self.requiredDownloadItems(for: profile)
        )
        try await downloader.ensureModelsPresent(at: staging) { fraction, _ in progress(fraction) }
        return try await self.publishStaged(from: staging, to: destination, profile: profile, publication: publication)
    }

    nonisolated static func stagingURL(for destination: URL, profile: MeetingNemotronModelProfile) -> URL {
        destination.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("download-\(profile.cacheVersion)", isDirectory: true)
    }

    /// Everything before the installer reads and writes only the staging folder. Only the installer,
    /// which copies beside the installed package and swaps it in, runs under the gate's admission.
    /// A damaged download is discarded. After a busy refusal, a cancellation or a local failure the
    /// transferred files stay in staging, so the retry transfers nothing again.
    nonisolated static func publishStaged(
        from staging: URL, to destination: URL, profile: MeetingNemotronModelProfile,
        publication: MeetingModelPublicationGate
    ) async throws -> MeetingNemotronModelArtifact {
        let downloaded = staging.appendingPathComponent(profile.packageFileName, isDirectory: true)
        do {
            try await Task.detached(priority: .utility) {
                // Publish weights and both host assets in one immutable atomic directory swap.
                try? FileManager.default.removeItem(at: downloaded)
                try FileManager.default.createDirectory(at: downloaded, withIntermediateDirectories: false)
                try FileManager.default.copyItem(
                    at: staging.appendingPathComponent(profile.remoteModelPath),
                    to: downloaded.appendingPathComponent(profile.compiledModelFileName))
                for name in profile.hostFileNames {
                    try FileManager.default.copyItem(at: staging.appendingPathComponent(name), to: downloaded.appendingPathComponent(name))
                }
            }.value
            let installed = try await publication.publish {
                try MeetingModelInstaller.install(from: downloaded, to: destination, profile: profile)
            }
            try? FileManager.default.removeItem(at: staging)
            return installed
        } catch MeetingModelInstaller.InstallError.wrongPackage {
            // A damaged download would otherwise be "resumed" forever; start clean next time.
            try? FileManager.default.removeItem(at: staging)
            throw MeetingModelInstaller.InstallError.wrongPackage
        } catch {
            try? FileManager.default.removeItem(at: downloaded)
            throw error
        }
    }

    nonisolated static func userMessage(for error: Error) -> String {
        // A meeting attempt started while the files were transferring: nothing is wrong with the
        // download, and the retry reuses it. Show the coordinator's existing retriable message.
        if let residency = error as? MeetingModelResidencyError, case .busy = residency {
            return residency.localizedDescription
        }
        if error is MeetingModelInstaller.InstallError {
            return PichiLocalization.text("The downloaded speaker model was damaged. Try again.")
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return PichiLocalization.text("Couldn't download the speaker model. Check your internet connection and try again.")
        }
        if nsError.domain == "HF", [401, 403, 404].contains(nsError.code) {
            return PichiLocalization.text("The speaker model isn't available for download right now. Try again later.")
        }
        return PichiLocalization.format("Couldn't download the speaker model (%@). Try again.", String(describing: error.localizedDescription))
    }
}

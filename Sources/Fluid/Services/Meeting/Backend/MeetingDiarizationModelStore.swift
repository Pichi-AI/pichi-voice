import Combine
import Foundation

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
    typealias Install = @Sendable (_ progress: @escaping @Sendable (Double) -> Void) async throws
        -> MeetingNemotronModelArtifact
    typealias InstallVoice = @Sendable (@escaping @Sendable (Double) -> Void) async throws -> Void

    @Published private(set) var state: State = .idle
    @Published private(set) var voiceMatchingReady = false
    nonisolated let supportsOwnerVoiceVerification: Bool
    private var attempt: Task<MeetingNemotronModelArtifact, Error>?
    private var voiceAttempt: Task<Void, Error>?
    private let validateVoice: @Sendable () throws -> Void
    private let installVoice: StagedInstallVoice
    private let residency: MeetingModelResidencyCoordinator
    private let canDownload: @Sendable () -> Bool
    private let validate: Validate
    private let install: StagedInstall

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
        install: Install? = nil,
        validateVoice: @escaping @Sendable () throws -> Void = MeetingSpeakerVoiceModelArtifacts.validate,
        installVoice: InstallVoice? = nil,
        stagedInstall: StagedInstall? = nil,
        stagedInstallVoice: StagedInstallVoice? = nil,
        residency: MeetingModelResidencyCoordinator? = nil
    ) {
        self.residency = residency ?? .shared
        self.supportsOwnerVoiceVerification = supportsOwnerVoiceVerification
        self.canDownload = canDownload
        self.validate = validate
        self.install = Self.resolveInstall(staged: stagedInstall, legacy: install)
        self.validateVoice = validateVoice
        self.installVoice = Self.resolveInstallVoice(staged: stagedInstallVoice, legacy: installVoice)
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
            stagedInstall: { progress, publication in
                try await Self.downloadAndInstallStaged(profile: profile, progress: progress, publication: publication)
            }
        )
    }

    /// Starts a check, and a download when needed, without waiting for it.
    func prepareInBackground() {
        #if DEBUG
        // A view that appears in a hosted unit test (the settings sheet, the meetings view) would start the
        // real download of the pinned model into the empty test home, and the task outlives the test. Hosted
        // tests own their model operations and call prepare/ensureInstalled themselves. A UI-test application
        // runs in another process, where XCTestCase is not loaded.
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
                try await self.installVoice({ fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.voiceAttempt != nil, !self.voiceMatchingReady,
                              case .downloading = self.state else { return }
                        self.state = .downloading(fraction: fraction)
                    }
                }, .speakerResources(modelID: "voice-matching", residency: self.residency))
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
        // A valid installed readiness check never retires a matching recording preload. The staged
        // install transfers without admission; publication, the actual artifact mutation, yields the
        // idle lease and holds admission only while it changes installed storage (see the gate).
        do {
            let installed = try await self.install({ fraction in
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.state else { return }
                    self.state = .downloading(fraction: fraction)
                }
            }, .speakerResources(modelID: "speaker-separation", residency: self.residency))
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

    nonisolated static func usesDefaultLocation() -> Bool {
        MeetingNemotronModelLocator().resolvedPackageURL().standardizedFileURL
            == MeetingNemotronModelLocator.defaultPackageURL().standardizedFileURL
    }

    /// Downloads into a stable staging folder, so an interrupted download resumes file by file,
    /// then hands the package to the checksum-pinned installer.
    nonisolated static func downloadAndInstall(
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> MeetingNemotronModelArtifact {
        try await self.downloadAndInstall(to: MeetingNemotronModelLocator.defaultPackageURL(), progress: progress)
    }

    nonisolated static func downloadAndInstall(
        profile: MeetingNemotronModelProfile, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> MeetingNemotronModelArtifact {
        try await self.downloadAndInstall(to: MeetingNemotronModelLocator.defaultPackageURL(profile: profile),
                                         profile: profile, progress: progress)
    }

    /// The existing install operation can target an explicitly owned store. Test and
    /// mobile preflight use the same pinned download and publication as desktop setup.
    /// The caller holds the model admission around the whole run, as before the staged form existed.
    nonisolated static func downloadAndInstall(
        to destination: URL, profile: MeetingNemotronModelProfile = .fast32SplitW8A8,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> MeetingNemotronModelArtifact {
        try await self.downloadAndInstallStaged(to: destination, profile: profile, progress: progress,
                                                publication: .alreadyAdmitted)
    }

    /// The same download with admission held only for publication. `publication` is required: a
    /// caller that mutates installed storage states its admission policy explicitly.
    nonisolated static func downloadAndInstallStaged(
        progress: @escaping @Sendable (Double) -> Void, publication: MeetingModelPublicationGate
    ) async throws -> MeetingNemotronModelArtifact {
        try await self.downloadAndInstallStaged(to: MeetingNemotronModelLocator.defaultPackageURL(),
                                                progress: progress, publication: publication)
    }

    nonisolated static func downloadAndInstallStaged(
        profile: MeetingNemotronModelProfile, progress: @escaping @Sendable (Double) -> Void,
        publication: MeetingModelPublicationGate
    ) async throws -> MeetingNemotronModelArtifact {
        try await self.downloadAndInstallStaged(to: MeetingNemotronModelLocator.defaultPackageURL(profile: profile),
                                                profile: profile, progress: progress, publication: publication)
    }

    nonisolated static func downloadAndInstallStaged(
        to destination: URL, profile: MeetingNemotronModelProfile = .fast32SplitW8A8,
        progress: @escaping @Sendable (Double) -> Void, publication: MeetingModelPublicationGate
    ) async throws -> MeetingNemotronModelArtifact {
        let staging = destination.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("download-\(profile.cacheVersion)", isDirectory: true)
        let downloader = await HuggingFaceModelDownloader(
            owner: Self.repositoryOwner,
            repo: Self.repositoryName,
            revision: Self.repositoryRevision,
            requiredItems: Self.requiredDownloadItems(for: profile)
        )
        try await downloader.ensureModelsPresent(at: staging) { fraction, _ in progress(fraction) }
        return try await self.publishStaged(from: staging, to: destination, profile: profile, publication: publication)
    }

    nonisolated static func userMessage(for error: Error) -> String {
        // A meeting attempt started while the files were transferring: the download is fine and the
        // retry reuses it. Show the coordinator's existing retriable message.
        if let busy = error as? MeetingModelResidencyError, case .busy = busy { return busy.localizedDescription }
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

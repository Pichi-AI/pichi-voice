import AppKit
import Combine
import Foundation
import PromiseKit

enum SimpleUpdateError: Error, LocalizedError {
    case invalidURL
    case distributionNotConfigured
    case invalidResponse
    case jsonDecoding
    case noSuitableRelease
    case noAsset
    case releaseChanged
    case updateAlreadyInProgress
    case downloadFailed
    case unzipFailed
    case notAnAppBundle
    case codesignMismatch
    case backupFailed
    case installedAppChanged
    case rollbackUnavailable
    case rollbackRestoreFailed
    case activeWork
    case stagingCleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .activeWork: return PichiLocalization.text("Finish the current recording, transcription, microphone preview, or voice model operation, then try installing again.")
        case let .stagingCleanupFailed(path): return "The previous update could not be cleaned up. Retained staging: \(path)."
        case .invalidURL: return "Invalid URL."
        case .distributionNotConfigured: return "Signed app updates are not configured for this distribution. Install a reviewed build manually."
        case .invalidResponse: return "Invalid HTTP response from GitHub."
        case .jsonDecoding: return "The data couldn’t be read because it isn’t in the correct format."
        case .noSuitableRelease: return "No suitable release found."
        case .releaseChanged: return "A different update is now available. Please review it before installing."
        case .noAsset: return "No matching asset found in the latest release."
        case .updateAlreadyInProgress: return "An update is already being installed."
        case .downloadFailed: return "Failed to download update."
        case .unzipFailed: return "Failed to extract the update archive."
        case .notAnAppBundle: return "Extracted content does not contain an app bundle."
        case .codesignMismatch: return "Downloaded app’s code signature does not match current app."
        case .backupFailed: return "The current app could not be backed up. Nothing was replaced."
        case .installedAppChanged: return AppBrand.text("The installed app changed. Restart FluidVoice before trying the update again.")
        case .rollbackUnavailable: return "No rollback backup is available."
        case .rollbackRestoreFailed: return "Failed to restore a previous version."
        }
    }
}

@MainActor
final class UpdateOperationGate {
    nonisolated deinit {}
    private(set) var isActive = false
    private(set) var commitStarted = false
    private var terminationAllowed = true
    private var terminationWaiters: [CheckedContinuation<Void, Never>] = []

    func begin() -> Bool {
        guard !self.isActive else { return false }
        self.isActive = true
        self.commitStarted = false
        self.terminationAllowed = false
        return true
    }

    func beginCommit() -> Bool {
        guard self.isActive, !self.commitStarted else { return false }
        self.commitStarted = true
        return true
    }

    func finish() {
        self.isActive = false
        self.allowTermination()
    }

    func allowTermination() {
        self.terminationAllowed = true
        let waiters = self.terminationWaiters
        self.terminationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitForTermination() async {
        guard self.isActive, !self.terminationAllowed else { return }
        await withCheckedContinuation { self.terminationWaiters.append($0) }
    }
}

nonisolated struct GHRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let browser_download_url: URL
        let content_type: String
        let size: Int64?
        let digest: String?
    }

    let tag_name: String
    let prerelease: Bool
    private let draftValue: Bool?
    var draft: Bool { draftValue ?? false }

    enum CodingKeys: String, CodingKey {
        case tag_name, prerelease, assets, body, name, published_at, html_url
        case draftValue = "draft"
    }
    let assets: [Asset]
    let body: String?
    let name: String?
    let published_at: String?
    let html_url: URL?
}

private struct SemanticVersion: Comparable {
    enum Identifier: Equatable {
        case numeric(Int)
        case string(String)
    }

    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [Identifier]
    var build: Int = 0

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // Stable release has higher precedence than prerelease for same core version.
        if lhs.prerelease.isEmpty && rhs.prerelease.isEmpty { return lhs.build < rhs.build }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }

        let count = min(lhs.prerelease.count, rhs.prerelease.count)
        for index in 0..<count {
            let left = lhs.prerelease[index]
            let right = rhs.prerelease[index]
            if left == right { continue }

            switch (left, right) {
            case let (.numeric(a), .numeric(b)):
                return a < b
            case (.numeric, .string):
                return true
            case (.string, .numeric):
                return false
            case let (.string(a), .string(b)):
                return a < b
            }
        }

        // If all compared identifiers are equal, shorter prerelease has lower precedence.
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

@MainActor
final class SimpleUpdater: ObservableObject {
    // Explicitly nonisolated: on macOS 15.4+ the synthesized main-actor deinit can abort until the OS runtime has the fix (swiftlang/swift#88036).
    nonisolated deinit {}

    struct ReleaseBuildOption {
        let version: String
        let url: URL
        var displayVersion: String {
            guard let identity = UpdateReleaseSelection.pichiVersion(version) else { return version }
            // Historical releases share a marketing version; keep their build
            // visible only in this diagnostic rollback picker.
            if let build = identity.build { return "\(identity.version) (\(build))" }
            return String(version.dropFirst())
        }
    }

    struct ReleaseNote: Codable, Hashable {
        let version: String
        let title: String
        let notes: String
        let publishedAt: Date?
        let url: URL?
        let isPrerelease: Bool
    }

    static let shared = SimpleUpdater()
    init(
        session: URLSession = .shared,
        defaults: UserDefaults = .standard,
        promptPresenter: UpdatePromptPresenter = .shared,
        operationGate: UpdateOperationGate? = nil,
        installationAdmission: @escaping @MainActor () throws -> (@MainActor () -> Void) = {
            try SimpleUpdater.reserveInstallation(using: AppServices.shared.asr)
        }
    ) {
        self.updateSession = session
        self.updateDefaults = defaults
        self.updatePrompts = promptPresenter
        self.updateOperationGate = operationGate ?? UpdateOperationGate()
        self.installationAdmission = installationAdmission
    }

    @Published private(set) var availableUpdateVersion: String?
    @Published private(set) var isCheckingForUpdates = false
    @Published private(set) var isUpdateInProgress = false
    enum DownloadState: Equatable {
        case idle, downloading(String), ready(String), failed(String)
    }
    @Published private(set) var downloadState: DownloadState = .idle
    @Published private(set) var canCancelUpdate = false
    private let installationAdmission: @MainActor () throws -> (@MainActor () -> Void)
    private var releaseInstallationAdmission: (@MainActor () -> Void)?
    private var selectedRelease: UpdateReleaseSelection?
    private var downloadSelection: UpdateReleaseSelection?
    private var downloadTask: Task<StagedDownload, Error>?
    private var downloadObserver: Task<Void, Never>?
    private var downloadGeneration = UUID()
    private var installTask: Task<Void, Never>?
    private var cancellationRequested = false
    private var failedInstallation: PreparedInstallation?
    private var previousSelections: [String: UpdateReleaseSelection] = [:]
    private var previousSelectionsRevision: Int?
    private var stagedDownload: StagedDownload?
    private var downloadCleanup: Task<[URL: Bool], Never>?
    private struct StagedDownload: Sendable {
        let selection: UpdateReleaseSelection
        let root: URL
        let app: URL
        let workspace: UpdateDownload.Workspace
    }
    #if DEBUG
    /// External staging/security boundary only. Release selection and operation ownership stay real.
    var stageDownloadForTesting: (@Sendable (URL, URL, UpdateReleaseSelection) throws -> URL)?
    var installStagedForTesting: (@MainActor (URL, UpdateReleaseSelection) async throws -> Void)?
    var downloadTemporaryDirectoryForTesting: URL?
    var currentVersionForTesting: String?
    var currentBuildForTesting: String?
    var currentBundleInformationForTesting: [String: Any]?
    #endif
    private let updateSession: URLSession
    private let updateDefaults: UserDefaults
    private let updatePrompts: UpdatePromptPresenter
    private var checkTask: Task<Void, Never>?
    private var checkID: UUID?
    private var checkIsExplicit = false
    private var checkChannelRevision: Int?
    private var availableChannelRevision: Int?
    #if DEBUG
    var simulationInstallHandler: (@MainActor () async throws -> Void)?
    var simulationHasUpdate = true
    // URLProtocol fixtures can verify upstream update UI without enabling a distribution feed.
    var updatesEnabledForTesting: Bool?
    #endif

    private var appUpdatesEnabled: Bool {
        #if DEBUG
        self.updatesEnabledForTesting ?? AppBrand.updatesEnabled
        #else
        AppBrand.updatesEnabled
        #endif
    }

    private var betaChannel: Bool {
        self.updateDefaults.bool(forKey: SettingsStore.UpdateKeys.betaReleasesEnabled)
    }

    private var channelRevision: Int {
        self.updateDefaults.integer(forKey: SettingsStore.UpdateKeys.channelPreferenceRevision)
    }

    private var popupRevision: Int {
        self.updateDefaults.integer(forKey: SettingsStore.UpdateKeys.popupPreferenceRevision)
    }

    private var popupsEnabled: Bool {
        self.updateDefaults.object(forKey: SettingsStore.UpdateKeys.showUpdatePopups) as? Bool ?? true
    }

    private let fileManager = FileManager.default
    private let maxRollbackBackups = 3
    private let rollbackBackupDirectoryName = "RollbackBackups"
    private let updateOperationGate: UpdateOperationGate
    private var updateStatusWindow: NSWindow?

    private var installedAppName: String {
        return Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
    }

    private var currentAppVersion: String {
        #if DEBUG
        if let currentVersionForTesting { return currentVersionForTesting }
        #endif
        return self.currentBundleInformation["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private var currentAppBuild: String {
        #if DEBUG
        if let currentBuildForTesting { return currentBuildForTesting }
        #endif
        return self.currentBundleInformation["CFBundleVersion"] as? String ?? ""
    }

    private var currentBundleInformation: [String: Any] {
        #if DEBUG
        if let currentBundleInformationForTesting { return currentBundleInformationForTesting }
        #endif
        return Bundle.main.infoDictionary ?? [:]
    }

    private var currentComparableVersion: String { "v\(self.currentAppVersion)+\(self.currentAppBuild)-public.1" }
    private func installedSemanticVersion() throws -> SemanticVersion {
        var value = self.isPichiDistribution ? self.currentComparableVersion : self.currentAppVersion
        // Unknown installed build metadata must fail closed, never compare as build zero.
        if self.isPichiDistribution {
            guard UpdateReleaseSelection.pichiVersion(value) != nil else { throw SimpleUpdateError.noSuitableRelease }
            if let rawTag = self.currentBundleInformation["AppReleaseTag"] {
                guard let tag = rawTag as? String else { throw SimpleUpdateError.noSuitableRelease }
                if !tag.isEmpty {
                    guard let identity = UpdateReleaseSelection.pichiVersion(tag), identity.version == self.currentAppVersion,
                          identity.build.map({ $0 == self.currentAppBuild }) ?? true else { throw SimpleUpdateError.noSuitableRelease }
                    value = tag
                }
            }
        }
        guard let version = self.parseSemanticVersion(value) else { throw SimpleUpdateError.noSuitableRelease }
        return version
    }

    private var isPichiDistribution: Bool {
        AppBrand.repositoryOwner == "Pichi-AI" && AppBrand.repositoryName == "pichi-voice"
    }

    func hasRollbackBackup() -> Bool {
        return self.latestRollbackBackup() != nil
    }

    func latestRollbackVersion() -> String? {
        guard let latest = self.latestRollbackBackup() else { return nil }
        return self.versionString(for: latest)
    }

    func rollbackToLatestBackup(expectedVersion: String? = nil) async throws {
        guard self.updateOperationGate.begin() else {
            throw SimpleUpdateError.updateAlreadyInProgress
        }

        self.cancellationRequested = false
        self.isUpdateInProgress = true
        self.canCancelUpdate = true
        self.cancelUpdateCheck()
        self.availableUpdateVersion = nil
        self.availableChannelRevision = nil
        self.updatePrompts.dismissUpdateOffers()
        var shouldKeepOperationActive = false
        defer {
            if !shouldKeepOperationActive {
                self.resetUpdateOperation()
            }
        }

        guard let rollbackBundleURL = self.latestRollbackBackup() else {
            throw SimpleUpdateError.rollbackUnavailable
        }

        if let expectedVersion, self.versionString(for: rollbackBundleURL) != expectedVersion {
            throw SimpleUpdateError.releaseChanged
        }
        do {
            try await self.performSwapAndRelaunch(
                installedAppURL: Bundle.main.bundleURL,
                downloadedAppURL: rollbackBundleURL,
                expectedVersion: Bundle(url: rollbackBundleURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                expectedBuild: Bundle(url: rollbackBundleURL)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                isRollback: true
            )
            DebugLogger.shared.info(
                "SimpleUpdater: Rolled back to \(rollbackBundleURL.lastPathComponent)",
                source: "SimpleUpdater"
            )
            shouldKeepOperationActive = true
        } catch {
            throw error
        }
    }

    /// Explicit user-selected downgrade. Re-fetch the tag so a stale picker never installs another release.
    func installPreviousRelease(version: String) async throws {
        guard self.appUpdatesEnabled else { throw SimpleUpdateError.distributionNotConfigured }
        let approvedRevision = self.previousSelectionsRevision ?? self.channelRevision
        guard approvedRevision == self.channelRevision else { throw SimpleUpdateError.releaseChanged }
        guard self.updateOperationGate.begin() else { throw SimpleUpdateError.updateAlreadyInProgress }
        self.cancellationRequested = false
        self.isUpdateInProgress = true
        self.canCancelUpdate = true
        self.cancelUpdateCheck()
        self.updatePrompts.dismissUpdateOffers()
        var installed = false
        defer {
            if !installed { self.resetUpdateOperation() }
        }
        let releases = try await self.fetchReleases(owner: AppBrand.repositoryOwner, repo: AppBrand.repositoryName)
        let current = try self.installedSemanticVersion()
        guard let release = releases.first(where: { $0.tag_name == version }),
              let target = self.parseSemanticVersion(version),
              target < current, self.releaseArchiveAsset(release, repo: AppBrand.repositoryName) != nil
        else { throw SimpleUpdateError.noSuitableRelease }
        guard approvedRevision == self.channelRevision else { throw SimpleUpdateError.releaseChanged }
        if let approved = self.previousSelections[version], self.selection(for: release, repo: AppBrand.repositoryName) != approved {
            throw SimpleUpdateError.releaseChanged
        }
        try Task.checkCancellation()
        #if DEBUG
        if let simulationInstallHandler {
            try await simulationInstallHandler()
            return
        }
        #endif
        try await self.installReleaseArchive(release, repo: AppBrand.repositoryName)
        installed = true
    }

    func fetchRecentReleaseBuildOptions(
        owner: String,
        repo: String,
        limit: Int = 3,
        includePrerelease: Bool = false,
        olderThanCurrent: Bool = false
    ) async throws -> [ReleaseBuildOption] {
        let releases = try await self.fetchReleases(owner: owner, repo: repo)
        let count = max(1, limit)
        let candidates = self.sortedCandidateReleases(
            releases,
            includePrerelease: includePrerelease
        ).filter { entry in
            guard olderThanCurrent else { return true }
            guard let current = try? self.installedSemanticVersion(),
                  let target = self.parseSemanticVersion(entry.release.tag_name)
            else { return false }
            return target < current && self.releaseArchiveAsset(entry.release, repo: repo) != nil
        }.prefix(count)

        if olderThanCurrent {
            self.previousSelectionsRevision = self.channelRevision
            self.previousSelections = candidates.reduce(into: [:]) { selections, entry in
                if selections[entry.release.tag_name] == nil {
                    selections[entry.release.tag_name] = self.selection(for: entry.release, repo: repo)
                }
            }
        }
        return candidates.map { entry in
            let release = entry.release
            let zipAsset = self.releaseArchiveAsset(release, repo: repo)
            let fallbackTagURL = URL(string: "https://github.com/\(owner)/\(repo)/releases/tag/\(release.tag_name)")
            let fallbackReleasesURL = URL(string: "https://github.com/\(owner)/\(repo)/releases")
            let url = zipAsset?.browser_download_url ??
                release.html_url ??
                fallbackTagURL ??
                fallbackReleasesURL ??
                URL(fileURLWithPath: "/")
            return ReleaseBuildOption(version: release.tag_name, url: url)
        }
    }

    func fetchRecentReleaseNotes(
        owner: String,
        repo: String,
        limit: Int = 6,
        includePrerelease: Bool = false
    ) async throws -> [ReleaseNote] {
        let releases = try await self.fetchReleases(owner: owner, repo: repo)
        let count = max(1, limit)

        return self.sortedCandidateReleases(
            releases,
            includePrerelease: includePrerelease
        )
        .prefix(count)
        .map { entry in
            let release = entry.release
            return ReleaseNote(
                version: self.selection(for: release, repo: repo)?.displayVersion ?? release.tag_name,
                title: (release.name == release.tag_name ? nil : Self.nonEmpty(release.name))
                    ?? self.selection(for: release, repo: repo)?.displayVersion ?? release.tag_name,
                notes: Self.nonEmpty(release.body) ?? "No release notes available.",
                publishedAt: Self.parseGitHubDate(release.published_at),
                url: release.html_url,
                isPrerelease: release.prerelease
            )
        }
    }

    // Allowed Apple Developer Team IDs for code-sign validation
    // No additional signing teams are approved for this downstream distribution.
    private nonisolated static var allowedTeamIDs: Set<String> {
        Set([AppBrand.distribution.expectedSigningTeam].compactMap { $0 })
    }

    private static let githubDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let githubFractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func parseGitHubDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return self.githubDateFormatter.date(from: value) ??
            self.githubFractionalDateFormatter.date(from: value)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // Fetch latest release notes from GitHub
    func fetchLatestReleaseNotes(
        owner: String,
        repo: String,
        includePrerelease: Bool = false
    ) async throws -> (version: String, notes: String) {
        let releases = try await self.fetchReleases(owner: owner, repo: repo)

        guard let latest = self.selectLatestRelease(
            from: releases,
            includePrerelease: includePrerelease
        ) else {
            throw SimpleUpdateError.noSuitableRelease
        }

        let version = self.selection(for: latest, repo: repo)?.displayVersion ?? latest.tag_name
        let notes = latest.body ?? "No release notes available."

        return (version, notes)
    }

    // Silent check that returns update info without showing alerts or installing
    func checkForUpdate(
        owner: String,
        repo: String,
        includePrerelease: Bool = false
    ) async throws -> (hasUpdate: Bool, latestVersion: String) {
        guard self.appUpdatesEnabled else { throw SimpleUpdateError.distributionNotConfigured }
        guard !self.isUpdateInProgress else {
            throw SimpleUpdateError.updateAlreadyInProgress
        }

        #if DEBUG
        if self === Self.shared, UpdatePromptSimulation.isEnabled {
            return (self.simulationHasUpdate, "Simulation")
        }
        #endif

        let releases = try await self.fetchReleases(owner: owner, repo: repo)

        guard let latest = self.selectLatestRelease(
            from: releases,
            includePrerelease: includePrerelease
        ) else {
            throw SimpleUpdateError.noSuitableRelease
        }

        let current = try self.installedSemanticVersion()
        let latestTag = latest.tag_name
        guard let latestVersion = self.parseSemanticVersion(latestTag) else {
            throw SimpleUpdateError.noSuitableRelease
        }

        let selection = self.selection(for: latest, repo: repo)
        let next = latestVersion > current ? selection : nil
        if self.selectedRelease != next { self.invalidateDownload() }
        self.selectedRelease = next
        return (latestVersion > current, selection?.displayVersion ?? latestTag)
    }

    func checkForUpdatesAutomatically() {
        guard self.appUpdatesEnabled else { return }
        guard self.updateDefaults.object(forKey: SettingsStore.UpdateKeys.autoUpdateCheckEnabled) as? Bool ?? true else { return }
        self.startUpdateCheck(explicit: false)
    }

    func checkForUpdatesManually() {
        self.startUpdateCheck(explicit: true)
    }

    func showAvailableUpdate() {
        guard !self.isUpdateInProgress,
              let version = self.availableUpdateVersion,
              self.availableChannelRevision == self.channelRevision
        else { return }
        self.presentUpdateOffer(version: version, automatic: false)
    }

    func automaticUpdatePopupPreferenceDidChange(isEnabled _: Bool) {
        // The callback may arrive after another toggle. Read the current preference.
        if !self.popupsEnabled { self.updatePrompts.dismissAutomaticUpdateOffers() }
    }

    func updateChannelDidChange() {
        let revision = self.channelRevision
        if self.checkID != nil, self.checkChannelRevision != revision { self.cancelUpdateCheck() }
        if self.availableChannelRevision != revision {
            self.selectedRelease = nil
            self.invalidateDownload()
            if self.canCancelUpdate { self.cancellationRequested = true; self.installTask?.cancel() }
            self.availableUpdateVersion = nil
            self.availableChannelRevision = nil
            self.updatePrompts.dismissUpdateOffers()
        }
    }

    private func startUpdateCheck(explicit: Bool) {
        guard !self.isUpdateInProgress else { return }
        if explicit { self.updatePrompts.dismissUpdateCheckResults() }
        self.updateChannelDidChange()
        if self.checkID != nil {
            self.checkIsExplicit = self.checkIsExplicit || explicit
            return
        }
        let requestID = UUID()
        let channel = self.betaChannel
        let channelRevision = self.channelRevision
        let popupRevision = self.popupRevision
        self.checkID = requestID
        self.checkChannelRevision = channelRevision
        self.checkIsExplicit = explicit
        self.isCheckingForUpdates = true
        self.checkTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.checkID == requestID { self.cancelUpdateCheck() }
            }
            do {
                let result = try await self.checkForUpdate(owner: AppBrand.repositoryOwner, repo: AppBrand.repositoryName, includePrerelease: channel)
                guard self.checkID == requestID, self.channelRevision == channelRevision, !self.isUpdateInProgress else { return }
                self.recordUpdateCheckDate()
                self.availableChannelRevision = channelRevision
                self.availableUpdateVersion = result.hasUpdate ? result.latestVersion : nil
                if result.hasUpdate {
                    if self.automaticDownloadsEnabled { self.startAutomaticDownload() }
                    if self.checkIsExplicit {
                        self.presentUpdateOffer(version: result.latestVersion, automatic: false)
                    } else if self.popupsEnabled, self.popupRevision == popupRevision,
                              self.updateDefaults.object(forKey: SettingsStore.UpdateKeys.autoUpdateCheckEnabled) as? Bool ?? true,
                              self.shouldShowUpdateOffer(version: result.latestVersion)
                    {
                        self.presentUpdateOffer(version: result.latestVersion, automatic: true)
                    }
                } else {
                    self.updatePrompts.dismissUpdateOffers()
                    if self.checkIsExplicit {
                        self.showUpdateCheckResult(title: channel ? "No Beta Updates" : "No Updates", message: AppBrand.text("You're already running the latest available version of FluidVoice."))
                    }
                }
            } catch {
                guard self.checkID == requestID, self.channelRevision == channelRevision, !self.isUpdateInProgress else { return }
                self.recordUpdateCheckDate()
                self.availableUpdateVersion = nil
                self.availableChannelRevision = nil
                self.selectedRelease = nil
                self.invalidateDownload()
                self.updatePrompts.dismissUpdateOffers()
                if self.checkIsExplicit {
                    self.showUpdateCheckResult(title: "Update Check Failed", message: "Unable to check for updates. Please try again later.\n\nError: \(error.localizedDescription)")
                } else {
                    DebugLogger.shared.debug("Automatic update check failed: \(error.localizedDescription)", source: "SimpleUpdater")
                }
            }
        }
    }

    private func recordUpdateCheckDate() {
        #if DEBUG
        if self === Self.shared, UpdatePromptSimulation.isEnabled { return }
        #endif
        self.updateDefaults.set(Date(), forKey: SettingsStore.UpdateKeys.lastUpdateCheckDate)
    }

    private func cancelUpdateCheck() {
        self.checkID = nil
        self.checkChannelRevision = nil
        self.checkTask?.cancel()
        self.checkTask = nil
        self.isCheckingForUpdates = false
        self.checkIsExplicit = false
    }

    private func shouldShowUpdateOffer(version: String) -> Bool {
        if let snoozed = self.updateDefaults.string(forKey: SettingsStore.UpdateKeys.snoozedUpdateVersion), snoozed != version { return true }
        guard let until = self.updateDefaults.object(forKey: SettingsStore.UpdateKeys.updatePromptSnoozedUntil) as? Date else { return true }
        return Date() >= until
    }

    private func presentUpdateOffer(version: String, automatic: Bool) {
        let channel = self.betaChannel
        let revision = self.channelRevision
        self.updatePrompts.presentFloatingPrompt(
            title: "Update Available",
            message: AppBrand.text("FluidVoice \(version) is now available. The app will restart automatically after installation."),
            actions: [
                FloatingPromptAction(title: "Install Now") { [weak self] in
                    guard let self, self.availableUpdateVersion == version, self.channelRevision == revision, !self.isUpdateInProgress else { return }
                    self.installApprovedUpdate(version: version, channel: channel)
                },
                FloatingPromptAction(title: "Later") { [weak self] in
                    guard let self, self.availableUpdateVersion == version, self.channelRevision == revision else { return }
                    #if DEBUG
                    if self === Self.shared, UpdatePromptSimulation.isEnabled { return }
                    #endif
                    self.updateDefaults.set(version, forKey: SettingsStore.UpdateKeys.snoozedUpdateVersion)
                    self.updateDefaults.set(Date().addingTimeInterval(24 * 60 * 60), forKey: SettingsStore.UpdateKeys.updatePromptSnoozedUntil)
                },
            ],
            isAutomaticUpdateOffer: automatic
        )
    }

    private func installApprovedUpdate(version: String, channel: Bool) {
        let approvedRevision = self.channelRevision
        self.installTask = Task {
            defer { self.installTask = nil }
            do {
                try await self.checkAndUpdate(owner: AppBrand.repositoryOwner, repo: AppBrand.repositoryName, includePrerelease: channel, expectedVersion: version)
            } catch SimpleUpdateError.releaseChanged {
                if self.availableUpdateVersion != nil, self.availableChannelRevision == self.channelRevision {
                    self.showAvailableUpdate()
                } else {
                    self.checkForUpdatesManually()
                }
            } catch SimpleUpdateError.updateAlreadyInProgress {
                return
            } catch is CancellationError {
                if self.channelRevision != approvedRevision { self.checkForUpdatesManually() }
                return
            } catch {
                if Task.isCancelled || self.cancellationRequested || (error as? URLError)?.code == .cancelled {
                    if self.channelRevision != approvedRevision { self.checkForUpdatesManually() }
                    return
                }
                let cancelled = (error as? PMKError)?.isCancelled == true
                self.showUpdateCheckResult(
                    title: cancelled ? "No Updates" : "Update Failed",
                    message: cancelled ? AppBrand.text("You're already running the latest available version of FluidVoice.")
                        : "Unable to install the update. Please try again later.\n\nError: \(error.localizedDescription)"
                )
            }
        }
    }

    private func showUpdateCheckResult(title: String, message: String) {
        self.updatePrompts.presentFloatingPrompt(title: title, message: message, actions: [FloatingPromptAction(title: "OK") {}])
    }

    func checkAndUpdate(
        owner: String,
        repo: String,
        includePrerelease: Bool = false,
        expectedVersion: String? = nil
    ) async throws {
        guard self.appUpdatesEnabled else { throw SimpleUpdateError.distributionNotConfigured }
        guard self.updateOperationGate.begin() else {
            throw SimpleUpdateError.updateAlreadyInProgress
        }

        let approvedSelection = self.selectedRelease
        let approvedChannelRevision = self.channelRevision
        self.cancellationRequested = false
        self.isUpdateInProgress = true
        self.canCancelUpdate = true
        self.cancelUpdateCheck()
        self.updatePrompts.dismissUpdateOffers()
        var shouldKeepOperationActive = false
        defer {
            if !shouldKeepOperationActive {
                self.resetUpdateOperation()
            }
        }

        #if DEBUG
        if self === Self.shared, UpdatePromptSimulation.isEnabled {
            self.showUpdateInstallStatus(version: "Simulation")
            shouldKeepOperationActive = true
            return
        }
        #endif

        let releases = try await self.fetchReleases(owner: owner, repo: repo)

        guard let latest = self.selectLatestRelease(
            from: releases,
            includePrerelease: includePrerelease
        ) else {
            throw SimpleUpdateError.noSuitableRelease
        }

        let current = try self.installedSemanticVersion()
        let latestTag = latest.tag_name
        guard let latestVersion = self.parseSemanticVersion(latestTag) else {
            throw SimpleUpdateError.noSuitableRelease
        }

        // up to date
        if !(latestVersion > current) {
            self.availableUpdateVersion = nil
            self.availableChannelRevision = nil
            throw PMKError.cancelled // mimic AppUpdater semantics for up-to-date
        }

        if expectedVersion != nil, self.channelRevision != approvedChannelRevision {
            self.availableUpdateVersion = nil
            self.availableChannelRevision = nil
            throw SimpleUpdateError.releaseChanged
        }
        let selection = self.selection(for: latest, repo: repo)
        if let expectedVersion, (expectedVersion != selection?.displayVersion && expectedVersion != latestTag)
            || (approvedSelection != nil && approvedSelection != selection) {
            self.availableChannelRevision = self.channelRevision
            self.availableUpdateVersion = selection?.displayVersion ?? latestTag
            self.selectedRelease = selection
            self.invalidateDownload()
            throw SimpleUpdateError.releaseChanged
        }
        if expectedVersion != nil, self.betaChannel != includePrerelease {
            throw SimpleUpdateError.releaseChanged
        }
        self.updateDefaults.removeObject(forKey: SettingsStore.UpdateKeys.updatePromptSnoozedUntil)
        self.updateDefaults.removeObject(forKey: SettingsStore.UpdateKeys.snoozedUpdateVersion)
        #if DEBUG
        if let simulationInstallHandler {
            try await simulationInstallHandler()
            return
        }
        #endif

        try await self.installReleaseArchive(latest, repo: repo)
        shouldKeepOperationActive = true
    }

    private func selection(for release: GHRelease, repo: String) -> UpdateReleaseSelection? {
        if self.isPichiDistribution {
            return UpdateReleaseSelection.pichi(release, owner: AppBrand.repositoryOwner, repo: repo)
        }
        guard let asset = self.releaseArchiveAsset(release, repo: repo) else { return nil }
        return UpdateReleaseSelection(tag: release.tag_name,
            version: release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name,
            build: nil, assetName: asset.name, assetURL: asset.browser_download_url, digest: asset.digest)
    }

    private func releaseArchiveAsset(_ release: GHRelease, repo: String) -> GHRelease.Asset? {
        if self.isPichiDistribution {
            guard repo == AppBrand.repositoryName,
                  let selection = UpdateReleaseSelection.pichi(release, owner: AppBrand.repositoryOwner, repo: repo) else { return nil }
            return release.assets.first { $0.name == selection.assetName && $0.browser_download_url == selection.assetURL }
        }
        // Find asset matching: "{repo-lower}-{version-from-tag}.*" and zip preferred
        let rawVersion = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        let prefix = "\(repo.lowercased())-\(rawVersion)"
        return release.assets.first { asset in
            let base = (asset.name as NSString).deletingPathExtension.lowercased()
            return (base == prefix) &&
                (asset.content_type == "application/zip" || asset.content_type == "application/x-zip-compressed")
        } ?? release.assets.first { asset in
            let base = (asset.name as NSString).deletingPathExtension.lowercased()
            return base == prefix
        }
    }

    private func installReleaseArchive(_ release: GHRelease, repo: String) async throws {
        guard let selection = self.selection(for: release, repo: repo) else { throw SimpleUpdateError.noAsset }
        self.showUpdateInstallStatus(version: selection.displayVersion)
        self.canCancelUpdate = true
        let revision = self.channelRevision
        let staged = try await self.verifiedDownload(for: selection)
        try Task.checkCancellation()
        guard revision == self.channelRevision else { throw SimpleUpdateError.releaseChanged }
        guard !self.cancellationRequested else { throw CancellationError() }
        self.releaseInstallationAdmission = try self.acquireInstallationAdmission()
        #if DEBUG
        if let installStagedForTesting {
            defer { self.resetUpdateOperation() }
            try await installStagedForTesting(staged.app, selection)
            return
        }
        #endif
        try await self.performSwapAndRelaunch(
            installedAppURL: Bundle.main.bundleURL, downloadedAppURL: staged.app,
            expectedVersion: selection.version, expectedBuild: selection.build,
            expectedReleaseTag: selection.expectedBundleReleaseTag, isRollback: false
        )
    }

    // MARK: - Helpers

    func showUpdateInstallStatus(version: String) {
        self.updatePrompts.dismissAll()
        guard self.updateStatusWindow == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 164),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.title = AppBrand.text("Installing FluidVoice \(version)")
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        content.material = .popover
        content.blendingMode = .behindWindow
        content.state = .active
        content.maskImage = .roundedRectMask(cornerRadius: 16)
        content.autoresizingMask = [.width, .height]

        let icon = NSImageView(frame: NSRect(x: 22, y: 74, width: 52, height: 52))
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(icon)

        let title = NSTextField(labelWithString: AppBrand.text("Installing FluidVoice \(version)"))
        title.frame = NSRect(x: 92, y: 108, width: 304, height: 24)
        title.font = .fluidSystemFont(ofSize: 16, weight: .semibold)
        content.addSubview(title)

        let detail = NSTextField(wrappingLabelWithString: AppBrand.text("Downloading the update. FluidVoice will restart automatically."))
        detail.frame = NSRect(x: 92, y: 74, width: 304, height: 34)
        detail.font = .fluidSystemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        content.addSubview(detail)

        let progress = NSProgressIndicator(frame: NSRect(x: 92, y: 56, width: 304, height: 6))
        progress.style = .bar
        progress.isIndeterminate = true
        progress.controlSize = .small
        progress.startAnimation(nil)
        content.addSubview(progress)

        let cancel = UpdateCancelButton { [weak self] in
            Task { await self?.cancelPendingUpdate() }
        }
        cancel.frame = NSRect(x: 300, y: 12, width: 96, height: 28)
        content.addSubview(cancel)
        panel.contentView = content
        panel.center()
        panel.orderFrontRegardless()
        self.updateStatusWindow = panel
    }

    #if DEBUG
    func finishSimulatedUpdate() {
        guard UpdatePromptSimulation.isEnabled else { return }
        self.resetUpdateOperation()
    }
    #endif

    private func resetUpdateOperation() {
        self.releaseInstallationAdmission?()
        self.releaseInstallationAdmission = nil
        self.canCancelUpdate = false
        self.updateOperationGate.finish()
        self.isUpdateInProgress = false
        self.dismissUpdateInstallStatus()
    }

    func dismissUpdateInstallStatus() {
        self.updateStatusWindow?.orderOut(nil)
        self.updateStatusWindow?.close()
        self.updateStatusWindow = nil
    }

    private func fetchReleases(owner: String, repo: String) async throws -> [GHRelease] {
        guard owner == AppBrand.repositoryOwner, repo == AppBrand.repositoryName else { throw SimpleUpdateError.invalidURL }
        var releases: [GHRelease] = []
        // Runtime/source publications can share the repository. Search a bounded
        // number of pages rather than assuming GitHub's first entry is an app.
        for page in 1...5 {
            guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=100&page=\(page)") else { throw SimpleUpdateError.invalidURL }
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let data = try await UpdateDownload.metadata(request, session: self.updateSession)
            try Task.checkCancellation()
            let entries: [GHRelease]
            do { entries = try JSONDecoder().decode([GHRelease].self, from: data) }
            catch { throw SimpleUpdateError.jsonDecoding }
            releases.append(contentsOf: entries)
            if entries.count < 100 { break }
        }
        return releases
    }

    private func selectLatestRelease(from releases: [GHRelease], includePrerelease: Bool) -> GHRelease? {
        return self.sortedCandidateReleases(releases, includePrerelease: includePrerelease).first?.release
    }

    private func sortedCandidateReleases(
        _ releases: [GHRelease],
        includePrerelease: Bool
    ) -> [(release: GHRelease, version: SemanticVersion)] {
        return releases
            .compactMap { release in
                guard !release.draft,
                      !self.isPichiDistribution || self.selection(for: release, repo: AppBrand.repositoryName) != nil,
                      let version = self.parseSemanticVersion(release.tag_name) else {
                    return nil
                }
                let isPrerelease = self.isPrereleaseRelease(release)
                if !includePrerelease, isPrerelease {
                    return nil
                }
                return (release, version)
            }
            .sorted { lhs, rhs in
                if lhs.version != rhs.version {
                    return lhs.version > rhs.version
                }

                // Tie-break with publish date when tags map to same semantic version.
                let lhsPublished = lhs.release.published_at ?? ""
                let rhsPublished = rhs.release.published_at ?? ""
                return lhsPublished > rhsPublished
            }
    }

    private func isPrereleaseRelease(_ release: GHRelease) -> Bool {
        return release.prerelease || release.tag_name.contains("-beta.") || self.hasPrereleaseSuffix(in: release.tag_name)
    }

    private func hasPrereleaseSuffix(in version: String) -> Bool {
        var trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }
        if let plusIndex = trimmed.firstIndex(of: "+") {
            trimmed = String(trimmed[..<plusIndex])
        }

        guard let hyphenIndex = trimmed.firstIndex(of: "-") else {
            return false
        }

        let suffix = trimmed[trimmed.index(after: hyphenIndex)...]
        return suffix.isEmpty == false
    }

    private func rollbackRootDirectory() -> URL {
        let base = self.fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let support = base ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support
            .appendingPathComponent(AppBrand.storageNamespace, isDirectory: true)
            .appendingPathComponent(self.rollbackBackupDirectoryName, isDirectory: true)
            .appendingPathComponent(self.installedAppName, isDirectory: true)
    }

    private func availableRollbackBackups() -> [URL] {
        let backupDir = self.rollbackRootDirectory()
        guard self.fileManager.fileExists(atPath: backupDir.path) else { return [] }

        let urls: [URL]
        do {
            urls = try self.fileManager.contentsOfDirectory(
                at: backupDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return []
        }

        return Self.sortedRollbackBackups(urls.filter { $0.pathExtension == "app" }) { url in
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
    }

    private func latestRollbackBackup() -> URL? {
        let currentVersion = "\(self.currentAppVersion) (\(self.currentAppBuild))"
        return self.availableRollbackBackups().first {
            Self.isRollbackVersion(self.versionString(for: $0), differentFrom: currentVersion)
        }
    }

    private func versionString(for appURL: URL) -> String? {
        guard let bundle = Bundle(url: appURL) else { return nil }
        guard let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
              let build = bundle.infoDictionary?["CFBundleVersion"] as? String else { return nil }
        return "\(version) (\(build))"
    }

    private func sanitizeVersion(_ version: String) -> String {
        return version
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private func pruneRollbackBackups(preserving protectedURLs: Set<URL>) async {
        let root = self.rollbackRootDirectory()
        let limit = self.maxRollbackBackups
        let warnings = await Task.detached(priority: .utility) {
            let manager = FileManager.default
            guard let urls = try? manager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return [String]() }
            let backups = Self.sortedRollbackBackups(urls.filter { $0.pathExtension == "app" }) {
                (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }
            var retained = Set(backups.filter { protectedURLs.contains($0) })
            for backup in backups where retained.count < limit {
                retained.insert(backup)
            }
            var failures = [String]()
            for backup in backups where !retained.contains(backup) {
                do {
                    try manager.removeItem(at: backup)
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            return failures
        }.value
        for warning in warnings {
            DebugLogger.shared.warning("SimpleUpdater: Rollback cleanup failed: \(warning)", source: "SimpleUpdater")
        }
    }

    nonisolated static func sortedRollbackBackups(
        _ urls: [URL],
        modificationDate: (URL) -> Date?
    ) -> [URL] {
        return urls
            .compactMap { url -> (URL, Date)? in
                guard let createdAt = self.rollbackBackupCreationDate(
                    from: url,
                    fallbackModificationDate: modificationDate(url)
                ) else {
                    return nil
                }
                return (url, createdAt)
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }

    static func isRollbackVersion(_ version: String?, differentFrom currentVersion: String) -> Bool {
        guard let version else { return false }
        return version != currentVersion
    }

    private nonisolated static func rollbackBackupCreationDate(
        from url: URL,
        fallbackModificationDate: Date?
    ) -> Date? {
        if let timestamp = self.rollbackBackupTimestamp(from: url) {
            return Date(timeIntervalSince1970: timestamp)
        }

        return fallbackModificationDate
    }

    private nonisolated static func rollbackBackupTimestamp(from url: URL) -> TimeInterval? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let suffix = name.split(separator: "-").last,
              let timestamp = TimeInterval(suffix)
        else {
            return nil
        }

        return timestamp
    }

    private func parseSemanticVersion(_ version: String) -> SemanticVersion? {
        var trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }

        let pichiBuild = UpdateReleaseSelection.pichiVersion(version).flatMap { $0.build }.flatMap(Int.init) ?? 0
        // Upstream semantic metadata has no precedence; Pichi numeric builds do.
        if let plusIndex = trimmed.firstIndex(of: "+") {
            trimmed = String(trimmed[..<plusIndex])
        }

        let components = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard !components.isEmpty else { return nil }

        let coreComponents = components[0].split(separator: ".", omittingEmptySubsequences: false)
        guard coreComponents.count >= 2 else { return nil }
        guard let major = Int(coreComponents[0]), let minor = Int(coreComponents[1]) else { return nil }
        let patch: Int
        if coreComponents.count >= 3 {
            guard let parsedPatch = Int(coreComponents[2]) else { return nil }
            patch = parsedPatch
        } else {
            patch = 0
        }

        let prereleaseIdentifiers: [SemanticVersion.Identifier]
        if components.count > 1 {
            prereleaseIdentifiers = components[1]
                .split(separator: ".", omittingEmptySubsequences: false)
                .map { identifier in
                    if let numeric = Int(identifier) {
                        return .numeric(numeric)
                    }
                    return .string(identifier.lowercased())
                }
        } else {
            prereleaseIdentifiers = []
        }

        return SemanticVersion(
            major: major,
            minor: minor,
            patch: patch,
            prerelease: prereleaseIdentifiers,
            build: pichiBuild
        )
    }

    nonisolated struct PreparedInstallation: Sendable {
        let replacement: UpdateAppReplacement
        let backupURL: URL
    }

    /// Runs under the replacement's process-shared lock on a background task.
    nonisolated static func prepareValidatedInstallation(
        installedAppURL: URL,
        downloadedAppURL: URL,
        installedExpectation: UpdateBundleValidator.Expectation,
        expectedVersion: String?,
        expectedBuild: String? = nil,
        expectedReleaseTag: String? = nil,
        backupURL: URL,
        isRollback: Bool,
        commit: Bool = true,
        validateBundle: @escaping @Sendable (URL, UpdateBundleValidator.Expectation, UpdateBundleValidator.SigningPolicy) throws -> UpdateBundleValidator.ValidatedBundle = {
            try UpdateBundleValidator.validate(at: $0, expectation: $1, policy: $2)
        }
    ) throws -> PreparedInstallation {
        let teams = Self.allowedTeamIDs
        guard isRollback || expectedVersion != nil, installedExpectation.version != nil, installedExpectation.build != nil
        else { throw UpdateBundleValidator.ValidationError.invalidExpectation }
        try Task.checkCancellation()
        let replacement = try UpdateAppReplacement.prepare(
            installedAppURL: installedAppURL,
            replacementAppURL: downloadedAppURL,
            validateInstalledApp: { url in
                do {
                    _ = try validateBundle(url, installedExpectation, .installedApp(allowedTeamIDs: teams))
                } catch UpdateBundleValidator.ValidationError.versionMismatch {
                    throw SimpleUpdateError.installedAppChanged
                } catch UpdateBundleValidator.ValidationError.buildMismatch {
                    throw SimpleUpdateError.installedAppChanged
                }
            }
        )
        var backupCreated = false
        do {
            try Task.checkCancellation()
            _ = try validateBundle(replacement.stagedAppURL,
                .init(bundleIdentifier: installedExpectation.bundleIdentifier, version: expectedVersion, build: expectedBuild,
                      releaseTag: expectedReleaseTag),
                isRollback ? .installedApp(allowedTeamIDs: teams) : .developerID(allowedTeamIDs: teams))
            do {
                try UpdateRollbackBackup.create(installedAppURL: installedAppURL, backupURL: backupURL) { url in
                    _ = try validateBundle(url, installedExpectation, .installedApp(allowedTeamIDs: teams))
                }
                backupCreated = true
            } catch let failure as UpdateRollbackBackup.Failure where failure.retainedDirectoryURL != nil {
                throw failure
            } catch {
                throw SimpleUpdateError.backupFailed
            }
            try Task.checkCancellation()
            if commit { try replacement.commit() }
            return PreparedInstallation(replacement: replacement, backupURL: backupURL)
        } catch {
            let originalError = error
            // A failed atomic exchange leaves the installed app untouched. The owned
            // duplicate backup is unnecessary until the exchange succeeds.
            var backupCleanupFailure: Error?
            if backupCreated {
                do {
                    try FileManager.default.removeItem(at: backupURL)
                } catch {
                    backupCleanupFailure = UpdateAppReplacement.Failure(
                        operation: .cleanup, recoveryDirectoryURL: backupURL, underlyingError: error
                    )
                }
            }
            do {
                try replacement.discardPrepared()
            } catch {
                throw error
            }
            if let backupCleanupFailure { throw backupCleanupFailure }
            throw originalError
        }
    }

    /// Reuse the existing conservative admission barrier, including preview,
    /// draining capture and failed-ASR meeting leases, without stopping any owner.
    static func reserveInstallation(using service: ASRService) throws -> (@MainActor () -> Void) {
        guard !service.isDictionaryTrainingCaptureActive else { throw SimpleUpdateError.activeWork }
        do {
            let lease = try service.beginSettingsBackupRestore()
            return { service.releaseExclusiveActivity(lease) }
        } catch is ASRActivityError { throw SimpleUpdateError.activeWork }
    }

    private func acquireInstallationAdmission() throws -> (@MainActor () -> Void) {
        do { return try self.installationAdmission() }
        catch is ASRActivityError { throw SimpleUpdateError.activeWork }
    }

    private func performSwapAndRelaunch(
        installedAppURL: URL,
        downloadedAppURL: URL,
        expectedVersion: String?,
        expectedBuild: String? = nil,
        expectedReleaseTag: String? = nil,
        isRollback: Bool
    ) async throws {
        guard let identifier = Bundle.main.bundleIdentifier,
              let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        else { throw SimpleUpdateError.notAnAppBundle }
        if self.releaseInstallationAdmission == nil {
            self.releaseInstallationAdmission = try self.acquireInstallationAdmission()
        }
        try Task.checkCancellation()
        let version = self.currentAppVersion
        let name = self.installedAppName
        let safeVersion = self.sanitizeVersion("\(version)-\(build)")
        let suffix = "\(isRollback ? "rollback-" : "")\(UUID().uuidString)-\(Int(Date().timeIntervalSince1970))"
        let backupURL = self.rollbackRootDirectory().appendingPathComponent("\(name)-\(safeVersion)-\(suffix).app")
        let preparation = Task.detached(priority: .utility) {
            try Self.prepareValidatedInstallation(
                installedAppURL: installedAppURL,
                downloadedAppURL: downloadedAppURL,
                installedExpectation: .init(bundleIdentifier: identifier, version: version, build: build),
                expectedVersion: expectedVersion,
                expectedBuild: expectedBuild,
                expectedReleaseTag: expectedReleaseTag,
                backupURL: backupURL,
                isRollback: isRollback,
                commit: false
            )
        }
        let installation = try await withTaskCancellationHandler {
            try await preparation.value
        } onCancel: {
            preparation.cancel()
        }

        do {
            // No suspension between the final cancellation decision and closing
            // admission to Cancel. The filesystem exchange itself is indivisible.
            try Task.checkCancellation()
            guard !self.cancellationRequested else { throw CancellationError() }
            guard self.updateOperationGate.beginCommit() else { throw SimpleUpdateError.updateAlreadyInProgress }
            self.canCancelUpdate = false
            self.updateStatusWindow?.contentView?.subviews.compactMap { $0 as? UpdateCancelButton }.forEach { $0.isEnabled = false }
            try await Task.detached(priority: .utility) { try installation.replacement.commit() }.value
        } catch {
            let original = error
            try await Task.detached(priority: .utility) {
                try installation.replacement.discardPrepared()
                try FileManager.default.removeItem(at: installation.backupURL)
            }.value
            throw original
        }
        self.canCancelUpdate = false
        await self.discardDownload()
        self.downloadState = .idle
        self.availableUpdateVersion = nil
        self.availableChannelRevision = nil
        self.dismissUpdateInstallStatus()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: installedAppURL, configuration: configuration) { application, error in
            Task { @MainActor in
                guard error == nil, let application else {
                    await self.recoverFailedRelaunch(installation, error: error)
                    return
                }
                // Keep the outgoing app and shared lock through the existing startup
                // grace period; a newly launched process must not start another swap.
                try? await Task.sleep(for: .seconds(2))
                guard !application.isTerminated else {
                    await self.recoverFailedRelaunch(installation, error: nil)
                    return
                }
                // Keep the shared lock while pruning so another process cannot
                // create a backup that this operation mistakes for an old one.
                var protected: Set<URL> = [installation.backupURL]
                if isRollback { protected.insert(downloadedAppURL) }
                await self.pruneRollbackBackups(preserving: protected)
                guard !application.isTerminated else {
                    await self.recoverFailedRelaunch(installation, error: nil)
                    return
                }
                let cleanupWarning = await Task.detached(priority: .utility) {
                    do {
                        try installation.replacement.finalize()
                        return String?.none
                    } catch {
                        return error.localizedDescription
                    }
                }.value
                if let cleanupWarning {
                    DebugLogger.shared.warning("SimpleUpdater: Update completed; cleanup failed: \(cleanupWarning)", source: "SimpleUpdater")
                }
                self.updateOperationGate.allowTermination()
                UpdateTerminationScheduler.requestTermination()
            }
        }
    }

    private func recoverFailedRelaunch(_ installation: PreparedInstallation, error: Error?) async {
        let recoveryWarning = await Task.detached(priority: .utility) {
            do {
                try installation.replacement.recover()
                return String?.none
            } catch {
                return error.localizedDescription
            }
        }.value
        if recoveryWarning == nil {
            self.failedInstallation = nil
            self.resetUpdateOperation()
        } else {
            // Keep the admission lease and filesystem lock when restoration fails.
            // The old process must not resume capture with an unresolved replacement.
            self.failedInstallation = installation
            self.canCancelUpdate = false
            self.dismissUpdateInstallStatus()
        }
        if let error {
            DebugLogger.shared.error("SimpleUpdater: Relaunch failed: \(error.localizedDescription)", source: "SimpleUpdater")
        }
        if let recoveryWarning {
            DebugLogger.shared.error("SimpleUpdater: Recovery failed; saved app at \(installation.backupURL.path): \(recoveryWarning)", source: "SimpleUpdater")
        }
        self.showUpdateCheckResult(
            title: "Update Failed",
            message: recoveryWarning == nil
                ? "The new app could not start. Your previous version has been restored. Please try again."
                : "The app could not restart. Your previous version is saved at \(installation.backupURL.path)."
        )
        self.updateOperationGate.allowTermination()
    }
}

extension SimpleUpdater {
    private var automaticDownloadsEnabled: Bool {
        self.updateDefaults.object(forKey: SettingsStore.UpdateKeys.automaticUpdateDownloads) as? Bool ?? true
    }

    func automaticDownloadPreferenceDidChange() {
        if self.canCancelUpdate { self.cancellationRequested = true; self.installTask?.cancel() }
        self.invalidateDownload()
        if self.automaticDownloadsEnabled { self.startAutomaticDownload() }
    }

    private func startAutomaticDownload() {
        guard let selection = self.selectedRelease, self.automaticDownloadsEnabled, !self.isUpdateInProgress else { return }
        #if DEBUG
        // Legacy popup tests substitute the entire install. Download lifecycle tests
        // substitute only extraction and trust, and still use the real transport.
        if self.simulationInstallHandler != nil { return }
        #endif
        if self.downloadSelection == selection,
           (self.stagedDownload != nil || (self.downloadTask != nil && self.downloadTask?.isCancelled == false)) { return }
        self.downloadObserver = Task { [weak self] in
            guard let self else { return }
            do { _ = try await self.verifiedDownload(for: selection) }
            catch is CancellationError {}
            catch { DebugLogger.shared.debug("Update download failed: \(error.localizedDescription)", source: "SimpleUpdater") }
        }
    }

    /// Invalidate synchronously; the next download and explicit cancellation join
    /// the old worker before deleting its files or allocating another staging root.
    private func invalidateDownload() {
        self.downloadGeneration = UUID()
        self.downloadTask?.cancel()
        self.downloadObserver?.cancel()
        self.downloadState = .idle
        _ = self.retireDownload()
    }

    func cancelPendingUpdate() async {
        if self.updateOperationGate.isActive && self.updateOperationGate.commitStarted { return }
        self.cancellationRequested = true
        self.installTask?.cancel()
        if self.releaseInstallationAdmission == nil {
            self.invalidateDownload()
            let retained = await self.discardDownload()
            if !retained.isEmpty { self.downloadState = .failed(SimpleUpdateError.stagingCleanupFailed(retained.map(\.path).sorted().joined(separator: ", ")).localizedDescription) }
        }
        await self.updateOperationGate.waitForTermination()
    }

    /// Normal quit joins background transport/staging before AppKit exits.
    /// A committed replacement keeps ownership until its relaunch callback finishes.
    func shutdownForTermination() async {
        let check = self.checkTask
        self.cancelUpdateCheck()
        await check?.value
        let observer = self.downloadObserver
        await self.cancelPendingUpdate()
        await self.updateOperationGate.waitForTermination()
        await observer?.value
        self.downloadObserver = nil
    }

    @discardableResult
    private func discardDownload() async -> Set<URL> {
        Set(await self.retireDownload().value.keys)
    }

    private func retireDownload() -> Task<[URL: Bool], Never> {
        let oldTask = self.downloadTask
        let oldCache = self.stagedDownload
        self.downloadTask = nil
        self.stagedDownload = nil
        self.downloadSelection = nil
        oldTask?.cancel()
        let previousCleanup = self.downloadCleanup
        let cleanup = Task.detached(priority: .utility) {
            defer { withExtendedLifetime(oldTask) {}; withExtendedLifetime(oldCache) {} }
            var roots = await previousCleanup?.value ?? [:]
            do {
                if let completed = try await oldTask?.value { roots[completed.root] = false }
            } catch let failure as UpdateDMGStager.Failure {
                roots[failure.retainedRoot] = failure.mayBeMounted
            } catch {}
            if let oldCache { roots[oldCache.root] = false }
            var retained: [URL: Bool] = [:]
            for (root, mayBeMounted) in roots {
                // A failed detach needs explicit recovery, never recursive deletion.
                if mayBeMounted { retained[root] = true; continue }
                do { try FileManager.default.removeItem(at: root) }
                catch let error as CocoaError where error.code == .fileNoSuchFile {}
                catch { retained[root] = false }
            }
            return retained
        }
        self.downloadCleanup = cleanup
        return cleanup
    }

    private func verifiedDownload(for selection: UpdateReleaseSelection) async throws -> StagedDownload {
        if self.downloadSelection == selection, let cached = self.stagedDownload { return cached }
        if self.downloadSelection == selection, let task = self.downloadTask, !task.isCancelled {
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        }
        let generation = self.downloadGeneration
        let retained = await self.discardDownload()
        guard retained.isEmpty else { throw SimpleUpdateError.stagingCleanupFailed(retained.map(\.path).sorted().joined(separator: ", ")) }
        try Task.checkCancellation()
        guard generation == self.downloadGeneration else { throw CancellationError() }
        // Another waiter may have started this same release during joined cleanup.
        if self.downloadSelection == selection, let task = self.downloadTask {
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        }
        let session = self.updateSession
        let identifier = Bundle.main.bundleIdentifier ?? ""
        let teams = Self.allowedTeamIDs
        let appName = self.isPichiDistribution ? "Pichi Voice.app" : self.installedAppName + ".app"
        let installationURL = Bundle.main.bundleURL
        let namespace = AppBrand.storageNamespace
        #if DEBUG
        let stageOverride = self.stageDownloadForTesting
        let temporaryDirectory = self.downloadTemporaryDirectoryForTesting ?? FileManager.default.temporaryDirectory
        #endif
        self.downloadSelection = selection
        self.downloadState = .downloading(selection.displayVersion)
        let task = Task.detached(priority: .utility) {
            #if DEBUG
            let workspace = try UpdateDownload.Workspace.open(installation: installationURL, namespace: namespace, temporaryDirectory: temporaryDirectory)
            #else
            let workspace = try UpdateDownload.Workspace.open(installation: installationURL, namespace: namespace)
            #endif
            let root = workspace.directory
            defer { withExtendedLifetime(workspace) {} }
            do {
                let archive = root.appendingPathComponent(selection.assetName)
                try await UpdateDownload.fetch(selection, session: session, to: archive)
                try Task.checkCancellation()
                let app: URL
                #if DEBUG
                if let stageOverride { app = try stageOverride(archive, root, selection) }
                else { app = try Self.stageAndValidate(archive: archive, root: root, appName: appName, selection: selection, identifier: identifier, teams: teams) }
                #else
                app = try Self.stageAndValidate(archive: archive, root: root, appName: appName, selection: selection, identifier: identifier, teams: teams)
                #endif
                try Task.checkCancellation()
                try FileManager.default.removeItem(at: archive)
                return StagedDownload(selection: selection, root: root, app: app, workspace: workspace)
            } catch let error as UpdateDMGStager.Failure {
                // The mount may still be attached. Its retained path is surfaced for recovery.
                throw error
            } catch {
                let original = error
                do { try FileManager.default.removeItem(at: root) }
                catch { throw UpdateDMGStager.Failure(retainedRoot: root, underlying: error, mayBeMounted: false) }
                throw original
            }
        }
        self.downloadTask = task
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard self.downloadGeneration == generation, !Task.isCancelled else {
                await Task.detached { try? FileManager.default.removeItem(at: result.root) }.value
                throw CancellationError()
            }
            self.stagedDownload = result
            self.downloadState = .ready(selection.displayVersion)
            return result
        } catch {
            if self.downloadGeneration == generation {
                self.downloadSelection = nil
                self.downloadState = (error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled) ? .idle : .failed(error.localizedDescription)
            }
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw error
        }
    }

    private nonisolated static func stageAndValidate(
        archive: URL, root: URL, appName: String, selection: UpdateReleaseSelection, identifier: String, teams: Set<String>
    ) throws -> URL {
        let app: URL
        if archive.pathExtension == "dmg" {
            app = try UpdateDMGStager.stage(image: archive, root: root, appName: appName)
        } else {
            let extraction = root.appendingPathComponent("extracted", isDirectory: true)
            try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: false)
            try UpdateDMGStager.run("/usr/bin/ditto", ["-x", "-k", archive.path, extraction.path], root, true)
            let apps = try FileManager.default.contentsOfDirectory(at: extraction, includingPropertiesForKeys: nil).filter { $0.pathExtension == "app" }
            guard apps.count == 1, let only = apps.first else { throw SimpleUpdateError.notAnAppBundle }
            app = only
        }
        _ = try UpdateBundleValidator.validate(at: app,
            expectation: .init(bundleIdentifier: identifier, version: selection.version, build: selection.build,
                               releaseTag: selection.expectedBundleReleaseTag),
            policy: .developerID(allowedTeamIDs: teams))
        return app
    }
}

/// A native status-window button shares the same action as Settings cancellation.
@MainActor
final class UpdateCancelButton: NSButton {
    var cancelUpdate: (@MainActor () -> Void)?
    convenience init(cancel: @escaping @MainActor () -> Void) {
        self.init(title: PichiLocalization.text("Cancel"), target: nil, action: #selector(cancelClicked))
        self.target = self
        self.cancelUpdate = cancel
        self.setAccessibilityIdentifier("updater.cancel")
    }
    @objc private func cancelClicked() { self.cancelUpdate?() }
}

import Foundation

/// Typed API for low-volume analytics.
final class AnalyticsService {
    static let shared = AnalyticsService()

    private let detailedConsentGate: DetailedAnalyticsConsentGate
    private let core: AnalyticsCore
    private var suspended = false
    private var submissions: [UUID: Task<Void, Never>] = [:]

    private init() {
        let detailedConsentGate = DetailedAnalyticsConsentGate()
        self.detailedConsentGate = detailedConsentGate
        self.core = AnalyticsCore(detailedConsentGate: detailedConsentGate)
    }

    func bootstrap() {
        self.submit { core, context in
            await core.bootstrap(context: context)
        }
    }

    func setDetailedAnalyticsEnabled(_ enabled: Bool) {
        let consentGeneration = self.detailedConsentGate.advance()
        let context = Self.context(
            detailedAnalyticsEnabled: enabled,
            detailedConsentGeneration: consentGeneration
        )
        guard !self.suspended, context.profile.isReadable else { return }
        self.enqueue(context: context) { core, context in
            await core.setDetailedAnalyticsEnabled(context: context)
        }
    }

    /// Records one active-user event per local day.
    func recordAppActivity() {
        self.submit { core, context in
            await core.recordActivity(.app, context: context)
        }
    }

    /// Counts accepted usage and attempted AI requests.
    func recordUsage(
        mode: AnalyticsUsageMode,
        transcriptionModel: AnalyticsModelDescriptor? = nil,
        aiModel: AnalyticsModelDescriptor? = nil
    ) {
        self.submit { core, context in
            await core.recordUsage(
                mode: mode,
                transcriptionModel: transcriptionModel,
                aiModel: aiModel,
                context: context
            )
        }
    }

    func recordModelUsage(
        role: AnalyticsModelRole,
        mode: AnalyticsUsageMode,
        descriptor: AnalyticsModelDescriptor
    ) {
        self.submit { core, context in
            await core.recordModelUsage(role: role, mode: mode, descriptor: descriptor, context: context)
        }
    }

    /// Beta builds aggregate Fluid Intelligence throughput locally and emit one summary per day.
    func recordBetaDictationPerformance(
        fluidModel: AnalyticsFluidIntelligenceModel?,
        tokensPerSecond: Double?
    ) {
        self.submit { core, context in
            await core.recordBetaDictationPerformance(
                fluidModel: fluidModel,
                tokensPerSecond: tokensPerSecond,
                context: context
            )
        }
    }

    func recordInsertionLatency(
        path: AnalyticsInsertionPath,
        outcome: AnalyticsInsertionOutcome,
        requestMilliseconds: Int,
        readyMilliseconds: Int?,
        toggleStopMilliseconds: Int?
    ) {
        self.submit { core, context in
            await core.recordInsertionLatency(
                path: path,
                outcome: outcome,
                requestMilliseconds: requestMilliseconds,
                readyMilliseconds: readyMilliseconds,
                toggleStopMilliseconds: toggleStopMilliseconds,
                context: context
            )
        }
    }

    func recordOnboardingStarted(origin: AnalyticsOnboardingOrigin) {
        self.submit { core, context in
            await core.recordOnboardingStarted(origin: origin, context: context)
        }
    }

    func recordOnboardingStepViewed(_ step: AnalyticsOnboardingStep, origin: AnalyticsOnboardingOrigin) {
        self.submit { core, context in
            await core.recordOnboardingStepViewed(step, origin: origin, context: context)
        }
    }

    func recordOnboardingStepCompleted(
        _ step: AnalyticsOnboardingStep,
        outcome: AnalyticsOnboardingOutcome,
        origin: AnalyticsOnboardingOrigin,
        completesFlow: Bool = false
    ) {
        self.submit { core, context in
            await core.recordOnboardingStepCompleted(
                step,
                outcome: outcome,
                origin: origin,
                completesFlow: completesFlow,
                context: context
            )
        }
    }

    func recordOnboardingTryoutAttemptStarted(startMethod: AnalyticsOnboardingTryoutStartMethod) {
        let origin = SettingsStore.shared.analyticsOnboardingOrigin
        self.submit { core, context in
            await core.recordOnboardingTryoutAttemptStarted(
                startMethod: startMethod,
                origin: origin,
                context: context
            )
        }
    }

    func recordOnboardingTryoutAttemptResult(
        outcome: AnalyticsOnboardingTryoutOutcome,
        failureStage: AnalyticsOnboardingTryoutFailureStage? = nil
    ) {
        let origin = SettingsStore.shared.analyticsOnboardingOrigin
        self.submit { core, context in
            await core.recordOnboardingTryoutAttemptResult(
                outcome: outcome,
                failureStage: failureStage,
                origin: origin,
                context: context
            )
        }
    }

    func finishOnboardingTryout(
        outcome: AnalyticsOnboardingTryoutOutcome,
        failureStage: AnalyticsOnboardingTryoutFailureStage? = nil
    ) {
        let origin = SettingsStore.shared.analyticsOnboardingOrigin
        self.submit { core, context in
            await core.finishOnboardingTryout(
                outcome: outcome,
                failureStage: failureStage,
                origin: origin,
                context: context
            )
        }
    }

    func skipOnboardingTryout(origin: AnalyticsOnboardingOrigin) {
        self.submit { core, context in
            await core.skipOnboardingTryout(origin: origin, context: context)
        }
    }

    func recordModelDownloadStarted(
        id: UUID,
        descriptor: AnalyticsModelDescriptor,
        source: AnalyticsModelDownloadSource
    ) {
        self.submit { core, context in
            await core.recordModelDownloadStarted(
                id: id.uuidString.lowercased(),
                descriptor: descriptor,
                source: source,
                context: context
            )
        }
    }

    func recordModelDownloadFinished(
        id: UUID,
        descriptor: AnalyticsModelDescriptor,
        source: AnalyticsModelDownloadSource,
        outcome: AnalyticsModelDownloadOutcome,
        duration: TimeInterval?
    ) {
        self.submit { core, context in
            await core.recordModelDownloadFinished(
                id: id.uuidString.lowercased(),
                descriptor: descriptor,
                source: source,
                outcome: outcome,
                duration: duration,
                context: context
            )
        }
    }

    private func submit(
        _ operation: @escaping @Sendable (AnalyticsCore, AnalyticsContext) async -> Void
    ) {
        let context = Self.context(
            detailedAnalyticsEnabled: SettingsStore.shared.shareDetailedAnalytics,
            detailedConsentGeneration: self.detailedConsentGate.currentGeneration
        )
        guard !self.suspended, context.profile.isReadable else { return }
        self.enqueue(context: context, operation: operation)
    }

    private func enqueue(context: AnalyticsContext,
                         operation: @escaping @Sendable (AnalyticsCore, AnalyticsContext) async -> Void) {
        let id = UUID()
        self.submissions[id] = Task(priority: .background) { [weak self, core] in
            defer { self?.submissions[id] = nil }
            guard !Task.isCancelled else { return }
            await operation(core, context)
        }
    }

    /// Cancel and join the transport and every admitted local write before releasing its DB.
    /// Legacy guest databases are retained in place and never copied to the next profile.
    func suspendForProfileTransition() async {
        self.suspended = true
        _ = self.detailedConsentGate.advance()
        let tasks = Array(self.submissions.values)
        for task in tasks { task.cancel() }
        await self.core.suspendForProfileTransition()
        for task in tasks { await task.value }
    }

    func activateCurrentProfile() { self.suspended = false }

    private static func context(
        detailedAnalyticsEnabled: Bool,
        detailedConsentGeneration: UInt64
    ) -> AnalyticsContext {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        return AnalyticsContext(
            profile: PrivateProfileStorage.current,
            detailedAnalyticsEnabled: detailedAnalyticsEnabled,
            detailedConsentGeneration: detailedConsentGeneration,
            config: AnalyticsConfig.fromBundle(),
            distinctID: AnalyticsIdentityStore.shared.anonymousInstallID,
            appVersion: version,
            collectsBetaPerformance: AnalyticsBuildPolicy
                .automaticallyCollectsDictationPerformance(appVersion: version)
        )
    }
}

private struct AnalyticsContext: Sendable {
    let profile: PrivateProfileSnapshot
    let detailedAnalyticsEnabled: Bool
    let detailedConsentGeneration: UInt64
    let config: AnalyticsConfig
    let distinctID: String
    let appVersion: String
    let collectsBetaPerformance: Bool
}

final nonisolated class DetailedAnalyticsConsentGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    var currentGeneration: UInt64 {
        self.lock.withLock { self.generation }
    }

    func advance() -> UInt64 {
        self.lock.withLock {
            self.generation &+= 1
            return self.generation
        }
    }

    func accepts(_ generation: UInt64) -> Bool {
        self.lock.withLock { generation == self.generation }
    }
}

private actor AnalyticsCore {
    private var context: AnalyticsContext?
    private let detailedConsentGate: DetailedAnalyticsConsentGate
    private var database: AnalyticsDatabase?
    private var databaseProfile: PrivateProfileSnapshot?
    private var retiredFlushTasks: [Task<Void, Never>] = []
    private var flushTask: Task<Void, Never>?
    private var activeUploadTask: Task<Int, Error>?
    private var isFlushing = false

    private let batchSize = 50

    init(detailedConsentGate: DetailedAnalyticsConsentGate) {
        self.detailedConsentGate = detailedConsentGate
    }

    func suspendForProfileTransition() async {
        self.stopFlushLoop()
        let retired = self.retiredFlushTasks
        self.retiredFlushTasks.removeAll()
        let uploadTask = self.activeUploadTask
        uploadTask?.cancel()
        if let uploadTask { _ = try? await uploadTask.value }
        for task in retired { await task.value }
        self.activeUploadTask = nil
        self.database = nil
        self.databaseProfile = nil
        self.context = nil
    }

    private func accepts(_ context: AnalyticsContext) -> Bool {
        let current = PrivateProfileStorage.current
        return current.isReadable && current.id == context.profile.id
            && current.generation == context.profile.generation
            && self.detailedConsentGate.accepts(context.detailedConsentGeneration)
    }

    func bootstrap(context: AnalyticsContext) async {
        guard self.apply(context) else { return }
        do {
            if !context.detailedAnalyticsEnabled {
                try self.purgeStoredDetailedAnalyticsIfPresent(context: context)
            }
            guard context.config.isConfigured else { return }
            let database = try self.database(for: context)
            try database.finalizeDays(before: Date())
            if context.detailedAnalyticsEnabled {
                try database.recoverInterruptedModelDownloads(at: Date())
            }
            self.startFlushLoopIfNeeded()
            await self.flushIfNeeded()
        } catch {
            self.stopFlushLoop()
        }
    }

    func setDetailedAnalyticsEnabled(context: AnalyticsContext) async {
        guard self.apply(context) else { return }
        self.activeUploadTask?.cancel()
        self.stopFlushLoop()
        await self.bootstrap(context: context)
    }

    func recordActivity(_ kind: AnalyticsActivityKind, context: AnalyticsContext) async {
        await self.writeActivity(context: context) { database, date in
            try database.recordActivity(kind, at: date)
        }
    }

    func recordUsage(
        mode: AnalyticsUsageMode,
        transcriptionModel: AnalyticsModelDescriptor?,
        aiModel: AnalyticsModelDescriptor?,
        context: AnalyticsContext
    ) async {
        await self.writeDetailed(context: context, fallbackActivity: .coreAction) { database, date in
            try database.recordUsage(
                mode: mode,
                transcriptionModel: transcriptionModel,
                aiModel: aiModel,
                at: date
            )
        }
    }

    func recordModelUsage(
        role: AnalyticsModelRole,
        mode: AnalyticsUsageMode,
        descriptor: AnalyticsModelDescriptor,
        context: AnalyticsContext
    ) async {
        await self.writeDetailed(context: context, fallbackActivity: .coreAction) { database, date in
            try database.recordModelUsage(role: role, mode: mode, descriptor: descriptor, at: date)
        }
    }

    func recordBetaDictationPerformance(
        fluidModel: AnalyticsFluidIntelligenceModel?,
        tokensPerSecond: Double?,
        context: AnalyticsContext
    ) async {
        guard self.apply(context), context.collectsBetaPerformance,
              context.config.isConfigured
        else { return }
        do {
            let database = try self.database(for: context)
            try database.recordDictationPerformance(
                fluidModel: fluidModel,
                tokensPerSecond: tokensPerSecond,
                measuredAppVersion: context.appVersion,
                at: Date()
            )
            self.startFlushLoopIfNeeded()
        } catch {
            return
        }
    }

    func recordInsertionLatency(
        path: AnalyticsInsertionPath,
        outcome: AnalyticsInsertionOutcome,
        requestMilliseconds: Int,
        readyMilliseconds: Int?,
        toggleStopMilliseconds: Int?,
        context: AnalyticsContext
    ) async {
        await self.writeDetailed(context: context) { database, date in
            try database.recordInsertionLatency(
                path: path,
                outcome: outcome,
                requestMilliseconds: requestMilliseconds,
                readyMilliseconds: readyMilliseconds,
                toggleStopMilliseconds: toggleStopMilliseconds,
                at: date
            )
        }
    }

    func recordOnboardingStarted(origin: AnalyticsOnboardingOrigin, context: AnalyticsContext) async {
        await self.writeDetailed(context: context, fallbackActivity: .app) { database, date in
            try database.recordOnboardingStarted(origin: origin, at: date)
        }
    }

    func recordOnboardingStepViewed(
        _ step: AnalyticsOnboardingStep,
        origin: AnalyticsOnboardingOrigin,
        context: AnalyticsContext
    ) async {
        await self.writeDetailed(context: context) { database, date in
            try database.recordOnboardingStepViewed(step, origin: origin, at: date)
        }
    }

    func recordOnboardingStepCompleted(
        _ step: AnalyticsOnboardingStep,
        outcome: AnalyticsOnboardingOutcome,
        origin: AnalyticsOnboardingOrigin,
        completesFlow: Bool,
        context: AnalyticsContext
    ) async {
        await self.writeDetailed(context: context) { database, date in
            try database.recordOnboardingStepCompleted(
                step,
                outcome: outcome,
                origin: origin,
                completesFlow: completesFlow,
                at: date
            )
        }
    }

    func recordOnboardingTryoutAttemptStarted(
        startMethod: AnalyticsOnboardingTryoutStartMethod,
        origin: AnalyticsOnboardingOrigin,
        context: AnalyticsContext
    ) async {
        await self.writeDetailed(context: context) { database, date in
            try database.recordOnboardingTryoutAttemptStarted(
                startMethod: startMethod,
                origin: origin,
                at: date
            )
        }
    }

    func recordOnboardingTryoutAttemptResult(
        outcome: AnalyticsOnboardingTryoutOutcome,
        failureStage: AnalyticsOnboardingTryoutFailureStage?,
        origin: AnalyticsOnboardingOrigin,
        context: AnalyticsContext
    ) async {
        await self.writeDetailed(context: context) { database, date in
            try database.recordOnboardingTryoutAttemptResult(
                outcome: outcome,
                failureStage: failureStage,
                origin: origin,
                at: date
            )
        }
    }

    func finishOnboardingTryout(
        outcome: AnalyticsOnboardingTryoutOutcome,
        failureStage: AnalyticsOnboardingTryoutFailureStage?,
        origin: AnalyticsOnboardingOrigin,
        context: AnalyticsContext
    ) async {
        await self.writeDetailed(context: context) { database, date in
            try database.finishOnboardingTryout(
                outcome: outcome,
                failureStage: failureStage,
                origin: origin,
                at: date
            )
        }
    }

    func skipOnboardingTryout(origin: AnalyticsOnboardingOrigin, context: AnalyticsContext) async {
        await self.writeDetailed(context: context) { database, date in
            try database.skipOnboardingTryout(origin: origin, at: date)
        }
    }

    func recordModelDownloadStarted(
        id: String,
        descriptor: AnalyticsModelDescriptor,
        source: AnalyticsModelDownloadSource,
        context: AnalyticsContext
    ) async {
        await self.writeDetailed(context: context, fallbackActivity: .coreAction) { database, date in
            try database.recordModelDownloadStarted(id: id, descriptor: descriptor, source: source, at: date)
        }
    }

    func recordModelDownloadFinished(
        id: String,
        descriptor: AnalyticsModelDescriptor,
        source: AnalyticsModelDownloadSource,
        outcome: AnalyticsModelDownloadOutcome,
        duration: TimeInterval?,
        context: AnalyticsContext
    ) async {
        await self.writeDetailed(context: context) { database, date in
            try database.recordModelDownloadFinished(
                id: id,
                descriptor: descriptor,
                source: source,
                outcome: outcome,
                duration: duration,
                at: date
            )
        }
    }

    private func writeActivity(
        context: AnalyticsContext,
        operation: (AnalyticsDatabase, Date) throws -> Void
    ) async {
        guard self.apply(context), context.config.isConfigured else { return }
        do {
            let database = try self.database(for: context)
            try operation(database, Date())
            self.startFlushLoopIfNeeded()
        } catch {
            return
        }
    }

    private func writeDetailed(
        context: AnalyticsContext,
        fallbackActivity: AnalyticsActivityKind? = nil,
        operation: (AnalyticsDatabase, Date) throws -> Void
    ) async {
        guard self.apply(context), context.config.isConfigured else { return }
        let mayRecordDetails = context.detailedAnalyticsEnabled
        guard mayRecordDetails || fallbackActivity != nil else { return }
        do {
            let database = try self.database(for: context)
            let date = Date()
            if mayRecordDetails {
                try operation(database, date)
            } else if let fallbackActivity {
                try database.recordActivity(fallbackActivity, at: date)
            }
            self.startFlushLoopIfNeeded()
        } catch {
            return
        }
    }

    private func apply(_ context: AnalyticsContext) -> Bool {
        guard self.accepts(context) else { return false }
        self.context = context
        return true
    }

    private func database(for context: AnalyticsContext) throws -> AnalyticsDatabase {
        guard self.accepts(context) else { throw CancellationError() }
        if let database {
            guard self.databaseProfile == context.profile else { throw CancellationError() }
            return database
        }
        let url = self.databaseURL(profile: context.profile)
        let database = try AnalyticsDatabase(
            url: url,
            distinctID: context.distinctID,
            appVersion: context.appVersion
        )
        self.database = database
        self.databaseProfile = context.profile
        return database
    }

    private func databaseURL(profile: PrivateProfileSnapshot) -> URL {
        profile.directory("Analytics").appendingPathComponent("analytics-v2.sqlite3")
    }

    private func purgeStoredDetailedAnalyticsIfPresent(context: AnalyticsContext) throws {
        if let database {
            guard self.databaseProfile == context.profile else { throw CancellationError() }
            try database.purgeDetailedAnalytics()
            return
        }
        let url = self.databaseURL(profile: context.profile)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let existingDatabase = try AnalyticsDatabase(
            url: url,
            distinctID: context.distinctID,
            appVersion: context.appVersion
        )
        try existingDatabase.purgeDetailedAnalytics()
    }

    private func startFlushLoopIfNeeded() {
        guard self.flushTask == nil,
              let context,
              self.accepts(context),
              context.config.isConfigured
        else { return }
        self.flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await self?.flushIfNeeded()
            }
        }
    }

    private func stopFlushLoop() {
        if let task = self.flushTask {
            task.cancel()
            self.retiredFlushTasks.append(task)
        }
        self.flushTask = nil
    }

    private func flushIfNeeded() async {
        guard !self.isFlushing,
              let context,
              self.accepts(context),
              context.config.isConfigured,
              let database
        else { return }

        self.isFlushing = true
        defer {
            self.activeUploadTask = nil
            self.isFlushing = false
        }

        let items: [AnalyticsOutboxItem]
        do {
            try database.finalizeDays(before: Date())
            items = try database.readyOutbox(limit: self.batchSize, at: Date())
        } catch {
            return
        }
        guard !items.isEmpty else { return }
        guard self.accepts(context) else { return }

        let ids = items.map(\.id)
        let uploadTask = Task {
            guard self.accepts(context) else {
                throw CancellationError()
            }
            return try await self.send(items: items, config: context.config)
        }
        self.activeUploadTask = uploadTask

        let status: Int
        do {
            status = try await uploadTask.value
        } catch {
            guard self.accepts(context) else { return }
            try? database.retry(ids: ids, at: Date())
            return
        }
        guard self.accepts(context) else { return }

        switch status {
        case 200..<300:
            try? database.acknowledgeUploaded(ids: ids, at: Date())
        case 408, 429, 500...599:
            try? database.retry(ids: ids, at: Date())
        default:
            try? database.discardPermanently(ids: ids)
        }
    }

    private func send(items: [AnalyticsOutboxItem], config: AnalyticsConfig) async throws -> Int {
        try await AnalyticsUploadTransport.send(items: items, config: config)
    }
}

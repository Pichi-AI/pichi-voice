import Combine
import Foundation

@main @MainActor struct FileOperationIsolationTests {
    static var checks = 0
    static var domains: [String] = []
    static var manifest: URL!
    static var root: URL!
    static func expect(_ value: Bool, _ message: String) {
        checks += 1
        precondition(value, message)
    }
    static func recordDomain(_ domain: String) throws {
        if !domains.contains(domain) { domains.append(domain) }
        try JSONEncoder().encode(domains).write(to: manifest, options: .atomic)
    }
    static func fixtureDefaults() throws -> UserDefaults {
        let name = "synthetic.file-operation.\(UUID())"
        try recordDomain(name)
        return UserDefaults(suiteName: name)!
    }
    static func account(_ name: String) throws -> PrivateProfileSnapshot {
        let nonce = UUID().uuidString
        let generation = UUID()
        let context = AccountContext(identity: .init(issuer: "https://synthetic.invalid", subject: name + nonce,
            internalUserID: name + nonce), organizationID: "org", workspaceID: "workspace", generation: generation)
        let profile = try PrivateProfileStorage.proposed(context: context, generation: generation, legacyRootDirectory: root)
        try recordDomain(AppBrand.storageNamespace + ".private-profile." + profile.id)
        return profile
    }
    static func store(_ profile: PrivateProfileSnapshot) throws -> FileTranscriptionHistoryStore {
        FileTranscriptionHistoryStore(defaults: PrivateProfileDefaults(profile: profile, guestDefaults: try fixtureDefaults()), profile: profile)
    }
    static func main() async throws {
        let original = PrivateProfileStorage.current
        root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        manifest = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            for domain in domains {
                let defaults = UserDefaults(suiteName: domain)!
                defaults.removePersistentDomain(forName: domain)
                precondition(defaults.synchronize())
                precondition(defaults.persistentDomain(forName: domain)?.isEmpty != false)
            }
            PrivateProfileStorage.select(original)
            PrivateProfileStorage.clearStoreCaches()
            PrivateProfileObjectCache.removeAll()
        }
        for path in ["native", "chunk", "speaker"] {
            try await heldCompletion(path: path, partial: false, forceForeign: false, throwsAfterGate: false)
        }
        try await heldCompletion(path: "chunk", partial: true, forceForeign: false, throwsAfterGate: false)
        try await heldCompletion(path: "speaker", partial: true, forceForeign: false, throwsAfterGate: false)
        try await heldCompletion(path: "native", partial: false, forceForeign: true, throwsAfterGate: false)
        try await heldCompletion(path: "native", partial: false, forceForeign: false, throwsAfterGate: true)
        try await visibleCancellation()
        try await explicitCancellationThenConceal()
        try await admittedProviderLifetime(holdPreparation: true)
        try await admittedProviderLifetime(holdPreparation: false)
        try await frozenConfiguration(speaker: false)
        try await frozenConfiguration(speaker: true)
        try await canceledBeforeInference()
        try await pendingHistory(clear: false)
        try await pendingHistory(clear: true)
        try await historyFailureWhileJoining()
        print("PASS: \(checks) actual file-service synthetic orchestration/profile/write assertions; no native decoding or inference")
    }

    static func input(_ name: String, frames: Int64 = 32_000, turns: Int = 1,
                      durationGate: SyntheticFileGate? = nil) -> URL {
        let url = root.appendingPathComponent(name + UUID().uuidString + ".wav")
        SyntheticFileRegistry.shared.set(.init(frames: frames, turns: (0..<turns).map {
            .init(speakerLabel: "Speaker \($0 + 1)", startSeconds: Double($0), endSeconds: Double($0 + 1))
        }, durationGate: durationGate), at: url)
        return url
    }
    static func heldCompletion(path: String, partial: Bool, forceForeign: Bool, throwsAfterGate: Bool) async throws {
        let a = try account("A"), b = try account("B")
        PrivateProfileStorage.select(a)
        SettingsStore.shared.fileTranscriptionSpeakerLabelsEnabled = path == "speaker"
        SettingsStore.shared.fileTranscriptionExpectedSpeakerCount = 2
        let gate = SyntheticFileGate()
        let providerA = SyntheticFileProvider("A-\(path)", native: path == "native", gate: gate, throwsAfterGate: throwsAfterGate)
        let providerB = SyntheticFileProvider("B", native: true)
        let asr = ASRService(provider: providerA)
        let history = try store(a)
        let service = FileTranscriptionService(asrService: asr, historyStore: history)
        let url = input(path, frames: partial && path == "chunk" ? 20 * 60 * 16_000 + 16_000 : 32_000,
                        turns: partial && path == "speaker" ? 2 : 1)
        var hiddenExposures = 0
        let subscription = service.objectWillChange.sink {
            if !PrivateProfileStorage.current.isReadable,
               service.currentFileURL != nil || service.result != nil || service.error != nil || service.progress != 0 {
                hiddenExposures += 1
            }
        }
        let work = Task { try await service.transcribeFile(url) }
        await gate.waitUntilEntered()
        expect(history.admittedWriteCount == 1 && asr.activeLease != nil, "File operation freezes write and ASR ownership before inference")
        PrivateProfileStorage.conceal(generation: UUID())
        expect(service.currentFileURL == nil && service.result == nil && service.error == nil && service.progress == 0,
            "Conceal immediately gates service fields")
        expect(history.entries.isEmpty, "Conceal immediately gates file history")
        var replayed: [FileTranscriptionEntry]?
        let historySubscription = history.entriesPublisher.sink { replayed = $0 }
        expect(replayed?.isEmpty == true, "Concealed history publisher never replays private rows")
        let entered = SyntheticFileSignal(), finished = CompletionFlag()
        let retirement = Task {
            entered.signal()
            try await service.prepareForPrivateProfileTransition()
            await finished.mark()
        }
        // The main actor yields into the retirement method before this read resumes.
        await entered.wait()
        expect(!(await finished.value), "Retirement joins a cancellation-ignoring provider")
        asr.fileTranscriptionProvider = providerB
        if forceForeign { PrivateProfileStorage.select(b) }
        await gate.release()
        do { _ = try await work.value; preconditionFailure("Retired source cannot deliver a result to its caller") }
        catch is CancellationError { checks += 1 }
        try await retirement.value
        expect(asr.activeLease == nil && asr.releases == 1 && history.admittedWriteCount == 0,
            "Completed or canceled source releases its exact lease and write admission")
        expect(hiddenExposures == 0, "Late completion publishes no hidden private service data")
        expect(providerB.calls == 0, "No awaited continuation resolves the replacement provider")
        expect(providerA.calls == 1, "Retirement never starts another chunk or speaker fallback")
        expect(providerA.returnedWhileCanceled, "The held provider actually observes retirement cancellation before returning")
        subscription.cancel(); historySubscription.cancel()
        PrivateProfileStorage.select(b)
        expect(try store(b).entries.isEmpty, "B never receives A file output")
        PrivateProfileStorage.select(a)
        let saved = try store(a).entries
        if !partial && !forceForeign && !throwsAfterGate {
            expect(saved.count == 1 && saved[0].text.contains("A-\(path)"), "A completed output remains durable only in A")
            expect(path != "speaker" || saved[0].speakerSegments.count == 1, "Speaker metadata uses the same A admission")
        } else { expect(saved.isEmpty, "Incomplete, failed or foreign output never commits") }
        expect(service.result == nil && service.error == nil, "Retired service never revives when A is selected again")
        try await history.prepareForProfileTransition()
    }

    static func visibleCancellation() async throws {
        let a = try account("visible-cancel")
        PrivateProfileStorage.select(a)
        SettingsStore.shared.fileTranscriptionSpeakerLabelsEnabled = false
        let gate = SyntheticFileGate(), provider = SyntheticFileProvider("visible-A", native: true, gate: gate)
        let history = try store(a), asr = ASRService(provider: provider)
        let service = FileTranscriptionService(asrService: asr, historyStore: history)
        let url = input("visible")
        let task = Task { try await service.transcribeFile(url) }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        do { _ = try await task.value; preconditionFailure("Caller cancellation must discard late visible output") }
        catch is CancellationError { checks += 1 }
        expect(history.entries.isEmpty && history.admittedWriteCount == 0, "Visible cancellation never stores an ignored-cancellation result")
        _ = try await service.transcribeFile(url)
        expect(history.entries.count == 1, "Visible cancellation does not retire future file operations")
        try await service.prepareForPrivateProfileTransition()
        try await history.prepareForProfileTransition()
    }

    static func explicitCancellationThenConceal() async throws {
        let a = try account("canceled-before-logout")
        PrivateProfileStorage.select(a)
        SettingsStore.shared.fileTranscriptionSpeakerLabelsEnabled = false
        let gate = SyntheticFileGate(), provider = SyntheticFileProvider("canceled-A", native: true, gate: gate)
        let asr = ASRService(provider: provider), history = try store(a)
        let service = FileTranscriptionService(asrService: asr, historyStore: history)
        let task = Task { try await service.transcribeFile(input("canceled-before-logout")) }
        await gate.waitUntilEntered()
        task.cancel()
        PrivateProfileStorage.conceal(generation: UUID())
        let entered = SyntheticFileSignal()
        let retirement = Task { entered.signal(); try await service.prepareForPrivateProfileTransition() }
        await entered.wait()
        await gate.release()
        do { _ = try await task.value; preconditionFailure("Logout cannot revive an explicit caller cancellation") }
        catch is CancellationError { checks += 1 }
        try await retirement.value
        PrivateProfileStorage.select(a)
        expect(try store(a).entries.isEmpty, "An explicitly canceled visible operation stays discarded after logout")
        expect(history.admittedWriteCount == 0 && asr.activeLease == nil, "Cancellation plus conceal releases exact original ownership")
        try await history.prepareForProfileTransition()
    }

    static func frozenConfiguration(speaker: Bool) async throws {
        let a = try account("frozen")
        PrivateProfileStorage.select(a)
        SettingsStore.shared.fileTranscriptionSpeakerLabelsEnabled = speaker
        SettingsStore.shared.fileTranscriptionExpectedSpeakerCount = 2
        let duration = SyntheticFileGate()
        let aProvider = SyntheticFileProvider("frozen-A", native: false)
        let bProvider = SyntheticFileProvider("frozen-B", native: true)
        let asr = ASRService(provider: aProvider), history = try store(a)
        let service = FileTranscriptionService(asrService: asr, historyStore: history)
        let url = input("configuration", frames: speaker ? 32_000 : 20 * 60 * 16_000 + 16_000, durationGate: duration)
        let task = Task { try await service.transcribeFile(url) }
        await duration.waitUntilEntered()
        SettingsStore.shared.fileTranscriptionSpeakerLabelsEnabled = !speaker
        SettingsStore.shared.fileTranscriptionExpectedSpeakerCount = 9
        asr.fileTranscriptionProvider = bProvider
        await duration.release()
        let result = try await task.value
        expect(bProvider.calls == 0 && aProvider.calls == (speaker ? 1 : 2), "Provider and route remain frozen across duration await")
        expect(result.speakerSegments.isEmpty != speaker, "Speaker-label setting remains frozen across duration await")
        if speaker { expect(SyntheticFileRegistry.shared.lastHint == 2, "Expected speaker count remains frozen") }
        try await service.prepareForPrivateProfileTransition()
        try await history.prepareForProfileTransition()
    }

    static func canceledBeforeInference() async throws {
        let a = try account("before-inference")
        PrivateProfileStorage.select(a)
        SettingsStore.shared.fileTranscriptionSpeakerLabelsEnabled = false
        let duration = SyntheticFileGate(), provider = SyntheticFileProvider("before", native: true)
        let asr = ASRService(provider: provider), history = try store(a)
        let service = FileTranscriptionService(asrService: asr, historyStore: history)
        let url = input("before", durationGate: duration)
        let task = Task { try await service.transcribeFile(url) }
        await duration.waitUntilEntered()
        PrivateProfileStorage.conceal(generation: UUID())
        let entered = SyntheticFileSignal()
        let retirement = Task { entered.signal(); try await service.prepareForPrivateProfileTransition() }
        await entered.wait()
        await duration.release()
        do { _ = try await task.value; preconditionFailure("Retirement before inference cannot complete output") }
        catch is CancellationError { checks += 1 }
        try await retirement.value
        expect(provider.calls == 0 && history.admittedWriteCount == 0, "No inference or pending write starts after cancellation")
        try await history.prepareForProfileTransition()
    }

    static func historyFailureWhileJoining() async throws {
        let guest = try PrivateProfileStorage.proposed(context: nil, generation: UUID(), legacyRootDirectory: root)
        PrivateProfileStorage.select(guest)
        let name = "synthetic.file-operation.\(UUID())"
        try recordDomain(name)
        let defaults = FailingFileDefaults(suiteName: name)!
        let bound = PrivateProfileDefaults(profile: guest, guestDefaults: defaults)
        let history = FileTranscriptionHistoryStore(defaults: bound, profile: guest)
        let output = try history.admitWrite()
        let result = TranscriptionResult(id: output.entryID, text: "joined pending output", confidence: 1,
            duration: 1, processingTime: 1, fileName: "synthetic.wav")
        PrivateProfileStorage.conceal(generation: UUID())
        let entered = SyntheticFileSignal(), done = CompletionFlag()
        let retiring = Task { entered.signal(); try await history.prepareForProfileTransition(); await done.mark() }
        await entered.wait()
        expect(!(await done.value), "Store retirement waits for its admitted operation")
        defaults.failSynchronization = true
        do { try history.addEntry(result, admission: output); preconditionFailure("Synthetic commit must fail") }
        catch { checks += 1 }
        output.finish()
        do { try await retiring.value; preconditionFailure("Joined persistence failure must surface without hanging") }
        catch { checks += 1 }
        expect(history.admittedWriteCount == 1, "Failed joined output retains exact retry state")
        defaults.failSynchronization = false
        try await history.prepareForProfileTransition()
        expect(history.admittedWriteCount == 0, "Repair drains the retained file-history write")
    }

    static func pendingHistory(clear: Bool) async throws {
        let guest = try PrivateProfileStorage.proposed(context: nil, generation: UUID(), legacyRootDirectory: root)
        PrivateProfileStorage.select(guest)
        let name = "synthetic.file-operation.\(UUID())"
        try recordDomain(name)
        let defaults = FailingFileDefaults(suiteName: name)!
        let bound = PrivateProfileDefaults(profile: guest, guestDefaults: defaults)
        let history = FileTranscriptionHistoryStore(defaults: bound, profile: guest)
        let output = try history.admitWrite()
        let result = TranscriptionResult(id: output.entryID, text: "pending A output", confidence: 1, duration: 1,
            processingTime: 1, fileName: "synthetic.wav")
        defaults.failSynchronization = true
        do { try history.addEntry(result, admission: output); preconditionFailure("Synthetic sync failure must surface") }
        catch { checks += 1 }
        output.finish()
        expect(history.admittedWriteCount == 1, "Failed durable output stays pinned for cleanup retry")
        defaults.failSynchronization = false
        if clear { history.clearAll() }
        PrivateProfileStorage.conceal(generation: UUID())
        try await history.prepareForProfileTransition()
        expect(history.admittedWriteCount == 0 && history.entries.isEmpty, "Transition retries or revokes pending output without private publication")
        PrivateProfileStorage.select(guest)
        let reopened = FileTranscriptionHistoryStore(defaults: bound, profile: guest)
        expect(clear ? reopened.entries.isEmpty : reopened.entries.map(\.text) == ["pending A output"],
            "Clear never resurrects a failed output; valid retry retains original A output")
        try await reopened.prepareForProfileTransition()
    }

    static func admittedProviderLifetime(holdPreparation: Bool) async throws {
        let a = try account("provider-lifetime")
        PrivateProfileStorage.select(a)
        SettingsStore.shared.fileTranscriptionSpeakerLabelsEnabled = false
        let original = SyntheticFileProvider("original-provider", native: true)
        let replacement = SyntheticFileProvider("replacement-provider", native: true)
        let preparation = SyntheticFileGate(), release = SyntheticFileGate()
        let asr = ASRService(provider: original)
        asr.isAsrReady = !holdPreparation
        asr.preparationGate = holdPreparation ? preparation : nil
        asr.releaseGate = release
        let history = try store(a)
        let service = FileTranscriptionService(asrService: asr, historyStore: history)
        let url = input("provider-lifetime", frames: 32_000, turns: 1)
        let work = Task { try await service.transcribeFile(url) }
        if holdPreparation { await preparation.waitUntilEntered() }
        else { await release.waitUntilEntered() }
        expect(asr.begins == 1 && asr.ends == 0, "Provider admission precedes the first preparation await")
        asr.fileTranscriptionProvider = replacement
        PrivateProfileStorage.conceal(generation: UUID())
        let retirement = Task { try await service.prepareForPrivateProfileTransition() }
        if holdPreparation {
            await preparation.release()
            await release.waitUntilEntered()
            expect(asr.preparedProviderName == original.name, "Cold readiness retains the admitted provider through conceal")
        }
        expect(asr.activeLease != nil && asr.releases == 0 && history.admittedWriteCount == 1,
            "Provider retirement retains both activity and local output ownership until joined")
        expect(service.result == nil && service.currentFileURL == nil, "Held retirement exposes no private file presentation")
        await release.release()
        do { _ = try await work.value; preconditionFailure("Retired provider cannot publish to the caller") }
        catch is CancellationError { checks += 1 }
        try await retirement.value
        expect(asr.ends == 1 && asr.releases == 1 && asr.activeLease == nil,
            "Provider retirement joins before its exact activity lease releases")
        expect(replacement.calls == 0 && history.admittedWriteCount == 0,
            "Retirement neither resolves the replacement provider nor leaks output admission")
        PrivateProfileStorage.select(a)
        let saved = try store(a).entries
        expect(holdPreparation ? saved.isEmpty : saved.count == 1,
            "Only an already completed original result survives conceal")
        try await history.prepareForProfileTransition()
    }
}

private actor CompletionFlag {
    private(set) var value = false
    func mark() { value = true }
}
private nonisolated final class FailingFileDefaults: UserDefaults, @unchecked Sendable {
    var failSynchronization = false
    override func synchronize() -> Bool { failSynchronization ? false : super.synchronize() }
}

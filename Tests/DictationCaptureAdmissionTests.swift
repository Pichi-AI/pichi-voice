import Foundation

// Inert neighbors only. The runner inserts the actual ASR admission, provider getter,
// selection validation and exact-lease release declarations at the marker below.
@MainActor final class SettingsStore {
    static let shared = SettingsStore()
    enum SpeechModel: Hashable {
        case gigaam, appleSpeechAnalyzer, appleSpeech, parakeetTDT, parakeetTDTv2
        case fluidParakeetMini, fluidParakeetPico, parakeetRealtime, cohereTranscribeSixBit
        case nemotronOffline, nemotronStreaming, nemotronStreaming320, qwen3Asr, whisper
        var nemotronProviderMode: Int { 0 }
    }
    var selectedSpeechModel = SpeechModel.gigaam
    var pauseMediaDuringTranscription = true
    var skipSilentRecordingsEnabled = true
    var saveTranscriptionHistory = true
    var saveAudioWithTranscriptionHistory = true
    var automaticDictionaryLearningEnabled = false
}
nonisolated struct PrivateProfileSnapshot: Sendable { let id: String }
nonisolated enum PrivateProfileStorage {
    static let current = PrivateProfileSnapshot(id: "A")
    nonisolated(unsafe) static var acceptsNewWork = true
    nonisolated(unsafe) static var readable = true
    static func isReadable(_ profile: PrivateProfileSnapshot) -> Bool { readable }
}
nonisolated enum DictionaryMatcherExperiment { static let collectNegatives = true }
nonisolated struct PronunciationEnrollmentCapture: Sendable {}
nonisolated struct DictionaryLearningAlignment: Sendable {}
nonisolated struct DictationAudioSnapshot { let samples: [Float]; let sampleRate: Double; let channels: Int }
nonisolated enum AppBrand { static func text(_ value: String) -> String { value } }
// ACTUAL_TRANSCRIPTION_PROVIDER_SOURCE

@MainActor final class Provider: TranscriptionProvider {
    let name: String
    let isAvailable = true
    let isReady = true
    #if TEST_MAIN_ACTOR
    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {}
    #else
    nonisolated func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {}
    #endif
    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult { .init(text: name) }
    var lease: UUID?
    var begins = 0
    var ends = 0
    var rejectAdmission = false
    var endGate: Gate?
    init(_ name: String) { self.name = name }
    func beginAdmittedTranscription(leaseID: UUID) throws {
        begins += 1
        if rejectAdmission { throw CancellationError() }
        lease = leaseID
    }
    func endAdmittedTranscription(leaseID: UUID) async {
        if let endGate { await endGate.hold() }
        ends += 1
        if lease == leaseID { lease = nil }
    }
}
@MainActor final class ASRService {
    var activeActivityLease: ASRActivityLease?
    var dictationActivityLease: ASRActivityLease?
    var modelProvidersForTesting: [SettingsStore.SpeechModel: TranscriptionProvider] = [:]
    var released: [ASRActivityLease] = []
    var lastCompletedAudioSnapshot: DictationAudioSnapshot?
    struct Gate { var isRecovering = false }
    var recordingBufferHandoffGate = Gate()
    func releaseExclusiveActivity(_ lease: ASRActivityLease) {
        guard activeActivityLease == lease else { return }
        released.append(lease)
        activeActivityLease = nil
    }
    func getGigaAMProvider() -> TranscriptionProvider { fatalError("missing injected provider") }
    func getAppleSpeechAnalyzerProvider() -> TranscriptionProvider { fatalError("missing injected provider") }
    func getAppleSpeechProvider() -> TranscriptionProvider { fatalError("missing injected provider") }
    func getFluidAudioProvider() -> TranscriptionProvider { fatalError("missing injected provider") }
    func getParakeetRealtimeProvider() -> TranscriptionProvider { fatalError("missing injected provider") }
    func getExternalCoreMLProvider() -> TranscriptionProvider { fatalError("missing injected provider") }
    func getNemotronProvider(mode: Int) -> TranscriptionProvider { fatalError("missing injected provider") }
    func getWhisperProvider() -> TranscriptionProvider { fatalError("missing injected provider") }

// ACTUAL_ASR_ADMISSION_SOURCE
}

actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false
    func hold() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@main struct Main {
    @MainActor static func main() async throws {
        let service = ASRService(), a = Provider("A"), b = Provider("B")
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message); checks += 1
        }
        service.modelProvidersForTesting = [.gigaam: a, .whisper: b]
        let settings = SettingsStore.shared
        let leaseA = ASRActivityLease(id: UUID(), activity: .dictation)
        service.activeActivityLease = leaseA; service.dictationActivityLease = leaseA
        try service.admitDictationTranscription(leaseA)
        check(a.begins == 1 && b.begins == 0, "admission uses original provider")
        check((service.transcriptionProvider as AnyObject) === a, "admitted provider is A")
        check(service.selectedTranscriptionModel == .gigaam, "admitted model is A")
        check(service.admittedTranscription?.retainHistoryAudio == true, "audio choice freezes at admission")
        check(service.admittedTranscription?.automaticLearning == false && service.admittedTranscription?.collectNegatives == true, "negative collection cannot enable original PCM retention")

        // A concealed profile's settings facade can expose fallback B while the original
        // capture and its finalization remain admitted. No UI/store read capability is granted.
        settings.selectedSpeechModel = .whisper
        settings.pauseMediaDuringTranscription = false
        settings.skipSilentRecordingsEnabled = false
        settings.saveTranscriptionHistory = false
        settings.saveAudioWithTranscriptionHistory = false
        settings.automaticDictionaryLearningEnabled = true
        check((service.transcriptionProvider as AnyObject) === a, "conceal cannot choose another provider")
        check(service.selectedTranscriptionModel == .gigaam, "conceal cannot change model")
        check(service.admittedTranscription?.pauseMedia == true, "media choice stays frozen")
        check(service.admittedTranscription?.skipSilentRecordings == true, "silence choice stays frozen")
        check(service.admittedTranscription?.retainHistoryAudio == true, "conceal cannot discard admitted audio")
        check(service.admittedTranscription?.automaticLearning == false, "hidden default cannot turn original PCM learning on")
        PrivateProfileStorage.readable = false
        service.retainConcealedCaptureAudio([1, 2, 3])
        check(service.lastCompletedAudioSnapshot?.samples == [1, 2, 3], "concealed training preserves original audio only under frozen history choices")
        PrivateProfileStorage.readable = true
        check(service.isTranscriptionSelectionCurrent(model: .gigaam, admittedLease: leaseA), "admitted readiness survives concealed defaults")
        check(!service.isTranscriptionSelectionCurrent(model: .whisper, admittedLease: leaseA), "another model is never current for A")
        check(!service.isTranscriptionSelectionCurrent(model: .gigaam, admittedLease: nil), "ordinary readiness still follows current profile")

        // Hold a synthetic final provider operation across the attempted release.
        let gate = Gate()
        let finalizationA = service.beginDictationFinalization(leaseA)!
        var joined = false
        let final = Task { await gate.hold() }
        let shutdownJoin = Task { @MainActor in await service.joinDictationFinalization(); joined = true }
        await gate.waitUntilEntered()
        service.releaseDictationActivityIfNeeded()
        check(a.ends == 0 && service.activeActivityLease == leaseA, "second stop cannot release held finalization")
        check(!joined, "termination waits for active finalization")
        check(service.beginDictationFinalization(leaseA) == nil, "second stop cannot replace held finalization")
        check(service.beginDictationFinalization(leaseA) == nil, "stopWithoutTranscription cannot replace held finalization")
        service.finishDictationFinalization(leaseA, id: UUID())
        check(service.dictationFinalizationID == finalizationA && a.ends == 0, "stale completion cannot release original operation")
        check((service.transcriptionProvider as AnyObject) === a, "held finalization retains exact provider")
        await gate.release(); await final.value
        service.recordingBufferHandoffGate.isRecovering = true
        service.finishDictationFinalization(leaseA, id: finalizationA)
        service.releaseDictationActivityIfNeeded(leaseA)
        check(a.ends == 0 && service.activeActivityLease == leaseA, "timeout retains provider until its actual return")
        service.recordingBufferHandoffGate.isRecovering = false
        let releaseGate = Gate()
        a.endGate = releaseGate
        service.releaseDictationActivityIfNeeded(leaseA)
        await releaseGate.waitUntilEntered()
        check(service.activeActivityLease == leaseA && (service.transcriptionProvider as AnyObject) === a, "reference cleanup retains exact activity/provider")
        service.releaseDictationActivityIfNeeded(leaseA)
        check(a.ends == 0, "duplicate retirement does not end provider early")
        check(!joined, "termination also waits for provider reference cleanup")
        await releaseGate.release()
        await service.dictationReleaseTask?.task.value
        await shutdownJoin.value
        check(joined, "termination finishes after exact provider cleanup")
        check(a.ends == 1 && a.lease == nil, "joined original lease ends provider options once")
        check(service.activeActivityLease == nil && service.admittedTranscription == nil, "joined original admission clears")
        check((service.transcriptionProvider as AnyObject) === b, "new admission can use B only after A ends")

        let leaseB = ASRActivityLease(id: UUID(), activity: .dictation)
        service.activeActivityLease = leaseB; service.dictationActivityLease = leaseB
        try service.admitDictationTranscription(leaseB)
        service.releaseDictationActivityIfNeeded(leaseA)
        check(service.activeActivityLease == leaseB && b.ends == 0, "stale A cleanup cannot release B")
        check(service.admittedTranscription?.retainHistoryAudio == false, "B owns its own output choices")
        service.lastCompletedAudioSnapshot = nil
        PrivateProfileStorage.readable = false
        service.retainConcealedCaptureAudio([4, 5])
        check(service.lastCompletedAudioSnapshot == nil, "conceal cannot enable audio when original history choices prohibited it")
        PrivateProfileStorage.readable = true
        check(!service.isTranscriptionSelectionCurrent(model: .gigaam, admittedLease: leaseA), "stale admission cannot pass readiness")
        do {
            try service.admitDictationTranscription(leaseB)
            preconditionFailure("duplicate admission must not replace pinned options")
        } catch { checks += 1 }
        check(b.begins == 1, "duplicate admission does not call provider begin")
        service.releaseDictationActivityIfNeeded(leaseB)
        await service.dictationReleaseTask?.task.value
        check(b.ends == 1 && service.released == [leaseA, leaseB], "matching cleanup releases each exclusive lease once")

        let rejected = ASRActivityLease(id: UUID(), activity: .dictation)
        service.activeActivityLease = rejected; service.dictationActivityLease = rejected
        b.rejectAdmission = true
        do {
            try service.admitDictationTranscription(rejected)
            preconditionFailure("provider rejection must propagate")
        } catch { checks += 1 }
        check(service.admittedTranscription == nil, "failed provider cannot publish admission")
        check(b.ends == 1 && b.lease == nil, "failed provider admission is atomic")
        service.releaseDictationActivityIfNeeded(rejected)
        check(service.activeActivityLease == nil, "failed admission's exclusive lease can retire")
        b.rejectAdmission = false
        let fileLease = ASRActivityLease(id: UUID(), activity: .fileTranscription)
        service.activeActivityLease = fileLease
        settings.selectedSpeechModel = .gigaam
        _ = try service.beginAdmittedTranscription(lease: fileLease)
        settings.selectedSpeechModel = .whisper
        check((service.transcriptionProvider as AnyObject) === a && service.selectedTranscriptionModel == .gigaam, "cold file readiness retains admitted A provider/model")
        check(service.isTranscriptionSelectionCurrent(model: .gigaam, admittedLease: fileLease), "file readiness uses exact admitted file lease after conceal")
        a.endGate = nil
        await service.endAdmittedTranscription(lease: leaseA)
        check(service.admittedTranscription?.lease == fileLease, "stale dictation cleanup cannot clear file admission")
        await service.endAdmittedTranscription(lease: fileLease)
        check(service.admittedTranscription == nil && service.activeActivityLease == fileLease, "file caller joins provider end before releasing exclusive lease")
        service.releaseExclusiveActivity(fileLease)
        let hiddenLease = ASRActivityLease(id: UUID(), activity: .fileTranscription)
        service.activeActivityLease = hiddenLease
        PrivateProfileStorage.acceptsNewWork = false
        do { _ = try service.beginAdmittedTranscription(lease: hiddenLease); preconditionFailure("hidden new admission must reject") } catch { checks += 1 }
        check(service.admittedTranscription == nil, "hidden rejection cannot pin fallback provider")
        service.releaseExclusiveActivity(hiddenLease)
        PrivateProfileStorage.acceptsNewWork = true
        print("Dictation capture admission: \(checks) assertions passed")
    }
}

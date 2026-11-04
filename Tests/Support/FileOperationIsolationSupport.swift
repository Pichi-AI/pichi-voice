import AVFoundation
import CoreMedia
import Foundation

// This harness compiles the real service and provider protocol. Only unrelated app
// infrastructure and decoding are synthetic. It never opens or creates audio files.
nonisolated struct PronunciationEnrollmentCapture: Sendable {}
nonisolated struct DictionaryLearningAlignment: Sendable {}
nonisolated final class DebugLogger: Sendable {
    static let shared = DebugLogger()
    func info(_ message: String, source: String) {}
    func warning(_ message: String, source: String) {}
    func debug(_ message: String, source: String) {}
}
@MainActor protocol PrivateProfileTransitionParticipant: AnyObject {
    func prepareForPrivateProfileTransition() async throws
}
@MainActor final class PrivateProfileService {
    static let shared = PrivateProfileService()
    func register(_ participant: any PrivateProfileTransitionParticipant) {}
}
@MainActor final class SettingsStore {
    struct Model { let analyticsDescriptor = "synthetic" }
    static let shared = SettingsStore()
    var selectedSpeechModel = Model()
    var fileTranscriptionSpeakerLabelsEnabled = false
    var fileTranscriptionExpectedSpeakerCount = 0
}
@MainActor final class AnalyticsService {
    enum Mode { case meeting }
    static let shared = AnalyticsService()
    func recordUsage(mode: Mode, transcriptionModel: String) {}
}
@MainActor final class ASRService {
    var isAsrReady = true
    var fileTranscriptionProvider: any TranscriptionProvider
    private(set) var activeLease: ASRActivityLease?
    private(set) var releases = 0
    private(set) var begins = 0
    private(set) var ends = 0
    private(set) var preparedProviderName: String?
    var preparationGate: SyntheticFileGate?
    var releaseGate: SyntheticFileGate?
    private var admittedProvider: (lease: ASRActivityLease, provider: any TranscriptionProvider)?
    init(provider: any TranscriptionProvider) { fileTranscriptionProvider = provider }
    func ensureAsrReady() async throws {
        await preparationGate?.hold()
        preparedProviderName = admittedProvider?.provider.name
        isAsrReady = true
    }
    func beginAdmittedTranscription(lease: ASRActivityLease) throws -> any TranscriptionProvider {
        precondition(activeLease == lease && admittedProvider == nil)
        admittedProvider = (lease, fileTranscriptionProvider)
        begins += 1
        return fileTranscriptionProvider
    }
    func endAdmittedTranscription(lease: ASRActivityLease) async {
        precondition(admittedProvider?.lease == lease && activeLease == lease)
        await releaseGate?.hold()
        admittedProvider = nil
        ends += 1
    }
    func acquireExclusiveActivity(_ activity: ASRExclusiveActivity) throws -> ASRActivityLease {
        guard activeLease == nil else { throw ASRActivityError.activityInProgress(activity) }
        let lease = ASRActivityLease(id: UUID(), activity: activity)
        activeLease = lease
        return lease
    }
    func acquireForegroundActivity(_ activity: ASRExclusiveActivity) async throws -> ASRActivityLease {
        try Task.checkCancellation()
        return try acquireExclusiveActivity(activity)
    }
    func releaseExclusiveActivity(_ lease: ASRActivityLease) {
        precondition(activeLease == lease && admittedProvider == nil)
        activeLease = nil; releases += 1
    }
}

nonisolated final class SyntheticFileRegistry: @unchecked Sendable {
    struct Input: Sendable {
        let frames: Int64
        let turns: [SpeakerDiarizationService.SpeakerTurn]
        let durationGate: SyntheticFileGate?
    }
    static let shared = SyntheticFileRegistry()
    private let lock = NSLock()
    private var inputs: [URL: Input] = [:]
    private var hints: [Int?] = []
    func set(_ input: Input, at url: URL) { lock.withLock { inputs[url] = input } }
    func input(_ url: URL) -> Input { lock.withLock { inputs[url]! } }
    func recordHint(_ value: Int?) { lock.withLock { hints.append(value) } }
    var lastHint: Int? { lock.withLock { hints.last ?? nil } }
}
actor SyntheticFileGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        entered = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters = []
        if !released { await withCheckedContinuation { releaseWaiters.append($0) } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
    }
    func release() {
        released = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters = []
    }
}
nonisolated final class SyntheticFileProvider: TranscriptionProvider, @unchecked Sendable {
    let name: String
    let isAvailable = true
    let isReady = true
    let prefersNativeFileTranscription: Bool
    let gate: SyntheticFileGate?
    let throwsAfterGate: Bool
    private let lock = NSLock()
    private var count = 0
    private var returnedCanceled = false
    var returnedWhileCanceled: Bool { lock.withLock { returnedCanceled } }
    var calls: Int { lock.withLock { count } }
    init(_ name: String, native: Bool, gate: SyntheticFileGate? = nil, throwsAfterGate: Bool = false) {
        self.name = name; self.prefersNativeFileTranscription = native
        self.gate = gate; self.throwsAfterGate = throwsAfterGate
    }
    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {}
    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult { try await response() }
    func transcribeFile(at fileURL: URL) async throws -> ASRTranscriptionResult { try await response() }
    private func response() async throws -> ASRTranscriptionResult {
        let ordinal = lock.withLock { count += 1; return count }
        if ordinal == 1 { await gate?.hold() }
        lock.withLock { returnedCanceled = Task.isCancelled }
        if throwsAfterGate { throw NSError(domain: "SyntheticPrivateAError", code: 1) }
        // Deliberately ignores Task cancellation to exercise the production owner join.
        return .init(text: "\(name) result \(ordinal)", confidence: 1)
    }
}

// Same-module names shadow only the decoding dependency. The complete production
// native/chunk/speaker orchestration and TranscriptionProvider calls remain unchanged.
nonisolated enum AVURLAsset {
    static func audiovisualTypes() -> [AVFileType] { [.wav] }
}
nonisolated final class AVAsset: Sendable {
    enum Property { case duration }
    let url: URL
    init(url: URL) { self.url = url }
    func load(_ key: Property) async throws -> CMTime {
        let input = SyntheticFileRegistry.shared.input(url)
        await input.durationGate?.hold()
        return CMTime(seconds: Double(input.frames) / 16_000, preferredTimescale: 16_000)
    }
}
nonisolated struct SyntheticAudioFormat: Sendable { let sampleRate: Double = 16_000 }
nonisolated final class AVAudioPCMBuffer: @unchecked Sendable {
    var frameLength: AVAudioFrameCount = 0
    init?(pcmFormat: SyntheticAudioFormat, frameCapacity: AVAudioFrameCount) {}
}
nonisolated final class AVAudioFile: @unchecked Sendable {
    let processingFormat = SyntheticAudioFormat()
    let length: AVAudioFramePosition
    var framePosition: AVAudioFramePosition = 0
    init(forReading url: URL) throws { self.length = SyntheticFileRegistry.shared.input(url).frames }
    func read(into buffer: AVAudioPCMBuffer, frameCount: AVAudioFrameCount) throws { buffer.frameLength = frameCount }
}
nonisolated enum AudioBufferConverter {
    static func monoSamples(from buffer: AVAudioPCMBuffer, targetSampleRate: Double) throws -> [Float] {
        [Float](repeating: 0, count: 16_000)
    }
}
actor SpeakerDiarizationService {
    static let isSupported = true
    nonisolated struct SpeakerTurn: Sendable, Equatable {
        let speakerLabel: String
        let startSeconds: Double
        let endSeconds: Double
    }
    init(expectedSpeakers: Int? = nil) { SyntheticFileRegistry.shared.recordHint(expectedSpeakers) }
    func diarize(fileURL: URL) async throws -> [SpeakerTurn] { SyntheticFileRegistry.shared.input(fileURL).turns }
}

nonisolated final class SyntheticFileSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() {
        lock.withLock {
            signaled = true
            let captured = waiters; waiters = []
            for waiter in captured { waiter.resume() }
        }
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.withLock { if signaled { continuation.resume() } else { waiters.append(continuation) } }
        }
    }
}

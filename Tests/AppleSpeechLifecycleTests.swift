import Foundation

// Only the system-facing speech/audio contracts are inert. The runner compiles
// the actual provider methods and complete production ownership helpers.
final nonisolated class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func open() {
        let waiters = self.lock.withLock {
            self.opened = true
            let result = self.waiters; self.waiters.removeAll(); return result
        }
        for waiter in waiters { waiter.resume() }
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = self.lock.withLock {
                if self.opened { return true }
                self.waiters.append(continuation); return false
            }
            if ready { continuation.resume() }
        }
    }
}
final nonisolated class TestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool { self.lock.withLock { self.storage } }
    func set() { self.lock.withLock { self.storage = true } }
}
nonisolated struct ASRTranscriptionResult: Sendable { let text: String; let confidence: Float }
final class SettingsStore { static let shared = SettingsStore(); var selectedAppleSpeechLocale = Locale(identifier: "ru-RU") }
final class DebugLogger {
    static let shared = DebugLogger()
    func debug(_ message: String, source: String) {}
    func warning(_ message: String, source: String) {}
}
final nonisolated class AVAudioFormat: @unchecked Sendable {}
final nonisolated class AVAudioPCMBuffer: @unchecked Sendable {}
final class BufferConverter {
    func convertBuffer(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer { buffer }
}
nonisolated protocol SFSpeechRecognitionTaskDelegate: AnyObject {
    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishRecognition result: SFSpeechRecognitionResult)
    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishSuccessfully successfully: Bool)
    func speechRecognitionTaskWasCancelled(_ task: SFSpeechRecognitionTask)
}
final nonisolated class SFSpeechRecognitionResult: @unchecked Sendable {
    struct Transcription { let formattedString: String }
    let bestTranscription: Transcription
    init(_ text: String) { self.bestTranscription = Transcription(formattedString: text) }
}
final nonisolated class SFSpeechAudioBufferRecognitionRequest: @unchecked Sendable {
    var shouldReportPartialResults = true
    var requiresOnDeviceRecognition = true
    private(set) var ended = 0
    func append(_ buffer: AVAudioPCMBuffer) {}
    func endAudio() { self.ended += 1 }
}
final nonisolated class SFSpeechRecognitionTask: @unchecked Sendable {
    let driver: RecognitionDriver
    init(_ driver: RecognitionDriver) { self.driver = driver }
    func cancel() { self.driver.cancelled.open() }
}
final nonisolated class RecognitionDriver: @unchecked Sendable {
    let started = TestGate(), cancelled = TestGate()
    var onCreation: (() -> Void)?
    weak var delegate: (any SFSpeechRecognitionTaskDelegate)?
    var task: SFSpeechRecognitionTask?
    func create(delegate: any SFSpeechRecognitionTaskDelegate) -> SFSpeechRecognitionTask {
        let task = SFSpeechRecognitionTask(self)
        self.delegate = delegate; self.task = task
        self.onCreation?()
        self.started.open()
        return task
    }
    func final(_ text: String) { self.delegate?.speechRecognitionTask(self.task!, didFinishRecognition: SFSpeechRecognitionResult(text)) }
    func complete(_ success: Bool = true) { self.delegate?.speechRecognitionTask(self.task!, didFinishSuccessfully: success) }
    func cancelOnly() { self.delegate?.speechRecognitionTaskWasCancelled(self.task!) }
}
final nonisolated class SFSpeechRecognizer: @unchecked Sendable {
    nonisolated(unsafe) static var driver = RecognitionDriver()
    let locale: Locale
    var isAvailable = true
    init?(locale: Locale) { self.locale = locale }
    func recognitionTask(with request: SFSpeechAudioBufferRecognitionRequest, delegate: any SFSpeechRecognitionTaskDelegate) -> SFSpeechRecognitionTask {
        Self.driver.create(delegate: delegate)
    }
}
nonisolated struct AnalyzerInput: Sendable { init(buffer: AVAudioPCMBuffer) {} }
nonisolated struct AnalyzerResult: Sendable { let text: AttributedString; let isFinal: Bool }
final nonisolated class AnalyzerDriver: @unchecked Sendable {
    enum Mode { case normal, failStart, failFinalize, holdStart }
    enum Failure: Error { case start, finalize }
    let mode: Mode
    let startEntered = TestGate(), startRelease = TestGate(), cancelEntered = TestGate(), cancelRelease = TestGate()
    let results: AsyncThrowingStream<AnalyzerResult, Error>
    let continuation: AsyncThrowingStream<AnalyzerResult, Error>.Continuation
    init(_ mode: Mode) {
        self.mode = mode
        (self.results, self.continuation) = AsyncThrowingStream.makeStream()
    }
    func start() async throws {
        self.startEntered.open()
        if self.mode == .holdStart { await self.startRelease.wait() }
        if self.mode == .failStart { throw Failure.start }
    }
    func finalize() throws {
        if self.mode == .failFinalize { throw Failure.finalize }
        self.continuation.yield(AnalyzerResult(text: AttributedString("synthetic first"), isFinal: true))
        self.continuation.yield(AnalyzerResult(text: AttributedString("synthetic second"), isFinal: true))
        self.continuation.finish()
    }
    func cancel() async {
        self.cancelEntered.open()
        self.startRelease.open()
        await self.cancelRelease.wait()
        self.continuation.finish()
    }
}
final nonisolated class SpeechTranscriber: @unchecked Sendable {
    nonisolated(unsafe) static var driver = AnalyzerDriver(.normal)
    let driver: AnalyzerDriver
    var results: AsyncThrowingStream<AnalyzerResult, Error> { self.driver.results }
    init(locale: Locale, transcriptionOptions: [Int], reportingOptions: [Int], attributeOptions: [Int]) { self.driver = Self.driver }
}
final nonisolated class SpeechAnalyzer: @unchecked Sendable {
    let driver: AnalyzerDriver
    init(modules: [SpeechTranscriber]) { self.driver = modules[0].driver }
    func start(inputSequence: AsyncStream<AnalyzerInput>) async throws { try await self.driver.start() }
    func finalizeAndFinishThroughEndOfInput() async throws { try self.driver.finalize() }
    func cancelAndFinishNow() async { await self.driver.cancel() }
}

@main struct AppleSpeechLifecycleTests {
    @MainActor private static var assertions = 0
    @MainActor private static func check(_ value: Bool, _ message: String) {
        self.assertions += 1
        precondition(value, message)
    }
    @MainActor private static func allowTasks() async { for _ in 0..<30 { await Task.yield() } }
    @MainActor static func main() async throws {
        // A normal final callback is not terminal. The delegate and request survive
        // until all recognition finishes; duplicate/late callbacks have one outcome.
        do {
            let driver = RecognitionDriver(); SFSpeechRecognizer.driver = driver
            let provider = AppleSpeechProvider(), lease = UUID(), done = TestFlag()
            try provider.beginAdmittedTranscription(leaseID: lease)
            let work = Task { let result = try await provider.transcribe([0]); done.set(); return result }
            await driver.started.wait()
            driver.final("synthetic legacy")
            await self.allowTasks()
            self.check(!done.value, "A final utterance alone cannot release SDK ownership")
            driver.complete(); driver.final("late ignored"); driver.complete()
            self.check(try await work.value.text == "synthetic legacy", "Only the terminally fenced result publishes")
            await provider.endAdmittedTranscription(leaseID: lease)
        }
        // Cancel and retire while recognition holds its terminal callback.
        do {
            SettingsStore.shared.selectedAppleSpeechLocale = Locale(identifier: "ru-RU")
            let driver = RecognitionDriver(); SFSpeechRecognizer.driver = driver
            let provider = AppleSpeechProvider(), lease = UUID(), done = TestFlag(), ended = TestFlag()
            try provider.beginAdmittedTranscription(leaseID: lease)
            let work = Task { defer { done.set() }; return try await provider.transcribe([0]) }
            await driver.started.wait(); work.cancel(); await driver.cancelled.wait()
            SettingsStore.shared.selectedAppleSpeechLocale = Locale(identifier: "en-US")
            let ending = Task { await provider.endAdmittedTranscription(leaseID: lease); ended.set() }
            await self.allowTasks()
            self.check(!done.value && !ended.value, "Cancellation and scope retirement both await system completion")
            self.check(provider.observedLocale == "ru-RU", "The original locale stays frozen during cancellation")
            do { try provider.beginAdmittedTranscription(leaseID: UUID()); preconditionFailure("Overlapping admission accepted") }
            catch { self.assertions += 1 }
            driver.final("cancelled late text"); driver.complete(false)
            do { _ = try await work.value; preconditionFailure("Cancelled recognition published") }
            catch is CancellationError { self.assertions += 1 }
            await ending.value
            self.check(done.value && ended.value && provider.observedLocale == "en-US", "Joined retirement releases only the matching locale")
        }
        // Ending admission itself cancels recognition, without relying on its
        // caller to cancel the Swift task first. A stale end cannot touch it.
        do {
            let driver = RecognitionDriver(); SFSpeechRecognizer.driver = driver
            let provider = AppleSpeechProvider(), lease = UUID(), ended = TestFlag()
            SettingsStore.shared.selectedAppleSpeechLocale = Locale(identifier: "ru-RU")
            try provider.beginAdmittedTranscription(leaseID: lease)
            let work = Task { try await provider.transcribe([0]) }
            await driver.started.wait()
            await provider.endAdmittedTranscription(leaseID: UUID())
            self.check(provider.observedLocale == "ru-RU", "Stale end cannot release an active legacy locale")
            let ending = Task { await provider.endAdmittedTranscription(leaseID: lease); ended.set() }
            await driver.cancelled.wait(); await self.allowTasks()
            self.check(!ended.value, "Admission end waits for its own cancellation completion")
            driver.cancelOnly()
            do { _ = try await work.value; preconditionFailure("Retired recognition published") }
            catch is CancellationError { self.assertions += 1 }
            await ending.value
            driver.cancelOnly(); driver.final("late after cancellation-only completion"); driver.complete(false)
            self.check(ended.value, "Cancellation-only completion tolerates duplicate and reordered late callbacks")
        }
        // Cancellation before the synchronous SDK creation call returns its handle.
        do {
            let driver = RecognitionDriver(); SFSpeechRecognizer.driver = driver
            let operation = AppleSpeechRecognitionOperation(request: SFSpeechAudioBufferRecognitionRequest())
            driver.onCreation = { operation.cancel(); driver.cancelOnly() }
            let work = Task { await operation.recognize(using: SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))!) }
            await driver.started.wait(); await driver.cancelled.wait()
            do { _ = try await work.value.get(); preconditionFailure("Startup cancellation published") }
            catch is CancellationError { self.assertions += 1 }
            driver.cancelOnly(); driver.final("ignored after early cancellation"); driver.complete(false)
            operation.finishJoining(); await operation.waitUntilFinished()
            self.check(true, "A late-installed handle is cancelled and joined after cancellation-only completion")
        }
        // Synchronous completion can arrive before the task handle is installed.
        do {
            let driver = RecognitionDriver(); SFSpeechRecognizer.driver = driver
            driver.onCreation = { driver.final("synchronous synthetic"); driver.complete() }
            let provider = AppleSpeechProvider()
            self.check(try await provider.transcribe([0]).text == "synchronous synthetic", "Early completion is delivered after handle installation")
        }
        // Both analyzer failure points must finish input and join SDK cancellation.
        for mode in [AnalyzerDriver.Mode.failStart, .failFinalize] {
            let driver = AnalyzerDriver(mode); SpeechTranscriber.driver = driver
            let provider = AppleSpeechAnalyzerProvider(), lease = UUID(), done = TestFlag(), ended = TestFlag()
            SettingsStore.shared.selectedAppleSpeechLocale = Locale(identifier: "ru-RU")
            try provider.beginAdmittedTranscription(leaseID: lease)
            let work = Task { defer { done.set() }; return try await provider.transcribe([0]) }
            await driver.cancelEntered.wait()
            SettingsStore.shared.selectedAppleSpeechLocale = Locale(identifier: "en-US")
            let ending = Task { await provider.endAdmittedTranscription(leaseID: lease); ended.set() }
            await self.allowTasks()
            self.check(!done.value && !ended.value, "A throwing analyzer stage cannot orphan cancellation")
            self.check(provider.observedLocale == "ru-RU", "Throwing stage cleanup retains the admitted locale")
            driver.cancelRelease.open()
            do { _ = try await work.value; preconditionFailure("Throwing analyzer stage succeeded") }
            catch is AnalyzerDriver.Failure { self.assertions += 1 }
            await ending.value
            self.check(ended.value && provider.observedLocale == "en-US", "Error cleanup joins before scope release")
        }
        // Cancellation interrupts a held analyzer start and also joins its cancel actor.
        do {
            let driver = AnalyzerDriver(.holdStart); SpeechTranscriber.driver = driver
            let provider = AppleSpeechAnalyzerProvider(), lease = UUID(), done = TestFlag()
            try provider.beginAdmittedTranscription(leaseID: lease)
            let work = Task { defer { done.set() }; return try await provider.transcribe([0]) }
            await driver.startEntered.wait(); work.cancel(); await driver.cancelEntered.wait()
            await self.allowTasks()
            self.check(!done.value, "Cancelled start waits for cancelAndFinishNow")
            driver.cancelRelease.open()
            do { _ = try await work.value; preconditionFailure("Cancelled analyzer published") }
            catch is CancellationError { self.assertions += 1 }
            await provider.endAdmittedTranscription(leaseID: lease)
        }
        // The collector can ignore cancellation temporarily. Joining must still wait.
        do {
            let collectorRelease = TestGate(), cancelRelease = TestGate(), cancelled = TestGate(), inputFinished = TestFlag(), joined = TestFlag()
            let collector = Task<String, Error> { await collectorRelease.wait(); return "late collector text" }
            let operation = AppleSpeechAnalyzerOperation(resultsTask: collector, finishInput: { inputFinished.set() }, cancelAnalyzer: { cancelled.open(); await cancelRelease.wait() })
            let cleanup = Task { await operation.cancelAndJoinWorkers(); joined.set(); operation.finishJoining() }
            await cancelled.wait(); await self.allowTasks()
            self.check(inputFinished.value && !joined.value, "Input finishes immediately but owned workers remain joined")
            cancelRelease.open(); await self.allowTasks()
            self.check(!joined.value, "SDK cancellation completion alone cannot release a held collector")
            collectorRelease.open(); await cleanup.value; await operation.waitUntilFinished()
            do { try operation.checkCancellation(); preconditionFailure("Late collector result accepted") }
            catch is CancellationError { self.assertions += 1 }
        }
        do {
            let driver = AnalyzerDriver(.normal); SpeechTranscriber.driver = driver
            let provider = AppleSpeechAnalyzerProvider()
            self.check(try await provider.transcribe([0]).text == "synthetic first synthetic second", "Normal analyzer final segments still accumulate")
        }
        print("Apple Speech lifecycle tests passed (\(self.assertions) assertions).")
    }
}

import Foundation

// Inert replacement for the package inference runtime. The runner compiles the
// real catalog beside this gate; no model, frontend, audio or network is used.
public enum GigaAMArtifactTestCapabilities {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var encoderFeatureAPIAvailable = false
    }
    private static let state = State()
    public static var encoderFeatureAPIAvailable: Bool {
        get { state.lock.withLock { state.encoderFeatureAPIAvailable } }
        set { state.lock.withLock { state.encoderFeatureAPIAvailable = newValue } }
    }
}

public actor GigaAMArtifactTestGate {
    public static let shared = GigaAMArtifactTestGate()
    public private(set) var loadedDirectory: URL?
    public private(set) var loadedDescriptor: String?
    private var started: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    private var cancelled: CheckedContinuation<Void, Never>?
    private var didCancel = false
    public init() {}
    public func reset() {
        precondition(self.release == nil && self.started == nil && self.cancelled == nil)
        self.loadedDirectory = nil
        self.loadedDescriptor = nil
        self.didCancel = false
    }
    public func waitUntilStarted() async {
        if self.loadedDirectory != nil { return }
        await withCheckedContinuation { self.started = $0 }
    }
    public func waitUntilCancelled() async {
        if self.didCancel { return }
        await withCheckedContinuation { self.cancelled = $0 }
    }
    public func cancel() {
        self.didCancel = true
        self.cancelled?.resume()
        self.cancelled = nil
    }
    public func open() {
        precondition(self.release != nil)
        self.release?.resume()
        self.release = nil
    }
    public func load(descriptor: GigaAMModelDescriptor, directory: URL) async throws {
        self.loadedDirectory = directory
        self.loadedDescriptor = descriptor.id
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.release = continuation
                self.started?.resume()
                self.started = nil
            }
        } onCancel: {
            Task { await self.cancel() }
        }
        throw GigaAMError.incompatibleModel
    }
}

public actor GigaAMRuntime {
    public nonisolated static var encoderFeatureAPIAvailable: Bool { GigaAMArtifactTestCapabilities.encoderFeatureAPIAvailable }
    public init() throws {}
    public var executionStatus: GigaAMExecutionStatus? { nil }
    public var isReady: Bool { false }
    public func beginAttempt() throws {}
    public func load(descriptor: GigaAMModelDescriptor, directory: URL,
                     executionProvider: GigaAMExecutionProvider = .automatic) async throws {
        try await GigaAMArtifactTestGate.shared.load(descriptor: descriptor, directory: directory)
    }
    public func unload() async {}
    public func transcribe(_ samples: [Float], captureEncoderFeatures: Bool = false,
                           reusingWindowsFor session: GigaAMWindowReuseSession? = nil) async throws -> GigaAMTranscript {
        preconditionFailure("Artifact ownership tests must never perform inference")
    }
    // Inference never runs here, so no window output is retained to discard.
    public func discardWindowReuse(for sessionID: UUID) {}
}

// GigaAMTranscript, GigaAMWordTiming and GigaAMExecutionProvider are real declarations
// the runner appends; it also compiles the real GigaAMWindowReuse.swift beside this file.

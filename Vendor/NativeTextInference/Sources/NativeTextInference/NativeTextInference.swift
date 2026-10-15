import Foundation
import llama

public enum NativeTextInferenceError: Error, LocalizedError, Equatable, Sendable {
    case operationInProgress
    case invalidContextLimit
    case invalidModelURL
    case modelLoadFailed
    case contextCreationFailed
    case modelNotLoaded
    case invalidOutputLimit
    case promptTooLarge
    case contextLimitExceeded(promptTokens: Int, outputTokens: Int, contextTokens: Int)
    case tokenizationFailed
    case decodeFailed(Int32)
    case samplerCreationFailed
    case outputLimitExceeded
    case invalidUTF8
    case tokenPieceTooLarge

    public var errorDescription: String? {
        switch self {
        case .operationInProgress: return "Another native text operation is in progress."
        case .invalidContextLimit: return "The native text context limit must be between 256 and 32768 tokens."
        case .invalidModelURL: return "The native text model must be a local file."
        case .modelLoadFailed: return "The native text model could not be loaded."
        case .contextCreationFailed: return "The native text context could not be created."
        case .modelNotLoaded: return "The native text model is not loaded."
        case .invalidOutputLimit: return "The native text output token limit is invalid."
        case .promptTooLarge: return "The native text prompt exceeds the input size limit."
        case let .contextLimitExceeded(prompt, output, context):
            return "The prompt requires \(prompt) tokens plus \(output) output tokens in a \(context)-token context."
        case .tokenizationFailed: return "The native text prompt could not be tokenized."
        case let .decodeFailed(code): return "Native text decoding failed with code \(code)."
        case .samplerCreationFailed: return "The native text sampler could not be created."
        case .outputLimitExceeded: return "The native text output did not finish within its token limit."
        case .invalidUTF8: return "The native text model emitted invalid UTF-8."
        case .tokenPieceTooLarge: return "The native text model emitted an oversized token."
        }
    }
}

/// Owns an embedded llama.cpp model and its bounded inference context.
/// Model prompts and artifact selection belong to the application's registered adapter.
/// Native work has no suspension points, so load, generation and unload cannot interleave.
public actor NativeTextInference {
    public static let contextTokenLimits = 256...32768
    private var session: NativeSession?
    private var operationInProgress = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public var isLoaded: Bool { self.session != nil }

    /// Counts the exact prompt tokens used by generation without decoding or changing its context.
    public func tokenCount(in text: String) throws -> Int {
        try Task.checkCancellation()
        try self.beginOperation()
        defer { self.finishOperation() }
        guard let session else { throw NativeTextInferenceError.modelNotLoaded }
        return try session.tokenCount(in: text)
    }

    public func load(modelURL: URL, contextTokenLimit: Int) async throws {
        try Task.checkCancellation()
        guard Self.contextTokenLimits.contains(contextTokenLimit) else {
            throw NativeTextInferenceError.invalidContextLimit
        }
        guard modelURL.isFileURL,
              (try? modelURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw NativeTextInferenceError.invalidModelURL
        }
        try self.beginOperation()
        defer { self.finishOperation() }
        // Model switches never retain both sets of weights.
        self.session = nil
        let cancellation = NativeCancellation()
        let loaded = try await withTaskCancellationHandler(operation: {
            let loaded = try NativeSession(modelURL: modelURL, contextTokenLimit: contextTokenLimit, cancellation: cancellation)
            try cancellation.check()
            return loaded
        }, onCancel: { cancellation.cancel() })
        try cancellation.check()
        self.session = loaded
    }

    /// Returns only a complete EOS-terminated response. A token limit never publishes truncation.
    /// streamHandler receives valid UTF-8 fragments; callers must commit output only on success.
    public func generate(
        prompt: String,
        maxOutputTokens: Int,
        streamHandler: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        try Task.checkCancellation()
        try self.beginOperation()
        defer { self.finishOperation() }
        guard let session else { throw NativeTextInferenceError.modelNotLoaded }
        let cancellation = NativeCancellation()
        let output = try await withTaskCancellationHandler(operation: {
            try session.generate(prompt: prompt, maxOutputTokens: maxOutputTokens, cancellation: cancellation, streamHandler: streamHandler)
        }, onCancel: { cancellation.cancel() })
        try cancellation.check()
        return output
    }

    /// Actor ordering joins all prior native work before releasing resources.
    public func unload() async {
        while self.operationInProgress {
            await withCheckedContinuation { self.idleWaiters.append($0) }
        }
        self.session = nil
    }

    private func beginOperation() throws {
        guard !self.operationInProgress else { throw NativeTextInferenceError.operationInProgress }
        self.operationInProgress = true
    }

    private func finishOperation() {
        self.operationInProgress = false
        let waiters = self.idleWaiters
        self.idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

/// Callback state is the only object shared with cancellation's executor.
private final class NativeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { self.lock.withLock { self.cancelled = true } }
    var isCancelled: Bool { self.lock.withLock { self.cancelled } }
    func check() throws {
        if self.isCancelled { throw CancellationError() }
        try Task.checkCancellation()
    }
}

/// C pointers never leave the owning actor. This reference type supplies deterministic deinit.
private final class NativeSession: @unchecked Sendable {
    private static let backendInitialization: Void = { llama_backend_init() }()
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocabulary: OpaquePointer
    private let contextTokenLimit: Int
    private static let batchTokenLimit = 256
    private static let maximumTextBytes = 8 * 1024 * 1024
    private static let maximumTokenPieceBytes = 65536

    init(modelURL: URL, contextTokenLimit: Int, cancellation: NativeCancellation) throws {
        _ = Self.backendInitialization
        try cancellation.check()
        let callbackState = Unmanaged.passUnretained(cancellation).toOpaque()
        var modelParameters = llama_model_default_params()
        #if arch(arm64)
        modelParameters.n_gpu_layers = -1
        #else
        modelParameters.n_gpu_layers = 0
        #endif
        modelParameters.progress_callback = { _, state in
            guard let state else { return false }
            return !Unmanaged<NativeCancellation>.fromOpaque(state).takeUnretainedValue().isCancelled
        }
        modelParameters.progress_callback_user_data = callbackState
        let loadedModel = modelURL.path.withCString { llama_model_load_from_file($0, modelParameters) }
        guard let loadedModel else {
            try cancellation.check()
            throw NativeTextInferenceError.modelLoadFailed
        }
        var keepModel = false
        defer { if !keepModel { llama_model_free(loadedModel) } }
        try cancellation.check()
        guard let vocabulary = llama_model_get_vocab(loadedModel) else {
            throw NativeTextInferenceError.modelLoadFailed
        }
        var contextParameters = llama_context_default_params()
        contextParameters.n_ctx = UInt32(contextTokenLimit)
        contextParameters.n_batch = UInt32(Self.batchTokenLimit)
        contextParameters.n_ubatch = UInt32(Self.batchTokenLimit)
        contextParameters.n_seq_max = 1
        let threads = Int32(min(8, max(1, ProcessInfo.processInfo.activeProcessorCount)))
        contextParameters.n_threads = threads
        contextParameters.n_threads_batch = threads
        contextParameters.no_perf = true
        guard let loadedContext = llama_init_from_model(loadedModel, contextParameters) else {
            throw NativeTextInferenceError.contextCreationFailed
        }
        var keepContext = false
        defer { if !keepContext { llama_free(loadedContext) } }
        try cancellation.check()
        self.model = loadedModel
        self.context = loadedContext
        self.vocabulary = vocabulary
        // llama.cpp may pad an allocation; enforce the caller's smaller logical budget.
        self.contextTokenLimit = min(contextTokenLimit, Int(llama_n_ctx(loadedContext)))
        keepContext = true
        keepModel = true
    }

    deinit {
        llama_free(self.context)
        llama_model_free(self.model)
    }

    func generate(
        prompt: String,
        maxOutputTokens: Int,
        cancellation: NativeCancellation,
        streamHandler: (@Sendable (String) -> Void)?
    ) throws -> String {
        try cancellation.check()
        guard maxOutputTokens > 0, maxOutputTokens < self.contextTokenLimit else {
            throw NativeTextInferenceError.invalidOutputLimit
        }
        var tokens = try self.tokenize(prompt, maxOutputTokens: maxOutputTokens)
        try cancellation.check()
        guard let memory = llama_get_memory(self.context) else { throw NativeTextInferenceError.contextCreationFailed }
        llama_memory_clear(memory, true)
        let callbackState = Unmanaged.passUnretained(cancellation).toOpaque()
        llama_set_abort_callback(self.context, { state in
            guard let state else { return true }
            return Unmanaged<NativeCancellation>.fromOpaque(state).takeUnretainedValue().isCancelled
        }, callbackState)
        defer {
            // Cleanup is joined even after an interrupted partial native decode.
            llama_set_abort_callback(self.context, nil, nil)
            llama_memory_clear(memory, true)
        }
        guard let sampler = llama_sampler_init_greedy() else { throw NativeTextInferenceError.samplerCreationFailed }
        defer { llama_sampler_free(sampler) }
        for start in stride(from: 0, to: tokens.count, by: Self.batchTokenLimit) {
            try cancellation.check()
            let count = min(Self.batchTokenLimit, tokens.count - start)
            let code = tokens.withUnsafeMutableBufferPointer { buffer in
                llama_decode(self.context, llama_batch_get_one(buffer.baseAddress!.advanced(by: start), Int32(count)))
            }
            try cancellation.check()
            guard code == 0 else { throw NativeTextInferenceError.decodeFailed(code) }
        }
        var decoder = IncrementalUTF8Decoder()
        var output = ""
        for generated in 0...maxOutputTokens {
            try cancellation.check()
            var token = llama_sampler_sample(sampler, self.context, -1)
            if llama_vocab_is_eog(self.vocabulary, token) {
                try decoder.finish()
                try cancellation.check()
                return output
            }
            guard generated < maxOutputTokens else { throw NativeTextInferenceError.outputLimitExceeded }
            let fragment = try decoder.append(self.piece(for: token))
            guard output.utf8.count + fragment.utf8.count <= Self.maximumTextBytes else {
                throw NativeTextInferenceError.outputLimitExceeded
            }
            output += fragment
            if !fragment.isEmpty { streamHandler?(fragment) }
            try cancellation.check()
            let code = llama_decode(self.context, llama_batch_get_one(&token, 1))
            try cancellation.check()
            guard code == 0 else { throw NativeTextInferenceError.decodeFailed(code) }
        }
        throw NativeTextInferenceError.outputLimitExceeded
    }

    func tokenCount(in text: String) throws -> Int {
        try Task.checkCancellation()
        let byteCount = text.utf8.count
        guard byteCount <= Self.maximumTextBytes else { throw NativeTextInferenceError.promptTooLarge }
        guard byteCount > 0 else { throw NativeTextInferenceError.tokenizationFailed }
        let required = text.withCString {
            llama_tokenize(self.vocabulary, $0, Int32(byteCount), nil, 0, true, true)
        }
        try Task.checkCancellation()
        guard required < 0, required != Int32.min else { throw NativeTextInferenceError.tokenizationFailed }
        return Int(-required)
    }

    private func tokenize(_ prompt: String, maxOutputTokens: Int) throws -> [llama_token] {
        let count = try self.tokenCount(in: prompt)
        guard count + maxOutputTokens <= self.contextTokenLimit else {
            throw NativeTextInferenceError.contextLimitExceeded(promptTokens: count, outputTokens: maxOutputTokens, contextTokens: self.contextTokenLimit)
        }
        var tokens = [llama_token](repeating: 0, count: count)
        let written = prompt.withCString { text in
            tokens.withUnsafeMutableBufferPointer { buffer in
                llama_tokenize(self.vocabulary, text, Int32(prompt.utf8.count), buffer.baseAddress, Int32(buffer.count), true, true)
            }
        }
        guard written == count else { throw NativeTextInferenceError.tokenizationFailed }
        return tokens
    }

    private func piece(for token: llama_token) throws -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 256)
        var written = llama_token_to_piece(self.vocabulary, token, &buffer, Int32(buffer.count), 0, false)
        if written < 0 {
            guard written != Int32.min, Int(-written) <= Self.maximumTokenPieceBytes else {
                throw NativeTextInferenceError.tokenPieceTooLarge
            }
            buffer = [CChar](repeating: 0, count: Int(-written))
            written = llama_token_to_piece(self.vocabulary, token, &buffer, Int32(buffer.count), 0, false)
        }
        guard written >= 0, Int(written) <= buffer.count else { throw NativeTextInferenceError.tokenizationFailed }
        return buffer.prefix(Int(written)).map { UInt8(bitPattern: $0) }
    }
}

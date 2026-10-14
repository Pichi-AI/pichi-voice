import Foundation

/// Serializes transcription operations and lets teardown cancel the real queued work.
actor TranscriptionExecutor {
    private var lastTask: Task<Void, Never>?
    private var lastTaskID: UUID?
    private var operationCancellations: [UUID: () -> Void] = [:]

    #if DEBUG
    var pendingOperationCountForTesting: Int { self.operationCancellations.count }
    #endif

    func run<T>(benchmarkSessionID: Int? = nil, _ operation: @escaping () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        logTranscriptionExecutorPhase("entered", sessionID: benchmarkSessionID)
        let previous = self.lastTask
        let operationID = UUID()
        let task = Task<T, Error> {
            logTranscriptionExecutorPhase("task_started", sessionID: benchmarkSessionID)
            _ = await previous?.result
            logTranscriptionExecutorPhase("previous_finished", sessionID: benchmarkSessionID)
            try Task.checkCancellation()
            let result = try await operation()
            try Task.checkCancellation()
            return result
        }
        self.operationCancellations[operationID] = { task.cancel() }
        self.lastTask = Task { _ = try? await task.value }
        self.lastTaskID = operationID
        defer { self.operationCancellations.removeValue(forKey: operationID) }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            task.cancel()
        }
    }

    func cancelAndAwaitPending() async {
        let pending = self.lastTask
        let pendingID = self.lastTaskID
        let cancellations = self.operationCancellations
        for cancel in cancellations.values {
            cancel()
        }
        _ = await pending?.result
        if self.lastTaskID == pendingID {
            self.lastTask = nil
            self.lastTaskID = nil
        }
        // A newer queued operation may have arrived while the old work drained.
        // Retire only the captured ownership set, preserving its cancellation handle.
        for id in cancellations.keys { self.operationCancellations.removeValue(forKey: id) }
    }
}

private nonisolated func logTranscriptionExecutorPhase(_ phase: String, sessionID: Int?) {
    guard DebugLogger.diagnosticsEnabled, let sessionID else { return }
    let timestamp = ProcessInfo.processInfo.systemUptime
    DebugLogger.shared.debug(
        "ASR_BENCH t=\(timestamp) session=\(sessionID) final_queue_\(phase) mainThread=\(Thread.isMainThread)",
        source: "ASRBenchmark"
    )
}

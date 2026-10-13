import Foundation

/// The provider owns its artifact transport and validation. This shared operation preserves
/// the existing preparation cancellation/cleanup behavior for all service entry points.
@MainActor
enum SpeechModelPreparationOperation {
    static func prepare(
        provider: any TranscriptionProvider,
        updateWeights: Bool = false,
        progress: @escaping (ModelPreparationProgress) -> Void
    ) async throws {
        do {
            try await provider.prepare(progressHandler: progress)
            if !updateWeights { try Task.checkCancellation() }
        } catch {
            if ParakeetArchiveDownloader.isCleanupFailure(error) { throw error }
            let cancelled = Task.isCancelled || error is CancellationError
                || (error as NSError).code == NSURLErrorCancelled
            if cancelled, !updateWeights, provider.shouldClearCacheAfterCancellation,
               provider.modelsExistOnDisk() == false {
                try? await provider.clearCache()
            }
            if cancelled { throw CancellationError() }
            throw error
        }
    }
}

import Foundation
#if canImport(FluidAudio)
import FluidAudio

/// Reuse dependency folder names without sharing its mutable model directory with FluidVoice.
nonisolated enum AppModelPaths {
    static func parakeet(for version: AsrModelVersion = .v3) -> URL {
        AppBrand.modelsDirectory.appendingPathComponent(AsrModels.defaultCacheDirectory(for: version).lastPathComponent, isDirectory: true)
    }
}
#endif

import Foundation
import Metal
import os

/// Capacity admission is a conservative policy, not a claim that a file's
/// byte count equals runtime RAM or that every GPU below this limit fails.
public struct GigaAMResourcePolicy: Sendable, Equatable {
    public let hasGPU: Bool
    public let physicalMemory: UInt64
    public let availableProcessMemory: UInt64?

    public init(hasGPU: Bool, physicalMemory: UInt64, availableProcessMemory: UInt64? = nil) {
        self.hasGPU = hasGPU
        self.physicalMemory = physicalMemory
        self.availableProcessMemory = availableProcessMemory
    }

    public static var current: Self {
        #if os(iOS)
        // Zero is meaningful for an iOS app, but the API may report zero for
        // an unmanaged tool. Keep unknown separate from measured exhaustion.
        let headroom: UInt64? = Bundle.main.bundleURL.pathExtension == "app"
            ? UInt64(os_proc_available_memory()) : nil
        #else
        let headroom: UInt64? = nil
        #endif
        return Self(hasGPU: MTLCreateSystemDefaultDevice() != nil,
                    physicalMemory: ProcessInfo.processInfo.physicalMemory,
                    availableProcessMemory: headroom)
    }

    /// Preserve the existing compact CPU route on nominal 4 GB tablets.
    /// This stable hardware decision may be cached by the model store; volatile
    /// process headroom is rechecked only at native preparation boundaries.
    public var automaticGPUProfileAllowed: Bool {
        self.hasGPU && self.physicalMemory >= 8_000_000_000
    }

    public var gpuAdmissionReason: GigaAMExecutionStatus.FallbackReason? {
        guard self.hasGPU else { return .gpuUnavailable }
        guard self.automaticGPUProfileAllowed else { return .memoryBudget }
        if let bytes = self.availableProcessMemory, bytes < 768 * 1_024 * 1_024 { return .memoryBudget }
        return nil
    }

    public var preferredDownload: GigaAMModelDescriptor {
        self.automaticGPUProfileAllowed ? GigaAMModelCatalog.downloadableModel : GigaAMModelCatalog.compactONNXModel
    }

    public var defaultCPUReason: GigaAMExecutionStatus.FallbackReason? {
        self.automaticGPUProfileAllowed ? nil : (self.hasGPU ? .memoryBudget : .gpuUnavailable)
    }
}

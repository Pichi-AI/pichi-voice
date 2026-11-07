import Foundation
import Metal
import os

/// One public artifact serves every device. Native preparation checks current
/// process headroom separately from total device RAM and model file size.
public struct GigaAMResourcePolicy: Sendable, Equatable {
    public let hasGPU: Bool
    public let physicalMemory: UInt64
    public let availableProcessMemory: UInt64?
    public let requiresBackgroundExecution: Bool

    public init(hasGPU: Bool, physicalMemory: UInt64, availableProcessMemory: UInt64? = nil,
                requiresBackgroundExecution: Bool = false) {
        self.hasGPU = hasGPU
        self.physicalMemory = physicalMemory
        self.availableProcessMemory = availableProcessMemory
        self.requiresBackgroundExecution = requiresBackgroundExecution
    }

    public static var current: Self {
        #if os(iOS) && !targetEnvironment(simulator)
        // Zero is meaningful for an iOS app, but the API may report zero for
        // an unmanaged tool. Keep unknown separate from measured exhaustion.
        let headroom: UInt64? = Bundle.main.bundleURL.pathExtension == "app"
            ? UInt64(os_proc_available_memory()) : nil
        #else
        // The simulator enforces no per-process limit and always reports zero.
        let headroom: UInt64? = nil
        #endif
        #if os(iOS)
        // Audio recording can continue while inactive/backgrounded, but Metal cannot.
        // Select CPU before loading and keep it for the complete operation. Checking
        // scene state before each prediction races an in-flight GPU command when
        // Notification Center, the Home screen or another application takes over.
        let requiresBackgroundExecution = true
        #else
        let requiresBackgroundExecution = false
        #endif
        return Self(hasGPU: MTLCreateSystemDefaultDevice() != nil,
                    physicalMemory: ProcessInfo.processInfo.physicalMemory,
                    availableProcessMemory: headroom,
                    requiresBackgroundExecution: requiresBackgroundExecution)
    }

    public var gpuAdmissionReason: GigaAMExecutionStatus.FallbackReason? {
        if self.requiresBackgroundExecution { return .backgroundExecution }
        guard self.hasGPU else { return .gpuUnavailable }
        if let bytes = self.availableProcessMemory, bytes < 768 * 1_024 * 1_024 { return .memoryBudget }
        return nil
    }

    public var preferredDownload: GigaAMModelDescriptor {
        GigaAMModelCatalog.downloadableModel
    }

    public var defaultCPUReason: GigaAMExecutionStatus.FallbackReason? {
        if self.requiresBackgroundExecution { return .backgroundExecution }
        return self.hasGPU ? nil : .gpuUnavailable
    }
}

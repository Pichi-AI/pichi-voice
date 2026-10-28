import Foundation

/// Persisted IDs also control dictation practice routing. Optional steps must not renumber them.
nonisolated enum DesktopOnboardingNavigation {
    static let lastLegacyStep = 6
    static let accountStep = 7

    static func lastStep(includesAccount: Bool) -> Int {
        includesAccount ? accountStep : lastLegacyStep
    }

    static func resolvedStep(_ storedStep: Int, includesAccount: Bool) -> Int {
        max(0, min(lastStep(includesAccount: includesAccount), storedStep))
    }

    static func next(after step: Int, includesAccount: Bool) -> Int {
        let current = resolvedStep(step, includesAccount: includesAccount)
        return min(lastStep(includesAccount: includesAccount), current + 1)
    }

    static func previous(before step: Int, includesAccount: Bool) -> Int {
        max(0, resolvedStep(step, includesAccount: includesAccount) - 1)
    }

    static func progress(at step: Int, includesAccount: Bool, includesCurrent: Bool) -> Double {
        let current = resolvedStep(step, includesAccount: includesAccount)
        let offset = includesCurrent ? 1 : 0
        return Double(current + offset) / Double(lastStep(includesAccount: includesAccount) + offset)
    }
}

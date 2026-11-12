import Foundation

/// Persisted IDs also control dictation practice routing. Optional steps must not renumber them.
nonisolated enum DesktopOnboardingNavigation {
    static let lastLegacyStep = 6
    static let accountStep = 7
    static let ownerVoiceStep = 8

    /// Voice setup follows permissions, while legacy practice and account IDs remain unchanged.
    static func orderedSteps(includesAccount: Bool) -> [Int] {
        let steps = [0, 1, 2, 3, ownerVoiceStep, 4, 5, lastLegacyStep]
        return includesAccount ? steps + [accountStep] : steps
    }

    static func lastStep(includesAccount: Bool) -> Int {
        includesAccount ? accountStep : lastLegacyStep
    }

    static func resolvedStep(_ storedStep: Int, includesAccount: Bool) -> Int {
        let steps = orderedSteps(includesAccount: includesAccount)
        if steps.contains(storedStep) { return storedStep }
        return storedStep < 0 ? steps[0] : lastStep(includesAccount: includesAccount)
    }

    static func next(after step: Int, includesAccount: Bool) -> Int {
        let steps = orderedSteps(includesAccount: includesAccount)
        let current = resolvedStep(step, includesAccount: includesAccount)
        guard let index = steps.firstIndex(of: current) else { return steps[0] }
        return steps[min(index + 1, steps.count - 1)]
    }

    static func previous(before step: Int, includesAccount: Bool) -> Int {
        let steps = orderedSteps(includesAccount: includesAccount)
        let current = resolvedStep(step, includesAccount: includesAccount)
        guard let index = steps.firstIndex(of: current) else { return steps[0] }
        return steps[max(0, index - 1)]
    }

    static func progress(at step: Int, includesAccount: Bool, includesCurrent: Bool) -> Double {
        let steps = orderedSteps(includesAccount: includesAccount)
        let current = resolvedStep(step, includesAccount: includesAccount)
        guard let index = steps.firstIndex(of: current) else { return 0 }
        let offset = includesCurrent ? 1 : 0
        return Double(index + offset) / Double(steps.count - 1 + offset)
    }

    static func stepNumber(at step: Int, includesAccount: Bool) -> Int {
        let steps = orderedSteps(includesAccount: includesAccount)
        let current = resolvedStep(step, includesAccount: includesAccount)
        return (steps.firstIndex(of: current) ?? 0) + 1
    }
}

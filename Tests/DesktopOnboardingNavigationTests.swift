import Foundation

@main
struct DesktopOnboardingNavigationTests {
    static func main() {
        typealias Navigation = DesktopOnboardingNavigation
        for available in [false, true] {
            let expected = [0, 1, 2, 3, 8, 4, 5, 6] + (available ? [7] : [])
            precondition(Navigation.orderedSteps(includesAccount: available) == expected)
            precondition(expected.map { Navigation.stepNumber(at: $0, includesAccount: available) } == Array(1...expected.count),
                         "Visible step numbers follow presentation order rather than persisted IDs")
            for legacy in 0...6 {
                precondition(Navigation.resolvedStep(legacy, includesAccount: available) == legacy,
                             "Existing persisted screens must retain their IDs")
            }
            precondition(Navigation.resolvedStep(8, includesAccount: available) == 8,
                         "An interrupted voice setup resumes its own screen")
            precondition(Navigation.resolvedStep(Int.min, includesAccount: available) == 0)
            precondition(Navigation.resolvedStep(Int.max, includesAccount: available) == (available ? 7 : 6))
            precondition(Navigation.previous(before: 0, includesAccount: available) == 0)
            precondition(Navigation.next(after: 3, includesAccount: available) == 8,
                         "Voice setup follows microphone permissions")
            precondition(Navigation.previous(before: 8, includesAccount: available) == 3)
            precondition(Navigation.next(after: 8, includesAccount: available) == 4,
                         "Both recording completion and optional skip lead to dictation practice")
            precondition(Navigation.previous(before: 4, includesAccount: available) == 8)
            var current = 0
            var traversed = [current]
            while current != Navigation.lastStep(includesAccount: available) {
                current = Navigation.next(after: current, includesAccount: available)
                traversed.append(current)
                precondition(traversed.count <= expected.count, "Navigation must terminate")
            }
            precondition(traversed == expected, "Every step is reachable exactly once")
            current = Navigation.lastStep(includesAccount: available)
            var reversed = [current]
            while current != 0 {
                current = Navigation.previous(before: current, includesAccount: available)
                reversed.append(current)
                precondition(reversed.count <= expected.count)
            }
            precondition(reversed == Array(expected.reversed()))
            for compact in [false, true] {
                let values = expected.map {
                    Navigation.progress(at: $0, includesAccount: available, includesCurrent: compact)
                }
                precondition(values.allSatisfy { (0...1).contains($0) })
                precondition(values == values.sorted())
                precondition(Set(values).count == expected.count)
                precondition(values.last == 1)
            }
        }
        precondition(Navigation.next(after: 5, includesAccount: true) == 6)
        precondition(Navigation.next(after: 6, includesAccount: true) == 7)
        precondition(Navigation.previous(before: 7, includesAccount: true) == 6)
        precondition(Navigation.next(after: 7, includesAccount: true) == 7)
        precondition(Navigation.next(after: 6, includesAccount: false) == 6)
        precondition(Navigation.resolvedStep(7, includesAccount: false) == 6,
                     "Removing account configuration must resume the last legacy screen")
        precondition(Navigation.previous(before: 7, includesAccount: false) == 5)
        print("PASS: stable desktop onboarding IDs, resumable optional voice setup, account on/off, complete forward/back traversal and ordered progress")
    }
}

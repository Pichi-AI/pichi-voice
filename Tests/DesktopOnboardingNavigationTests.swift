import Foundation

@main
struct DesktopOnboardingNavigationTests {
    static func main() {
        typealias Navigation = DesktopOnboardingNavigation
        for available in [false, true] {
            for legacy in 0...6 {
                precondition(Navigation.resolvedStep(legacy, includesAccount: available) == legacy,
                             "Existing persisted screens must retain their IDs")
            }
            precondition(Navigation.resolvedStep(Int.min, includesAccount: available) == 0)
            precondition(Navigation.resolvedStep(Int.max, includesAccount: available) == (available ? 7 : 6))
            precondition(Navigation.previous(before: 0, includesAccount: available) == 0)
            for compact in [false, true] {
                let values = (0...Navigation.lastStep(includesAccount: available)).map {
                    Navigation.progress(at: $0, includesAccount: available, includesCurrent: compact)
                }
                precondition(values.allSatisfy { (0...1).contains($0) })
                precondition(values == values.sorted())
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
        print("PASS: stable desktop onboarding IDs, optional final account step, removed configuration, bounded navigation and progress")
    }
}

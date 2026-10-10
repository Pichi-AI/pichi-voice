import Foundation

// Standalone harness only; the macOS target uses the app's real localization.
nonisolated enum PichiLocalization {
    static func text(_ value: String) -> String { value }
    static func format(_ value: String, _ arguments: CVarArg...) -> String { String(format: value, arguments: arguments) }
}

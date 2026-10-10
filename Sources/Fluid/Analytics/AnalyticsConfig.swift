import Foundation

struct AnalyticsConfig {
    let postHogApiKey: String
    let postHogHost: String

    /// Default EU ingestion host.
    nonisolated static let defaultEUHost = "https://eu.i.posthog.com"

    nonisolated static func fromBundle() -> AnalyticsConfig {
        // No downstream analytics endpoint has been approved for this distribution.
        return AnalyticsConfig(postHogApiKey: "", postHogHost: AnalyticsConfig.defaultEUHost)
    }

    nonisolated var isConfigured: Bool {
        !self.postHogApiKey.isEmpty
    }
}

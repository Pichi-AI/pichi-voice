import Foundation

/// Trusted distribution settings. Runtime theme files cannot enable telemetry
/// or redirect an installed app's analytics to another destination.
nonisolated struct AnalyticsConfig: Equatable {
    let postHogApiKey: String
    let postHogHost: String

    nonisolated static func fromBundle() -> AnalyticsConfig {
        self.from(info: Bundle.main.infoDictionary ?? [:])
    }

    nonisolated static func from(info: [String: Any]) -> AnalyticsConfig {
        let disabled = AnalyticsConfig(postHogApiKey: "", postHogHost: "")
        let enabled = (info["PICHI_POSTHOG_ENABLED"] as? String)?.lowercased() == "yes"
        guard enabled,
              let key = info["PICHI_POSTHOG_PROJECT_TOKEN"] as? String,
              self.isProjectToken(key),
              let host = info["PICHI_POSTHOG_HOST"] as? String,
              self.validatedHost(host) != nil
        else { return disabled }
        return AnalyticsConfig(postHogApiKey: key, postHogHost: host)
    }

    nonisolated var isConfigured: Bool {
        Self.isProjectToken(self.postHogApiKey) && Self.validatedHost(self.postHogHost) != nil
    }

    nonisolated var batchURL: URL? {
        guard self.isConfigured, let host = Self.validatedHost(self.postHogHost) else { return nil }
        return host.appendingPathComponent("batch")
    }

    private nonisolated static func isProjectToken(_ value: String) -> Bool {
        // Never package a personal/admin API token (phx_*) or unresolved build variable.
        value.hasPrefix("phc_") && (8...256).contains(value.count)
            && value.utf8.allSatisfy { byte in
                (65...90).contains(byte) || (97...122).contains(byte)
                    || (48...57).contains(byte) || byte == 95 || byte == 45
            }
    }

    private nonisolated static func validatedHost(_ value: String) -> URL? {
        guard let components = URLComponents(string: value), components.scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              components.port == nil || components.port == 443
        else { return nil }
        // The host comes from the distributor's trusted build config, including
        // a self-hosted HTTPS instance. No cloud region or upstream token fallback.
        return components.url
    }
}

import Foundation

/// Direct typed batch ingestion avoids SDK autocapture, session replay and
/// automatic device/person properties. Redirects never receive a batch/token.
final nonisolated class AnalyticsRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

nonisolated enum AnalyticsUploadTransport {
    private static let approvedPropertyKeys: Set<String> = {
        var keys: Set<String> = [
            "distinct_id", "platform", "$os", "app_version", "ram_gb", "chip", "schema_version",
            "activity_kind", "activity_date", "usage_date", "dictation_count", "command_count", "edit_count", "meeting_count",
            "role", "mode", "provider", "model", "use_count", "flow_id", "origin", "step", "outcome",
            "duration_bucket", "attempt_count_bucket", "start_method", "failure_stage", "download_id", "source", "duration_seconds",
            "latency_date", "delivery_path", "request_count", "request_total_ms", "request_average_ms", "request_min_ms", "request_max_ms",
            "ready_count", "ready_total_ms", "ready_average_ms", "ready_min_ms", "ready_max_ms",
            "toggle_stop_to_dispatch_count", "toggle_stop_to_dispatch_total_ms", "toggle_stop_to_dispatch_average_ms",
            "toggle_stop_to_dispatch_min_ms", "toggle_stop_to_dispatch_max_ms",
            "performance_date", "measured_app_version", "measured_os_version", "histogram_schema_version",
        ]
        for prefix in ["asr", "fluid_intelligence", "pico_tps", "mini_tps"] {
            for suffix in ["sample_count", "p50_bucket", "p95_bucket"] { keys.insert("\(prefix)_\(suffix)") }
        }
        return keys
    }()
    static let redirectPolicy = AnalyticsRedirectPolicy()
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration, delegate: redirectPolicy, delegateQueue: nil)
    }()

    static func request(items: [AnalyticsOutboxItem], config: AnalyticsConfig) throws -> URLRequest {
        guard let url = config.batchURL else { throw URLError(.badURL) }
        let batch = try items.map { item -> Any in
            let stored = try JSONSerialization.jsonObject(with: item.payload) as? [String: Any] ?? [:]
            guard let name = stored["event"] as? String, AnalyticsEvent(rawValue: name) != nil,
                  let storedProperties = stored["properties"] as? [String: Any]
            else { throw URLError(.cannotParseResponse) }
            var properties = storedProperties.filter { self.approvedPropertyKeys.contains($0.key) }
            // Also sanitize older outbox payloads created before this policy.
            properties.removeValue(forKey: "$set")
            properties["$process_person_profile"] = false
            properties["$geoip_disable"] = true
            properties["$ip"] = ""
            properties["app_bundle_id"] = Bundle.main.bundleIdentifier ?? "unknown"
            properties["app_product"] = "desktop_voice"
            if let provider = properties["provider"] as? String, let model = properties["model"] as? String {
                let descriptor = AnalyticsModelDescriptor(provider: provider, model: model)
                properties["provider"] = descriptor.provider
                properties["model"] = descriptor.model
            }
            var event: [String: Any] = ["event": name, "properties": properties]
            for key in ["uuid", "timestamp"] { event[key] = stored[key] }
            return event
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["api_key": config.postHogApiKey, "batch": batch])
        return request
    }

    static func send(items: [AnalyticsOutboxItem], config: AnalyticsConfig) async throws -> Int {
        let request = try self.request(items: items, config: config)
        let (_, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return http.statusCode
    }
}

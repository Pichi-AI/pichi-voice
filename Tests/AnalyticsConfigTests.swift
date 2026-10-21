import Foundation

// The application defines the same outbox value in AnalyticsDatabase.swift.
struct AnalyticsOutboxItem { let id: String; let payload: Data }

@main
enum AnalyticsConfigTests {
    static func main() throws {
        try self.check(!AnalyticsConfig.from(info: [:]).isConfigured, "An unconfigured distribution must send nothing")
        let info: [String: Any] = [
            "PICHI_POSTHOG_ENABLED": "YES", "PICHI_POSTHOG_PROJECT_TOKEN": "phc_testfixture",
            "PICHI_POSTHOG_HOST": "https://eu.i.posthog.com",
        ]
        let config = AnalyticsConfig.from(info: info)
        try self.check(config.batchURL?.absoluteString == "https://eu.i.posthog.com/batch", "Correct explicit ingestion origin")
        for invalid in ["", "phx_admin_fixture", "$(PICHI_POSTHOG_PROJECT_TOKEN)", "phc_test\nsecond"] {
            var modified = info
            modified["PICHI_POSTHOG_PROJECT_TOKEN"] = invalid
            try self.check(!AnalyticsConfig.from(info: modified).isConfigured, "Do not accept secret or unresolved tokens")
        }
        for invalid in ["http://eu.i.posthog.com", "https://user:password@eu.i.posthog.com", "https://eu.i.posthog.com/?key=secret", "https://eu.i.posthog.com/#destination", "https://eu.i.posthog.com/other", "https://eu.i.posthog.com:8443"] {
            var modified = info
            modified["PICHI_POSTHOG_HOST"] = invalid
            try self.check(!AnalyticsConfig.from(info: modified).isConfigured, "Do not accept malformed or insecure ingestion config")
        }
        for key in ["PICHI_POSTHOG_ENABLED", "PICHI_POSTHOG_PROJECT_TOKEN", "PICHI_POSTHOG_HOST"] {
            var modified = info
            modified.removeValue(forKey: key)
            try self.check(!AnalyticsConfig.from(info: modified).isConfigured, "Every trusted config field is required")
        }
        try self.check(!AnalyticsConfig.from(info: ["POSTHOG_API_KEY": "phc_upstreamfixture", "POSTHOG_HOST": "https://eu.i.posthog.com"]).isConfigured, "Never use upstream keys")
        let custom = AnalyticsModelDescriptor(provider: "Client Alice alice@example.com", model: "/Users/alice/private/customer.onnx")
        try self.check(custom.provider == "custom_provider" && custom.model == "custom_model", "Private aliases and paths must be collapsed")
        let known = AnalyticsModelDescriptor(provider: "SaluteDevices", model: "gigaam-v3-eou")
        try self.check(known.provider == "salutedevices" && known.model == "gigaam-v3-eou", "Retain approved public model metrics")
        let recorded = AnalyticsModelDescriptor(provider: "pichi", model: "gigaam-v3-eou")
        try self.check(recorded.provider == "pichi", "Rows recorded before the publisher credit keep their provider")
        let payload: [String: Any] = ["event": "model_usage_daily_summary", "properties": [
            "distinct_id": "anonymous-test-install", "provider": "private bank", "model": "alice@example.com",
            "$set": ["name": "Alice"], "use_count": 2,
            "transcript": "private speech", "filename": "/private/audio.wav", "recording_url": "file:///private/audio.wav",
        ]]
        let item = AnalyticsOutboxItem(id: "synthetic", payload: try JSONSerialization.data(withJSONObject: payload))
        let request = try AnalyticsUploadTransport.request(items: [item], config: config)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let batch = body["batch"] as! [[String: Any]]
        let properties = batch[0]["properties"] as! [String: Any]
        try self.check(properties["$set"] == nil, "Never create person profiles from an older queued batch")
        try self.check(properties["$process_person_profile"] as? Bool == false && properties["$geoip_disable"] as? Bool == true, "Anonymous event flags")
        try self.check(properties["$ip"] as? String == "", "Do not enrich network address")
        try self.check(properties["provider"] as? String == "custom_provider" && properties["model"] as? String == "custom_model", "Sanitize old custom identifiers at upload")
        try self.check(properties["use_count"] as? Int == 2, "Keep approved metric counts")
        try self.check(properties["transcript"] == nil && properties["filename"] == nil && properties["recording_url"] == nil, "Unknown/private fields never leave the outbox")
        let session = AnalyticsUploadTransport.session.configuration
        try self.check(session.httpCookieStorage == nil && session.urlCredentialStorage == nil && session.urlCache == nil, "No cookies, shared credentials or cache")
        let task = AnalyticsUploadTransport.session.dataTask(with: URL(string: "https://example.com")!)
        let redirect = RedirectResult()
        AnalyticsUploadTransport.redirectPolicy.urlSession(AnalyticsUploadTransport.session, task: task,
            willPerformHTTPRedirection: HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil, headerFields: nil)!,
            newRequest: URLRequest(url: URL(string: "https://example.com/redirect")!), completionHandler: { redirect.set($0 != nil) })
        try self.check(!redirect.value, "Never forward token/events through a redirect")
        print("Analytics configuration/privacy checks passed")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "AnalyticsConfigTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}

private final nonisolated class RedirectResult: @unchecked Sendable {
    private let lock = NSLock()
    private var redirected = true
    var value: Bool { self.lock.withLock { self.redirected } }
    func set(_ value: Bool) { self.lock.withLock { self.redirected = value } }
}

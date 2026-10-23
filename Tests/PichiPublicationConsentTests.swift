import Darwin
import Foundation

@main
struct PichiPublicationConsentTests {
    static func main() async throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath()
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: root) }
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            checks += 1
        }
        func configuration(_ field: String = "") -> AccountConfiguration {
            .init(issuer: URL(string: field == "issuer" ? "https://identity.example/realms/other" : "https://identity.example/realms/pichi")!,
                apiBaseURL: URL(string: field == "api" ? "https://other-api.example" : "https://api.example")!,
                clientID: field == "client" ? "another-client" : "synthetic-native",
                apiAudience: field == "audience" ? "another-audience" : "synthetic-api",
                bundleIdentifier: field == "bundle" ? "ai.synthetic.other" : "ai.synthetic.voice")
        }
        func context(_ field: String = "", configuration: AccountConfiguration? = nil) -> AccountContext {
            .init(identity: .init(issuer: (configuration ?? trustedConfiguration).issuer.absoluteString,
                subject: field == "subject" ? "synthetic-B" : "synthetic-A",
                internalUserID: field == "user" ? "user-B" : "user-A"),
                organizationID: field == "organization" ? "organization-B" : "organization-A",
                workspaceID: field == "workspace" ? "workspace-B" : "workspace-A", generation: UUID())
        }
        let trustedConfiguration = configuration()
        let a = context()
        let store = PichiPublicationConsentStore(directory: root, configuration: trustedConfiguration)
        check(try await !store.automaticPublicationEnabled(for: a), "A new account/workspace defaults off")
        check(try manager.contentsOfDirectory(atPath: root.path).isEmpty, "Reading absent consent never writes a setting")
        try await store.setAutomaticPublicationEnabled(true, for: a)
        check(try await store.automaticPublicationEnabled(for: a), "Explicit opt-in persists")
        let restarted = PichiPublicationConsentStore(directory: root, configuration: trustedConfiguration)
        check(try await restarted.automaticPublicationEnabled(for: context()),
              "The same verified owner/workspace retains consent across a new process-local generation")
        for field in ["subject", "user", "organization", "workspace"] {
            check(try await !store.automaticPublicationEnabled(for: context(field)),
                  "Consent cannot cross an owner or destination boundary: " + field)
        }
        for field in ["issuer", "api", "client", "audience", "bundle"] {
            let config = configuration(field)
            let other = PichiPublicationConsentStore(directory: root, configuration: config)
            check(try await !other.automaticPublicationEnabled(for: context(configuration: config)),
                  "Consent cannot cross a trusted distribution boundary: " + field)
        }
        let files = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        check(files.count == 1 && files[0].lastPathComponent.range(of: "^[a-f0-9]{64}\\.json$", options: .regularExpression) != nil,
              "Stable digest filenames contain no raw account identifiers")
        let recordURL = files[0]
        let initialBytes = try Data(contentsOf: recordURL)
        check(!(String(data: initialBytes, encoding: .utf8) ?? "").contains(a.generation.uuidString),
              "Process-local generation is not a durable consent identity")
        let permissions = try manager.attributesOfItem(atPath: recordURL.path)[.posixPermissions] as? NSNumber
        check(permissions?.intValue == 0o600, "Consent files are private from first creation")
        check(try await !store.deliveryPaused(for: a), "Pause defaults false independently of future-capture consent")
        try await store.setDeliveryPaused(true, for: a)
        check(try await restarted.deliveryPaused(for: a), "Explicit pause is durable across a new actor")
        check(try await !store.deliveryPaused(for: context("subject")), "Pause cannot cross account ownership")
        try await restarted.setAutomaticPublicationEnabled(false, for: a)
        check(try await store.deliveryPaused(for: a), "Changing future-capture consent preserves explicit pause")
        try await store.setDeliveryPaused(false, for: a)
        check(try await !restarted.deliveryPaused(for: a), "Explicit resume clears only this account/workspace pause")
        try await store.setCloudSyncEnabled(false, for: a)
        let coherentOff = try await store.automaticPublicationEnabled(for: a)
        let pausedOff = try await store.deliveryPaused(for: a)
        check(!coherentOff && pausedOff, "Cloud sync OFF atomically disables future consent and persists pause")
        try await store.setCloudSyncEnabled(true, for: a)
        let coherentOn = try await store.automaticPublicationEnabled(for: a)
        let pausedOn = try await store.deliveryPaused(for: a)
        check(coherentOn && !pausedOn, "Cloud sync ON atomically opts in future captures and clears scoped pause")
        check(try await !store.automaticPublicationEnabled(for: a), "Opt-out is durable without stale in-memory caching")
        try await store.setAutomaticPublicationEnabled(true, for: a)
        check(try manager.contentsOfDirectory(atPath: root.path).count == 1, "Atomic replacement leaves no task-owned temporary files")

        func rejects(_ expected: PichiPublicationConsentFailure, _ message: String,
                     _ operation: () async throws -> Void) async throws {
            do { try await operation(); check(false, message) }
            catch let error as PichiPublicationConsentFailure { check(error == expected, message) }
        }
        let absentRoot = root.appendingPathComponent("absent", isDirectory: true)
        let unconfigured = PichiPublicationConsentStore(directory: absentRoot, configuration: nil)
        check(try await !unconfigured.automaticPublicationEnabled(for: a), "Missing configuration is inactive before filesystem access")
        try await rejects(.unconfigured, "An unconfigured store cannot enable cloud consent") {
            try await unconfigured.setAutomaticPublicationEnabled(true, for: a)
        }
        check(!manager.fileExists(atPath: absentRoot.path), "Unconfigured consent never creates a directory")
        let noWorkspace = AccountContext(identity: a.identity, organizationID: nil, workspaceID: nil, generation: UUID())
        check(try await !store.automaticPublicationEnabled(for: noWorkspace), "No workspace means publication consent is off")
        try await rejects(.workspaceUnavailable, "No default workspace is inferred") {
            try await store.setAutomaticPublicationEnabled(true, for: noWorkspace)
        }
        try await rejects(.invalidScope, "A foreign issuer cannot reuse this trusted configuration") {
            _ = try await store.automaticPublicationEnabled(for: context(configuration: configuration("issuer")))
        }
        let tooLong = AccountContext(identity: .init(issuer: a.identity.issuer, subject: String(repeating: "x", count: 513),
            internalUserID: a.identity.internalUserID), organizationID: a.organizationID, workspaceID: a.workspaceID, generation: UUID())
        try await rejects(.invalidScope, "Scope identifiers are bounded before encoding") {
            try await store.setAutomaticPublicationEnabled(true, for: tooLong)
        }
        let missing = PichiPublicationConsentStore(directory: absentRoot, configuration: trustedConfiguration)
        check(try await !missing.automaticPublicationEnabled(for: a), "An absent private root defaults off")
        try await rejects(.unavailable, "N2 retains ownership of private root creation") {
            try await missing.setAutomaticPublicationEnabled(true, for: a)
        }

        func replace(_ data: Data) throws {
            if manager.fileExists(atPath: recordURL.path) { try manager.removeItem(at: recordURL) }
            try data.write(to: recordURL, options: .withoutOverwriting)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
        }
        for mutation in ["truncated", "version", "owner", "workspace", "oversized"] {
            var object = try JSONSerialization.jsonObject(with: initialBytes) as! [String: Any]
            var bytes: Data
            switch mutation {
            case "truncated": bytes = Data("{".utf8)
            case "version": object["schemaVersion"] = 999; bytes = try JSONSerialization.data(withJSONObject: object)
            case "oversized": bytes = Data(repeating: 32, count: 16_385)
            default:
                var scope = object["scope"] as! [String: Any]
                if mutation == "workspace" { scope["workspaceID"] = "foreign-workspace" }
                else { var identity = scope["identity"] as! [String: Any]; identity["subject"] = "foreign-owner"; scope["identity"] = identity }
                object["scope"] = scope; bytes = try JSONSerialization.data(withJSONObject: object)
            }
            try replace(bytes)
            try await rejects(.corruptConsent, "Corrupt or foreign consent cannot enable publication: " + mutation) {
                _ = try await store.automaticPublicationEnabled(for: a)
            }
            try await rejects(.corruptConsent, "A write preserves corruption evidence: " + mutation) {
                try await store.setAutomaticPublicationEnabled(true, for: a)
            }
            check(try Data(contentsOf: recordURL) == bytes, "Rejected consent remains byte-identical for recovery")
        }
        try replace(initialBytes)
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: recordURL.path)
        try await rejects(.corruptConsent, "A publicly readable consent file fails closed") { _ = try await store.automaticPublicationEnabled(for: a) }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try await rejects(.invalidStorage, "A nonprivate supplied directory fails closed") { _ = try await store.automaticPublicationEnabled(for: a) }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)

        let target = root.appendingPathComponent("synthetic-target.json")
        try initialBytes.write(to: target)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try manager.removeItem(at: recordURL)
        try manager.createSymbolicLink(at: recordURL, withDestinationURL: target)
        try await rejects(.invalidStorage, "A symlinked consent file is never followed") { _ = try await store.automaticPublicationEnabled(for: a) }
        try await rejects(.invalidStorage, "A write cannot repair a symlink by following it") { try await store.setAutomaticPublicationEnabled(false, for: a) }
        check(try Data(contentsOf: target) == initialBytes, "Symlink rejection preserves its target")
        try manager.removeItem(at: recordURL)
        check(mkfifo(recordURL.path, 0o600) == 0, "Synthetic FIFO fixture was created")
        try await rejects(.corruptConsent, "A FIFO is rejected without blocking a private read") { _ = try await store.automaticPublicationEnabled(for: a) }
        try manager.removeItem(at: recordURL)
        check(link(target.path, recordURL.path) == 0, "Synthetic hard-link fixture was created")
        try await rejects(.corruptConsent, "A multiply linked consent file is rejected") { _ = try await store.automaticPublicationEnabled(for: a) }
        try manager.removeItem(at: recordURL)
        try replace(initialBytes)
        let alias = root.appendingPathComponent("directory-alias", isDirectory: true)
        try manager.createSymbolicLink(at: alias, withDestinationURL: root)
        let symlinkedRoot = PichiPublicationConsentStore(directory: alias, configuration: trustedConfiguration)
        try await rejects(.invalidStorage, "A symlinked supplied root is never trusted") { _ = try await symlinkedRoot.automaticPublicationEnabled(for: a) }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.setAutomaticPublicationEnabled(false, for: a)
        }
        do { try await cancelled.value; check(false, "A cancelled change must not commit") }
        catch is CancellationError { check(true, "Cancellation is joined and remains distinct from storage errors") }
        check(try Data(contentsOf: recordURL) == initialBytes, "Cancelled consent change preserves the prior durable setting")
        let stray = root.appendingPathComponent(".consent-\(UUID().uuidString).tmp")
        try Data("interrupted synthetic write".utf8).write(to: stray)
        check(try await store.automaticPublicationEnabled(for: a), "An interrupted temporary file cannot replace the last complete setting")
        print("Publication consent tests passed: \(checks) checks; synthetic account/configuration/filesystem inputs only")
        let wireChecks = try await Self.checkPublicationWire(fixtures: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
        print("Publication wire tests passed: \(wireChecks) checks; frozen W2 fixtures only, no network or server acceptance")
    }
}

import Foundation

private actor SyntheticLatch {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { open = true; for waiter in waiters { waiter.resume() }; waiters.removeAll() }
}
private actor SyntheticFlag {
    private var value = false
    func set() { value = true }
    func get() -> Bool { value }
}

private nonisolated final class SyntheticProviderProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0
    nonisolated(unsafe) private static var stopCount = 0
    nonisolated(unsafe) static var hold = false
    static var requests: Int { lock.withLock { count } }
    static var stops: Int { lock.withLock { stopCount } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let count = Self.lock.withLock { Self.count += 1; return Self.count }
        guard !Self.hold else { return }
        let data = try! JSONSerialization.data(withJSONObject: ["access_token": "synthetic-token-\(count)",
            "expires_at": Date().addingTimeInterval(1800).timeIntervalSince1970 * 1000])
        self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: data)
        self.client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { if self.request.value(forHTTPHeaderField: "Authorization") == "Basic pending" { Self.lock.withLock { Self.stopCount += 1 } } }
}

@main struct PrivateProfileDefaultsTests {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message); checks += 1
    }

    @MainActor static func main() async throws {
        let original = PrivateProfileStorage.current
        let guestName = AppBrand.storageNamespace + ".synthetic-guest"
        let guestDefaults = UserDefaults(suiteName: guestName)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let guest = try PrivateProfileStorage.proposed(context: nil, generation: UUID(), legacyRootDirectory: root)
        func profile(_ user: String, workspace: String = "workspace") throws -> PrivateProfileSnapshot {
            try PrivateProfileStorage.proposed(context: .init(identity: .init(issuer: "https://synthetic.invalid", subject: user,
                internalUserID: user), organizationID: "org", workspaceID: workspace, generation: UUID()),
                generation: UUID(), legacyRootDirectory: root)
        }
        let a = try profile("A"), b = try profile("B"), secondWorkspace = try profile("A", workspace: "other")
        let domains = [a, b, secondWorkspace].map { AppBrand.storageNamespace + ".private-profile." + $0.id }
        if let path = ProcessInfo.processInfo.environment["PICHI_PRIVATE_SETTINGS_DOMAIN_MANIFEST"] {
            try JSONEncoder().encode(domains + [guestName]).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        defer {
            for name in domains + [guestName] {
                let suite = UserDefaults(suiteName: name)!
                suite.removePersistentDomain(forName: name)
                precondition(suite.synchronize(), "Synthetic domain cleanup must persist")

            }
            PrivateProfileStorage.select(original)
        }
        let defaults = PrivateProfileDefaults(guestDefaults: guestDefaults)
        PrivateProfileStorage.select(guest)
        defaults.set("guest-prompt", forKey: "PrivatePrompt")
        defaults.set(["name": "guest-only"], forKey: "Dictionary")
        defaults.set("dark", forKey: "ThemePreference")
        defaults.set(true, forKey: "OnboardingCompleted")
        defaults.set(1, forKey: "MobileSetupVersion")
        defaults.set(6, forKey: "MobileSetupStep")
        defaults.set(true, forKey: "MobileSetupReplay")
        defaults.set(7, forKey: "OnboardingCurrentStep")
        let privateSetupValues: [String: Any] = [
            "OnboardingAISkipped": true,
            "OnboardingPlaygroundValidated": true, "OnboardingSelectedLanguageID": "ru",
            "MobileSetupSelectedModel": "guest-model",
            "MobileMeetingBehaviorVersion": 1, "SelectedSpeechModel": "guest-model",
            "SelectedProviderID": "guest-provider", "MeetingPIIRedactionEnabled": true,
            "MeetingPIIRedactionRequested": true,
            "MeetingEncryptLocalRecordings": true,
            "LocalAPIEnabled": true,
        ]
        for (key, value) in privateSetupValues { defaults.set(value, forKey: key) }
        expect(guestDefaults.string(forKey: "PrivatePrompt") == "guest-prompt", "guest delegates legacy defaults")
        defaults.register(defaults: ["PublicProductDefault": "default", "PrivatePrompt": "registered"])
        PrivateProfileStorage.select(a)
        expect(defaults.string(forKey: "PrivatePrompt") == "registered", "account sees registration, never guest prompt")
        expect(defaults.dictionary(forKey: "Dictionary") == nil, "guest dictionary not copied")
        expect(defaults.string(forKey: "PublicProductDefault") == "default", "product registration retained")
        expect(defaults.string(forKey: "ThemePreference") == "dark", "explicit device preference shared")
        expect(defaults.bool(forKey: "OnboardingCompleted"), "desktop installation stays complete in A")
        expect(defaults.integer(forKey: "MobileSetupVersion") == 1, "mobile installation stays complete in A")
        expect(defaults.integer(forKey: "MobileSetupStep") == 6, "mobile Ready step survives sign-in to A")
        expect(defaults.bool(forKey: "MobileSetupReplay"), "explicit mobile replay remains installation-scoped in A")
        expect(defaults.integer(forKey: "OnboardingCurrentStep") == 7, "optional desktop account step survives sign-in")
        for key in privateSetupValues.keys {
            expect(!PrivateProfileDefaults.sharedDeviceKeys.contains(key), "\(key) remains outside device allowlist")
            expect(defaults.object(forKey: key) == nil, "\(key) is not copied from guest into A")
        }
        defaults.set("A-prompt", forKey: "PrivatePrompt")
        defaults.set(Data([1, 2, 3]), forKey: "PrivateData")
        defaults.set(["one", "two"], forKey: "PrivateArray")
        defaults.set(true, forKey: "PrivateBool")
        defaults.set(42, forKey: "PrivateInteger")
        defaults.set(0.5, forKey: "PrivateDouble")
        defaults.set(URL(fileURLWithPath: "/synthetic/A"), forKey: "PrivateURL")
        expect(defaults.data(forKey: "PrivateData") == Data([1, 2, 3]), "typed data")
        expect(defaults.stringArray(forKey: "PrivateArray") == ["one", "two"], "typed array")
        expect(defaults.bool(forKey: "PrivateBool"), "typed bool")
        expect(defaults.integer(forKey: "PrivateInteger") == 42, "typed integer")
        expect(defaults.double(forKey: "PrivateDouble") == 0.5, "typed double")
        expect(defaults.url(forKey: "PrivateURL")?.path == "/synthetic/A", "typed URL")
        let frozen = PrivateProfileDefaults(profile: a, guestDefaults: guestDefaults)
        expect(frozen.string(forKey: "PrivatePrompt") == "A-prompt", "bound operation starts at A")
        PrivateProfileStorage.select(b)
        expect(defaults.bool(forKey: "OnboardingCompleted"), "desktop installation stays complete in B")
        expect(defaults.integer(forKey: "MobileSetupVersion") == 1, "mobile installation stays complete in B")
        expect(defaults.integer(forKey: "MobileSetupStep") == 6, "mobile Ready step survives sign-in to B")
        expect(defaults.bool(forKey: "MobileSetupReplay"), "explicit mobile replay survives account switching")
        defaults.set(false, forKey: "MobileSetupReplay")
        expect(defaults.dictionaryRepresentation()["MobileSetupSelectedModel"] == nil, "device completion does not expose guest wizard model")
        defaults.set(false, forKey: "OnboardingCompleted")
        defaults.set(0, forKey: "MobileSetupVersion")
        defaults.set(0, forKey: "MobileSetupStep")
        defaults.set(true, forKey: "ManualOnboardingResetRequested")
        let replayAt = Date(timeIntervalSince1970: 123456)
        defaults.set(replayAt, forKey: "ManualOnboardingResetRequestedAt")
        defaults.set(0, forKey: "OnboardingCurrentStep")
        PrivateProfileStorage.select(a)
        expect(!defaults.bool(forKey: "OnboardingCompleted"), "explicit desktop replay applies to this installation")
        expect(!defaults.bool(forKey: "MobileSetupReplay"), "ending mobile replay applies across profiles")
        expect(defaults.integer(forKey: "MobileSetupVersion") == 0, "explicit mobile replay applies to this installation")
        expect(defaults.integer(forKey: "MobileSetupStep") == 0, "mobile replay starts at the installation's first step")
        expect(defaults.bool(forKey: "ManualOnboardingResetRequested") && defaults.object(forKey: "ManualOnboardingResetRequestedAt") as? Date == replayAt,
               "manual desktop replay remains protected from legacy repair across profiles")
        expect(defaults.integer(forKey: "OnboardingCurrentStep") == 0, "desktop replay progress stays with installation")
        defaults.set(6, forKey: "MobileSetupStep")
        PrivateProfileStorage.select(b)
        expect(defaults.integer(forKey: "MobileSetupVersion") == 0 && defaults.integer(forKey: "MobileSetupStep") == 6,
            "An incomplete Ready step stays Ready when signing into another profile")
        defaults.set(true, forKey: "OnboardingCompleted")
        defaults.set(1, forKey: "MobileSetupVersion")
        defaults.removeObject(forKey: "ManualOnboardingResetRequested")
        defaults.removeObject(forKey: "ManualOnboardingResetRequestedAt")
        PrivateProfileStorage.select(b)
        expect(defaults.data(forKey: "PrivateData") == nil, "B cannot see A")
        expect(defaults.dictionaryRepresentation()["Dictionary"] == nil, "enumeration cannot see guest")
        expect(frozen.string(forKey: "PrivatePrompt") == nil, "old bound reader masked")
        frozen.set("late-A-callback", forKey: "PrivatePrompt")
        expect(defaults.string(forKey: "PrivatePrompt") == "registered", "old bound writer cannot retarget B")
        defaults.set("B-prompt", forKey: "PrivatePrompt")
        PrivateProfileStorage.select(secondWorkspace)
        expect(defaults.string(forKey: "PrivatePrompt") == "registered", "workspaces are private")
        PrivateProfileStorage.select(a)
        expect(defaults.string(forKey: "PrivatePrompt") == "A-prompt", "A data preserved")
        PrivateProfileStorage.conceal(generation: UUID())
        expect(defaults.string(forKey: "PrivatePrompt") == nil, "concealed private reads masked")
        defaults.set("concealed-write", forKey: "PrivatePrompt")
        expect(defaults.string(forKey: "ThemePreference") == "dark", "concealment retains explicit device behavior")
        expect(defaults.bool(forKey: "OnboardingCompleted"), "concealment retains desktop completion gate")
        expect(defaults.integer(forKey: "MobileSetupVersion") == 1, "concealment retains mobile completion gate")
        expect(defaults.integer(forKey: "MobileSetupStep") == 6, "concealment retains device setup progress")
        PrivateProfileStorage.select(a)
        expect(defaults.string(forKey: "PrivatePrompt") == "A-prompt", "concealed write ignored")
        PrivateProfileStorage.select(guest)
        expect(defaults.string(forKey: "PrivatePrompt") == "guest-prompt", "legacy guest prompt preserved")
        expect(defaults.dictionary(forKey: "Dictionary")? ["name"] as? String == "guest-only", "legacy dictionary preserved")
        expect(defaults.bool(forKey: "OnboardingCompleted") && defaults.integer(forKey: "MobileSetupVersion") == 1,
               "guest completion survives account A/B and replay completion")
        expect(defaults.string(forKey: "MobileSetupSelectedModel") == "guest-model", "guest wizard model preserved privately")
        expect(defaults.bool(forKey: "MeetingPIIRedactionRequested"), "guest privacy choice preserved privately")

        // Exact desktop production property; existing steps keep their saved IDs. The owner voice enrollment
        // step (b964d2e3) widened the range from 7 to 8, so the clamp now sits at that step.
        PrivateProfileStorage.select(guest)
        let onboarding = DesktopOnboardingStepProjection(defaults: defaults)
        defaults.set(true, forKey: "OnboardingCompleted")
        for step in 0...8 {
            onboarding.onboardingCurrentStep = step
            expect(DesktopOnboardingStepProjection(defaults: defaults).onboardingCurrentStep == step, "saved onboarding step \(step) preserved")
        }
        onboarding.onboardingCurrentStep = Int.max
        expect(onboarding.onboardingCurrentStep == 8, "desktop setter clamps at the owner voice enrollment step")
        defaults.set(Int.max, forKey: "OnboardingCurrentStep")
        expect(onboarding.onboardingCurrentStep == 8, "desktop getter clamps future stored step")
        onboarding.onboardingCurrentStep = -1
        expect(onboarding.onboardingCurrentStep == 0, "desktop negative step clamps at zero")
        expect(defaults.bool(forKey: "OnboardingCompleted"), "new step does not reset completed installations")

        // Capability metadata is private and delayed discovery cannot write to B.
        PrivateProfileStorage.select(a)
        let temperature = ModelTemperatureSupport(defaults: defaults)
        let admittedTemperature = temperature.boundForOperation()
        PrivateProfileStorage.select(b)
        admittedTemperature.record(["synthetic-model": false], baseURL: "https://synthetic.invalid")
        expect(temperature.isSupported("synthetic-model", baseURL: "https://synthetic.invalid") == nil, "late capability write cannot retarget B")
        PrivateProfileStorage.select(a)
        expect(temperature.isSupported("synthetic-model", baseURL: "https://synthetic.invalid") == nil, "retired capability write dropped")

        // Bound metadata writers retain one serializer for disjoint updates.
        let nativeTemperature = ModelTemperatureSupport(defaults: PrivateProfileDefaults.shared)
        let writers = (0..<50).map { _ in nativeTemperature.boundForOperation() }
        DispatchQueue.concurrentPerform(iterations: writers.count) { index in
            writers[index].record(["model-\(index)": false], baseURL: "https://synthetic.invalid")
        }
        expect((0..<writers.count).allSatisfy { nativeTemperature.isSupported("model-\($0)", baseURL: "https://synthetic.invalid") == false }, "concurrent capability updates retain every key")
        let verifierA = ProviderModelVerificationStore(defaults: PrivateProfileDefaults.bound(to: a))
        let verificationID = String(repeating: "a", count: 64)
        verifierA.recordSuccess(verificationID)
        expect(verifierA.contains(verificationID), "A verification retained")
        PrivateProfileStorage.select(b)
        let verifierB = ProviderModelVerificationStore(defaults: PrivateProfileDefaults.bound(to: b))
        expect(!verifierB.contains(verificationID) && !verifierA.contains(verificationID), "verification reads masked across profiles")
        verifierA.clearInMemory()
        verifierA.recordSuccess(String(repeating: "b", count: 64))
        PrivateProfileStorage.select(a)
        expect(!verifierA.contains(String(repeating: "b", count: 64)), "late verification cannot refill a retired cache")
        expect(ProviderModelVerificationStore(defaults: PrivateProfileDefaults.bound(to: a)).contains(verificationID), "A persisted verification preserved")

        // Injected credential backends never call Security or the user's Keychain.
        PrivateProfileStorage.select(a)
        let serviceA = KeychainService(service: a.credentialService, account: AppBrand.keychainAccount,
            migratesLegacyEntries: false, profile: a, testingLoad: { ["provider": "A-key"] }, testingSave: { _ in },
            testingLegacyLoad: { preconditionFailure("Account must never scan legacy guest credentials") })
        expect(serviceA.service != guest.credentialService, "account Keychain service isolated from guest")
        expect(serviceA.service != b.credentialService, "A/B Keychain services isolated")
        let keys = try await serviceA.loadForUserAction()
        expect(keys == ["provider": "A-key"], "account credentials authoritative")
        PrivateProfileStorage.select(b)
        expect(serviceA.cachedKeys == nil && serviceA.loadedKeys == nil, "foreign cached credentials masked")
        do { _ = try await serviceA.loadForUserAction(); preconditionFailure("Foreign action admitted") } catch {}
        expect(!serviceA.loadInBackground { _ in preconditionFailure("Foreign callback") }, "foreign refresh rejected")
        PrivateProfileStorage.select(a)
        let started = SyntheticLatch(), release = SyntheticLatch(), retired = SyntheticFlag()
        let service = KeychainService(testingLoad: { ["provider": "synthetic-key"] }, testingSave: { _ in })
        expect(service.loadInBackground { _ in await started.release(); await release.wait() }, "background admitted")
        await started.wait()
        let retirement = Task { await service.retireAndJoin(); await retired.set() }
        for _ in 0..<10 { await Task.yield() }
        let prematurelyRetired = await retired.get()
        expect(!prematurelyRetired, "retirement waits for main callback acknowledgment")
        expect(service.cachedKeys == nil, "retirement hides cache immediately")
        await release.release()
        await retirement.value
        expect(service.readiness == .unavailable, "retired credentials remain unavailable")
        expect(!service.loadInBackground { _ in preconditionFailure("Retired callback") }, "retired service cannot reload")
        do { _ = try await service.loadForUserAction(); preconditionFailure("Retired action admitted") } catch {}
        // Entire transport is intercepted. No live provider receives a request.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyntheticProviderProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let authorization = CloudTextProviderAuthorization(session: session)
        let provider = CloudTextProvider.descriptor(for: "gigachat")!
        let firstHeaders = try await authorization.headers(for: provider, credential: "synthetic", options: [:])
        expect(firstHeaders["Authorization"] == "Bearer synthetic-token-1", "synthetic token exchanged")
        _ = try await authorization.headers(for: provider, credential: "synthetic", options: [:])
        expect(SyntheticProviderProtocol.requests == 1, "same profile may use its cached token")
        SyntheticProviderProtocol.hold = true
        let pending = Task { try await authorization.headers(for: provider, credential: "pending", options: [:]) }
        for _ in 0..<100 where SyntheticProviderProtocol.requests < 2 { try await Task.sleep(for: .milliseconds(10)) }
        expect(SyntheticProviderProtocol.requests == 2, "pending exchange admitted")
        await authorization.pauseAndClearForPrivateProfileTransition()
        do { _ = try await pending.value; preconditionFailure("Retired OAuth exchange returned token") } catch { expect(error is CancellationError, "retired exchange cancelled") }
        for _ in 0..<100 where SyntheticProviderProtocol.stops == 0 { try await Task.sleep(for: .milliseconds(10)) }
        expect(SyntheticProviderProtocol.stops == 1, "retired URL request stopped")
        do { _ = try await authorization.headers(for: provider, credential: "synthetic", options: [:]); preconditionFailure("Paused OAuth admission") } catch {}
        expect(SyntheticProviderProtocol.requests == 2, "paused authorization cannot send")
        SyntheticProviderProtocol.hold = false
        await authorization.resumeAfterPrivateProfileTransition()
        let resumed = try await authorization.headers(for: provider, credential: "synthetic", options: [:])
        expect(resumed["Authorization"] == "Bearer synthetic-token-3", "next profile cannot reuse former cached token")
        await authorization.pauseAndClearForPrivateProfileTransition()
        print("PASS: \(checks) synthetic defaults, immutable ownership, credential namespace and joined callback checks")
    }
}

import Foundation

@MainActor extension MeetingSummaryAdmissionTests {
    private static let normalInput = "Synthetic raw transcript Ёё."
    private static func normalSnapshot(settings: SettingsStore, slot: SettingsStore.DictationShortcutSlot = .primary, hasTarget: Bool = true) -> DictationStopSnapshot {
        SettingsStore.shared = settings
        let target = TypingService.RecordingTargetContext(id: UUID(), pid: 123, bundleIdentifier: "synthetic.editor", window: nil, element: nil)
        return .capture(target: hasTarget ? target : nil,
            appInfo: ("Synthetic editor", "synthetic.editor", "Synthetic window"), slot: slot, precedingText: "Synthetic preceding text")
    }
    private static func resetNormalMetadata() {
        DictationAppSession.shared.appID = nil
        DictationAppSession.shared.selected = nil
        DictationAppSession.shared.selectedSlot = .primary
        UserDefaults.standard.values["synthetic-profiles"] = nil
        UserDefaults.standard.values["synthetic-prompt-off"] = nil
        UserDefaults.standard.values["synthetic-private-capability"] = false
        UserDefaults.standard.values["synthetic-private-selection"] = false
    }
    private static func normalRejects(settings: SettingsStore, reason: String, callers: [String] = ["stop", "no-stop", "direct", "override", "manual", "reprocess"]) async {
        SettingsStore.shared = settings
        for caller in callers {
            let requests = AdmissionURLProtocol.requestCount
            let owner = NormalDictationAdmissionOwner(client: self.commandClient)
            if caller == "stop" || caller == "no-stop" {
                let snapshot = caller == "stop" ? self.normalSnapshot(settings: settings) : nil
                let output = await owner.finish(self.normalInput, snapshot: snapshot)
                self.check(output == self.normalInput, "\(reason), \(caller): actual post-ASR fallback retains raw text; new intercepted requests=\(AdmissionURLProtocol.requestCount - requests), authorization present=\(AdmissionURLProtocol.lastAuthorization != nil)")
                if let snapshot { self.check(!snapshot.usesAI, "Inadmissible stop freezes AI off") }
            } else if caller == "manual" {
                await owner.callOpenAIChat()
                self.check(owner.aiOutputText.hasPrefix("Error:") && owner.aiInputText == self.normalInput,
                    "\(reason), manual: actual enhancement reports configuration failure and retains input; new intercepted requests=\(AdmissionURLProtocol.requestCount - requests), authorization present=\(AdmissionURLProtocol.lastAuthorization != nil)")
            } else if caller == "reprocess" {
                let output = await owner.finishReprocess(self.normalInput)
                self.check(output == self.normalInput,
                    "\(reason), reprocess: actual AI/fallback block retains raw text; new intercepted requests=\(AdmissionURLProtocol.requestCount - requests), authorization present=\(AdmissionURLProtocol.lastAuthorization != nil)")
            } else if caller == "warm" {
                let warm = NormalDictationWarmAdmissionOwner()
                let selected = warm.selectedRoute()
                if let selected {
                    do {
                        try await DictationPostProcessingService.shared.prewarmLocalModel(selected, client: self.commandClient)
                        _ = try await LocalAIModelResidencyTransport.isReady(selected)
                    } catch { self.check(false, "The injected warm transport must complete") }
                }
                self.check(selected == nil, "\(reason), warm: no route admitted; new intercepted requests=\(AdmissionURLProtocol.requestCount - requests), authorization present=\(AdmissionURLProtocol.lastAuthorization != nil)")
            } else {
                do {
                    _ = try await owner.processTextWithAIMetrics(self.normalInput,
                        overrideProviderID: caller == "override" ? settings.selectedProviderID : nil,
                        overrideModel: caller == "override" ? settings.selectedModel : nil,
                        dictationSlot: .primary, client: self.commandClient)
                    self.check(false, "\(reason), \(caller): actual processor admitted request; new intercepted requests=\(AdmissionURLProtocol.requestCount - requests), authorization present=\(AdmissionURLProtocol.lastAuthorization != nil)")
                } catch {
                    guard case AIProcessingError.noVerifiedProvider = error else { self.check(false, "Expected admission error before HTTP"); continue }
                    self.check(true, "Actual direct/explicit processor rejected admission")
                }
            }
            self.check(AdmissionURLProtocol.requestCount == requests && MeetingSummaryActivityCoordinator.shared.activeCount == 0
                && MeetingModelResidencyCoordinator.shared.activeCount == 0, "Rejected normal admission has no HTTP or retained processing ownership")
        }
    }
    static func normalPendingProbe(caller: String) async throws {
        self.resetNormalMetadata()
        let endpoint = caller == "warm" ? "http://127.0.0.1:11434/v1" : "http://127.0.0.1:1234/v1"
        let backend = AdmissionBackend(["custom:normal-probe": "synthetic-normal-key"])
        let (settings, service, _) = self.fixture(backend, provider: "normal-probe", endpoint: endpoint, key: "synthetic-normal-key")
        await self.load(service)
        backend.failNextReadWhileBlocked()
        var settled = false
        self.check(service.loadInBackground { _ in settled = true }, "Normal probe refresh admitted")
        await self.waitUntil { backend.isBlocked }
        self.check(service.loadedKeys == nil && service.cachedKeys != nil, "Probe has authoritative unknown and retained old display key")
        await self.normalRejects(settings: settings, reason: "Pending retained-key normal probe", callers: [caller])
        backend.unblockFailure()
        await self.waitUntil { settled }
    }
    static func normalDictationAdmission() async throws {
        for (provider, endpoint) in [("normal-remote", "https://alias.example/v1"), ("normal-local", "http://127.0.0.1:1234/v1")] {
            self.resetNormalMetadata()
            let key = "synthetic-normal-key"
            let canonical = "custom:\(provider)"
            let backend = AdmissionBackend([canonical: key])
            let (settings, service, _) = self.fixture(backend, provider: provider, endpoint: endpoint, key: key)
            await self.normalRejects(settings: settings, reason: "Cold normal credentials")
            self.check(backend.readCount == 0, "Cold normal rejection never loads credentials")
            await self.load(service)
            SettingsStore.shared = settings
            let owner = NormalDictationAdmissionOwner(client: self.commandClient)
            let snapshot = self.normalSnapshot(settings: settings)
            self.check(snapshot.usesAI && snapshot.route.apiKey == key, "Stop freezes one admitted loaded route")
            self.check(await owner.finish(self.normalInput, snapshot: snapshot) == "Synthetic summary", "Actual normal post-ASR pipeline returns intercepted AI output")
            self.check(AdmissionURLProtocol.lastAuthorization == "Bearer \(key)", "Stop request carries authoritative key")
            for explicit in [false, true] {
                let result = try await owner.processTextWithAIMetrics(self.normalInput,
                    overrideProviderID: explicit ? provider : nil, overrideModel: explicit ? "synthetic-model" : nil,
                    dictationSlot: .primary, client: self.commandClient)
                self.check(result.text == "Synthetic summary" && AdmissionURLProtocol.lastAuthorization == "Bearer \(key)", "Actual global and explicit callers preserve verified loaded keys")
            }
            self.check(await owner.finish(self.normalInput, snapshot: nil) == "Synthetic summary", "No-stop caller follows actual post-ASR admission path")
            await owner.callOpenAIChat()
            self.check(owner.aiOutputText == "Synthetic summary", "Actual manual enhancement delegates to the admitted processor")
            self.check(await owner.finishReprocess(self.normalInput) == "Synthetic summary", "Actual reprocess AI/fallback block uses the admitted processor")
            let frozen = self.normalSnapshot(settings: settings)
            backend.replace([canonical: "replacement-normal-key"])
            await self.load(service)
            settings.savedProviders = [.init(id: provider, name: "Synthetic changed", baseURL: "https://changed.example/v1", models: ["replacement-model"])]
            settings.selectedModel = "replacement-model"
            settings.selectedModelByProvider[canonical] = "replacement-model"
            settings.providerConnectionOptions[provider] = ["project": "replacement-project"]
            settings.verifiedProviderFingerprints[canonical] = "replaced-verification"
            UserDefaults.standard.values["synthetic-prompt-off"] = true
            self.check(await owner.finish(self.normalInput, snapshot: frozen) == "Synthetic summary", "Admitted stop survives synthetic ASR delay and later settings changes")
            self.check(frozen.usesAI && frozen.route.connectionOptions.isEmpty && AdmissionURLProtocol.lastAuthorization == "Bearer \(key)"
                && AdmissionURLProtocol.lastURL == "\(endpoint)/chat/completions" && AdmissionURLProtocol.lastModel == "synthetic-model",
                "Frozen stop request retains its admitted key, endpoint, model, connection options and AI decision")
            await self.normalRejects(settings: settings, reason: "New stop after Off/configuration change")
            UserDefaults.standard.values["synthetic-prompt-off"] = nil
            settings.savedProviders = [.init(id: provider, name: "Synthetic provider", baseURL: endpoint, models: ["synthetic-model"])]
            settings.selectedModel = "synthetic-model"
            settings.selectedModelByProvider[canonical] = "synthetic-model"
            settings.providerConnectionOptions[provider] = [:]
            settings.verifiedProviderFingerprints[canonical] = CloudTextProvider.connectionFingerprint(baseURL: endpoint, apiKey: "replacement-normal-key")
            backend.failNextReadWhileBlocked()
            var settled = false
            self.check(service.loadInBackground { _ in settled = true }, "Normal refresh admitted")
            await self.waitUntil { backend.isBlocked }
            let reads = backend.readCount
            await self.normalRejects(settings: settings, reason: "Pending normal refresh with retained keyed display")
            backend.unblockFailure()
            await self.waitUntil { settled && service.readiness == .unavailable }
            await self.normalRejects(settings: settings, reason: "Failed normal refresh with retained keyed display")
            self.check(backend.readCount == reads && settings.providerAPIKeys[canonical] == "replacement-normal-key", "Normal failure rejects without credential reread while retaining presentation cache")
            await self.load(service)
            self.check(await owner.finish(self.normalInput, snapshot: self.normalSnapshot(settings: settings)) == "Synthetic summary", "Authoritative normal credential recovery restores AI")
            let requests = AdmissionURLProtocol.requestCount
            self.check(await owner.finish(self.normalInput, snapshot: self.normalSnapshot(settings: settings, hasTarget: false)) == self.normalInput
                && AdmissionURLProtocol.requestCount == requests, "Missing target retains ordinary raw transcription with no AI request")
            backend.replace([:])
            await self.load(service)
            await self.normalRejects(settings: settings, reason: "Loaded empty cannot reuse old keyed normal verification")
            settings.verifiedProviderFingerprints[canonical] = CloudTextProvider.connectionFingerprint(baseURL: endpoint, apiKey: "")
            if endpoint.hasPrefix("http:") {
                self.check(await owner.finish(self.normalInput, snapshot: self.normalSnapshot(settings: settings)) == "Synthetic summary"
                    && AdmissionURLProtocol.lastAuthorization == nil, "Explicitly verified loaded-empty normal local provider remains keyless")
                let result = try await owner.processTextWithAIMetrics(self.normalInput, dictationSlot: .primary, client: self.commandClient)
                self.check(result.text == "Synthetic summary" && AdmissionURLProtocol.lastAuthorization == nil, "Direct caller preserves verified keyless local admission")
            } else {
                await self.normalRejects(settings: settings, reason: "Remote empty credentials remain inadmissible")
            }
            self.check(backend.interactiveAccessCount == 0, "Normal admission never prompts for credentials")
        }
        try await self.normalProfileAndPrivateAdmission()
        try await self.normalWarmAdmission()
        self.resetNormalMetadata()
    }
    private static func normalProfileAndPrivateAdmission() async throws {
        self.resetNormalMetadata()
        let backend = AdmissionBackend(["custom:normal-profile": "synthetic-profile-key"])
        let (settings, service, _) = self.fixture(backend, provider: "normal-profile", endpoint: "https://alias.example/v1", key: "synthetic-profile-key")
        await self.load(service)
        settings.syntheticProfiles = ["synthetic.visited": .init(id: "profile", name: "Synthetic profile", prompt: "Frozen secondary app prompt.", providerID: "normal-profile", model: "profile-model")]
        DictationAppSession.shared.appID = "synthetic.visited"
        DictationAppSession.shared.selected = .profile("profile")
        DictationAppSession.shared.selectedSlot = .secondary
        let snapshot = self.normalSnapshot(settings: settings, slot: .secondary)
        self.check(snapshot.hasCustomPrompt && snapshot.route.model == "profile-model" && snapshot.systemPrompt == "Frozen secondary app prompt."
            && snapshot.appInfo.bundleId == "synthetic.editor", "Actual stop honors visited-app secondary profile while retaining delivery app identity")
        settings.syntheticProfiles = [:]
        DictationAppSession.shared.selected = .off
        let owner = NormalDictationAdmissionOwner(client: self.commandClient)
        self.check(await owner.finish(self.normalInput, snapshot: snapshot, slot: .secondary) == "Synthetic summary"
            && AdmissionURLProtocol.lastModel == "profile-model" && AdmissionURLProtocol.lastSystemPrompt == "Frozen secondary app prompt.",
            "Admitted secondary profile retains its prompt and model after app metadata changes")
        self.resetNormalMetadata()
        let privateBackend = AdmissionBackend([:])
        let (privateSettings, privateService, _) = self.fixture(privateBackend)
        privateSettings.selectsPrivateCapability = true
        privateSettings.privateCapabilityReady = true
        let requests = AdmissionURLProtocol.requestCount
        let calls = PrivateAIIntegrationService.shared.calls
        let privateOwner = NormalDictationAdmissionOwner(client: self.commandClient)
        self.check(await privateOwner.finish(self.normalInput, snapshot: self.normalSnapshot(settings: privateSettings)) == "Synthetic private result", "Normal stop preserves registered private capability")
        _ = try await privateOwner.processTextWithAIMetrics(self.normalInput, dictationSlot: .primary, client: self.commandClient)
        self.check(PrivateAIIntegrationService.shared.calls == calls + 2 && AdmissionURLProtocol.requestCount == requests
            && privateBackend.readCount == 0 && privateService.loadedKeys == nil, "Private normal paths remain credential independent and use existing adapter without HTTP")
        privateSettings.privateCapabilityReady = false
        await self.normalRejects(settings: privateSettings, reason: "Unverified normal private capability")
        self.resetNormalMetadata()
    }
    private static func normalWarmAdmission() async throws {
        self.resetNormalMetadata()
        let endpoint = "http://127.0.0.1:11434/v1"
        let backend = AdmissionBackend(["custom:normal-warm": "synthetic-warm-key"])
        let (settings, service, _) = self.fixture(backend, provider: "normal-warm", endpoint: endpoint, key: "synthetic-warm-key")
        await self.normalRejects(settings: settings, reason: "Cold warm route", callers: ["warm"])
        await self.load(service)
        let owner = NormalDictationWarmAdmissionOwner()
        SettingsStore.shared = settings
        let route = owner.selectedRoute()!
        self.check(route.apiKey == "synthetic-warm-key", "Actual AppServices warm admission freezes loaded credential")
        try await DictationPostProcessingService.shared.prewarmLocalModel(route, client: self.commandClient)
        self.check(AdmissionURLProtocol.lastAuthorization == "Bearer synthetic-warm-key" && AdmissionURLProtocol.lastURL == "http://127.0.0.1:11434/api/chat", "Actual warm operation uses its admitted credential")
        self.check(try await !LocalAIModelResidencyTransport.isReady(route), "Actual readiness HTTP decodes the intercepted empty residency result")
        self.check(AdmissionURLProtocol.lastAuthorization == "Bearer synthetic-warm-key" && AdmissionURLProtocol.lastURL == "http://127.0.0.1:11434/api/ps", "Actual readiness uses the same admitted credential")
        backend.failNextReadWhileBlocked()
        var settled = false
        self.check(service.loadInBackground { _ in settled = true }, "Warm refresh admitted")
        await self.waitUntil { backend.isBlocked }
        await self.normalRejects(settings: settings, reason: "Pending cached keyed warm route", callers: ["warm"])
        backend.unblockFailure()
        await self.waitUntil { settled && service.readiness == .unavailable }
        await self.normalRejects(settings: settings, reason: "Unavailable cached keyed warm route", callers: ["warm"])
        backend.replace([:])
        await self.load(service)
        await self.normalRejects(settings: settings, reason: "Loaded-empty old keyed warm route", callers: ["warm"])
        settings.verifiedProviderFingerprints["custom:normal-warm"] = CloudTextProvider.connectionFingerprint(baseURL: endpoint, apiKey: "")
        let keyless = owner.selectedRoute()!
        try await DictationPostProcessingService.shared.prewarmLocalModel(keyless, client: self.commandClient)
        _ = try await LocalAIModelResidencyTransport.isReady(keyless)
        self.check(AdmissionURLProtocol.lastAuthorization == nil && backend.interactiveAccessCount == 0
            && MeetingModelResidencyCoordinator.shared.activeCount == 0 && MeetingSummaryActivityCoordinator.shared.activeCount == 0,
            "Explicitly verified keyless warming preserves joined ownership without credential prompts")
    }
}

import Foundation
enum PichiLocalization { static func text(_ key: String) -> String { key }; static func format(_ key: String, _ value: Int64) -> String { key } }
enum KeychainService { enum Readiness { case pending, loaded, unavailable } }

// Compile the production draft/save adapter against isolated settings and Keychain doubles.
final class UserDefaults {
    static let standard = UserDefaults()
    var values: [String: [String]] = [:]
    // Match Foundation UserDefaults, including an absent key.
    // swiftlint:disable:next discouraged_optional_collection
    func stringArray(forKey key: String) -> [String]? { self.values[key] }
    func set(_ value: [String], forKey key: String) { self.values[key] = value }
}

struct PrivateAIProviderFeature {
    static let shared = PrivateAIProviderFeature()
    let providerID = "fluid"
}

struct ModelRepository {
    static let shared = ModelRepository()
    func isBuiltIn(_ id: String) -> Bool { ["openai", "ollama", "fluid"].contains(id) }
    func defaultModels(for id: String) -> [String] { ["default-model"] }
    func builtInProvidersList() -> [(id: String, name: String)] { [("openai", "OpenAI"), ("ollama", "Ollama"), ("fluid", "Fluid")] }
}

final class SettingsStore {
    struct SavedProvider {
        var id = UUID().uuidString
        let name: String
        let baseURL: String
        let models: [String]
    }

    struct Configuration: Equatable {
        var providerID: String
        var modelName = "model"
        var shortcut = "keep-shortcut"
    }

    var providerAPIKeyReadiness = KeychainService.Readiness.loaded
    var providerAPIKeys: [String: String] = [:]
    var providerConnectionOptions: [String: [String: String]] = [:]
    var selectedProviderID = "fluid"
    var selectedModel: String? = "mini"
    var rewriteModeSelectedProviderID = ""
    var rewriteModeSelectedModel: String?
    var commandModeSelectedProviderID = ""
    var commandModeSelectedModel: String?
    var availableModelsByProvider: [String: [String]] = [:]
    var selectedModelByProvider: [String: String] = [:]
    var dictationPromptConfigurations: [String: Configuration] = [:]
    var verifiedProviderFingerprints: [String: String] = [:]
}

final class AIEnhancementSettingsViewModel {
    struct ProviderItemData {
        let id: String
        let name: String
        let isBuiltIn: Bool
    }

    let settings = SettingsStore()
    var isTestingConnection = false
    var isSavingProviderCredentials = false
    var isFetchingModels = false
    var selectedProviderID = "openai"
    var managedOriginalKey: String?
    var managedProviderID: String?
    var knownProviderAPIKeys: [String: String] = [:]
    var persistsSelectedProvider = true
    var unconfiguredProviderDraftIDs = Set<String>()
    var credentialReads = 0
    var fetchedModelsProviders: Set<String> = []
    var providerAPIKeys: [String: String] = [:]
    var savedProviders: [SettingsStore.SavedProvider] = []
    var availableModelsByProvider: [String: [String]] = [:]
    var selectedModelByProvider: [String: String] = ["fluid": "mini"]
    enum Status { case unknown, success }
    var statuses: [String: Status] = [:]
    var verifiedRefreshes = 0
    func connectionStatus(for id: String) -> Status { self.statuses[id] ?? .unknown }
    var cachedProviderItems: [ProviderItemData] = []
    var cachedVerifiedProviderItems: [ProviderItemData] = []
    var cachedUnverifiedProviderItems: [ProviderItemData] = []
    var cachedAddedProviderItems: [ProviderItemData] = []
    var failKeychain = false
    var saves = 0
    var keySaves = 0
    var persistedKeys: [String: String] = [:]
    func providerKey(for id: String) -> String { id }
    func providerAPIKey(for id: String) -> String { self.providerAPIKeys[id] ?? "" }
    func updateProviderAPIKey(_ value: String, for id: String) { self.providerAPIKeys[id] = value }
    func saveProviderAPIKeys(invalidating id: String, removing ids: [String] = []) async -> Bool {
        self.keySaves += 1
        guard !self.failKeychain else { return false }
        self.persistedKeys = self.providerAPIKeys
        self.knownProviderAPIKeys = self.persistedKeys
        return true
    }

    func ensureKeychainAccessForAPIKeyEdit() async -> Bool {
        self.credentialReads += 1
        self.settings.providerAPIKeyReadiness = .loaded
        self.mergeLoadedProviderAPIKeys(self.settings.providerAPIKeys)
        return true
    }
    func selectProviderForUse(_ id: String) { self.selectedProviderID = id }
    func setEditingAPIKey(_ editing: Bool, for id: String) {}

    func hasProviderAPIKeyDraft(for id: String) -> Bool { self.providerAPIKeys[id] != nil }
    func saveSavedProviders() { self.saves += 1; self.refreshProviderItems() }
    func clearEditProviderDraft() {}
    func finishConfiguringProvider() { self.selectedProviderID = self.settings.selectedProviderID }
    func refreshVerifiedProviders() { self.verifiedRefreshes += 1 }
    func selectSoleVerifiedProviderIfNeeded() {}
}

@main enum ProviderSetupBoundaryTests {
    static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            count += 1
        }
        let vm = AIEnhancementSettingsViewModel()
        vm.refreshProviderItems()
        check(vm.cachedAddedProviderItems.isEmpty, "Fresh catalog stays hidden")
        let connectionEdits: [(inout ProviderSetupDraft) -> Void] = [
            { $0.providerID = "ollama" },
            { $0.baseURL = "http://localhost:4321/v1" },
            { $0.apiKey = "replacement-key" },
        ]
        for edit in connectionEdits {
            var fetched = ProviderSetupDraft(name: "Server", baseURL: "http://localhost:1234/v1")
            let oldIdentity = fetched.connectionIdentity
            check(fetched.applyFetchedModels(["second", "first", "first"], for: oldIdentity), "Current discovery is accepted")
            check(fetched.model == "first", "Discovery selects its first sorted result")
            fetched.selectFetchedModel("second")
            edit(&fetched)
            check(fetched.model.isEmpty && fetched.fetchedModels.isEmpty, "Connection edits clear automatic and picker selections immediately")
            check(fetched.modelsToSave(defaults: []).isEmpty, "Saving a new custom connection cannot retain an old fetched model")
            check(!fetched.applyFetchedModels(["stale"], for: oldIdentity), "Late discovery from the old connection is rejected")
            check(fetched.model.isEmpty && fetched.fetchedModels.isEmpty, "Rejected discovery cannot repopulate the cleared selection")

            var manual = ProviderSetupDraft(name: "Server", baseURL: "http://localhost:1234/v1")
            manual.applyFetchedModels(["first"], for: manual.connectionIdentity)
            // Typing even the same ID explicitly makes it a manual choice.
            manual.model = "first"
            edit(&manual)
            check(manual.model == "first" && manual.fetchedModels.isEmpty, "Connection edits preserve an explicitly entered ID")
            check(manual.modelsToSave(defaults: []) == ["first"], "Manual IDs remain available to save")
            manual.applyFetchedModels([], for: manual.connectionIdentity)
            check(manual.model == "first", "Empty discovery must not erase manual entry")
        }
        var reloaded = ProviderSetupDraft(name: "Server", baseURL: "http://localhost:1234/v1")
        reloaded.applyFetchedModels(["first", "second"], for: reloaded.connectionIdentity)
        reloaded.selectFetchedModel("second")
        reloaded.name = "Renamed server"
        reloaded.baseURL = " http://localhost:1234/v1 "
        check(reloaded.model == "second", "Name and URL whitespace edits preserve a valid fetched choice")
        reloaded.applyFetchedModels(["second", "third"], for: reloaded.connectionIdentity)
        check(reloaded.model == "second", "Reload preserves a selection still returned by the server")
        reloaded.applyFetchedModels(["third"], for: reloaded.connectionIdentity)
        check(reloaded.model == "third", "Reload replaces a fetched selection the server no longer returns")
        reloaded.applyFetchedModels([], for: reloaded.connectionIdentity)
        check(reloaded.model.isEmpty, "Empty discovery clears an old fetched selection")
        reloaded.applyFetchedModels(["old-server-model"], for: reloaded.connectionIdentity)
        reloaded.baseURL = "http://localhost:4321/v1"
        reloaded.apiKey = "new-key"
        let freshVM = AIEnhancementSettingsViewModel()
        check((await freshVM.addProvider(reloaded)), "A custom provider can be saved after rapid connection edits")
        check(freshVM.savedProviders.first?.models == [], "Persistence receives no model from the previous connection")
        check(freshVM.settings.selectedProviderID == "fluid", "Saving the new connection leaves the current dictation route intact")
        var draft = ProviderSetupDraft(name: "Local", baseURL: "http://localhost:1234/v1", model: "tiny")
        check(draft.isValid && vm.saves == 0, "Editing a valid draft has no persistence effects")
        var discoveryDraft = draft
        discoveryDraft.fetchedModels = ["first", "second"]
        discoveryDraft.model = "second"
        check(discoveryDraft.modelsToSave(defaults: []) == ["second", "first"], "Selected discovered model is saved first without dropping other models")
        discoveryDraft.model = "manual"
        check(discoveryDraft.modelsToSave(defaults: []) == ["manual", "first", "second"], "Manual entry preserves discovered models")
        discoveryDraft.model = ""
        check(discoveryDraft.modelsToSave(defaults: ["default"]) == ["first", "second"], "Discovery replaces fallback defaults")
        discoveryDraft.fetchedModels = []
        check(discoveryDraft.modelsToSave(defaults: ["default"]) == ["default"], "Empty discovery preserves default fallback")
        let originalConnection = discoveryDraft.connectionIdentity
        discoveryDraft.model = "another"
        check(discoveryDraft.connectionIdentity == originalConnection, "Model selection does not invalidate a connection request")
        discoveryDraft.apiKey = "changed"
        check(discoveryDraft.connectionIdentity != originalConnection, "Credential edits invalidate stale discovery")
        check(vm.saves == 0 && vm.providerAPIKeys.isEmpty && vm.savedProviders.isEmpty, "Model discovery drafts do not persist credentials or providers")
        draft.baseURL = "file:///tmp/model"
        let invalidAdd = await vm.addProvider(draft)
        check(!draft.isValid && !invalidAdd, "Reject non-HTTP endpoints without persistence")
        draft.baseURL = "https://user:secret@example.com"
        check(!draft.isValid, "Reject credentials embedded in URL")
        draft.baseURL = "http://localhost:1234/v1"
        draft.apiKey = "test-key"
        vm.failKeychain = true
        check(
            !(await vm.addProvider(draft)) && vm.savedProviders.isEmpty && vm.providerAPIKeys.isEmpty && vm.saves == 0,
            "Keychain failure keeps records, keys, and model maps unchanged"
        )
        vm.failKeychain = false
        draft.fetchedModels = ["other", "tiny"]
        check((await vm.addProvider(draft)) && vm.savedProviders.count == 1, "Explicit Add saves a custom provider")
        check(vm.savedProviders.first?.models == ["tiny", "other"], "Add persists the selected model and complete discovered list")
        check(vm.settings.selectedProviderID == "fluid" && vm.selectedModelByProvider["fluid"] == "mini", "Adding does not change current route/model")
        check((await vm.addProvider(draft)) && vm.savedProviders.count == 2, "Same display name cannot overwrite another provider")
        check(vm.cachedAddedProviderItems.count == 2, "Saved custom providers appear without verification")
        let builtIn = ProviderSetupDraft(providerID: "ollama", name: "Ollama", baseURL: "http://localhost:11434/v1")
        check((await vm.addProvider(builtIn)), "Keyless local provider can be added")
        check(!(await vm.addProvider(builtIn)), "Duplicate built-in Add is rejected")
        check(vm.cachedAddedProviderItems.contains { $0.id == "ollama" }, "Keyless provider remains visible via explicit membership")
        vm.providerAPIKeys["openai"] = "expired-key"
        vm.refreshProviderItems()
        check(vm.cachedAddedProviderItems.contains { $0.id == "openai" }, "Unverified legacy credentials remain discoverable")
        vm.providerAPIKeys.removeValue(forKey: "openai")
        vm.settings.dictationPromptConfigurations["legacy"] = .init(providerID: "openai")
        vm.refreshProviderItems()
        check(vm.cachedAddedProviderItems.contains { $0.id == "openai" }, "Referenced provider stays visible after credentials disappear")
        vm.isFetchingModels = true
        check(!(await vm.addProvider(draft)), "In-flight editor request blocks another Add")
        let source = try String(contentsOfFile: "Sources/Fluid/UI/AISettingsView+AIConfiguration.swift", encoding: .utf8)
        let manager = source.components(separatedBy: "private var externalProviderManager: some View")[1]
            .components(separatedBy: "private var legacyAIConfigurationCard")[0]
        check(!manager.contains("Use for shortcut") && !manager.contains("Edit details"), "External manager has no duplicate editor or shortcut assignment action")
        check(source.contains(".onSubmit {") && source.contains("self.viewModel.addNewModel()"), "Manual model input retains Enter-to-add behavior")
        check(source.contains(".accessibilityLabel(\"Add model\")"), "Model add button remains accessible")
        check(source.contains("if isCustom || managementLayout"), "Built-in management exposes removal")
        let makeDefault = source.components(separatedBy: "private func makePrimaryDefaultProviderAfterSaving")[1]
            .components(separatedBy: "private func modelBinding")[0]
        check(
            makeDefault.contains("saveManagedProviderAPIKeyIfNeeded") && !makeDefault.contains("saveProviderAPIKeys"),
            "Making a provider default only persists an active credential edit"
        )
        let removal = AIEnhancementSettingsViewModel()
        removal.providerAPIKeys = ["openai": "remove-key", "other": "keep-key"]
        removal.knownProviderAPIKeys = removal.providerAPIKeys
        removal.settings.dictationPromptConfigurations = [
            "affected": .init(providerID: "openai"),
            "unrelated": .init(providerID: "other"),
        ]
        removal.settings.rewriteModeSelectedProviderID = "openai"
        removal.settings.rewriteModeSelectedModel = "old"
        removal.settings.commandModeSelectedProviderID = "other"
        removal.settings.commandModeSelectedModel = "keep-model"
        removal.availableModelsByProvider = ["openai": ["old"], "other": ["keep"]]
        removal.selectedModelByProvider["openai"] = "old"
        UserDefaults.standard.set(["openai", "other"], forKey: AIEnhancementSettingsViewModel.addedProviderIDsKey)
        let before = removal.settings.dictationPromptConfigurations
        removal.failKeychain = true
        check(!(await removal.deleteCurrentProvider()), "Failed credential removal must fail the operation")
        check(removal.providerAPIKeys["openai"] == "remove-key" && removal.saves == 0, "Failed removal restores keys without saving provider changes")
        check(removal.settings.dictationPromptConfigurations == before, "Failed removal preserves assignments")
        check(UserDefaults.standard.stringArray(forKey: AIEnhancementSettingsViewModel.addedProviderIDsKey) == ["openai", "other"], "Failed removal preserves explicit membership")
        removal.failKeychain = false
        removal.isFetchingModels = true
        check(!(await removal.deleteCurrentProvider()), "Busy editor cannot remove a provider")
        removal.isFetchingModels = false
        check((await removal.deleteCurrentProvider()), "Built-in removal succeeds")
        check(removal.settings.selectedProviderID == "fluid" && removal.settings.selectedModel == "mini", "Removing another provider preserves the default")
        check(removal.settings.dictationPromptConfigurations["affected"]?.providerID == "", "Removed provider cannot remain referenced")
        check(removal.settings.dictationPromptConfigurations["affected"]?.shortcut == "keep-shortcut", "Removal preserves hotkeys")
        check(removal.settings.dictationPromptConfigurations["unrelated"] == before["unrelated"], "Unrelated prompt assignment is unchanged")
        check(removal.settings.rewriteModeSelectedProviderID.isEmpty && removal.settings.rewriteModeSelectedModel == nil, "Affected rewrite route is cleared")
        check(removal.settings.commandModeSelectedProviderID == "other" && removal.settings.commandModeSelectedModel == "keep-model", "Unrelated command route is unchanged")
        check(removal.providerAPIKeys == ["other": "keep-key"] && removal.availableModelsByProvider["other"] == ["keep"], "Unrelated provider credentials and models survive")
        check(!removal.cachedAddedProviderItems.contains { $0.id == "openai" }, "Removed built-in disappears from added providers")
        removal.selectedProviderID = "ollama"
        removal.settings.selectedProviderID = "ollama"
        let keySavesBeforeKeylessRemoval = removal.keySaves
        removal.failKeychain = true
        check(
            (await removal.deleteCurrentProvider()) && removal.settings.selectedProviderID.isEmpty && removal.settings.selectedModel == nil,
            "Removing the default clears its model without selecting another provider"
        )
        check(removal.keySaves == keySavesBeforeKeylessRemoval, "Removing a keyless provider does not require a Keychain write")
        removal.selectedProviderID = "fluid"
        check(!(await removal.deleteCurrentProvider()), "External provider removal cannot remove private AI")
        let newDraft = AIEnhancementSettingsViewModel()
        newDraft.selectedProviderID = "new-synthetic-draft"
        newDraft.unconfiguredProviderDraftIDs.insert(newDraft.selectedProviderID)
        newDraft.settings.providerAPIKeyReadiness = .unavailable
        check(await newDraft.deleteCurrentProvider(), "A keyless draft created in this session can be removed without loading credentials")
        check(newDraft.credentialReads == 0 && newDraft.keySaves == 0, "Removing a new keyless draft never invokes the credential backend")
        let cold = AIEnhancementSettingsViewModel()
        cold.settings.providerAPIKeyReadiness = .pending
        cold.configureProvider("openai")
        check(cold.managedOriginalKey == nil, "Cold manager baseline is unknown, never verified empty")
        cold.settings.providerAPIKeys = ["openai": "synthetic-loaded-key"]
        check(await cold.deleteCurrentProvider(), "Cold manager removes the credential found by authoritative load")
        check(cold.credentialReads == 1 && cold.keySaves == 1 && cold.persistedKeys["openai"] == nil,
              "Cold removal performs the real production credential-delete boundary")
        let arriving = AIEnhancementSettingsViewModel()
        arriving.settings.providerAPIKeyReadiness = .pending
        arriving.refreshProviderItems()
        check(arriving.cachedAddedProviderItems.isEmpty, "Credential-only provider is absent while cold keys are unknown")
        arriving.configureProvider("openai")
        arriving.statuses["openai"] = .success
        arriving.mergeLoadedProviderAPIKeys(["openai": "synthetic-arrived-key"])
        arriving.settings.providerAPIKeyReadiness = .loaded
        check(arriving.cachedAddedProviderItems.contains { $0.id == "openai" }, "Successful key arrival refreshes the displayed provider membership without reopening")
        check(arriving.cachedVerifiedProviderItems.contains { $0.id == "openai" } && arriving.verifiedRefreshes == 1,
              "Key arrival refreshes the verified and added descriptor lists through the production list builder")
        check(arriving.managedOriginalKey == "synthetic-arrived-key", "Stored key arrival establishes the manager baseline")
        check(await arriving.saveManagedProviderBeforeClosing("openai"), "Unedited cold manager may close after load")
        check(arriving.keySaves == 0 && arriving.selectedProviderID == "openai", "Key arrival is not misclassified as an edit and keeps selection")
        let dirty = AIEnhancementSettingsViewModel()
        dirty.settings.providerAPIKeyReadiness = .pending
        dirty.configureProvider("openai")
        dirty.updateProviderAPIKey("synthetic-user-edit", for: "openai")
        dirty.mergeLoadedProviderAPIKeys(["openai": "synthetic-arrived-key"])
        check(dirty.providerAPIKey(for: "openai") == "synthetic-user-edit" && dirty.managedOriginalKey == "synthetic-arrived-key",
              "Cold arrival preserves the draft while recording its persisted baseline")
        let external = AIEnhancementSettingsViewModel()
        external.settings.providerAPIKeyReadiness = .loaded
        external.configureProvider("openai")
        check(external.managedOriginalKey == "", "Loaded empty is a verified empty baseline")
        external.mergeLoadedProviderAPIKeys(["openai": "synthetic-external-key"])
        check(await external.saveManagedProviderBeforeClosing("openai"), "An untouched external key arrival may close")
        check(external.keySaves == 0, "An untouched external key arrival is never an implicit write")
        let closing = AIEnhancementSettingsViewModel()
        closing.managedProviderID = "openai"
        closing.providerAPIKeys["openai"] = "edited-key"
        closing.managedOriginalKey = "edited-key"
        closing.knownProviderAPIKeys["openai"] = "edited-key"
        closing.failKeychain = true
        check((await closing.saveManagedProviderBeforeClosing("openai")) && closing.keySaves == 0, "Unchanged key closes without any Keychain write, even if writes would fail")
        closing.managedOriginalKey = "old-key"
        closing.knownProviderAPIKeys["openai"] = "old-key"
        closing.failKeychain = true
        check(!(await closing.saveManagedProviderBeforeClosing("openai")), "Keychain failure keeps Manage open")
        check(closing.providerAPIKeys["openai"] == "edited-key" && closing.settings.selectedProviderID == "fluid", "Failed close preserves the draft and default")
        closing.failKeychain = false
        check(
            (await closing.saveManagedProviderBeforeClosing("openai")) && closing.persistedKeys["openai"] == "edited-key",
            "Done persists an edited key without verification or model refresh"
        )
        let savedCount = closing.keySaves
        closing.selectedProviderID = "fluid"
        check((await closing.saveManagedProviderBeforeClosing("openai")) && closing.keySaves == savedCount, "Removal cleanup must not save a different selected provider")
        closing.selectedProviderID = "ollama"
        check((await closing.saveManagedProviderBeforeClosing("ollama")) && closing.keySaves == savedCount, "Keyless provider close does not touch Keychain")
        closing.failKeychain = true
        check((await closing.saveManagedProviderAPIKeyIfNeeded("ollama")) && closing.keySaves == savedCount, "Making a keyless provider default does not require a Keychain write")
        closing.isTestingConnection = true
        check(!(await closing.saveManagedProviderBeforeClosing("ollama")), "Busy editor cannot dismiss")
        check(manager.contains(".interactiveDismissDisabled()"), "Interactive dismissal cannot bypass failed persistence")
        let historySource = try String(contentsOfFile: "Sources/Fluid/UI/TranscriptionHistoryView.swift", encoding: .utf8)
        // Inspect only the request type and its inputs. Unrelated properties may
        // legitimately sit between these declarations and the filtered list.
        func declaration(_ marker: String) -> String {
            guard let start = historySource.range(of: marker),
                  let end = historySource.range(of: "\n    }", range: start.upperBound..<historySource.endIndex)
            else { preconditionFailure("Missing history declaration: \(marker)") }
            return String(historySource[start.lowerBound..<end.upperBound])
        }
        let audioRequest = declaration("private struct AudioAvailabilityRequest")
            + declaration("private var audioAvailabilityRequest:")
        check(!audioRequest.contains("selectedEntry") && !audioRequest.contains("selectedID"), "Row selection cannot restart audio scans")
        print("Passed \(count) provider setup assertions")
    }
}

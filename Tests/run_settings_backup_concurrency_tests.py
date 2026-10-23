#!/usr/bin/env python3
"""Test source-extracted backup methods with bounded real-actor dependency probes.

No production defaults, disk stores, UI, hardware, or network are used.
--ref REF --expect-overlap-gap reproduces a historical overlapping snapshot gap.
Normal execution checks the current gate and credential serialization boundaries.
--ref selects BackupService and SettingsStore source from the same revision.
"""

import argparse
import os
from pathlib import Path
import subprocess
import tempfile


def declaration(source: str, marker: str) -> str:
    start = source.index(marker)
    brace = source.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def credential_probe(source: str, settings_source: str) -> str:
    """Compile actual migration/serialization with memory preferences and injected Keychain."""
    payload = declaration(source, "struct SettingsBackupPayload:")
    redaction = declaration(payload, "    nonisolated func redactingProviderCredentials()")
    saved_provider = declaration(settings_source, "    struct SavedProvider:")
    settings_export = declaration(settings_source, "    func makeBackupPayload()")
    export_lines = [line.strip() for line in settings_export.splitlines() if line.strip().startswith("savedProviders:")]
    assert len(export_lines) == 1, "Ambiguous saved-provider backup boundary"
    export_argument = export_lines[0].split(":", 1)[1].strip().removesuffix(",")
    members = "\n".join(declaration(source, marker) for marker in (
        "    func encode(_ document: AppBackupDocument)",
        "    func decode(_ data: Data)",
        "    private func validate(_ document: AppBackupDocument)",
        "    private static func dataByMigratingLegacyPrivateAIKeys(",
    ))
    swift = r'''
import Foundation
// Display preferences remain inert, matching the concurrency probe below.
nonisolated class UserDefaults: @unchecked Sendable {
    static let standard = UserDefaults()
    func string(forKey key: String) -> String? { nil }
    func dictionary(forKey key: String) -> [String: Any]? { nil }
    func data(forKey key: String) -> Data? { nil }
    func set(_ value: Any?, forKey key: String) { fatalError("Unexpected preference write") }
    func removeObject(forKey key: String) { fatalError("Unexpected preference removal") }
    func synchronize() -> Bool { fatalError("Unexpected preference synchronization") }
}
// This probe injects ordinary memory preferences. Profile facade routes must
// never run here; the actual storage snapshot below still checks generation.
nonisolated final class PrivateProfileDefaults: UserDefaults, @unchecked Sendable {
    var selectedProfile: PrivateProfileSnapshot { fatalError("Unexpected profile facade read") }
    static func bound(to profile: PrivateProfileSnapshot) -> UserDefaults {
        fatalError("Unexpected profile facade binding")
    }
}
SCHEMA
ERRORS
struct SettingsBackupPayload: Codable, Equatable {
    var savedProviders: [SettingsStore.SavedProvider]
    var selectedProviderID = "custom:fixture"
    var selectedModelByProvider = ["custom:fixture": "модель-ёж"]
    var privateAIPrefixKVCacheEnabled: Bool? = nil
    var visualizerNoiseThreshold = 0.15
    PAYLOAD_REDACTION
}
// Only persistence dependencies and unrelated nested value types are replaced.
// SavedProvider, document, redaction and encode/decode bodies are actual source.
final class MemoryPreferences: UserDefaults, @unchecked Sendable {
    private var values: [String: Any]
    private(set) var writes = 0
    private var persisted: [String: Any]
    var synchronizationSucceeds = true
    var reintroduceSourceAfterSynchronization = false
    var synchronizationStarted: (@Sendable () -> Void)?
    var synchronizationRelease: DispatchSemaphore?
    private let originalProviderBytes: Data
    init(providerBytes: Data, legacy: [String: String]? = nil) {
        originalProviderBytes = providerBytes
        values = ["SavedProviders": providerBytes]
        if let legacy { values["ProviderAPIKeys"] = legacy }
        persisted = values
    }
    override func synchronize() -> Bool {
        precondition(!Thread.isMainThread, "Migration persistence must never wait on main")
        synchronizationStarted?()
        if let synchronizationRelease {
            precondition(synchronizationRelease.wait(timeout: .now() + 5) == .success,
                         "Synthetic synchronization must be released")
        }
        guard synchronizationSucceeds else { return false }
        persisted = values
        if reintroduceSourceAfterSynchronization { values["SavedProviders"] = originalProviderBytes }
        return true
    }
    var persistedProviderBytes: Data { persisted["SavedProviders"] as! Data }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func dictionary(forKey key: String) -> [String: Any]? { values[key] as? [String: Any] }
    override func set(_ value: Any?, forKey key: String) { writes += 1; values[key] = value }
    override func removeObject(forKey key: String) { writes += 1; values.removeValue(forKey: key) }
}
final class ChangeCounter { func send() {} }
final class DebugLogger {
    static let shared = DebugLogger()
    func error(_ message: String, source: String) {}
}
actor SynchronizationGate {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    func didEnter() { entered = true; waiter?.resume(); waiter = nil }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { waiter = $0 }
    }
}
struct ModelRepository {
    static let shared = ModelRepository()
    static let builtInProviderIDs = ["builtin-fixture"]
    func isBuiltIn(_ id: String) -> Bool { Self.builtInProviderIDs.contains(id) }
}
final class SettingsStore {
    SAVED_PROVIDER
    typealias DictationPromptProfile = String
    typealias AppPromptBinding = String
    enum Keys { static let savedProviders = "SavedProviders"; static let providerAPIKeys = "ProviderAPIKeys"; static let providerAPIKeyIdentifiers = "ProviderAPIKeyIdentifiers" }
    private let defaults: UserDefaults
    private var memoryPreferences: MemoryPreferences { defaults as! MemoryPreferences }
    private let keychain = KeychainService(
        testingLoad: { fatalError("Unexpected Keychain read") },
        testingSave: { _ in fatalError("Unexpected Keychain write") },
        testingLegacyLoad: { fatalError("Unexpected legacy Keychain read") },
        testingLegacyRemove: { _ in fatalError("Unexpected legacy Keychain removal") }
    )
    private var providerCredentialCleanupNeedsPersistence = false
    private let objectWillChange = ChangeCounter()
    init(savedProviders: [SavedProvider], legacy: [String: String]? = nil) {
        defaults = MemoryPreferences(providerBytes: try! JSONEncoder().encode(savedProviders), legacy: legacy)
    }
    SAVED_PROVIDERS_ACCESSOR
    MIGRATION_SNAPSHOT_TYPE
    MIGRATION_SNAPSHOT
    MIGRATION_COMPLETION
    @MainActor
    ACKNOWLEDGE_MIGRATION
    CREDENTIAL_SOURCES_CLEAR
    SANITIZE_KEYS
    CANONICAL_PROVIDER_KEY
    func exerciseMigration(verifiedKeys: [String: String]) {
        let snapshot = self.providerCredentialMigrationSnapshot()
        _ = self.completeProviderCredentialMigration(snapshot, verifiedKeys: verifiedKeys)
    }
    func exerciseChangedSourceMigration() {
        let snapshot = self.providerCredentialMigrationSnapshot()
        var changed = self.savedProviders
        let old = changed[0]
        changed[0] = SavedProvider(id: old.id, name: old.name, baseURL: old.baseURL, apiKey: "synthetic-newer-edit", models: old.models)
        self.defaults.set(try! JSONEncoder().encode(changed), forKey: Keys.savedProviders)
        _ = self.completeProviderCredentialMigration(snapshot, verifiedKeys: snapshot.keys)
    }
    var legacyDefaults: [String: String]? { defaults.dictionary(forKey: Keys.providerAPIKeys) as? [String: String] }
    func exerciseAcknowledgedMigration(verifiedKeys: [String: String], persistenceSucceeds: Bool, reintroduceSource: Bool = false) async -> Bool {
        let snapshot = self.providerCredentialMigrationSnapshot()
        self.memoryPreferences.synchronizationSucceeds = persistenceSucceeds
        self.memoryPreferences.reintroduceSourceAfterSynchronization = reintroduceSource
        return await self.acknowledgeProviderCredentialMigration(snapshot, verifiedKeys: verifiedKeys)
    }
    @MainActor
    func exerciseProfileAcknowledgment(
        verifiedKeys: [String: String], beforeAcknowledgment: () -> Void = {},
        synchronizationStarted: (@Sendable () -> Void)? = nil,
        synchronizationRelease: DispatchSemaphore? = nil
    ) async -> Bool {
        let source = self.providerCredentialMigrationSnapshot()
        let snapshot = ProviderCredentialMigrationSnapshot(
            preferences: source.preferences, keychain: source.keychain,
            profile: PrivateProfileStorage.current, legacyDefaults: source.legacyDefaults,
            savedProviderBytes: source.savedProviderBytes, keys: source.keys,
            canonicalProviderIDs: source.canonicalProviderIDs
        )
        self.memoryPreferences.synchronizationStarted = synchronizationStarted
        self.memoryPreferences.synchronizationRelease = synchronizationRelease
        beforeAcknowledgment()
        return await self.acknowledgeProviderCredentialMigration(snapshot, verifiedKeys: verifiedKeys)
    }
    func joinCredentialWorker() async { await self.keychain.retireAndJoin() }
    var persistedProviders: [SavedProvider] { try! JSONDecoder().decode([SavedProvider].self, from: self.memoryPreferences.persistedProviderBytes) }
    var sourceBytes: Data { defaults.data(forKey: Keys.savedProviders)! }
    var preferenceWrites: Int { memoryPreferences.writes }
    func makeBackupPayload() -> SettingsBackupPayload {
        .init(savedProviders: SETTINGS_EXPORT_ARGUMENT)
    }
}
typealias TranscriptionHistoryEntry = String
typealias PronunciationDictionaryProfile = String
DOCUMENT
@MainActor final class BackupService {
MEMBERS
}
@MainActor var assertions = 0
@MainActor func expect(_ condition: Bool, _ message: String) {
    assertions += 1
    if !condition { fatalError("FAIL: " + message) }
}
@MainActor func expectMetadata(_ original: AppBackupDocument, _ redacted: AppBackupDocument) {
    expect(redacted.schemaVersion == original.schemaVersion, "schema version preserved")
    expect(redacted.appVersion == original.appVersion && redacted.exportedAt == original.exportedAt, "app version and ISO timestamp preserved")
    expect(redacted.settings.selectedProviderID == original.settings.selectedProviderID
        && redacted.settings.selectedModelByProvider == original.settings.selectedModelByProvider
        && redacted.settings.privateAIPrefixKVCacheEnabled == original.settings.privateAIPrefixKVCacheEnabled
        && redacted.settings.visualizerNoiseThreshold == original.settings.visualizerNoiseThreshold, "unrelated settings preserved")
    expect(redacted.promptProfiles == original.promptProfiles && redacted.appPromptBindings == original.appPromptBindings, "prompt profiles and bindings preserved")
    expect(redacted.transcriptionHistory == original.transcriptionHistory && redacted.pronunciationProfiles == original.pronunciationProfiles, "history and pronunciation payload preserved")
    expect(redacted.settings.savedProviders.count == original.settings.savedProviders.count, "provider order and count preserved")
    for (before, after) in zip(original.settings.savedProviders, redacted.settings.savedProviders) {
        expect(after.apiKey.isEmpty, "every saved-provider key redacted")
        expect(after.id == before.id && after.name == before.name
            && after.baseURL == before.baseURL && after.models == before.models, "provider metadata preserved exactly")
    }
}
@main struct Run {
    @MainActor static func main() async throws {
        let providers = [
            SettingsStore.SavedProvider(id: "custom:fixture", name: "Ёж и café", baseURL: "https://fixture.invalid/v1", apiKey: "synthetic-key-leak-marker", models: ["модель-ёж", "model-42"]),
            SettingsStore.SavedProvider(id: "empty-key", name: "Empty", baseURL: "http://127.0.0.1:11434/v1", models: []),
            SettingsStore.SavedProvider(id: "custom:русский", name: "Синтетический провайдер", baseURL: "https://another.invalid/api", apiKey: "синтетический-ключ-ёж", models: ["custom-model"]),
        ]
        let original = AppBackupDocument(schemaVersion: .init(major: 1, minor: 7), appVersion: "fixture-1.2.3",
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000), settings: .init(savedProviders: providers),
            promptProfiles: ["Keep user prompt: ёж"], appPromptBindings: ["fixture.app"],
            transcriptionHistory: ["User transcript: Do not translate 42"], pronunciationProfiles: ["synthetic voice metadata"])
        let service = BackupService()
        let sanitizedProvider = providers[0].redactingAPIKey()
        expect(sanitizedProvider.apiKey.isEmpty && providers[0].apiKey == "synthetic-key-leak-marker", "provider helper redacts a copy")
        let snapshot = original.redactingProviderCredentials()
        expectMetadata(original, snapshot)
        expect(snapshot.redactingProviderCredentials() == snapshot, "redaction is idempotent")
        let exported = try service.encode(original)
        expect(!String(decoding: exported, as: UTF8.self).contains("synthetic-key-leak-marker")
            && !String(decoding: exported, as: UTF8.self).contains("синтетический-ключ-ёж"), "export bytes contain no synthetic credentials")
        let exportedJSON = try JSONSerialization.jsonObject(with: exported) as! [String: Any]
        let exportedSettings = exportedJSON["settings"] as! [String: Any]
        let exportedProviders = exportedSettings["savedProviders"] as! [[String: Any]]
        expect(exportedProviders.allSatisfy { ($0["apiKey"] as? String) == "" }, "JSON retains compatible empty apiKey fields")
        let decoded = try service.decode(exported)
        expectMetadata(original, decoded)
        expect(decoded == snapshot, "real production encode/decode roundtrip matches sanitized snapshot")
        expect(original.settings.savedProviders == providers && providers[2].apiKey == "синтетический-ключ-ёж", "serialization leaves caller's original credentials unchanged")
        let legacyStore = SettingsStore(savedProviders: providers)
        let preferenceBytes = legacyStore.sourceBytes
        legacyStore.exerciseMigration(verifiedKeys: [:])
        expect(legacyStore.preferenceWrites == 0, "actual migration cleanup with no verified keys never rewrites in-memory legacy preferences")
        expect(legacyStore.savedProviders == providers && legacyStore.sourceBytes == preferenceBytes, "actual savedProviders getter retains legacy keys after failed migration")
        let mixedStore = SettingsStore(savedProviders: providers)
        mixedStore.exerciseMigration(verifiedKeys: [providers[0].id: providers[0].apiKey])
        expect(mixedStore.savedProviders[0].apiKey.isEmpty, "verified provider may be scrubbed")
        expect(mixedStore.savedProviders[2].apiKey == providers[2].apiKey, "failed provider secret survives another provider's successful migration")
        let defaultStore = SettingsStore(savedProviders: providers, legacy: ["legacy": "synthetic-legacy-default"])
        defaultStore.exerciseMigration(verifiedKeys: [:])
        expect(defaultStore.legacyDefaults == ["legacy": "synthetic-legacy-default"], "unverified legacy defaults are retained")
        expect(defaultStore.preferenceWrites == 0, "failed aggregate migration never deletes defaults")
        defaultStore.exerciseMigration(verifiedKeys: ["custom:legacy": "synthetic-legacy-default", providers[0].id: providers[0].apiKey, providers[2].id: providers[2].apiKey])
        expect(defaultStore.legacyDefaults == nil, "verified legacy defaults are removed")
        expect(defaultStore.savedProviders.allSatisfy { $0.apiKey.isEmpty }, "successful verified migration scrubs all migrated provider secrets")
        let changedStore = SettingsStore(savedProviders: providers)
        changedStore.exerciseChangedSourceMigration()
        expect(changedStore.savedProviders[0].apiKey == "synthetic-newer-edit", "stale completion preserves a newer source edit")
        expect(changedStore.savedProviders[2].apiKey == providers[2].apiKey && changedStore.preferenceWrites == 1,
            "stale completion performs no additional write or mixed partial scrub")
        let persistenceFailure = SettingsStore(savedProviders: providers)
        let verified = [providers[0].id: providers[0].apiKey, providers[2].id: providers[2].apiKey]
        let failedAck = await persistenceFailure.exerciseAcknowledgedMigration(verifiedKeys: verified, persistenceSucceeds: false)
        expect(!failedAck, "a failed preference persistence acknowledgment must reject subsequent credential intent")
        expect(persistenceFailure.persistedProviders == providers, "failed persistence retains original secrets across synthetic restart")
        let retryAck = await persistenceFailure.exerciseAcknowledgedMigration(verifiedKeys: verified, persistenceSucceeds: true)
        expect(retryAck && persistenceFailure.persistedProviders.allSatisfy { $0.apiKey.isEmpty },
               "an empty next snapshot must retry failed pending persistence before acknowledging cleanup")
        let persisted = SettingsStore(savedProviders: providers)
        let successfulAck = await persisted.exerciseAcknowledgedMigration(verifiedKeys: verified, persistenceSucceeds: true)
        expect(successfulAck && persisted.persistedProviders.allSatisfy { $0.apiKey.isEmpty }, "acknowledgment joins durable legacy removal before an explicit edit may commit")
        let reintroduced = SettingsStore(savedProviders: providers)
        let reintroducedAck = await reintroduced.exerciseAcknowledgedMigration(verifiedKeys: verified, persistenceSucceeds: true, reintroduceSource: true)
        expect(!reintroducedAck && reintroduced.savedProviders == providers, "a source reintroduced during persistence remains intact and rejects the credential edit")
        expect(reintroduced.preferenceWrites == 1, "final acknowledgment validation never scrubs a new source without another joined persistence step")
        let selectedProfile = PrivateProfileStorage.current
        let hidden = SettingsStore(savedProviders: providers)
        let hiddenAck = await hidden.exerciseProfileAcknowledgment(verifiedKeys: verified) {
            PrivateProfileStorage.conceal(generation: UUID())
        }
        expect(!hiddenAck && hidden.preferenceWrites == 0 && hidden.savedProviders == providers,
               "concealed captured profile rejects migration before preference writes")
        PrivateProfileStorage.select(selectedProfile)
        let replaced = SettingsStore(savedProviders: providers)
        let replacedAck = await replaced.exerciseProfileAcknowledgment(verifiedKeys: verified) {
            PrivateProfileStorage.select(try! PrivateProfileStorage.proposed(context: nil, generation: UUID()))
        }
        expect(!replacedAck && replaced.preferenceWrites == 0,
               "same profile ID with another generation rejects the captured migration")
        PrivateProfileStorage.select(selectedProfile)
        let held = SettingsStore(savedProviders: providers)
        let release = DispatchSemaphore(value: 0)
        let synchronizationGate = SynchronizationGate()
        let heldOperation = Task { @MainActor in
            await held.exerciseProfileAcknowledgment(verifiedKeys: verified,
                synchronizationStarted: { Task { await synchronizationGate.didEnter() } },
                synchronizationRelease: release)
        }
        await synchronizationGate.waitUntilEntered()
        PrivateProfileStorage.conceal(generation: UUID())
        release.signal()
        let heldAck = await heldOperation.value
        expect(!heldAck && held.persistedProviders.allSatisfy { $0.apiKey.isEmpty },
               "conceal during joined persistence rejects late acknowledgment while retaining durable cleanup")
        PrivateProfileStorage.select(selectedProfile)
        let settingsSnapshot = legacyStore.makeBackupPayload()
        expect(settingsSnapshot.savedProviders == snapshot.settings.savedProviders, "actual settings-export argument redacts saved providers before document construction")
        expect(legacyStore.sourceBytes == preferenceBytes && legacyStore.savedProviders == providers,
            "settings export does not mutate legacy preference bytes or provider values")

        // Encode a legacy fixture independently so production encode cannot
        // sanitize the input before the production decode boundary is tested.
        let fixtureEncoder = JSONEncoder()
        fixtureEncoder.dateEncodingStrategy = .iso8601
        let legacyBytes = try fixtureEncoder.encode(original)
        let pristineBytes = legacyBytes
        expect(String(decoding: legacyBytes, as: UTF8.self).contains("synthetic-key-leak-marker"), "legacy fixture actually contains a credential")
        let legacyDecoded = try service.decode(legacyBytes)
        expectMetadata(original, legacyDecoded)
        expect(legacyDecoded == snapshot && legacyBytes == pristineBytes, "legacy decode sanitizes its value without mutating input bytes")
        let legacyReencoded = try service.encode(legacyDecoded)
        expect(!String(decoding: legacyReencoded, as: UTF8.self).contains("synthetic-key-leak-marker"), "legacy decode/reencode never republishes the key")

        var root = try JSONSerialization.jsonObject(with: legacyBytes) as! [String: Any]
        var settings = root["settings"] as! [String: Any]
        let legacyCacheKey = ["fluid", "Int", "elligence", "PrefixKVCacheEnabled"].joined()
        settings.removeValue(forKey: "privateAIPrefixKVCacheEnabled")
        settings[legacyCacheKey] = false
        root["settings"] = settings
        let migrated = try service.decode(JSONSerialization.data(withJSONObject: root))
        expect(migrated.settings.privateAIPrefixKVCacheEnabled == false, "legacy cache-field migration remains effective alongside credential redaction")
        expect(migrated.settings.savedProviders == snapshot.settings.savedProviders, "migrated legacy decode redacts credentials")
        settings["privateAIPrefixKVCacheEnabled"] = true
        root["settings"] = settings
        let modernWins = try service.decode(JSONSerialization.data(withJSONObject: root))
        expect(modernWins.settings.privateAIPrefixKVCacheEnabled == true, "current cache field takes precedence over a legacy field")

        // Actual encoder failures return no partial Data and retain source state.
        var invalidSettings = original.settings
        invalidSettings.visualizerNoiseThreshold = .nan
        let invalid = AppBackupDocument(schemaVersion: original.schemaVersion, appVersion: original.appVersion,
            exportedAt: original.exportedAt, settings: invalidSettings, promptProfiles: original.promptProfiles,
            appPromptBindings: original.appPromptBindings, transcriptionHistory: original.transcriptionHistory,
            pronunciationProfiles: original.pronunciationProfiles)
        var partial: Data?
        do { partial = try service.encode(invalid); fatalError("Expected nonfinite JSON encode failure") }
        catch EncodingError.invalidValue { }
        expect(partial == nil && invalid.settings.savedProviders == providers, "encode failure publishes no bytes and leaves source state unchanged")
        do { _ = try service.decode(Data("{}".utf8)); fatalError("Expected invalid JSON document rejection") }
        catch BackupServiceError.invalidJSON { }
        root["schemaVersion"] = ["major": 99, "minor": 0]
        do { _ = try service.decode(JSONSerialization.data(withJSONObject: root)); fatalError("Expected unsupported-schema rejection") }
        catch BackupServiceError.unsupportedSchemaVersion(let version) { expect(version.major == 99, "schema rejection retains error classification") }
        expect(original.settings.savedProviders == providers, "all success and failure paths leave original providers unchanged")
        for store in [legacyStore, mixedStore, defaultStore, changedStore, persistenceFailure, persisted, reintroduced, hidden, replaced, held] {
            await store.joinCredentialWorker()
        }
        print("PASS: \(assertions) production serialization/redaction/migration assertions; memory preferences and injected Keychain only")
    }
}
'''
    substitutions = {
        "SCHEMA": declaration(source, "struct BackupFileVersion:"),
        "ERRORS": declaration(source, "enum BackupServiceError:"),
        "PAYLOAD_REDACTION": redaction,
        "SAVED_PROVIDER": saved_provider,
        "SAVED_PROVIDERS_ACCESSOR": declaration(settings_source, "    var savedProviders:"),
        "MIGRATION_SNAPSHOT_TYPE": declaration(settings_source, "    private struct ProviderCredentialMigrationSnapshot:"),
        "MIGRATION_SNAPSHOT": declaration(settings_source, "    private func providerCredentialMigrationSnapshot()"),
        "MIGRATION_COMPLETION": declaration(settings_source, "    private func completeProviderCredentialMigration("),
        "ACKNOWLEDGE_MIGRATION": declaration(settings_source, "    private func acknowledgeProviderCredentialMigration("),
        "CREDENTIAL_SOURCES_CLEAR": declaration(settings_source, "    private func providerCredentialSourcesAreClear("),
        "SANITIZE_KEYS": declaration(settings_source, "    private func sanitizeAPIKeys("),
        "CANONICAL_PROVIDER_KEY": declaration(settings_source, "    private func canonicalProviderKey("),
        "SETTINGS_EXPORT_ARGUMENT": export_argument,
        "DOCUMENT": declaration(source, "struct AppBackupDocument:"),
        "MEMBERS": members,
    }
    for marker in sorted(substitutions, key=len, reverse=True):
        swift = swift.replace(marker, substitutions[marker])
    return swift


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref")
    probes = parser.add_mutually_exclusive_group()
    probes.add_argument("--expect-overlap-gap", action="store_true")
    probes.add_argument("--expect-active-work-gap", action="store_true")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    selected = subprocess.check_output(["xcode-select", "-p"], text=True, timeout=10).strip()
    developer_dir = os.environ.get("DEVELOPER_DIR", selected)
    if not (Path(developer_dir) / "Platforms/MacOSX.platform").is_dir():
        raise SystemExit("Set DEVELOPER_DIR to a full installed Xcode before running this test.")
    environment = dict(os.environ, DEVELOPER_DIR=developer_dir)
    source_path = "Sources/Fluid/Persistence/BackupService.swift"
    source = (
        subprocess.check_output(["git", "show", f"{args.ref}:{source_path}"], cwd=repo, text=True, timeout=10)
        if args.ref else (repo / source_path).read_text()
    )
    settings_path = "Sources/Fluid/Persistence/SettingsStore.swift"
    settings_source = (
        subprocess.check_output(["git", "show", f"{args.ref}:{settings_path}"], cwd=repo, text=True, timeout=10)
        if args.ref else (repo / settings_path).read_text()
    )
    members = "\n".join(declaration(source, marker) for marker in (
        "    func makeBackupDocument() async throws -> AppBackupDocument",
        "    func restore(_ document: AppBackupDocument) async throws",
        "    private func validate(_ document: AppBackupDocument)",
    ))
    if "private var operationInProgress" in source:
        # Extract the actual gate storage and admission method, never a mirrored gate.
        gate_line = next(line for line in source.splitlines() if "private var operationInProgress" in line)
        members = gate_line + "\n" + declaration(source, "    private func beginOperation()") + "\n" + members
    errors = declaration(source, "enum BackupServiceError:")
    schema = declaration(source, "struct BackupFileVersion:")
    asr_source = (repo / "Sources/Fluid/Services/ASRService.swift").read_text()
    # --ref intentionally selects the backup/settings boundary only; keep its
    # ASR dependency current, including declarations split into their own file.
    # Repositories predating that split still provide the types in ASRService.
    lease_path = repo / "Sources/Fluid/Services/ASRActivityLease.swift"
    lease_source = lease_path.read_text() if lease_path.exists() else asr_source
    asr_admission = declaration(asr_source, "    func beginSettingsBackupRestore()")
    if "    var canBeginPrivateProfileTransition:" in asr_source:
        asr_admission = declaration(asr_source, "    var canBeginPrivateProfileTransition:") + "\n" + asr_admission
    asr_activity = declaration(lease_source, "enum ASRExclusiveActivity:")
    asr_lease = declaration(lease_source, "struct ASRActivityLease:")
    asr_error = declaration(lease_source, "enum ASRActivityError:")
    asr_release = declaration(asr_source, "    func releaseExclusiveActivity(")
    asr_restore = declaration(asr_source, "    func handleSettingsBackupDidRestore()")
    swift = r'''
import Foundation
// Keep production display metadata, with only preferences/package storage isolated.
nonisolated final class UserDefaults: @unchecked Sendable {
    static let standard = UserDefaults()
    func string(forKey key: String) -> String? { nil }
    func set(_ value: Any?, forKey key: String) { fatalError("Unexpected preference write") }
}
SCHEMA
ERRORS
struct Payload: Codable {
    var owner: String
    var privateAIIdleUnload: Int?
    var meetingLanguage: String? = nil
    var promptConfigurations: [String: String]? = nil
}
struct AppBackupDocument {
    var schemaVersion: BackupFileVersion = .current
    var appVersion = "fixture"
    var exportedAt = Date()
    var settings: Payload
    var promptProfiles: [String] = []
    var appPromptBindings: [String] = []
    var transcriptionHistory: [String] = []
    var pronunciationProfiles: [String]?
}
@MainActor final class SettingsStore {
    static let shared = SettingsStore()
    var owner = "original"
    var privateAIIdleUnload = 30
    var meetingLanguage = "en"
    var configurations = ["__default__": "original"]
    var dictationPromptProfiles: [String] = []
    var appPromptBindings: [String] = []
    func makeBackupPayload() -> Payload {
        .init(owner: owner, privateAIIdleUnload: privateAIIdleUnload,
              meetingLanguage: meetingLanguage, promptConfigurations: configurations)
    }
    func restore(from payload: Payload, promptProfiles: [String], appPromptBindings: [String]) {
        owner = payload.owner
        if let idle = payload.privateAIIdleUnload { privateAIIdleUnload = idle }
        if let language = payload.meetingLanguage { meetingLanguage = language }
        if let configurations = payload.promptConfigurations { self.configurations = configurations }
        dictationPromptProfiles = promptProfiles
        self.appPromptBindings = appPromptBindings
    }
}
actor Gate {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func pause() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
enum ProbeFailure: Error { case storage }
actor PronunciationDictionaryStore {
    static let shared = PronunciationDictionaryStore()
    var profiles = ["original"]
    var reject = false
    var exportGate: Gate?
    var restoreGate: Gate?
    var snapshots = 0, replacements = 0
    func setup(reject: Bool = false, exportGate: Gate? = nil, restoreGate: Gate? = nil) {
        profiles = ["original"]; self.reject = reject
        self.exportGate = exportGate; self.restoreGate = restoreGate
        snapshots = 0; replacements = 0
    }
    func allProfiles() async -> [String] {
        snapshots += 1
        let snapshot = profiles
        if let gate = exportGate { exportGate = nil; await gate.pause() }
        return snapshot
    }
    func replaceAllProfiles(_ profiles: [String]) async throws {
        replacements += 1
        if let gate = restoreGate { restoreGate = nil; await gate.pause() }
        if reject { throw ProbeFailure.storage }
        self.profiles = profiles
    }
    func ordinaryEdit(_ profiles: [String]) { self.profiles = profiles }
    func state() -> ([String], Int, Int) { (profiles, snapshots, replacements) }
}
@MainActor final class TranscriptionHistoryStore {
    static let shared = TranscriptionHistoryStore()
    var history = ["original"]
    var loaded = true
    var loadGate: Gate?
    var loads = 0, writes = 0
    func waitUntilLoaded() async throws {
        loads += 1
        if let gate = loadGate { loadGate = nil; await gate.pause() }
        if !loaded { throw ProbeFailure.storage }
    }
    func makeBackupPayload() -> [String] { history }
    func restore(from payload: [String]) { writes += 1; history = payload }
}
actor IdleDouble {
    var gate: Gate?
    var calls = 0
    var observations: [Int] = []
    func setup(gate: Gate? = nil) { self.gate = gate; calls = 0; observations = [] }
    func settingsChanged() async {
        calls += 1
        if let gate { self.gate = nil; await gate.pause() }
        observations.append(await SettingsStore.shared.privateAIIdleUnload)
    }
    func state() -> (Int, [Int]) { (calls, observations) }
}
enum PrivateAIIntegrationService { static let idleUnloader = IdleDouble() }
@MainActor final class NotificationCenter {
    static let `default` = NotificationCenter()
    var snapshots: [(String, [String])] = []
    var onPost: (() -> Void)?
    enum Name { case settingsBackupDidRestore }
    func post(name: Name, object: Any?) {
        snapshots.append((SettingsStore.shared.owner, TranscriptionHistoryStore.shared.history))
        onPost?()
    }
}
ASR_ACTIVITY
ASR_ERROR
ASR_LEASE
@MainActor final class HandoffProbe { var isRecovering = false }
@MainActor final class ResidencyProbe { var isExclusive = false }
@MainActor final class ASRService {
    var isTerminating = false
    struct AdmittedProbe { let lease: ASRActivityLease }
    var admittedTranscription: AdmittedProbe?
    var activeActivityLease: ASRActivityLease?
    var activeExclusiveActivity: ASRExclusiveActivity?
    var isRunning = false, isStarting = false, isStoppingFinalTranscription = false
    let recordingBufferHandoffGate = HandoffProbe()
    var isMicrophonePreviewRequested = false, isMicrophonePreviewActive = false
    var hasActiveModelDownload = false, hasActiveModelPreparation = false
    var deletingModelID: String?, providerResetDrain: UUID?
    var isCancellingModelPreparation = false, isCancellingModelDownload = false
    let meetingModelResidency = ResidencyProbe()
    var isAsrReady = true, isDownloadingModel = false, isLoadingModel = false
    var admissions = 0
    var releases: Int { DictionaryAudioLearningService.shared.activityEnds }
    var providerResetPending = false
    var deferredMeetingActivityLeaseRelease: ASRActivityLease?
    var completedResets = 0, recoveryRequests = 0
    ASR_ADMISSION
    func acquireExclusiveActivity(_ activity: ASRExclusiveActivity) throws -> ASRActivityLease {
        guard activeActivityLease == nil else { throw ASRActivityError.activityInProgress(activeExclusiveActivity!) }
        let lease = ASRActivityLease(id: UUID(), activity: activity)
        activeActivityLease = lease; activeExclusiveActivity = activity; admissions += 1; return lease
    }
    ASR_RELEASE
    ASR_RESTORE
    func isMeetingASRClaimBlocking(lease: ASRActivityLease) -> Bool { false }
    func resetTranscriptionProvider() {
        if activeActivityLease != nil { providerResetPending = true; return }
        isAsrReady = false; completedResets += 1
    }
    func scheduleAudioRouteRecovery(reason: String, requiresIdlePrewarm: Bool, reconcilesInputSelection: Bool) {
        recoveryRequests += 1
    }
}
@MainActor final class DictionaryAudioLearningService {
    static let shared = DictionaryAudioLearningService()
    var activityEnds = 0
    func activityDidEnd() { activityEnds += 1 }
}
@MainActor final class SpeechModelInstallationSnapshot {
    static let shared = SpeechModelInstallationSnapshot()
    func refresh() {}
}
@MainActor final class AppServices {
    static let shared = AppServices()
    var asr = ASRService()
}
@MainActor final class BackupService {
MEMBERS
}
@MainActor var assertions = 0
@MainActor func expect(_ condition: Bool, _ message: String) {
    assertions += 1
    if !condition { fatalError("FAIL: " + message) }
}
@MainActor func busy(_ work: () async throws -> Void) async {
    do { try await work(); fatalError("Expected busy rejection") }
    catch BackupServiceError.operationInProgress {
        expect(BackupServiceError.operationInProgress.localizedDescription.contains("already running"), "busy error tells user to retry")
    } catch { fatalError("Wrong busy error: \(error)") }
}
@MainActor func reset(idleGate: Gate? = nil, exportGate: Gate? = nil, restoreGate: Gate? = nil) async {
    AppServices.shared.asr = ASRService()
    DictionaryAudioLearningService.shared.activityEnds = 0
    SettingsStore.shared.owner = "original"
    SettingsStore.shared.privateAIIdleUnload = 30
    SettingsStore.shared.meetingLanguage = "en"
    SettingsStore.shared.configurations = ["__default__": "original"]
    SettingsStore.shared.dictationPromptProfiles = []
    SettingsStore.shared.appPromptBindings = []
    TranscriptionHistoryStore.shared.history = ["original"]
    TranscriptionHistoryStore.shared.loaded = true
    TranscriptionHistoryStore.shared.loads = 0; TranscriptionHistoryStore.shared.writes = 0
    TranscriptionHistoryStore.shared.loadGate = nil
    NotificationCenter.default.snapshots = []; NotificationCenter.default.onPost = nil
    await PronunciationDictionaryStore.shared.setup(exportGate: exportGate, restoreGate: restoreGate)
    await PrivateAIIntegrationService.idleUnloader.setup(gate: idleGate)
}
func awaitGate(_ gate: Gate) async {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await gate.entered) {
        if ContinuousClock.now > deadline { fatalError("Timed out waiting for actor gate") }
        try? await Task.sleep(for: .milliseconds(1))
    }
}
@MainActor func document(_ owner: String, idle: Int? = 60) -> AppBackupDocument {
    .init(settings: .init(owner: owner, privateAIIdleUnload: idle),
          promptProfiles: [owner], appPromptBindings: [owner],
          transcriptionHistory: [owner], pronunciationProfiles: [owner])
}
@main struct Run {
    @MainActor static func main() async throws {
        let service = BackupService()
        // Export suspended after obtaining old pronunciation; concurrent import used
        // to make the eventual settings/History snapshot belong to a different backup.
        let exportGate = Gate()
        await reset(exportGate: exportGate)
        let firstExport = Task { try await service.makeBackupDocument() }
        await awaitGate(exportGate)
        OVERLAP_ACTION
        await exportGate.release()
        let snapshot = try await firstExport.value
        OVERLAP_ASSERTION
        CURRENT_TESTS
    }
}
'''.replace("SCHEMA", schema).replace("ERRORS", errors).replace("MEMBERS", members).replace("ASR_ACTIVITY", asr_activity).replace("ASR_LEASE", asr_lease).replace("ASR_ERROR", asr_error).replace("ASR_ADMISSION", asr_admission).replace("ASR_RELEASE", asr_release).replace("ASR_RESTORE", asr_restore)

    if args.expect_active_work_gap:
        swift = swift[:swift.index("@main struct Run")] + r'''
@main struct Run {
    @MainActor static func main() async throws {
        let service = BackupService()
        await reset()
        let asr = AppServices.shared.asr
        asr.isRunning = true
        let dictation = try asr.acquireExclusiveActivity(.dictation)
        try await service.restore(document("changed-during-dictation", idle: nil))
        let state = await PronunciationDictionaryStore.shared.state()
        expect(SettingsStore.shared.owner == "changed-during-dictation" && state.0 == ["changed-during-dictation"], "historical restore changes settings/profiles during dictation")
        expect(TranscriptionHistoryStore.shared.writes == 1 && NotificationCenter.default.snapshots.count == 1, "historical restore publishes history and restore callbacks while recording")
        expect(asr.activeActivityLease == dictation && asr.isRunning, "the ongoing dictation did not release its lease before the restore")
        print("REPRODUCED: backup changes settings/profiles/history and posts restore callbacks while dictation still owns its recording lease")
    }
}
'''
    elif args.expect_overlap_gap:
        # Historical enum lacks the busy case, so remove the current-only helper.
        start = swift.index("@MainActor func busy(")
        end = swift.index("@MainActor func reset(", start)
        swift = swift[:start] + swift[end:]
        swift = swift.replace("OVERLAP_ACTION", 'try await service.restore(document("B", idle: nil))')
        swift = swift.replace("OVERLAP_ASSERTION", r'''
        expect(snapshot.pronunciationProfiles == ["original"] && snapshot.settings.owner == "B" && snapshot.transcriptionHistory == ["B"], "historical export/import overlap must expose mixed snapshot")
        print("REPRODUCED: old pronunciation + new settings/History from overlapping export/import")
''')
        swift = swift.replace("CURRENT_TESTS", 'print("Historical overlap probe completed")')
    else:
        swift = swift.replace("OVERLAP_ACTION", r'''
        await busy { try await service.restore(document("B", idle: nil)) }
        await busy { _ = try await service.makeBackupDocument() }
        let during = await PronunciationDictionaryStore.shared.state()
        expect(during.2 == 0 && during.1 == 1, "rejected overlap cannot enter profile writer/second snapshot")
        expect(SettingsStore.shared.owner == "original" && TranscriptionHistoryStore.shared.writes == 0 && NotificationCenter.default.snapshots.isEmpty, "rejected import cannot write or notify")
''')
        swift = swift.replace("OVERLAP_ASSERTION", r'''
        expect(snapshot.pronunciationProfiles == [snapshot.settings.owner] && snapshot.transcriptionHistory == [snapshot.settings.owner], "admitted export remains a consistent snapshot")
        try await service.restore(document("B", idle: nil))
        let freshExport = try await service.makeBackupDocument()
        expect(freshExport.pronunciationProfiles == ["B"] && freshExport.settings.owner == "B", "import and export can retry after owner finishes")
''')
        swift = swift.replace("CURRENT_TESTS", r'''
        // Reject complete imports before any profile/settings/history mutation when
        // existing capture, processing, preparation, download or cleanup owns the app.
        for blocker in 0..<21 {
            await reset()
            let asr = AppServices.shared.asr
            switch blocker {
            case 0: _ = try asr.acquireExclusiveActivity(.dictation)
            case 1: _ = try asr.acquireExclusiveActivity(.fileTranscription)
            case 2: _ = try asr.acquireExclusiveActivity(.localAPI)
            case 3: _ = try asr.acquireExclusiveActivity(.meeting)
            case 4: _ = try asr.acquireExclusiveActivity(.modelMaintenance)
            case 5: asr.isRunning = true
            case 6: asr.isStarting = true
            case 7: asr.isStoppingFinalTranscription = true
            case 8: asr.recordingBufferHandoffGate.isRecovering = true
            case 9: asr.isMicrophonePreviewRequested = true
            case 10: asr.isMicrophonePreviewActive = true
            case 11: asr.hasActiveModelDownload = true
            case 12: asr.hasActiveModelPreparation = true
            case 13: asr.deletingModelID = "fixture"
            case 14: asr.providerResetDrain = UUID()
            case 15: asr.isCancellingModelPreparation = true
            case 16: asr.meetingModelResidency.isExclusive = true
            case 17: asr.isAsrReady = false; asr.isLoadingModel = true
            case 18: asr.isCancellingModelDownload = true
            case 19: asr.isTerminating = true
            default: asr.isAsrReady = false; asr.isDownloadingModel = true
            }
            let originalLease = asr.activeActivityLease
            do {
                try await service.restore(document("busy", idle: nil))
                fatalError("Active work must reject the import before any writes")
            } catch ASRActivityError.settingsRestoreUnavailable {
                expect(ASRActivityError.settingsRestoreUnavailable.localizedDescription.contains("import the backup again"), "busy rejection gives an explicit retry")
            }
            let untouched = await PronunciationDictionaryStore.shared.state()
            expect(untouched.2 == 0 && untouched.0 == ["original"], "busy import must not replace profiles")
            expect(SettingsStore.shared.owner == "original" && TranscriptionHistoryStore.shared.history == ["original"] && TranscriptionHistoryStore.shared.writes == 0, "busy import must preserve settings/history")
            expect(NotificationCenter.default.snapshots.isEmpty && asr.activeActivityLease == originalLease, "busy import must not notify or release another activity")
            // No queued automatic import: a fresh explicit retry is required.
            AppServices.shared.asr = ASRService()
            try await service.restore(document("retry", idle: nil))
            expect(SettingsStore.shared.owner == "retry" && AppServices.shared.asr.activeActivityLease == nil, "busy rejection releases backup gate for explicit retry")
        }

        // Reverse overlap: an admitted import has not yet replaced profiles.
        let restoreGate = Gate()
        await reset(restoreGate: restoreGate)
        let firstRestore = Task { try await service.restore(document("A")) }
        await awaitGate(restoreGate)
        let restoringASR = AppServices.shared.asr
        expect(restoringASR.activeExclusiveActivity == .settingsRestore, "import reserves ASR before the profile actor hop")
        for activity: ASRExclusiveActivity in [.dictation, .fileTranscription, .localAPI, .meeting, .modelMaintenance] {
            do {
                _ = try restoringASR.acquireExclusiveActivity(activity)
                fatalError("A new activity must not race into the suspended import")
            } catch ASRActivityError.activityInProgress(let existing) {
                expect(existing == .settingsRestore, "competing activity sees the exact import owner")
            }
        }
        await busy { _ = try await service.makeBackupDocument() }
        await busy { try await service.restore(document("B")) }
        let beforeReplace = await PronunciationDictionaryStore.shared.state()
        expect(beforeReplace.2 == 1 && beforeReplace.1 == 0 && TranscriptionHistoryStore.shared.loads == 0, "reverse overlap is rejected before export load or second profile write")
        await restoreGate.release(); try await firstRestore.value
        expect(restoringASR.activeActivityLease == nil && restoringASR.admissions == 1 && restoringASR.releases == 1, "successful import releases its exact ASR reservation once")
        let nextDictation = try restoringASR.acquireExclusiveActivity(.dictation)
        restoringASR.releaseExclusiveActivity(nextDictation)
        let afterRestore = try await service.makeBackupDocument()
        expect(afterRestore.settings.owner == "A" && afterRestore.pronunciationProfiles == ["A"] && afterRestore.transcriptionHistory == ["A"], "admitted restore publishes one complete document")

        // An unchanged idle preference leaves no await after the UI notification.
        // Observe synchronous reset arming, then queue capture admission before
        // restore returns; it must never observe the old ready-model state.
        await reset()
        let unchangedASR = AppServices.shared.asr
        var queuedCapture: Task<Void, Never>?
        NotificationCenter.default.onPost = {
            expect(unchangedASR.activeExclusiveActivity == .settingsRestore && unchangedASR.providerResetPending, "UI observers run after model retirement is armed while import admission is held")
            queuedCapture = Task { @MainActor in
                expect(!unchangedASR.isAsrReady && unchangedASR.completedResets == 1, "queued capture sees retired ready-model state before admission")
                do {
                    let lease = try unchangedASR.acquireExclusiveActivity(.dictation)
                    unchangedASR.releaseExclusiveActivity(lease)
                } catch { fatalError("Capture should be retryable after the completed fixture reset") }
            }
        }
        try await service.restore(document("unchanged-idle", idle: 30))
        await queuedCapture?.value
        let unchangedIdle = await PrivateAIIntegrationService.idleUnloader.state()
        expect(unchangedIdle.0 == 0 && unchangedASR.recoveryRequests == 1 && unchangedASR.completedResets == 1, "unchanged idle import arms exactly one reset/recovery without a timer hop")
        expect(!unchangedASR.providerResetPending && unchangedASR.activeActivityLease == nil, "queued capture leaves no stale reset or import reservation")

        // Retain ownership through timer replies and notification reentrancy.
        let idleGate = Gate()
        await reset(idleGate: idleGate)
        let idleRestore = Task { try await service.restore(document("A")) }
        await awaitGate(idleGate)
        await busy { _ = try await service.makeBackupDocument() }
        await busy { try await service.restore(document("B", idle: nil)) }
        expect(NotificationCenter.default.snapshots.count == 1 && NotificationCenter.default.snapshots.allSatisfy { $0.1 == [$0.0] }, "synchronous observers see matching settings/history")
        SettingsStore.shared.privateAIIdleUnload = 0
        idleRestore.cancel(); await idleGate.release(); try await idleRestore.value
        let idleState = await PrivateAIIntegrationService.idleUnloader.state()
        expect(idleState.1 == [0], "timer reads latest user preference after cancellation")
        try await service.restore(document("retry", idle: nil))
        expect(SettingsStore.shared.owner == "retry", "cancellation after commit releases busy flag")

        // Cancel a read-only export while actor reply is delayed: no document or write.
        let cancelledGate = Gate()
        await reset(exportGate: cancelledGate)
        let cancelledExport = Task { try await service.makeBackupDocument() }
        await awaitGate(cancelledGate); cancelledExport.cancel(); await cancelledGate.release()
        do { _ = try await cancelledExport.value; fatalError("Expected cancellation") } catch is CancellationError {}
        expect(SettingsStore.shared.owner == "original" && TranscriptionHistoryStore.shared.writes == 0 && NotificationCenter.default.snapshots.isEmpty, "cancelled export has no writes/notifications")
        _ = try await service.makeBackupDocument()
        try await service.restore(document("after-export-cancel", idle: nil))
        expect(SettingsStore.shared.owner == "after-export-cancel", "cancelled export releases gate for both operations")

        // A profile write admitted before cancellation must finish the matching
        // synchronous commit rather than leave new profiles with old settings.
        let cancelledRestoreGate = Gate()
        await reset(restoreGate: cancelledRestoreGate)
        let cancelledRestore = Task { try await service.restore(document("cancelled", idle: nil)) }
        await awaitGate(cancelledRestoreGate); cancelledRestore.cancel(); await cancelledRestoreGate.release()
        try await cancelledRestore.value
        expect(AppServices.shared.asr.activeActivityLease == nil && AppServices.shared.asr.releases == 1, "cancelled admitted import releases its ASR reservation")
        let completed = try await service.makeBackupDocument()
        expect(completed.pronunciationProfiles == ["cancelled"] && completed.settings.owner == "cancelled" && completed.transcriptionHistory == ["cancelled"], "cancellation after profile admission finishes a consistent restore")
        expect(NotificationCenter.default.snapshots.count == 1, "completed cancelled restore notifies exactly once")

        // Cancellation before admission prevents all dependency work and releases gate.
        for isRestore in [false, true] {
            await reset()
            let task = Task { () throws -> Void in
                withUnsafeCurrentTask { $0?.cancel() }
                if isRestore { try await service.restore(document("unstarted")) }
                else { _ = try await service.makeBackupDocument() }
            }
            do { try await task.value; fatalError("Expected early cancellation") } catch is CancellationError {}
            let untouched = await PronunciationDictionaryStore.shared.state()
            expect(untouched.1 == 0 && untouched.2 == 0 && TranscriptionHistoryStore.shared.loads == 0, "pre-cancelled operation never touches dependencies")
            _ = try await service.makeBackupDocument()
            try await service.restore(document("retry", idle: nil))
            expect(SettingsStore.shared.owner == "retry", "early cancellation clears admission flag")
        }
        // Every failure path releases its hold and preserves non-effects.
        await reset()
        await PronunciationDictionaryStore.shared.setup(reject: true)
        do { try await service.restore(document("failed")); fatalError("Expected store failure") } catch ProbeFailure.storage {}
        expect(SettingsStore.shared.owner == "original" && TranscriptionHistoryStore.shared.writes == 0 && NotificationCenter.default.snapshots.isEmpty, "profile failure has no settings/history/notification effects")
        expect(AppServices.shared.asr.activeActivityLease == nil && AppServices.shared.asr.releases == 1, "profile failure releases the exact ASR reservation")
        await PronunciationDictionaryStore.shared.setup()
        _ = try await service.makeBackupDocument()
        try await service.restore(document("retry", idle: nil))
        expect(SettingsStore.shared.owner == "retry", "profile failure clears gate")
        await reset()
        var invalid = document("invalid"); invalid.schemaVersion = .init(major: 99, minor: 0)
        do { try await service.restore(invalid); fatalError("Expected schema failure") } catch BackupServiceError.unsupportedSchemaVersion {}
        let rejected = await PronunciationDictionaryStore.shared.state()
        expect(rejected.2 == 0 && SettingsStore.shared.owner == "original", "schema validation rejects before profile write")
        _ = try await service.makeBackupDocument()
        expect(TranscriptionHistoryStore.shared.loads == 1, "schema failure clears gate")
        await reset(); TranscriptionHistoryStore.shared.loaded = false
        do { _ = try await service.makeBackupDocument(); fatalError("Expected load failure") } catch ProbeFailure.storage {}
        let unloaded = await PronunciationDictionaryStore.shared.state()
        expect(unloaded.1 == 0 && unloaded.2 == 0 && NotificationCenter.default.snapshots.isEmpty, "load failure has no profile or notification effects")
        TranscriptionHistoryStore.shared.loaded = true
        try await service.restore(document("retry", idle: nil))
        expect(SettingsStore.shared.owner == "retry", "load failure clears gate")

        // Export retains admission even before history has loaded; cancellation
        // is checked after the pre-existing non-cancellable load reply returns.
        let loadGate = Gate()
        await reset(); TranscriptionHistoryStore.shared.loadGate = loadGate
        let loading = Task { try await service.makeBackupDocument() }
        await awaitGate(loadGate)
        await busy { try await service.restore(document("blocked")) }
        await busy { _ = try await service.makeBackupDocument() }
        loading.cancel(); await loadGate.release()
        do { _ = try await loading.value; fatalError("Expected load cancellation") } catch is CancellationError {}
        let noSnapshot = await PronunciationDictionaryStore.shared.state()
        expect(noSnapshot.1 == 0, "cancelled history wait exits before pronunciation snapshot")
        _ = try await service.makeBackupDocument()

        for (idle, expectedCalls) in [(nil, 0), (Optional(30), 0), (Optional(60), 1), (Optional(0), 1)] {
            await reset(); try await service.restore(document("field", idle: idle))
            let state = await PrivateAIIntegrationService.idleUnloader.state()
            expect(state.0 == expectedCalls, "only changed present idle values reschedule")
            expect(SettingsStore.shared.privateAIIdleUnload == (idle ?? 30), "legacy absent idle preserves preference")
        }
        await reset()
        var legacy = document("legacy", idle: nil); legacy.pronunciationProfiles = nil
        try await service.restore(legacy)
        let legacyExport = try await service.makeBackupDocument()
        expect(legacyExport.pronunciationProfiles == [] && legacyExport.settings.owner == "legacy", "legacy import clears newer pronunciation profiles")
        expect(SettingsStore.shared.meetingLanguage == "en" && SettingsStore.shared.configurations == ["__default__": "original"], "absent additive settings remain unchanged")
        var modern = document("modern", idle: nil)
        modern.settings.meetingLanguage = "fr"; modern.settings.promptConfigurations = [:]
        try await service.restore(modern)
        expect(SettingsStore.shared.meetingLanguage == "fr" && SettingsStore.shared.configurations.isEmpty, "present empty configuration remains authoritative")
        await reset()
        NotificationCenter.default.onPost = { SettingsStore.shared.privateAIIdleUnload = 0 }
        try await service.restore(document("notice"))
        let notificationSettings = await PrivateAIIntegrationService.idleUnloader.state()
        expect(notificationSettings.1 == [0], "timer respects synchronous observer preference changes")

        // Deliberately document the limit: ordinary dictionary/settings edits do
        // not participate in BackupService admission. This gate cannot serialize them.
        let manualGate = Gate()
        await reset(exportGate: manualGate)
        let manualExport = Task { try await service.makeBackupDocument() }
        await awaitGate(manualGate)
        await PronunciationDictionaryStore.shared.ordinaryEdit(["manual"])
        SettingsStore.shared.owner = "manual"; TranscriptionHistoryStore.shared.history = ["manual"]
        await manualGate.release()
        let manualSnapshot = try await manualExport.value
        expect(manualSnapshot.pronunciationProfiles == ["original"] && manualSnapshot.settings.owner == "manual", "service gate does not falsely serialize ordinary dictionary/settings mutations")
        expect(AppServices.shared.asr.activeActivityLease == nil, "no completed test leaves import admission held")
        print("LIMIT: ordinary dictionary/settings edits remain outside backup-operation admission")
        print("PASS: \(assertions) production-method concurrency assertions")
''')
    build_root = repo / ".build/settings-backup-tests"
    build_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="probe-", dir=build_root) as directory:
        swift_path = Path(directory) / "Probe.swift"
        binary = Path(directory) / "probe"
        swift_path.write_text(swift)
        package_source = (repo / "Sources/Fluid/Branding/BrandPackage.swift").read_text()
        package_path = Path(directory) / "BrandPackageMetadata.swift"
        package_path.write_text(package_source[:package_source.index("nonisolated final class BrandPackageStore:")])
        compile_prefix = ["xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(build_root / "ModuleCache"),
                        str(repo / "Sources/Fluid/Localization/PichiLocalization.swift"),
                        str(repo / "Sources/Fluid/Branding/AppBrand.swift"),
                        str(repo / "Sources/Fluid/Branding/BrandDistribution.swift"),
                        str(repo / "Tests/Support/StandaloneBrandPackageStore.swift"),
                        str(package_path)]
        subprocess.run(compile_prefix + [str(swift_path), "-o", str(binary)],
                       cwd=repo, env=environment, check=True, timeout=60)
        subprocess.run([str(binary)], env=environment, check=True, timeout=20)
        if not args.expect_overlap_gap and not args.expect_active_work_gap:
            credentials_path = Path(directory) / "Credentials.swift"
            credentials_binary = Path(directory) / "credentials"
            credentials_path.write_text(credential_probe(source, settings_source))
            credential_dependencies = [
                "-D", "PICHI_CREDENTIAL_TEST_BACKEND_ONLY",
                str(repo / "Sources/Fluid/Persistence/KeychainService.swift"),
                str(repo / "Sources/Fluid/Account/AccountDomain.swift"),
                str(repo / "Sources/Fluid/Account/PrivateProfileStorage.swift"),
            ]
            subprocess.run(compile_prefix + credential_dependencies + [str(credentials_path), "-o", str(credentials_binary)],
                           cwd=repo, env=environment, check=True, timeout=60)
            subprocess.run([str(credentials_binary)], env=environment, check=True, timeout=20)


if __name__ == "__main__":
    main()

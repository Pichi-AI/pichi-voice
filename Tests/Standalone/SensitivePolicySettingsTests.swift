import Foundation

/// Exercises the production settings extension and profile stores. The runner
/// supplies only the otherwise unrelated SettingsStore shell and identity metadata.
@main
struct SensitivePolicySettingsTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        let passed = try condition()
        precondition(passed, message); checks += 1
    }
    static func cancelled(_ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Stale profile operation was accepted") }
        catch is CancellationError { checks += 1 }
        catch { preconditionFailure("Expected stale-profile cancellation, got \(error)") }
    }
    static func tooMany(_ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Inadmissible effective policy was saved") }
        catch SensitiveDataDictionaryError.tooManyEntries { checks += 1 }
        catch { preconditionFailure("Expected policy-size rejection, got \(error)") }
    }

    @MainActor
    static func main() throws {
        precondition(CommandLine.arguments.count == 2, "A synthetic trained artifact path is required")
        let artifactURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let artifact = try SensitiveTopicClassifierSnapshot.readArtifact(at: artifactURL)
        let original = PrivateProfileStorage.current
        let root = AppBrand.applicationSupportDirectory
        let guestName = AppBrand.storageNamespace + ".synthetic-guest"
        let guestDefaults = UserDefaults(suiteName: guestName)!
        let guest = try PrivateProfileStorage.proposed(context: nil, generation: UUID(), legacyRootDirectory: root)
        func account(_ subject: String) throws -> PrivateProfileSnapshot {
            let identity = AccountIdentity(issuer: "synthetic-issuer", subject: subject, internalUserID: subject)
            let context = AccountContext(identity: identity, organizationID: "synthetic-org", workspaceID: "synthetic-workspace", generation: UUID())
            return try PrivateProfileStorage.proposed(context: context, generation: UUID(), legacyRootDirectory: root)
        }
        let a = try account("a"), b = try account("b")
        let domains = [a, b].map { AppBrand.storageNamespace + ".private-profile." + $0.id }
        let allDomains = domains + [guestName]
        if let path = ProcessInfo.processInfo.environment["PICHI_PRIVATE_SETTINGS_DOMAIN_MANIFEST"] {
            try JSONEncoder().encode(allDomains).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        defer {
            for name in allDomains {
                let defaults = UserDefaults(suiteName: name)!
                defaults.removePersistentDomain(forName: name)
                precondition(defaults.synchronize(), "Synthetic settings cleanup did not persist")
            }
            PrivateProfileStorage.select(original)
            try? FileManager.default.removeItem(at: root)
        }
        func saved(_ domain: String) -> NSDictionary {
            (UserDefaults(suiteName: domain)!.persistentDomain(forName: domain) ?? [:]) as NSDictionary
        }

        PrivateProfileStorage.select(a)
        let retargetable = SettingsStore(defaults: PrivateProfileDefaults(guestDefaults: guestDefaults))
        let admittedA = retargetable.boundToCurrentPrivateProfile()
        try expect(try admittedA.sensitiveDataDictionarySnapshot().isEmpty, "Empty settings enabled a semantic policy")
        // A pre-release imported model cannot override the built-in distribution policy.
        admittedA.defaults.set(Data("obsolete-untrusted-model".utf8), forKey: "SensitiveTopicClassifierConfiguration")
        try expect(try admittedA.sensitiveDataDictionarySnapshot().isEmpty, "Legacy model settings enabled an unselected topic")
        try admittedA.setSensitiveBusinessGroup(id: "illicit-remuneration", enabled: true)
        let frozen = try admittedA.sensitiveDataDictionarySnapshot()
        expect(frozen.selectedTopicIDs == ["illicit-remuneration"], "Selected group did not automatically admit its topic")
        let indirect = "Победителя уже выбрали, а остальные заявки нужны только для вида."
        try admittedA.setSensitiveBusinessGroup(id: "illicit-remuneration", enabled: false)
        let changed = try admittedA.sensitiveDataDictionarySnapshot()
        expect(frozen.fingerprint != changed.fingerprint && frozen.selectedTopicIDs == ["illicit-remuneration"],
               "Settings mutation changed an admitted snapshot or reused its identity")
        expect(changed.isEmpty, "Disabling the last group kept semantic masking active")
        _ = try admittedA.addSensitiveDataDictionaryPhrase("взятке")
        try expect(try admittedA.sensitiveDataDictionarySnapshot().selectedTopicIDs == ["illicit-remuneration"],
               "A declined dictionary seed did not activate its topic")
        try admittedA.replaceSensitiveDataDictionaryEntries([.init(phrase: "откат")])
        try expect(try admittedA.sensitiveDataDictionarySnapshot().selectedTopicIDs == ["illicit-remuneration"],
               "A whole dictionary seed did not activate its topic")
        try admittedA.replaceSensitiveDataDictionaryEntries([.init(phrase: "ТЗ"), .init(phrase: "компания"), .init(phrase: "интерес")])
        try expect(try admittedA.sensitiveDataDictionarySnapshot().selectedTopicIDs.isEmpty,
               "An ambiguous word or partial group expression activated semantic masking")
        try admittedA.replaceSensitiveDataDictionaryEntries([.init(phrase: "взятке", matchMode: .exact)])
        try expect(try admittedA.sensitiveDataDictionarySnapshot().selectedTopicIDs.isEmpty,
               "An exact-only declined spelling matched a different dictionary seed")
        try admittedA.replaceSensitiveDataDictionaryEntries([.init(phrase: "синтетическая тайна")])
        try admittedA.setSensitiveBusinessGroup(id: "procurement-collusion", enabled: true)
        let procurement = try admittedA.sensitiveDataDictionarySnapshot()
        expect(procurement.selectedTopicIDs == ["procurement-collusion"], "Group selected the wrong topic")
        try expect(try procurement.spans(in: indirect).contains { $0.range == NSRange(location: 0, length: indirect.utf16.count) },
               "Built-in classifier did not hide an indirect complete sentence")
        let expected = try SensitiveTopicClassifierSnapshot(data: artifact,
            expectedSHA256: SensitiveTopicClassifierSnapshot.bundledArtifactSHA256, selectedTopicIDs: ["procurement-collusion"])
        try expect(try expected.detect(in: indirect, complete: true).spans.count == 1, "Bundled v2 decisions changed")
        let emptyBundleRoot = root.appendingPathComponent("Empty.bundle")
        try FileManager.default.createDirectory(at: emptyBundleRoot, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "synthetic.empty"], format: .xml, options: 0)
            .write(to: emptyBundleRoot.appendingPathComponent("Info.plist"))
        let emptyBundle = Bundle(path: emptyBundleRoot.path)!
        do {
            _ = try SensitiveTopicClassifierSnapshot.bundled(selectedTopicIDs: ["illicit-remuneration"], in: emptyBundle)
            preconditionFailure("Missing built-in model silently disabled protection")
        } catch SensitiveTopicClassifierError.invalidArtifact { checks += 1 }
        let corruptBundleRoot = root.appendingPathComponent("Corrupt.bundle")
        try FileManager.default.copyItem(at: emptyBundleRoot, to: corruptBundleRoot)
        try Data("tampered-model".utf8).write(to: corruptBundleRoot.appendingPathComponent("sensitive-topics-v2.json"))
        let corruptBundle = Bundle(path: corruptBundleRoot.path)!
        do {
            _ = try SensitiveTopicClassifierSnapshot.bundled(selectedTopicIDs: ["illicit-remuneration"], in: corruptBundle)
            preconditionFailure("Corrupt built-in model silently disabled protection")
        } catch SensitiveTopicClassifierError.checksumMismatch { checks += 1 }
        let savedA = saved(domains[0])

        PrivateProfileStorage.select(b)
        let currentB = SettingsStore(defaults: PrivateProfileDefaults(guestDefaults: guestDefaults))
        try currentB.setSensitiveBusinessGroup(id: "personal-health", enabled: true)
        let savedB = saved(domains[1])
        // These calls model a file picker or draft completion admitted in A and
        // delivered after B becomes current. The bound owner must not retarget.
        cancelled { try admittedA.replaceSensitiveBusinessGroupTerms(id: "illicit-remuneration", terms: ["чужая фраза"]) }
        cancelled { try admittedA.replaceSensitiveDataDictionaryEntries([.init(phrase: "чужой словарь")]) }
        cancelled { try admittedA.setSensitiveBusinessGroup(id: "illicit-remuneration", enabled: false) }
        expect(savedB.isEqual(saved(domains[1])), "Late A completion changed B settings")
        expect(savedA.isEqual(saved(domains[0])), "Rejected late completion changed A settings")
        try expect(try currentB.sensitiveDataDictionarySnapshot().selectedTopicIDs.isEmpty,
               "A semantic topic from A became enabled in B")
        expect(guestDefaults.data(forKey: "SensitiveTopicClassifierConfiguration") == nil,
               "Account settings reached guest defaults")
        PrivateProfileStorage.select(guest)
        cancelled { try admittedA.setSensitiveBusinessGroup(id: "commercial-metrics", enabled: true) }
        expect(savedA.isEqual(saved(domains[0])) && savedB.isEqual(saved(domains[1])),
               "Switching to guest changed a saved account")

        PrivateProfileStorage.select(a)
        for group in SensitiveBusinessGroupCatalog.groups {
            try admittedA.setSensitiveBusinessGroup(id: group.id, enabled: true)
        }
        let defaultTermCount = SensitiveBusinessGroupCatalog.groups.flatMap(\.terms).count
        expect(defaultTermCount <= SensitiveBusinessGroupCatalog.maximumCatalogTerms, "Default catalog exceeds the active group budget")
        let firstGroupCount = SensitiveBusinessGroupCatalog.group(id: "illicit-remuneration")!.terms.count
        let overflowingCount = SensitiveBusinessGroupCatalog.maximumCatalogTerms - (defaultTermCount - firstGroupCount) + 1
        let beforeOverflow = saved(domains[0])
        tooMany {
            try admittedA.replaceSensitiveBusinessGroupTerms(id: "illicit-remuneration",
                terms: (0..<overflowingCount).map { "синтетика\($0)" })
        }
        expect(beforeOverflow.isEqual(saved(domains[0])), "Rejected edit changed persisted policy")
        _ = try admittedA.sensitiveDataDictionarySnapshot()

        for group in SensitiveBusinessGroupCatalog.groups where !["illicit-remuneration", "procurement-collusion"].contains(group.id) {
            try admittedA.setSensitiveBusinessGroup(id: group.id, enabled: false)
        }
        try admittedA.replaceSensitiveBusinessGroupTerms(id: "illicit-remuneration", terms: [])
        try admittedA.replaceSensitiveBusinessGroupTerms(id: "procurement-collusion", terms: (0..<120).map { "пример\($0)" })
        let beforeReset = saved(domains[0])
        tooMany { try admittedA.resetSensitiveBusinessGroupTerms(id: "illicit-remuneration") }
        expect(beforeReset.isEqual(saved(domains[0])), "Rejected reset changed persisted policy")
        expect(admittedA.sensitiveBusinessGroupTerms(id: "illicit-remuneration").isEmpty,
               "Rejected reset restored default terms")
        _ = try admittedA.sensitiveDataDictionarySnapshot()
        print("Sensitive policy settings: \(checks) checks passed; built-in v2, automatic topic selection, stale drafts, group limits and frozen identities")
    }
}

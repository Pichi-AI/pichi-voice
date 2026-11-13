import Foundation
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class GigaAMDictionaryCacheIdentityXCTests: XCTestCase {
    private func withProfile(_ body: (URL, PrivateProfileSnapshot) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gigaam-cache-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let prior = PrivateProfileStorage.current
        let profile = try PrivateProfileStorage.proposed(context: nil, generation: UUID(), legacyRootDirectory: root)
        PrivateProfileStorage.select(profile)
        defer {
            PrivateProfileStorage.select(prior)
            try? FileManager.default.removeItem(at: root)
        }
        try body(root, profile)
    }

    private func key(_ read: DictionaryNegativeExampleStore.CaptureRead) -> String {
        GigaAMDictionaryAcoustics.referenceCacheKey(.init(modelKey: "test-model", generation: "settings-v1",
            enabled: true, entries: [], pronunciation: nil, negatives: read), stableNegativeEvidence: true)
    }

    func testUnchangedNegativeEvidenceKeepsCacheIdentityAcrossAdmissions() throws {
        try self.withProfile { root, profile in
            let store = DictionaryNegativeExampleStore(url: root.appendingPathComponent("negative.plist"), profile: profile)
            let firstLease = UUID(), secondLease = UUID()
            let first = try store.admitCaptureRead(leaseID: firstLease, modelKey: "test-model", entryIDs: [])
            defer { first.close(leaseID: firstLease) }
            let second = try store.admitCaptureRead(leaseID: secondLease, modelKey: "test-model", entryIDs: [])
            defer { second.close(leaseID: secondLease) }
            XCTAssertNotEqual(first.revision, second.revision, "Read authority still belongs to a distinct admission")
            XCTAssertEqual(first.contentFingerprint, second.contentFingerprint)
            XCTAssertEqual(self.key(first), self.key(second), "Starting another dictation must not recalibrate unchanged pronunciation references")
            let firstLegacy = GigaAMDictionaryAcoustics.referenceCacheKey(.init(modelKey: "test-model", generation: "settings-v1",
                enabled: true, entries: [], pronunciation: nil, negatives: first))
            let secondLegacy = GigaAMDictionaryAcoustics.referenceCacheKey(.init(modelKey: "test-model", generation: "settings-v1",
                enabled: true, entries: [], pronunciation: nil, negatives: second))
            XCTAssertNotEqual(firstLegacy, secondLegacy, "Legacy file-error retry must retain its per-admission identity")
        }
    }

    func testRelevantEvidenceChangesInvalidateThePreparedReferenceCache() throws {
        try self.withProfile { root, profile in
            let file = root.appendingPathComponent("negative.plist")
            let store = DictionaryNegativeExampleStore(url: file, profile: profile)
            let entry = UUID(), example = UUID(), firstLease = UUID(), secondLease = UUID()
            func save(_ values: [Float]) throws {
                let rows = [DictionaryNegativeExampleStore.Example(id: example, entryID: entry,
                    profileKey: "fixture-profile", modelKey: "test-model", frames: .init(hiddenSize: 2, values: values))]
                try PropertyListEncoder().encode(rows).write(to: file)
            }
            try save([1, 0, 0, 1])
            let first = try store.admitCaptureRead(leaseID: firstLease, modelKey: "test-model", entryIDs: [entry])
            defer { first.close(leaseID: firstLease) }
            try save([0, 1, 0, 1])
            let second = try store.admitCaptureRead(leaseID: secondLease, modelKey: "test-model", entryIDs: [entry])
            defer { second.close(leaseID: secondLease) }
            XCTAssertNotEqual(first.contentFingerprint, second.contentFingerprint)
            XCTAssertNotEqual(self.key(first), self.key(second))
        }
    }

    func testUnselectedEvidenceDoesNotInvalidateTheAdmittedSubset() throws {
        try self.withProfile { root, profile in
            let file = root.appendingPathComponent("negative.plist")
            let store = DictionaryNegativeExampleStore(url: file, profile: profile)
            let selected = UUID(), other = UUID(), firstLease = UUID(), secondLease = UUID()
            let row = DictionaryNegativeExampleStore.Example(id: UUID(), entryID: other,
                profileKey: "fixture-profile", modelKey: "test-model", frames: .init(hiddenSize: 2, values: [1, 0]))
            let first = try store.admitCaptureRead(leaseID: firstLease, modelKey: "test-model", entryIDs: [selected])
            defer { first.close(leaseID: firstLease) }
            try PropertyListEncoder().encode([row]).write(to: file)
            let second = try store.admitCaptureRead(leaseID: secondLease, modelKey: "test-model", entryIDs: [selected])
            defer { second.close(leaseID: secondLease) }
            XCTAssertEqual(self.key(first), self.key(second))
        }
    }

    func testProfileGenerationCannotReuseAnOlderProfilesEvidenceIdentity() throws {
        try self.withProfile { root, profile in
            let file = root.appendingPathComponent("negative.plist"), lease = UUID()
            let firstStore = DictionaryNegativeExampleStore(url: file, profile: profile)
            let first = try firstStore.admitCaptureRead(leaseID: lease, modelKey: "test-model", entryIDs: [])
            defer { first.close(leaseID: lease) }
            let next = try PrivateProfileStorage.proposed(context: nil, generation: UUID(), legacyRootDirectory: root)
            PrivateProfileStorage.select(next)
            let secondStore = DictionaryNegativeExampleStore(url: file, profile: next)
            let second = try secondStore.admitCaptureRead(leaseID: lease, modelKey: "test-model", entryIDs: [])
            defer { second.close(leaseID: lease) }
            XCTAssertNotEqual(self.key(first), self.key(second))
        }
    }

    func testSharedTokenPatternsKeepCamelCaseAcronymsUnicodeAndApostrophes() {
        XCTAssertEqual(GigaAMDictionaryLexicalEvidence.componentKeys("PichiVoice"), ["pichi", "voice"])
        XCTAssertEqual(GigaAMDictionaryLexicalEvidence.componentKeys("XMLParser"), ["xml", "parser"])
        XCTAssertEqual(GigaAMDictionaryLexicalEvidence.componentKeys("Model2Beta"), ["model2", "beta"])
        XCTAssertEqual(GigaAMDictionaryLexicalEvidence.componentKeys("O'Connor"),
                       GigaAMDictionaryLexicalEvidence.componentKeys("O’Connor"))
        XCTAssertEqual(GigaAMDictionaryLexicalEvidence.componentKeys("Ёжик"),
                       GigaAMDictionaryLexicalEvidence.componentKeys("Ежик"))
        XCTAssertNil(GigaAMDictionaryLexicalEvidence.componentKeys("One\nTwo"))
        XCTAssertNil(GigaAMDictionaryLexicalEvidence.componentKeys(String(repeating: "а", count: 81)))
    }

    func testSharedTokenPatternsRemainDeterministicAcrossConcurrentMatchingRequests() async {
        let inputs = ["PichiVoice", "XMLParser", "Model2Beta", "Ёжик", "O’Connor"]
        let expected = inputs.map { GigaAMDictionaryLexicalEvidence.componentKeys($0) }
        await withTaskGroup(of: (Int, [String]?).self) { group in
            for index in 0..<100 {
                let slot = index % inputs.count, input = inputs[index % inputs.count]
                group.addTask { (slot, GigaAMDictionaryLexicalEvidence.componentKeys(input)) }
            }
            for await (index, actual) in group { XCTAssertEqual(actual, expected[index]) }
        }
    }
}

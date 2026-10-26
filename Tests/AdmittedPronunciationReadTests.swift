import CryptoKit
import Foundation
import Darwin

@main @MainActor struct AdmittedPronunciationReadTests {
    static var checks = 0
    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        precondition(condition, message)
    }

    nonisolated static func wait(_ semaphore: DispatchSemaphore, seconds: Double) -> Bool {
        semaphore.wait(timeout: .now() + seconds) == .success
    }

    static func descriptorCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    }

    static func rejects(_ message: String, _ body: () throws -> Void) {
        do { try body(); preconditionFailure(message) }
        catch { checks += 1 }
    }

    struct Original: Encodable {
        let version = 1
        let sampleRate = 16_000
        let encoding = "float32-little-endian"
        let entryID: UUID
        let intendedText = "synthetic"
        let evidenceID: UUID
        let recordingID = UUID()
        let modelKey = "synthetic"
        let observedText = "synthetic"
        let sourceSampleRange = 0..<3
        let focalSampleRange = 1..<3
        let sourceWordRange = 0..<1
        let pcmFloat32: Data
    }

    static func main() async throws {
        let initial = PrivateProfileStorage.current
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-pronunciation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            PrivateProfileStorage.select(initial)
            try? FileManager.default.removeItem(at: root)
        }
        func account(_ subject: String, generation: UUID = UUID()) throws -> PrivateProfileSnapshot {
            let context = AccountContext(identity: .init(issuer: "https://synthetic.invalid", subject: subject,
                internalUserID: subject), organizationID: nil, workspaceID: nil, generation: generation)
            return try PrivateProfileStorage.proposed(context: context, generation: generation, legacyRootDirectory: root)
        }
        let guestURL = root.appendingPathComponent("pronunciation-dictionary-v1.json")
        let guestBytes = Data("synthetic preserved guest data".utf8)
        try guestBytes.write(to: guestURL)
        let a = try account("A"), b = try account("B")
        PrivateProfileStorage.select(a)
        let file = a.rootDirectory.appendingPathComponent("pronunciation-dictionary-v1.json")
        let store = PronunciationDictionaryStore(fileURL: file, profile: a)
        let negativeURL = a.rootDirectory.appendingPathComponent("dictionary-negative-examples-v1.plist")
        let negativeStore = DictionaryNegativeExampleStore(url: negativeURL, profile: a, collectionEnabled: { true })
        let entry = UUID(), originalEntry = UUID(), evidence = UUID()
        let ids = (0..<4).map { _ in UUID() }
        let inspection = DictionaryAudioInspection(samples: [Float](repeating: 0.25, count: 1280),
            recordedSampleCount: 1280,
            frames: [.init(offset: 0, frameDuration: 0.08, hiddenSize: 2, values: [1, 0])],
            words: [], selectedStart: 0, selectedEnd: 0.08)
        let captures = ids.map { id in
            PronunciationEnrollmentCapture(values: [1, 0], sourceFrameCount: 1, modelKey: "synthetic", inspectionID: id)
        }
        let originalCapture = PronunciationEnrollmentCapture(values: [1, 0], sourceFrameCount: 1,
            modelKey: "synthetic", originalAudioID: evidence)
        let profiles = [PronunciationDictionaryProfile(dictionaryEntryID: entry, label: "A private", modelKey: "synthetic",
            hiddenSize: 2, enrollments: captures),
            PronunciationDictionaryProfile(dictionaryEntryID: originalEntry, label: "A original", modelKey: "synthetic",
            hiddenSize: 2, enrollments: [originalCapture])]
        try await store.replaceAllProfiles(profiles)
        let inspectionDirectory = a.rootDirectory.appendingPathComponent("pronunciation-inspection")
        try FileManager.default.createDirectory(at: inspectionDirectory, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        for id in ids { try encoder.encode(inspection).write(to: inspectionDirectory.appendingPathComponent("\(id).plist")) }
        let audioDirectory = a.rootDirectory.appendingPathComponent("pronunciation-audio")
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let audioURL = audioDirectory.appendingPathComponent("\(evidence).json")
        let samples: [Float] = [0.1, 0.2, 0.3]
        let original = Original(entryID: originalEntry, evidenceID: evidence, pcmFloat32: samples.withUnsafeBytes { Data($0) })
        try JSONEncoder().encode(original).write(to: audioURL, options: .atomic)
        let negativeFrames = DictionaryMatchFrames(hiddenSize: 2, values: [1, 0, 1, 0])
        for _ in 0..<32 {
            let correction = DictionaryNegativeCorrection(evidence: .init(id: UUID(), entryID: UUID(), label: "synthetic",
                profileKey: "other", modelKey: "other", sourceWordRange: 0..<1, frames: negativeFrames),
                correctedText: "synthetic", expiresAt: Date().addingTimeInterval(60))
            try await negativeStore.save(correction, expectedRevision: negativeStore.revision())
        }
        let correction = DictionaryNegativeCorrection(evidence: .init(id: UUID(), entryID: entry, label: "synthetic",
            profileKey: "selected", modelKey: "synthetic", sourceWordRange: 0..<1, frames: negativeFrames),
            correctedText: "synthetic", expiresAt: Date().addingTimeInterval(60))
        try await negativeStore.save(correction, expectedRevision: negativeStore.revision())
        let familyURL = a.rootDirectory.appendingPathComponent("synthetic-family-profiles.json")
        let familyStore = PronunciationDictionaryStore(fileURL: familyURL, profile: a)
        let familyEntry = UUID(), unselectedEntry = UUID()
        func familyProfile(entryID: UUID, key: String, width: Int) -> PronunciationDictionaryProfile {
            .init(dictionaryEntryID: entryID, label: "Synthetic family", modelKey: key, hiddenSize: width,
                enrollments: (0..<3).map { _ in .init(values: Array(repeating: 0.5, count: width), sourceFrameCount: 1, modelKey: key) })
        }
        let sharedFamily = familyProfile(entryID: familyEntry, key: "synthetic-family-a", width: 2)
        let exactDifferentWidth = familyProfile(entryID: familyEntry, key: "synthetic-family-b", width: 3)
        let unrelatedFamily = familyProfile(entryID: unselectedEntry, key: "synthetic-family-a", width: 2)
        let otherModel = familyProfile(entryID: familyEntry, key: "synthetic-other", width: 2)
        try await familyStore.replaceAllProfiles([sharedFamily, exactDifferentWidth, unrelatedFamily, otherModel])
        let familyBytes = try Data(contentsOf: familyURL)
        let familyLease = UUID()
        let exactRead = try familyStore.admitCaptureRead(leaseID: familyLease, modelKey: "synthetic-family-b", entryIDs: [familyEntry])
        expect(exactRead.profiles == [exactDifferentWidth], "Existing exact-model admission remains the default")
        exactRead.close(leaseID: familyLease)
        let familyRead = try familyStore.admitCaptureRead(leaseID: familyLease, modelKey: "synthetic-family-b", entryIDs: [familyEntry], includingSharedFamilies: true)
        expect(familyRead.profiles == [sharedFamily, exactDifferentWidth], "Shared admission pins only selected entry and compatible family candidates")
        expect(PronunciationDictionaryStore.selectSharedProfiles(familyRead.profiles, modelKey: "synthetic-family-b", hiddenSize: 2) == [sharedFamily], "Loaded shape can select a compatible fallback after exact-model shape mismatch")
        expect(PronunciationDictionaryStore.selectSharedProfiles(familyRead.profiles, modelKey: "synthetic-family-b", hiddenSize: 3) == [exactDifferentWidth], "Exact model remains preferred when compatible")
        expect(PronunciationDictionaryStore.selectSharedProfiles(familyRead.profiles, modelKey: "synthetic-family-b", hiddenSize: 4).isEmpty, "Incompatible encoder shape cannot activate retained vectors")
        expect(await familyStore.sharedProfiles(modelKey: "synthetic-family-b", hiddenSize: 2).contains(sharedFamily), "Ordinary shared profile selection works while visible")
        defer { familyRead.close(leaseID: familyLease) }
        let handlesBefore = try descriptorCount()
        let leaseID = UUID()
        let read = try store.admitCaptureRead(leaseID: leaseID, modelKey: "synthetic", entryIDs: [entry, originalEntry])
        let negatives = try negativeStore.admitCaptureRead(leaseID: leaseID, modelKey: "synthetic", entryIDs: [entry])
        defer { read.close(leaseID: leaseID); negatives.close(leaseID: leaseID) }
        expect(try descriptorCount() == handlesBefore + 4, "Admission retains only three inspection and one original descriptor globally")
        expect(read.profile == a && read.profiles == profiles, "Admission freezes original metadata and generation")
        expect(try read.inspection(for: ids[0]) == inspection, "Selected evidence decodes through the retained descriptor")
        rejects("Fourth reference must not be pinned") { _ = try read.inspection(for: ids[3]) }
        rejects("Unselected entry has no original authority") { _ = try read.originalAudioSamples(for: originalCapture, entryID: UUID()) }
        expect(try read.originalAudioSamples(for: originalCapture, entryID: originalEntry) == [0.2, 0.3], "Original focal extraction keeps existing validation")
        expect(negatives.frames(entryID: entry, profileKey: "selected", modelKey: "synthetic") == [negativeFrames], "Only selected negative records are frozen")
        expect(negatives.frames(entryID: entry, profileKey: "other", modelKey: "synthetic").isEmpty, "Negative metadata keys remain exact")
        let negativeRevision = negatives.revision
        let preserved = try Data(contentsOf: file)
        let preservedNegative = try Data(contentsOf: negativeURL)
        let replacement = DictionaryAudioInspection(samples: [Float](repeating: 0.5, count: 1280),
            recordedSampleCount: 1280, frames: inspection.frames, words: [], selectedStart: 0, selectedEnd: 0.08)
        try encoder.encode(replacement).write(to: inspectionDirectory.appendingPathComponent("\(ids[0]).plist"), options: .atomic)
        expect(try read.inspection(for: ids[0]) == inspection, "Atomic path replacement cannot substitute the pinned reference")
        PrivateProfileStorage.closeAdmission()
        rejects("Closed admission must reject another pronunciation lease") {
            _ = try store.admitCaptureRead(leaseID: UUID(), modelKey: "synthetic", entryIDs: [entry])
        }
        rejects("Closed admission must reject another negative lease") {
            _ = try negativeStore.admitCaptureRead(leaseID: UUID(), modelKey: "synthetic", entryIDs: [entry])
        }
        PrivateProfileStorage.conceal(generation: UUID())
        await store.prepareForProfileTransition()
        await negativeStore.prepareForProfileTransition()
        expect(await store.allProfiles().isEmpty, "Ordinary pronunciation reads remain concealed")
        expect(await familyStore.sharedProfiles(modelKey: "synthetic-family-b", hiddenSize: 2).isEmpty, "New shared-profile reads obey concealed profile boundary")
        expect(await negativeStore.frames(entryID: entry, profileKey: "selected", modelKey: "synthetic").isEmpty, "Ordinary negative reads remain concealed")
        expect(try read.inspection(for: ids[0]) == inspection, "Admitted original reference survives conceal and store retirement")
        expect(negatives.revision == negativeRevision && negatives.frames(entryID: entry, profileKey: "selected", modelKey: "synthetic") == [negativeFrames], "Admitted negative comparison remains immutable")
        PrivateProfileStorage.select(b)
        expect(await familyStore.sharedProfiles(modelKey: "synthetic-family-b", hiddenSize: 2).isEmpty, "B cannot query A through new shared-profile API")
        expect(familyRead.profiles == [sharedFamily, exactDifferentWidth], "A family candidates remain immutable under admitted lease after B selection")
        rejects("Old A cannot open a shared family read while B is selected") { _ = try familyStore.admitCaptureRead(leaseID: UUID(), modelKey: "synthetic-family-b", entryIDs: [familyEntry], includingSharedFamilies: true) }
        familyRead.close(leaseID: familyLease)
        let familyBytesAfterClose = try Data(contentsOf: familyURL)
        expect(familyRead.profiles.isEmpty && familyBytesAfterClose == familyBytes, "Family read close removes metadata without changing original bytes")
        expect(try read.originalAudioSamples(for: originalCapture, entryID: originalEntry) == [0.2, 0.3], "Account B cannot redirect admitted A reads")
        rejects("Old A store must not admit against B") { _ = try store.admitCaptureRead(leaseID: UUID(), modelKey: "synthetic", entryIDs: [entry]) }
        read.close(leaseID: UUID()); negatives.close(leaseID: UUID())
        expect(try read.inspection(for: ids[0]) == inspection, "Foreign lease cannot close the active read")
        expect(!negatives.frames(entryID: entry, profileKey: "selected", modelKey: "synthetic").isEmpty, "Foreign lease cannot close negative snapshot")
        read.close(leaseID: leaseID); negatives.close(leaseID: leaseID)
        expect(try descriptorCount() == handlesBefore, "Exact close releases every retained process descriptor")
        expect(read.profiles.isEmpty, "Exact close removes private metadata")
        rejects("Exact close releases reference authority") { _ = try read.inspection(for: ids[0]) }
        rejects("Exact close releases original authority") { _ = try read.originalAudioSamples(for: originalCapture, entryID: originalEntry) }
        expect(negatives.frames(entryID: entry, profileKey: "selected", modelKey: "synthetic").isEmpty, "Exact close removes negative evidence")
        expect(try Data(contentsOf: file) == preserved && Data(contentsOf: negativeURL) == preservedNegative, "Admission, conceal and close preserve original data")
        let sameAccountNewGeneration = try account("A")
        PrivateProfileStorage.select(sameAccountNewGeneration)
        rejects("Same account with a new generation cannot reuse old admission") { _ = try store.admitCaptureRead(leaseID: UUID(), modelKey: "synthetic", entryIDs: [entry]) }
        // Bounded failures reject the whole snapshot rather than silently omitting selected data.
        let failedReference = try FileHandle(forWritingTo: inspectionDirectory.appendingPathComponent("\(ids[1]).plist"))
        try failedReference.truncate(atOffset: 24_000_001); try failedReference.close()
        let partial = PronunciationDictionaryStore(fileURL: file, profile: sameAccountNewGeneration)
        let beforeFailure = try descriptorCount()
        rejects("Oversized second reference must reject the whole admission") {
            _ = try partial.admitCaptureRead(leaseID: UUID(), modelKey: "synthetic", entryIDs: [entry])
        }
        expect(try descriptorCount() == beforeFailure, "Partial admission closes both earlier reference and metadata descriptors")
        let largeURL = a.rootDirectory.appendingPathComponent("synthetic-large-metadata.json")
        let large = PronunciationDictionaryStore(fileURL: largeURL, profile: sameAccountNewGeneration)
        let tooMany = (0..<129).map { _ in PronunciationDictionaryProfile(dictionaryEntryID: UUID(),
            label: "synthetic", modelKey: "synthetic", hiddenSize: 2, enrollments: [originalCapture]) }
        try await large.replaceAllProfiles(tooMany)
        rejects("Too many selected profiles must reject admission") {
            _ = try large.admitCaptureRead(leaseID: UUID(), modelKey: "synthetic", entryIDs: Set(tooMany.map(\.dictionaryEntryID)))
        }
        let oversized = try FileHandle(forWritingTo: largeURL)
        try oversized.truncate(atOffset: 16_000_001); try oversized.close()
        rejects("Oversized metadata must reject admission before decoding") {
            _ = try large.admitCaptureRead(leaseID: UUID(), modelKey: "synthetic", entryIDs: [])
        }
        let negativeBank = (0..<33).map { _ in DictionaryNegativeExampleStore.Example(id: UUID(), entryID: entry,
            profileKey: "selected", modelKey: "synthetic", frames: negativeFrames) }
        try encoder.encode(negativeBank).write(to: negativeURL, options: .atomic)
        let freshNegatives = DictionaryNegativeExampleStore(url: negativeURL, profile: sameAccountNewGeneration)
        rejects("Oversized negative bank must reject admission") {
            _ = try freshNegatives.admitCaptureRead(leaseID: UUID(), modelKey: "synthetic", entryIDs: [entry])
        }
        let bInspection = b.rootDirectory.appendingPathComponent("pronunciation-inspection")
        try FileManager.default.createDirectory(at: bInspection, withIntermediateDirectories: true)
        try encoder.encode(replacement).write(to: bInspection.appendingPathComponent("\(ids[0]).plist"))
        let savedInspections = a.rootDirectory.appendingPathComponent("synthetic-saved-inspections")
        try FileManager.default.moveItem(at: inspectionDirectory, to: savedInspections)
        try FileManager.default.createSymbolicLink(at: inspectionDirectory, withDestinationURL: bInspection)
        let beforeSymlinkFailure = try descriptorCount()
        rejects("An intermediate evidence directory cannot redirect A admission to B") {
            _ = try partial.admitCaptureRead(leaseID: UUID(), modelKey: "synthetic", entryIDs: [entry])
        }
        expect(try descriptorCount() == beforeSymlinkFailure, "Intermediate symlink failure closes all directory and metadata descriptors")
        try FileManager.default.removeItem(at: inspectionDirectory)
        try FileManager.default.moveItem(at: savedInspections, to: inspectionDirectory)
        let savedProfile = a.rootDirectory.appendingPathExtension("synthetic-preserved")
        try FileManager.default.moveItem(at: a.rootDirectory, to: savedProfile)
        try FileManager.default.createSymbolicLink(at: a.rootDirectory, withDestinationURL: b.rootDirectory)
        rejects("A symlinked profile root cannot redirect A metadata admission to B") {
            _ = try partial.admitCaptureRead(leaseID: UUID(), modelKey: "synthetic", entryIDs: [entry])
        }
        rejects("A symlinked profile root cannot redirect negative admission") {
            _ = try freshNegatives.admitCaptureRead(leaseID: UUID(), modelKey: "synthetic", entryIDs: [entry])
        }
        expect(try descriptorCount() == beforeSymlinkFailure, "Profile symlink failures release their directory descriptors")
        try FileManager.default.removeItem(at: a.rootDirectory)
        try FileManager.default.moveItem(at: savedProfile, to: a.rootDirectory)
        let rawURL = root.appendingPathComponent("synthetic-joined-read")
        try Data("synthetic".utf8).write(to: rawURL)
        let heldFile = try DictionaryCaptureEvidenceFile(url: rawURL, maximumBytes: 32)!
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let closing = DispatchSemaphore(value: 0), closed = DispatchSemaphore(value: 0)
        let reading = Task.detached { try heldFile.read { data in
            entered.signal()
            guard release.wait(timeout: .now() + 5) == .success else { throw CancellationError() }
            return data
        } }
        expect(await Task.detached { Self.wait(entered, seconds: 5) }.value,
            "Synthetic read entered its bounded decode section")
        let cleanup = Task.detached { closing.signal(); heldFile.close(); closed.signal() }
        expect(await Task.detached { Self.wait(closing, seconds: 5) }.value,
            "Synthetic cleanup started")
        expect(!Self.wait(closed, seconds: 0.02), "Close must join an active read/decode")
        reading.cancel(); release.signal()
        do { _ = try await reading.value; preconditionFailure("Cancelled read must not publish decoded bytes") }
        catch is CancellationError { checks += 1 }
        await cleanup.value
        expect(Self.wait(closed, seconds: 1), "Joined cleanup releases its exact descriptor")
        rejects("Closed evidence cannot be read again") { _ = try heldFile.read { $0 } }
        let symlink = root.appendingPathComponent("synthetic-symlink")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: rawURL)
        rejects("Evidence admission must not follow a replaced symlink") {
            _ = try DictionaryCaptureEvidenceFile(url: symlink, maximumBytes: 32)
        }
        let fifo = root.appendingPathComponent("synthetic-fifo")
        expect(mkfifo(fifo.path, 0o600) == 0, "Synthetic FIFO created without any audio or device input")
        rejects("Evidence admission must reject a FIFO without blocking") {
            _ = try DictionaryCaptureEvidenceFile(url: fifo, maximumBytes: 32)
        }
        expect(try Data(contentsOf: guestURL) == guestBytes, "Account admission never migrates or changes guest data")
        print("Admitted pronunciation reads: \(checks) assertions passed")
    }
}

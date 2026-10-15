@preconcurrency import AVFoundation
import Foundation
import XCTest
#if os(iOS)
@testable import PichiVoiceMobile
#else
@testable import FluidVoice_Debug
#endif

final class MeetingOwnerVoiceProfileTests: XCTestCase {
    private func vector(_ angle: Float) -> [Float] {
        [cos(angle), sin(angle)] + [Float](repeating: 0, count: 254)
    }
    private func snapshot(angle: Float = 0) -> MeetingOwnerVoiceProfileSnapshot {
        .init(metadata: .init(generation: UUID(), enrolledAt: Date()),
              encoderFingerprint: MeetingOwnerVoiceProfileStore.encoderFingerprint,
              embeddings: [self.vector(angle), self.vector(angle)])
    }
    private func profile(track: UUID, epoch: Int = 0, slot: Int, angle: Float = 0) -> MeetingSpeakerVoiceProfile {
        .init(token: .init(analysisEpochID: .init(trackID: track, ordinal: epoch), label: "slot-\(slot)"),
              embeddings: [self.vector(angle), self.vector(angle)])
    }
    private func privateStore() throws -> MeetingOwnerVoiceProfileStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-owner-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return .init(fileURL: root.appendingPathComponent("profile.json"))
    }
    func testConfidentOwnerIsSeparatedFromAnotherVoiceWithoutChangingParticipantClustering() {
        let track = UUID()
        let owner = self.profile(track: track, slot: 0)
        let other = self.profile(track: track, slot: 1, angle: .pi / 2)
        XCTAssertEqual(MeetingOwnerVoiceVerifier.confirmedTokens(owner: self.snapshot(), profiles: [owner, other]), [owner.token])
        XCTAssertTrue(MeetingOwnerVoiceVerifier.confirmedTokens(owner: nil, profiles: [owner, other]).isEmpty)
    }
    func testAmbiguousOwnerAndSelfInconsistentOrInvalidReferencesStayUnknown() {
        let track = UUID()
        let first = self.profile(track: track, slot: 0)
        let same = self.profile(track: track, slot: 1, angle: 0.1)
        XCTAssertTrue(MeetingOwnerVoiceVerifier.confirmedTokens(owner: self.snapshot(), profiles: [first, same]).isEmpty)
        let inconsistent = MeetingSpeakerVoiceProfile(token: first.token, embeddings: [self.vector(0), self.vector(.pi / 2)])
        XCTAssertTrue(MeetingOwnerVoiceVerifier.confirmedTokens(owner: self.snapshot(), profiles: [inconsistent]).isEmpty)
        for embeddings in [[[Float](repeating: 0, count: 256), [Float](repeating: 0, count: 256)], [[1, 0], [1, 0]], [[Float.nan] + [Float](repeating: 0, count: 255), self.vector(0)]] {
            let malformed = MeetingOwnerVoiceProfileSnapshot(metadata: self.snapshot().metadata,
                encoderFingerprint: MeetingOwnerVoiceProfileStore.encoderFingerprint, embeddings: embeddings)
            XCTAssertFalse(MeetingOwnerVoiceProfileStore.isValid(malformed))
            XCTAssertTrue(MeetingOwnerVoiceVerifier.confirmedTokens(owner: malformed, profiles: [first]).isEmpty)
        }
        let incompatible = MeetingOwnerVoiceProfileSnapshot(metadata: self.snapshot().metadata,
            encoderFingerprint: "different-model", embeddings: [self.vector(0), self.vector(0)])
        XCTAssertFalse(MeetingOwnerVoiceProfileStore.isValid(incompatible))
    }
    func testLinkedEpochsAreOneOwnerButDistinctSimultaneousSlotsCannotBothBecomeOwner() {
        let track = UUID()
        let first = self.profile(track: track, slot: 0)
        let later = self.profile(track: track, epoch: 1, slot: 2)
        let link = MeetingSpeakerIdentityLink(token: later.token, canonicalToken: first.token)
        XCTAssertEqual(MeetingOwnerVoiceVerifier.confirmedTokens(owner: self.snapshot(), profiles: [first, later], identityLinks: [link]), [first.token, later.token])
        XCTAssertTrue(MeetingOwnerVoiceVerifier.confirmedTokens(owner: self.snapshot(), profiles: [first, later]).isEmpty)
    }
    func testLocalStoreRoundTripPersistsOnlyBoundedEmbeddingsAndDeletionKeepsFrozenSnapshot() throws {
        let store = try self.privateStore()
        XCTAssertNil(try store.load())
        let reference = self.snapshot()
        try store.save(reference)
        let frozen = try XCTUnwrap(store.load())
        XCTAssertEqual(frozen, reference)
        let data = try Data(contentsOf: store.fileURL)
        XCTAssertLessThan(data.count, MeetingOwnerVoiceProfileStore.maximumBytes)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["schema", "generation", "enrolledAt", "encoderFingerprint", "embeddings"])
        let files = try FileManager.default.contentsOfDirectory(atPath: store.fileURL.deletingLastPathComponent().path)
        XCTAssertEqual(files, ["profile.json"])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try store.delete()
        XCTAssertNil(try store.load())
        XCTAssertEqual(frozen, reference)
    }
    func testStoreRejectsOversizedOrSymbolicFileWithoutFollowingIt() throws {
        let store = try self.privateStore()
        try Data(repeating: 0, count: MeetingOwnerVoiceProfileStore.maximumBytes + 1).write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
        try FileManager.default.removeItem(at: store.fileURL)
        let outside = store.fileURL.deletingLastPathComponent().appendingPathComponent("outside")
        try Data("private".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: outside)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(self.snapshot()))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "private")
    }
    @MainActor
    func testExplicitSaveAndDeleteInvalidateAnAlreadyPreparedCandidate() async throws {
        let store = try self.privateStore()
        let vector = self.vector(0)
        let service = MeetingOwnerVoiceProfileService(store: store, prepareResources: {}, encode: { requests in
            requests.map { .init(token: $0.token, embeddings: [vector, vector]) }
        })
        let audio = (0..<160_000).map { index in Float(sin(Double(index) * 0.1)) * 0.08 }
        let draft = try await service.prepare(samples: audio)
        XCTAssertNil(try store.load(), "Preparing an enrollment must never save it implicitly.")
        let metadata = try await service.save(draft)
        XCTAssertEqual(try store.load()?.metadata, metadata)
        do { _ = try await service.save(draft); XCTFail("A candidate can only be saved once.") }
        catch { XCTAssertTrue(error is MeetingOwnerVoiceProfileError) }
        let replacement = try await service.prepare(samples: audio)
        try await service.delete()
        do { _ = try await service.save(replacement); XCTFail("Delete must invalidate pending enrollment.") }
        catch { XCTAssertTrue(error is MeetingOwnerVoiceProfileError) }
        XCTAssertNil(try store.load())
        do { _ = try await service.prepare(samples: [Float](repeating: 0, count: 160_000)); XCTFail("Silence is not enrollment.") }
        catch { XCTAssertTrue(error is MeetingOwnerVoiceProfileError) }
    }
}

private nonisolated final class OwnerVoiceEncodingLatch: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    let lock = NSLock()
    private var returned = false
    func didReturn() { self.lock.withLock { self.returned = true } }
    var hasReturned: Bool { self.lock.withLock { self.returned } }
}

extension MeetingOwnerVoiceProfileTests {
    func testRealWeSpeakerEnrollmentMatchesOnlyTheEnrolledSyntheticVoice() async throws {
        let assets = try MobileInferenceTestAssets.resolve()
        let package = assets.appendingPathComponent("models/speaker-resources/voice/\(MeetingSpeakerVoiceModelArtifacts.packageName)", isDirectory: true)
        let read: (String) throws -> [Float] = { name in
            let file = try AVAudioFile(forReading: assets.appendingPathComponent("audio/\(name).wav"))
            XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
            XCTAssertEqual(file.processingFormat.channelCount, 1)
            XCTAssertTrue((102_400...320_000).contains(file.length))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                       frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            return Array(UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData?[0]), count: Int(buffer.frameLength)))
        }
        // Explicitly staged Apple TTS. Enrollment and later speech have different
        // text, so the positive comparison does not reuse identical PCM excerpts.
        let enrollment = try read("owner-enrollment")
        let first = try read("owner-observation")
        let second = try read("other-observation")
        let store = try self.privateStore()
        let service = MeetingOwnerVoiceProfileService(store: store,
            prepareResources: { try MeetingSpeakerVoiceModelArtifacts.validate(at: package) },
            encode: { try MeetingSpeakerVoiceEncoder.encode(samples: $0, directory: package, validateDefaultRoot: false) })
        let draft = try await service.prepare(samples: enrollment)
        XCTAssertNil(try store.load(), "Checking must not enroll a voice without Save.")
        _ = try await service.save(draft)
        let saved = try XCTUnwrap(store.load())
        XCTAssertEqual(saved.embeddings.map(\.count), [256, 256])
        let track = UUID()
        let ownSamples = MeetingSpeakerVoiceSamples.collect(epoch: .init(trackID: track, ordinal: 0),
            samples: first, segments: [.init(slotIndex: 0, start: 0, end: Double(first.count) / 16_000)])
        let otherSamples = MeetingSpeakerVoiceSamples.collect(epoch: .init(trackID: track, ordinal: 0),
            samples: second, segments: [.init(slotIndex: 1, start: 0, end: Double(second.count) / 16_000)])
        XCTAssertEqual(ownSamples.count, 1)
        XCTAssertEqual(otherSamples.count, 1)
        let profiles = try await TranscriptionExecutor().runBlocking {
            try MeetingSpeakerVoiceEncoder.encode(samples: ownSamples + otherSamples,
                directory: package, validateDefaultRoot: false)
        }
        XCTAssertEqual(profiles.count, 2)
        let matched = MeetingOwnerVoiceVerifier.confirmedTokens(owner: saved, profiles: profiles)
        XCTAssertEqual(matched, Set(ownSamples.map(\.token)), "A different real encoded voice must remain an ordinary participant.")
        try await service.delete()
        XCTAssertNil(try store.load())
        XCTAssertEqual(MeetingOwnerVoiceVerifier.confirmedTokens(owner: saved, profiles: profiles), matched,
                       "A running attempt keeps its immutable profile even if settings delete it.")
    }

    @MainActor
    func testCancelledEnrollmentWaitsForTheActualEncoderAndDoesNotSave() async throws {
        let store = try self.privateStore()
        let began = self.expectation(description: "actual native encoder entered")
        let latch = OwnerVoiceEncodingLatch()
        let vector = self.vector(0)
        let service = MeetingOwnerVoiceProfileService(store: store, prepareResources: {}, encode: { requests in
            began.fulfill()
            _ = latch.release.wait(timeout: .now() + 5)
            return requests.map { .init(token: $0.token, embeddings: [vector, vector]) }
        })
        let audio = (0..<160_000).map { Float(sin(Double($0) * 0.1)) * 0.08 }
        let operation = Task {
            defer { latch.didReturn() }
            return try await service.prepare(samples: audio)
        }
        await self.fulfillment(of: [began], timeout: 3)
        operation.cancel()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(latch.hasReturned, "Cancellation must join synchronous model work before releasing the microphone lease.")
        latch.release.signal()
        do { _ = try await operation.value; XCTFail("Cancelled enrollment cannot produce a candidate.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(latch.hasReturned)
        XCTAssertNil(try store.load())
    }
}

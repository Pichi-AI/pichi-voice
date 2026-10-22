import AVFoundation
import CoreMedia
@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class MeetingModelPreparationQueueTests: XCTestCase {
    private actor Counter {
        var active = 0
        var maximum = 0
        var completed = 0
        func enter() { self.active += 1; self.maximum = max(self.maximum, self.active) }
        func leave() { self.active -= 1; self.completed += 1 }
    }

    func testConcurrentPreparationsNeverOverlap() async throws {
        let queue = MeetingModelPreparationQueue()
        let counter = Counter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await queue.run {
                        await counter.enter()
                        try await Task.sleep(nanoseconds: 1_000_000)
                        await counter.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        let maximum = await counter.maximum
        let completed = await counter.completed
        XCTAssertEqual(maximum, 1)
        XCTAssertEqual(completed, 20)
    }

    private actor PreparationGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false
        func wait() async {
            if self.isOpen { return }
            await withCheckedContinuation { self.continuation = $0 }
        }

        func open() {
            self.isOpen = true
            self.continuation?.resume()
            self.continuation = nil
        }
    }

    func testCancelledQueuedPreparationReturnsBeforeActivePreparationFinishes() async throws {
        let queue = MeetingModelPreparationQueue()
        let gate = PreparationGate()
        let active = expectation(description: "active preparation holds the cache")
        let cancelled = expectation(description: "cancelled waiter returns while cache is occupied")
        let waiting = expectation(description: "second preparation is admitted to the queue")
        let first = Task {
            try await queue.run {
                active.fulfill()
                await gate.wait()
            }
        }
        await fulfillment(of: [active], timeout: 2)
        let second = Task {
            do {
                try await queue.run { XCTFail("Cancelled preparation must not load a model") }
                XCTFail("Expected cancellation")
            } catch is CancellationError {
                cancelled.fulfill()
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        let admission = Task {
            while !Task.isCancelled {
                if await queue.queuedPreparationCount == 1 {
                    waiting.fulfill()
                    return
                }
                await Task.yield()
            }
        }
        await fulfillment(of: [waiting], timeout: 2)
        admission.cancel()
        let queuedCount = await queue.queuedPreparationCount
        XCTAssertEqual(queuedCount, 1)
        second.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        await gate.open()
        _ = await first.result
        _ = await second.result
        let counter = Counter()
        try await queue.run { await counter.enter(); await counter.leave() }
        let completed = await counter.completed
        XCTAssertEqual(completed, 1)
    }

    func testFailureAndCancellationDoNotPoisonNextPreparation() async throws {
        let queue = MeetingModelPreparationQueue()
        let counter = Counter()
        do {
            try await queue.run { throw CancellationError() }
            XCTFail("Expected failure")
        } catch is CancellationError {}
        let cancelled = Task {
            try await Task.sleep(nanoseconds: 10_000_000)
            try await queue.run { await counter.enter() }
        }
        cancelled.cancel()
        _ = await cancelled.result
        try await queue.run { await counter.enter(); await counter.leave() }
        let completed = await counter.completed
        let active = await counter.active
        XCTAssertEqual(completed, 1)
        XCTAssertEqual(active, 0)
    }
}

final class MeetingLiveTimeConversionTests: XCTestCase {
    func testZeroOriginPassesPTSThrough() {
        let pts = CMTime(value: 5, timescale: 1)
        let origin = CMTime(value: 0, timescale: 1)
        XCTAssertEqual(MeetingLiveTimeConversion.sessionSeconds(pts: pts, origin: origin), 5, accuracy: 0.001)
    }

    func testNonZeroOriginSubtracts() {
        let pts = CMTime(value: 7, timescale: 1)
        let origin = CMTime(value: 2, timescale: 1)
        XCTAssertEqual(MeetingLiveTimeConversion.sessionSeconds(pts: pts, origin: origin), 5, accuracy: 0.001)
    }

    func testPTSBeforeOriginClampsToZero() {
        let pts = CMTime(value: 1, timescale: 1)
        let origin = CMTime(value: 4, timescale: 1)
        XCTAssertEqual(MeetingLiveTimeConversion.sessionSeconds(pts: pts, origin: origin), 0, accuracy: 0.001)
    }

    func testInvalidTimesReturnZero() {
        XCTAssertEqual(MeetingLiveTimeConversion.sessionSeconds(pts: .invalid, origin: .zero), 0)
    }

    func testOriginBoxKeepsTheEarliestPTS() {
        let box = MeetingLiveOriginBox()
        XCTAssertEqual(box.establish(CMTime(value: 5, timescale: 1)), CMTime(value: 5, timescale: 1))
        // A later-arriving but earlier PTS (out-of-order tee delivery) still wins.
        XCTAssertEqual(box.establish(CMTime(value: 2, timescale: 1)), CMTime(value: 2, timescale: 1))
        XCTAssertEqual(box.establish(CMTime(value: 9, timescale: 1)), CMTime(value: 2, timescale: 1))
    }
}

final class MeetingLiveTranscriptSnapshotTests: XCTestCase {
    func testDeliveryRejectsStoppedPreviousAndDuplicateSessionUpdates() {
        let generation = UUID()
        var current = MeetingLiveTranscriptSnapshot.empty
        current.revision = 2
        var latest = current
        latest.revision = 3
        latest.availability = .available
        XCTAssertTrue(current.accepts(latest, generation: generation, activeGeneration: generation))
        XCTAssertFalse(current.accepts(current, generation: generation, activeGeneration: generation))
        XCTAssertFalse(current.accepts(.empty, generation: generation, activeGeneration: generation))
        XCTAssertFalse(current.accepts(latest, generation: generation, activeGeneration: nil))
        XCTAssertFalse(MeetingLiveTranscriptSnapshot.empty.accepts(latest, generation: generation, activeGeneration: UUID()))
        XCTAssertEqual(current.revision, 2, "Rejected deliveries do not mutate existing captions")
        XCTAssertNotEqual(current.availability, .available)
    }

    func testNewWordsCountAsSpeechAndCaptionHousekeepingDoesNot() {
        let empty = MeetingLiveTranscriptSnapshot.empty
        let partial = MeetingLivePartial(id: UUID(), text: "so the", start: 1)
        let talking = empty.settingPartial(partial, for: .them)
        XCTAssertTrue(talking.hasNewWords(since: empty))
        XCTAssertFalse(talking.hasNewWords(since: talking))

        var longer = partial
        longer.text = "so the plan"
        XCTAssertTrue(talking.settingPartial(longer, for: .them).hasNewWords(since: talking))

        let finished = talking.inserting(self.utterance(.them, "so the plan", start: 1, end: 2)).settingPartial(nil, for: .them)
        XCTAssertTrue(finished.hasNewWords(since: talking))

        XCTAssertFalse(talking.settingPartial(nil, for: .them).hasNewWords(since: talking), "a caption going away is not speech")
        XCTAssertFalse(finished.settingAvailability(.available).hasNewWords(since: finished))
        XCTAssertFalse(finished.markingFinalized(UUID()).hasNewWords(since: finished))
    }

    private func utterance(_ speaker: MeetingLiveSpeaker, _ text: String, start: TimeInterval, end: TimeInterval) -> MeetingLiveUtterance {
        MeetingLiveUtterance(id: UUID(), speaker: speaker, text: text, start: start, end: end)
    }

    func testInsertingKeepsUtterancesSortedByStart() {
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot = snapshot.inserting(self.utterance(.you, "second", start: 5, end: 6))
        snapshot = snapshot.inserting(self.utterance(.them, "first", start: 1, end: 2))
        snapshot = snapshot.inserting(self.utterance(.you, "third", start: 8, end: 9))
        XCTAssertEqual(snapshot.utterances.map(\.text), ["first", "second", "third"])
    }

    /// A later-arriving finalize whose audio started earlier must still sort before an
    /// already-published utterance with a later start — engines finalize independently.
    func testLaterArrivingEarlierStartSortsFirst() {
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot = snapshot.inserting(self.utterance(.them, "arrived first, starts late", start: 10, end: 12))
        snapshot = snapshot.inserting(self.utterance(.you, "arrived second, starts early", start: 3, end: 4))
        XCTAssertEqual(snapshot.utterances.first?.text, "arrived second, starts early")
    }

    private func partial(_ text: String, id: UUID = UUID(), start: TimeInterval = 0) -> MeetingLivePartial {
        MeetingLivePartial(id: id, text: text, start: start)
    }

    func testGrowingPartialsReplaceRatherThanConcatenate() {
        let id = UUID()
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot = snapshot.settingPartial(self.partial("hel", id: id), for: .you)
        snapshot = snapshot.settingPartial(self.partial("hello", id: id), for: .you)
        snapshot = snapshot.settingPartial(self.partial("hello there", id: id), for: .you)
        XCTAssertEqual(snapshot.partials[.you]?.text, "hello there")
    }

    func testEmptyPartialClearsTheSlot() {
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot = snapshot.settingPartial(self.partial("hello"), for: .them)
        snapshot = snapshot.settingPartial(nil, for: .them)
        XCTAssertNil(snapshot.partials[.them])
    }

    func testPartialsForEachSpeakerAreIndependent() {
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot = snapshot.settingPartial(self.partial("you partial"), for: .you)
        snapshot = snapshot.settingPartial(self.partial("them partial"), for: .them)
        XCTAssertEqual(snapshot.partials[.you]?.text, "you partial")
        XCTAssertEqual(snapshot.partials[.them]?.text, "them partial")
    }

    func testStalePartialAfterFinalizeIsDropped() {
        let id = UUID()
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot = snapshot.inserting(self.utterance(.you, "final text", start: 0, end: 1))
        snapshot = snapshot.markingFinalized(id)
        snapshot = snapshot.settingPartial(self.partial("resurrected", id: id), for: .you)
        XCTAssertNil(snapshot.partials[.you])
    }

    func testEchoSuppressionFinalizesTurnWithoutUtterance() {
        let id = UUID()
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot = snapshot.settingPartial(self.partial("in flight", id: id), for: .you)
        snapshot = snapshot.settingPartial(nil, for: .you).markingFinalized(id)
        XCTAssertNil(snapshot.partials[.you])
        XCTAssertTrue(snapshot.utterances.isEmpty)

        let late = snapshot.settingPartial(self.partial("late arrival", id: id), for: .you)
        XCTAssertNil(late.partials[.you], "a partial for an echo-suppressed turn must not resurrect")
    }

    func testFinalizedTurnIDCapEvictsOldestWithoutBreakingRecentDedup() {
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        var ids: [UUID] = []
        for index in 0..<100 {
            let id = UUID()
            ids.append(id)
            snapshot = snapshot.inserting(self.utterance(.you, "turn \(index)", start: TimeInterval(index), end: TimeInterval(index) + 1))
            snapshot = snapshot.markingFinalized(id)
        }
        let oldest = ids[0]
        let recent = ids[ids.count - 1]
        XCTAssertFalse(snapshot.finalizedTurnIDs.contains(oldest), "cap must evict the oldest id")
        let staleOldPartial = snapshot.settingPartial(self.partial("should not be dropped by cap logic", id: oldest), for: .you)
        XCTAssertNotNil(staleOldPartial.partials[.you], "an evicted id is no longer recognized as stale")

        let staleRecentPartial = snapshot.settingPartial(self.partial("still dropped", id: recent), for: .you)
        XCTAssertNil(staleRecentPartial.partials[.you], "a recently finalized id must still be recognized as stale")
    }
}

final class MeetingLiveBubbleComposerTests: XCTestCase {
    private func utterance(_ speaker: MeetingLiveSpeaker, _ text: String, start: TimeInterval, end: TimeInterval, id: UUID = UUID()) -> MeetingLiveUtterance {
        MeetingLiveUtterance(id: id, speaker: speaker, text: text, start: start, end: end)
    }

    func testFinalizedThenBottomPinnedPartialsOrderedByStart() {
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot = snapshot.inserting(self.utterance(.you, "hello", start: 0, end: 1))
        snapshot = snapshot.settingPartial(MeetingLivePartial(id: UUID(), text: "them partial", start: 5), for: .them)
        snapshot = snapshot.settingPartial(MeetingLivePartial(id: UUID(), text: "you partial", start: 3), for: .you)

        let rows = MeetingLiveBubbleComposer.rows(for: snapshot)
        XCTAssertEqual(rows.map(\.text), ["hello", "you partial", "them partial"])
        XCTAssertEqual(rows.map(\.isPartial), [false, true, true])
        XCTAssertEqual(rows.map(\.showsLabel), [false, false, false], "Capture sources do not invent participant headers")
    }

    func testShowsLabelIsFalseWhenSpeakerRepeatsAcrossPartial() {
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot = snapshot.inserting(self.utterance(.you, "first", start: 0, end: 1))
        snapshot = snapshot.settingPartial(MeetingLivePartial(id: UUID(), text: "still talking", start: 2), for: .you)

        let rows = MeetingLiveBubbleComposer.rows(for: snapshot)
        XCTAssertEqual(rows.map(\.showsLabel), [false, false], "Unidentified captions remain readable without pseudo-speaker labels")
    }

    func testSolidifyKeepsRowIdentityStable() {
        let turnID = UUID()
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot = snapshot.settingPartial(MeetingLivePartial(id: turnID, text: "in flight text", start: 0), for: .you)
        let partialRows = MeetingLiveBubbleComposer.rows(for: snapshot)
        XCTAssertEqual(partialRows.first?.id, turnID)
        XCTAssertEqual(partialRows.first?.isPartial, true)

        snapshot = snapshot.inserting(self.utterance(.you, "in flight text finalized", start: 0, end: 2, id: turnID))
            .settingPartial(nil, for: .you)
        let finalRows = MeetingLiveBubbleComposer.rows(for: snapshot)
        XCTAssertEqual(finalRows.first?.id, turnID)
        XCTAssertEqual(finalRows.first?.isPartial, false)
    }
}

final class MeetingLiveBoundedQueueTests: XCTestCase {
    func testEnqueueUnderCapacityNeverDrops() {
        let queue = MeetingLiveBoundedQueue<Int>(capacity: 4)
        for value in 0..<4 {
            XCTAssertFalse(queue.enqueue(value))
        }
        XCTAssertEqual(queue.drainAll(), [0, 1, 2, 3])
    }

    func testSaturationDropsTheOldestElement() {
        let queue = MeetingLiveBoundedQueue<Int>(capacity: 3)
        for value in 0..<3 {
            _ = queue.enqueue(value)
        }
        let dropped = queue.enqueue(3)
        XCTAssertTrue(dropped)
        // 0 was the oldest; it must be gone, newest (3) must be present.
        XCTAssertEqual(queue.drainAll(), [1, 2, 3])
    }

    func testDrainClearsTheQueue() {
        let queue = MeetingLiveBoundedQueue<Int>(capacity: 4)
        _ = queue.enqueue(1)
        _ = queue.drainAll()
        XCTAssertEqual(queue.drainAll(), [])
    }

    func testHeavySaturationNeverGrowsPastCapacity() {
        let queue = MeetingLiveBoundedQueue<Int>(capacity: 4)
        for value in 0..<1000 {
            _ = queue.enqueue(value)
        }
        let drained = queue.drainAll()
        XCTAssertEqual(drained.count, 4)
        XCTAssertEqual(drained, [996, 997, 998, 999])
    }
}

final class MeetingLiveEchoFilterTests: XCTestCase {
    func testMicUtteranceMatchingRecentThemTextIsSuppressed() {
        let them = [
            MeetingLiveUtterance(
                id: UUID(),
                speaker: .them,
                text: "let's push the release to next Tuesday afternoon",
                start: 10,
                end: 14
            ),
        ]
        let recent = MeetingLiveEchoFilter.recentThemText(from: them, before: 15, windowSeconds: 20)
        let shouldSuppress = MeetingLiveEchoFilter.shouldSuppress(
            micText: "let's push the release to next Tuesday afternoon",
            recentThemText: recent
        )
        XCTAssertTrue(shouldSuppress)
    }

    func testGenuineLocalUtteranceIsNotSuppressed() {
        let them = [
            MeetingLiveUtterance(id: UUID(), speaker: .them, text: "let's push the release to next Tuesday", start: 10, end: 14),
        ]
        let recent = MeetingLiveEchoFilter.recentThemText(from: them, before: 15, windowSeconds: 20)
        let shouldSuppress = MeetingLiveEchoFilter.shouldSuppress(
            micText: "I think we should grab lunch after this call",
            recentThemText: recent
        )
        XCTAssertFalse(shouldSuppress)
    }

    func testThemTextOutsideTheWindowIsExcluded() {
        let them = [
            MeetingLiveUtterance(id: UUID(), speaker: .them, text: "let's push the release to next Tuesday afternoon", start: 0, end: 2),
        ]
        let recent = MeetingLiveEchoFilter.recentThemText(from: them, before: 100, windowSeconds: 20)
        XCTAssertTrue(recent.isEmpty)
        XCTAssertFalse(MeetingLiveEchoFilter.shouldSuppress(micText: "let's push the release to next Tuesday afternoon", recentThemText: recent))
    }
}

final class MeetingLiveMemoryGateTests: XCTestCase {
    func testGigaAMRejectsUnsupportedLanguageBeforeCaptionModelsLoad() {
        let notice = expectation(description: "Unsupported GigaAM language is rejected before loading")
        let coordinator = MeetingLiveTranscriptionCoordinator { snapshot in
            XCTAssertEqual(snapshot.availability, .unavailable(reason: "The selected model does not support live captions in this meeting language."))
            XCTAssertTrue(snapshot.utterances.isEmpty)
            notice.fulfill()
        }
        coordinator.start(mode: .onlineCall, languageCode: "de", modelID: PichiMeetingProviderFactory.gigaamModelID)
        wait(for: [notice], timeout: 1)
    }

    func testGigaAMLiveAdmissionIncludesMeasuredNominalFourGBDevice() throws {
        let admission = try XCTUnwrap(PichiMeetingProviderFactory.registeredLiveAdmission(
            for: PichiMeetingProviderFactory.gigaamModelID))
        XCTAssertEqual(admission.minimumPhysicalMemoryBytes, 4_000_000_000)
        // The physical iPad's reported capacity is below four binary GiB.
        let measuredPhysicalMemory: UInt64 = 4_166_696_960
        XCTAssertLessThan(measuredPhysicalMemory, 4 * 1_073_741_824)
        XCTAssertGreaterThanOrEqual(measuredPhysicalMemory, admission.minimumPhysicalMemoryBytes)
        XCTAssertLessThan(UInt64(4_000_000_000 - 1), admission.minimumPhysicalMemoryBytes)
        XCTAssertLessThan(UInt64(3 * 1_073_741_824), admission.minimumPhysicalMemoryBytes)
        XCTAssertEqual(admission.maximumTrackCount, 2)
        XCTAssertLessThanOrEqual(1, admission.maximumTrackCount)
        XCTAssertLessThanOrEqual(2, admission.maximumTrackCount)
        XCTAssertGreaterThan(3, admission.maximumTrackCount)
    }

    func testOtherRegisteredLiveAdmissionFloorsAndLegacyGateRemainUnchanged() throws {
        let tiny = try XCTUnwrap(PichiMeetingProviderFactory.registeredLiveAdmission(
            for: PichiMeetingProviderFactory.whisperTinyModelID))
        let parakeet = try XCTUnwrap(PichiMeetingProviderFactory.registeredLiveAdmission(
            for: PichiMeetingProviderFactory.parakeetV3ModelID))
        XCTAssertEqual(tiny.minimumPhysicalMemoryBytes, 2 * 1_073_741_824)
        XCTAssertEqual(parakeet.minimumPhysicalMemoryBytes, 4 * 1_073_741_824)
        XCTAssertEqual(tiny.maximumTrackCount, 2)
        XCTAssertEqual(parakeet.maximumTrackCount, 2)
        XCTAssertLessThan(UInt64(4_166_696_960), parakeet.minimumPhysicalMemoryBytes)
        XCTAssertNil(PichiMeetingProviderFactory.registeredLiveAdmission(for: "synthetic-unregistered"))
        XCTAssertEqual(MeetingLiveTranscriptionCoordinator.minimumPhysicalMemoryBytes, 8 * 1_073_741_824)
        XCTAssertFalse(MeetingLiveTranscriptionCoordinator.isMemorySufficient(physicalMemory: 4_166_696_960))
    }

    func testBelowThresholdDisablesLive() {
        let oneGigabyte: UInt64 = 1 * 1024 * 1024 * 1024
        XCTAssertFalse(MeetingLiveTranscriptionCoordinator.isMemorySufficient(physicalMemory: oneGigabyte))
    }

    func testAtOrAboveThresholdAllowsLive() {
        XCTAssertTrue(MeetingLiveTranscriptionCoordinator.isMemorySufficient(
            physicalMemory: MeetingLiveTranscriptionCoordinator.minimumPhysicalMemoryBytes
        ))
        XCTAssertTrue(MeetingLiveTranscriptionCoordinator.isMemorySufficient(physicalMemory: 64 * 1024 * 1024 * 1024))
    }
}

final class MeetingLiveCaptionRouteTests: XCTestCase {
    private typealias Route = MeetingLiveTranscriptionCoordinator.CaptionRoute
    private static let englishOnly = Route.unavailable(
        reason: "Live captions support English only. Your transcript will be generated after recording.")
    private static let unsupportedLanguage = Route.unavailable(
        reason: "The selected model does not support live captions in this meeting language.")
    private static let unregisteredModelIDs: [String?] = [
        nil,
        SettingsStore.SpeechModel.appleSpeech.rawValue,
        SettingsStore.SpeechModel.appleSpeechAnalyzer.rawValue,
        SettingsStore.SpeechModel.parakeetTDTv2.rawValue,
        SettingsStore.SpeechModel.whisperBase.rawValue,
        "fixture.unregistered-provider",
    ]

    private func route(_ languageCode: String, _ modelID: String?) -> Route {
        MeetingLiveTranscriptionCoordinator.captionRoute(languageCode: languageCode, modelID: modelID)
    }

    func testRegisteredModelsCaptionOnlyTheirOwnSupportedLanguages() {
        let parakeetV3 = PichiMeetingProviderFactory.parakeetV3ModelID
        let gigaam = PichiMeetingProviderFactory.gigaamModelID
        let whisperTiny = PichiMeetingProviderFactory.whisperTinyModelID
        XCTAssertEqual(self.route("ru", parakeetV3), .buffered(modelID: parakeetV3))
        XCTAssertEqual(self.route("en", parakeetV3), .buffered(modelID: parakeetV3))
        XCTAssertEqual(self.route("ru", gigaam), .buffered(modelID: gigaam))
        XCTAssertEqual(self.route("en", gigaam), Self.unsupportedLanguage)
        XCTAssertEqual(self.route("ru", whisperTiny), .buffered(modelID: whisperTiny))
        XCTAssertEqual(self.route("en", whisperTiny), .buffered(modelID: whisperTiny))
    }

    func testUnregisteredModelsKeepUpstreamEnglishOnlyCaptionsWithoutSubstitutingAModel() {
        for modelID in Self.unregisteredModelIDs {
            XCTAssertNil(modelID.flatMap(PichiMeetingProviderFactory.registeredLanguageCodes(for:)), "\(modelID ?? "nil")")
            XCTAssertEqual(self.route("en", modelID), .englishStreaming, "\(modelID ?? "nil")")
            for languageCode in ["ru", "de", "auto"] {
                XCTAssertEqual(self.route(languageCode, modelID), Self.englishOnly, "\(modelID ?? "nil") \(languageCode)")
            }
        }
    }

    func testUnregisteredRussianMeetingPublishesNoticeWithoutLoadingBufferedCaptions() {
        for modelID in Self.unregisteredModelIDs {
            let notice = expectation(description: "English-only notice for \(modelID ?? "nil")")
            let noLoading = expectation(description: "No caption model loads for \(modelID ?? "nil")")
            noLoading.isInverted = true
            let published = Counter()
            let coordinator = MeetingLiveTranscriptionCoordinator { snapshot in
                if published.increment() == 1 {
                    XCTAssertEqual(snapshot.availability, .unavailable(reason: "Live captions support English only. Your transcript will be generated after recording."))
                    XCTAssertTrue(snapshot.utterances.isEmpty)
                    notice.fulfill()
                } else {
                    noLoading.fulfill()
                }
            }
            coordinator.start(mode: .onlineCall, languageCode: "ru", modelID: modelID, artifactFingerprint: nil)
            wait(for: [notice, noLoading], timeout: 0.2)
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() -> Int { self.lock.withLock { self.value += 1; return self.value } }
    }
}

final class MeetingLiveProvisionalContainmentTests: XCTestCase {
    /// Provisional live text must never reach the exporter: it only ever reads `MeetingSession`,
    /// and live utterances are never written into `session.transcriptSegments`.
    func testExportedTranscriptNeverContainsLiveOnlyText() {
        let microphone = MeetingMicrophoneIdentity(captureDeviceID: "mic-1", coreAudioUID: nil, displayName: "Test Mic")
        let configuration = MeetingCaptureConfiguration(mode: .inRoom, title: "Standup", microphone: microphone)
        let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil)
        var session = MeetingSession(configuration: configuration, timebase: timebase)

        let speakerID = UUID()
        session.speakers = [
            MeetingSessionSpeaker(
                id: speakerID,
                displayName: "Speaker 1",
                diarizationClusterID: nil,
                trackKind: .microphone,
                isLocalUser: true,
                identityCandidates: []
            ),
        ]
        session.transcriptSegments = [
            MeetingTranscriptSegment(
                id: UUID(),
                start: MeetingMediaTime(value: 0, timescale: 1),
                end: MeetingMediaTime(value: 1, timescale: 1),
                sourceTrackID: UUID(),
                speakerID: speakerID,
                text: "FINAL_TRANSCRIPT_TEXT",
                revision: 0,
                status: .final,
                overlap: .none,
                completeness: .complete
            ),
        ]

        // A live snapshot exists in memory alongside the session, as it would during recording,
        // but nothing ever threads it into the exporter or the session's segments.
        let liveSnapshot = MeetingLiveTranscriptSnapshot.empty
            .inserting(MeetingLiveUtterance(id: UUID(), speaker: .you, text: "PROVISIONAL_LIVE_ONLY_TEXT", start: 0, end: 1))
            .settingPartial(MeetingLivePartial(id: UUID(), text: "PROVISIONAL_PARTIAL_ONLY_TEXT", start: 0), for: .them)

        let exported = MeetingTranscriptExporter.text(for: session, includeEchoes: true)
        XCTAssertTrue(exported.contains("FINAL_TRANSCRIPT_TEXT"))
        XCTAssertFalse(exported.contains("PROVISIONAL_LIVE_ONLY_TEXT"))
        XCTAssertFalse(exported.contains("PROVISIONAL_PARTIAL_ONLY_TEXT"))
        XCTAssertFalse(session.transcriptSegments.contains { $0.text.contains("PROVISIONAL") })
        XCTAssertFalse(liveSnapshot.utterances.isEmpty, "sanity: the live snapshot really did hold provisional content")
    }
}

@MainActor
final class MeetingOverlayVisibilityTests: XCTestCase {
    func testVisibleOnlyForRecordingAndRecordingDegraded() {
        let id = MeetingSessionID()
        XCTAssertFalse(MeetingOverlayVisibility.isVisible(for: .idle))
        XCTAssertFalse(MeetingOverlayVisibility.isVisible(for: .preparing(id)))
        XCTAssertTrue(MeetingOverlayVisibility.isVisible(for: .recording(id)))
        XCTAssertTrue(MeetingOverlayVisibility.isVisible(for: .recordingDegraded(id)))
        XCTAssertFalse(MeetingOverlayVisibility.isVisible(for: .stopping(id)))
        XCTAssertFalse(MeetingOverlayVisibility.isVisible(for: .processing(id, .saving)))
        XCTAssertFalse(MeetingOverlayVisibility.isVisible(for: .completed(id)))
        XCTAssertFalse(MeetingOverlayVisibility.isVisible(for: .interrupted(id)))
        XCTAssertFalse(MeetingOverlayVisibility.isVisible(for: .failed(id, MeetingSessionFailure(
            id: UUID(), occurredAt: Date(), domain: .capture, code: "test", message: "test failure", recoverable: true
        ))))
    }
}

#if arch(arm64)
@MainActor
final class MeetingLiveStartupCancellationTests: XCTestCase {
    private actor SuspendedRecognizer: MeetingLiveRecognizer {
        let didBeginInstalling: @Sendable () -> Void
        let didPrepare: @Sendable () -> Void
        private var continuation: CheckedContinuation<Void, Never>?
        private var eouCallback: (@Sendable (String) -> Void)?
        private var partialCallback: (@Sendable (String) -> Void)?
        private(set) var installationCount = 0

        init(didBeginInstalling: @escaping @Sendable () -> Void, didPrepare: @escaping @Sendable () -> Void) {
            self.didBeginInstalling = didBeginInstalling
            self.didPrepare = didPrepare
        }

        func setEouCallback(_ callback: @escaping @Sendable (String) -> Void) async {
            self.eouCallback = callback
            self.installationCount += 1
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                self.didBeginInstalling()
            }
        }

        func setPartialTranscriptCallback(_ callback: @escaping @Sendable (String) -> Void) async {
            self.partialCallback = callback
        }

        func resumeInstallation() {
            self.continuation?.resume()
            self.continuation = nil
        }

        func emitStaleCallbacks() {
            self.partialCallback?("late partial")
            self.eouCallback?("late final")
        }

        func prepareModels() async throws { self.didPrepare() }
        func appendAudio(_ buffer: AVAudioPCMBuffer) async throws {}
        func processBufferedAudio() async throws {}
        func finish() async throws -> String { "" }
        func reset() async {}
    }

    func testStopDuringCallbackInstallationCannotLaunchModelsOrPublish() async {
        let installing = expectation(description: "callback installation suspended")
        let noPrepare = expectation(description: "stopped engine must not load models")
        noPrepare.isInverted = true
        let noPublish = expectation(description: "stopped engine must not publish")
        noPublish.isInverted = true
        let recognizer = SuspendedRecognizer(
            didBeginInstalling: { installing.fulfill() },
            didPrepare: { noPrepare.fulfill() }
        )
        let engine = MeetingLiveTrackEngine(kind: .microphone, recognizer: recognizer)
        await engine.configure(
            onPartial: { _, _, _, _, _ in noPublish.fulfill() },
            onUtterance: { _, _, _, _, _ in noPublish.fulfill() },
            onDegraded: { _, _ in noPublish.fulfill() },
            onReady: { _ in noPublish.fulfill() }
        )
        let starting = Task { await engine.start() }
        await fulfillment(of: [installing], timeout: 2)
        await engine.stop()
        await recognizer.resumeInstallation()
        await starting.value
        await recognizer.emitStaleCallbacks()
        await engine.start() // A delayed coordinator launch cannot restart a stopped engine either.
        await fulfillment(of: [noPrepare, noPublish], timeout: 0.1)
        let installationCount = await recognizer.installationCount
        XCTAssertEqual(installationCount, 1)
        await engine.stop()
    }

    func testUninterruptedStartupStillLoadsAndBecomesReady() async {
        let installing = expectation(description: "installing callbacks")
        let prepared = expectation(description: "models prepared")
        let ready = expectation(description: "captions ready")
        let recognizer = SuspendedRecognizer(
            didBeginInstalling: { installing.fulfill() },
            didPrepare: { prepared.fulfill() }
        )
        let engine = MeetingLiveTrackEngine(kind: .microphone, recognizer: recognizer)
        await engine.configure(
            onPartial: { _, _, _, _, _ in },
            onUtterance: { _, _, _, _, _ in },
            onDegraded: { _, _ in XCTFail("Unexpected degradation") },
            onReady: { _ in ready.fulfill() }
        )
        let starting = Task { await engine.start() }
        await fulfillment(of: [installing], timeout: 2)
        await recognizer.resumeInstallation()
        await starting.value
        await fulfillment(of: [prepared, ready], timeout: 2)
        await engine.stop()
    }

    func testStopBeforeLaunchPreventsCallbackInstallation() async {
        let noInstall = expectation(description: "stopped engine must not install callbacks")
        noInstall.isInverted = true
        let recognizer = SuspendedRecognizer(didBeginInstalling: { noInstall.fulfill() }, didPrepare: {})
        let engine = MeetingLiveTrackEngine(kind: .microphone, recognizer: recognizer)
        await engine.stop()
        let starting = Task { await engine.start() }
        await fulfillment(of: [noInstall], timeout: 0.1)
        // Unblock a regression so a failed assertion cannot leak a suspended task.
        await recognizer.resumeInstallation()
        await starting.value
        await engine.stop()
    }
}
#endif


@MainActor
final class PichiMeetingBufferedCaptionsTests: XCTestCase {
    @MainActor private final class CaptionProvider: TranscriptionProvider {
        let name = "Unknown caption provider fixture"
        let isAvailable = true
        var isReady = false
        let endOfUtteranceProbability: Float?
        var streamingInputs: [[Float]] = []
        var ordinaryTranscriptionCalls = 0
        var prepareCalls = 0
        var releaseCalls = 0
        var clearCacheCalls = 0
        var supportsWordTimings = false
        var timedCalls = 0

        init(endOfUtteranceProbability: Float? = nil) {
            self.endOfUtteranceProbability = endOfUtteranceProbability
        }

        func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {
            self.prepareCalls += 1
            self.isReady = true
        }

        func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
            self.ordinaryTranscriptionCalls += 1
            return ASRTranscriptionResult(text: "Ordinary transcription must not be selected")
        }

        func transcribeStreaming(_ samples: [Float]) async throws -> ASRTranscriptionResult {
            self.streamingInputs.append(samples)
            if let endOfUtteranceProbability {
                return ASRTranscriptionResult(
                    text: "Unknown provider caption",
                    endOfUtteranceProbability: endOfUtteranceProbability
                )
            }
            // Exercise the compatibility default used by providers without endpoint metadata.
            return ASRTranscriptionResult(text: "Unknown provider caption")
        }

        func releaseResidency() async {
            self.releaseCalls += 1
            self.isReady = false
        }

        func clearCache() async throws { self.clearCacheCalls += 1 }

        func transcribeWithWordTimings(_ samples: [Float]) async throws -> (result: ASRTranscriptionResult, words: [ASRWordTiming]) {
            self.timedCalls += 1
            return (.init(text: "Closed tail"), [.init(text: "Closed", start: 17, end: 18), .init(text: "tail", start: 19, end: 20)])
        }
    }

    private actor Recognizer: PichiMeetingCaptionRecognizing {
        var inputs: [[Float]] = []
        var prepareCount = 0
        func prepare() { self.prepareCount += 1 }
        func recognize(_ samples: [Float]) -> PichiMeetingCaptionRecognition {
            self.inputs.append(samples)
            return PichiMeetingCaptionRecognition(text: "Русская встреча", endOfUtteranceProbability: nil)
        }
        func unload() {}
    }

    private final nonisolated class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var partialValues: [(UUID, String)] = []
        private var utteranceValues: [(MeetingAudioTrackKind, UUID, String, Double, Double)] = []
        private var degradedValues: [String] = []
        func partial(_ id: UUID, _ text: String) { self.lock.withLock { self.partialValues.append((id, text)) } }
        func utterance(_ kind: MeetingAudioTrackKind, _ id: UUID, _ text: String, _ start: CMTime, _ end: CMTime) {
            self.lock.withLock { self.utteranceValues.append((kind, id, text, start.seconds, end.seconds)) }
        }
        func degraded(_ text: String) { self.lock.withLock { self.degradedValues.append(text) } }
        var partials: [(UUID, String)] { self.lock.withLock { self.partialValues } }
        var utterances: [(MeetingAudioTrackKind, UUID, String, Double, Double)] { self.lock.withLock { self.utteranceValues } }
        var degraded: [String] { self.lock.withLock { self.degradedValues } }
    }

    private func sample(start: Double, seconds: Double, value: Float) throws -> MeetingLiveSampleCopy.Sample {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let count = AVAudioFrameCount((seconds * 16_000).rounded())
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
        buffer.frameLength = count
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        channel.update(repeating: value, count: Int(count))
        return MeetingLiveSampleCopy.Sample(buffer: buffer, pts: CMTime(seconds: start, preferredTimescale: 16_000), duration: CMTime(seconds: seconds, preferredTimescale: 16_000))
    }

    private func configure(_ engine: PichiMeetingBufferedTrackEngine, events: Events) async {
        await engine.configure(
            onPartial: { _, id, text, _, _ in events.partial(id, text) },
            onUtterance: { kind, id, text, start, end in events.utterance(kind, id, text, start, end) },
            onDegraded: { _, text in events.degraded(text) },
            onReady: { _ in }
        )
    }

    private actor BlockedRecognizer: PichiMeetingCaptionRecognizing {
        private var gate: CheckedContinuation<Void, Never>?
        private var opened = false
        private let firstCall: @Sendable () -> Void
        var inputs: [[Float]] = []
        init(firstCall: @escaping @Sendable () -> Void) { self.firstCall = firstCall }
        func prepare() {}
        func recognize(_ samples: [Float]) async -> PichiMeetingCaptionRecognition {
            self.inputs.append(samples)
            if self.inputs.count == 1 {
                self.firstCall()
                if !self.opened { await withCheckedContinuation { self.gate = $0 } }
            }
            return .init(text: samples.contains(0.1) ? "first turn" : "second turn", endOfUtteranceProbability: nil)
        }
        func release() { self.opened = true; self.gate?.resume(); self.gate = nil }
        func unload() { self.release() }
    }

    private func offer(_ engine: PichiMeetingBufferedTrackEngine, start: Double, packets: Int, value: Float) throws {
        for packet in 0..<packets {
            engine.offer(try self.sample(start: start + Double(packet) / 10, seconds: 0.1, value: value))
        }
    }

    private func waitForUtterances(_ count: Int, events: Events) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while events.utterances.count < count, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return events.utterances.count >= count
    }

    func testQueuedBacklogSuppressesObsoletePrefixesButPreservesBothFinalTurns() async throws {
        let entered = expectation(description: "first prefix parked")
        let ready = expectation(description: "engine ready")
        let recognizer = BlockedRecognizer(firstCall: { entered.fulfill() })
        let engine = PichiMeetingBufferedTrackEngine(kind: .microphone, recognizer: recognizer)
        let events = Events()
        self.addTeardownBlock { await recognizer.release(); await engine.stop(); await recognizer.unload() }
        await engine.configure(onPartial: { _, id, text, _, _ in events.partial(id, text) },
            onUtterance: { kind, id, text, start, end in events.utterance(kind, id, text, start, end) },
            onDegraded: { _, reason in events.degraded(reason) }, onReady: { _ in ready.fulfill() })
        await engine.start()
        await fulfillment(of: [ready], timeout: 2)
        try self.offer(engine, start: 0, packets: 13, value: 0.1)
        await fulfillment(of: [entered], timeout: 2)
        // Captured PCM keeps arriving while the recognizer is suspended. Some of this work
        // will already be in drainAll's local batch, so testing queue count alone is insufficient.
        try self.offer(engine, start: 1.3, packets: 27, value: 0.1)
        try self.offer(engine, start: 4, packets: 8, value: 0)
        try self.offer(engine, start: 4.8, packets: 42, value: 0.2)
        try self.offer(engine, start: 9, packets: 8, value: 0)
        await recognizer.release()
        let completed = await self.waitForUtterances(2, events: events)
        XCTAssertTrue(completed)
        let inputs = await recognizer.inputs
        XCTAssertLessThanOrEqual(inputs.count, 4, "Obsolete intermediate prefixes must yield to queued endpoints")
        XCTAssertEqual(events.utterances.map { $0.2 }, ["first turn", "second turn"])
        let first = try XCTUnwrap(events.utterances.first)
        let second = try XCTUnwrap(events.utterances.dropFirst().first)
        XCTAssertEqual(first.3, 0, accuracy: 0.0001)
        XCTAssertEqual(first.4, 4.7, accuracy: 0.0001)
        XCTAssertEqual(second.4, 9.7, accuracy: 0.0001)
        XCTAssertTrue(inputs.contains { $0.filter { $0 == 0.1 }.count == 64_000 })
        XCTAssertTrue(inputs.contains { $0.filter { $0 == 0.2 }.count == 67_200 })
        XCTAssertTrue(events.degraded.isEmpty)
    }

    func testResetDuringBlockedPrefixDoesNotPublishPreviousEraAndAcceptsNewClock() async throws {
        let entered = expectation(description: "old prefix parked")
        let ready = expectation(description: "engine ready")
        let recognizer = BlockedRecognizer(firstCall: { entered.fulfill() })
        let engine = PichiMeetingBufferedTrackEngine(kind: .microphone, recognizer: recognizer)
        let events = Events()
        self.addTeardownBlock { await recognizer.release(); await engine.stop(); await recognizer.unload() }
        await engine.configure(onPartial: { _, id, text, _, _ in events.partial(id, text) },
            onUtterance: { kind, id, text, start, end in events.utterance(kind, id, text, start, end) },
            onDegraded: { _, reason in events.degraded(reason) }, onReady: { _ in ready.fulfill() })
        await engine.start()
        await fulfillment(of: [ready], timeout: 2)
        try self.offer(engine, start: 10, packets: 13, value: 0.1)
        await fulfillment(of: [entered], timeout: 2)
        engine.requestReset()
        try self.offer(engine, start: 1, packets: 16, value: 0.2)
        try self.offer(engine, start: 2.6, packets: 8, value: 0)
        await recognizer.release()
        let completed = await self.waitForUtterances(1, events: events)
        XCTAssertTrue(completed)
        XCTAssertTrue(events.partials.filter { !$0.1.isEmpty }.allSatisfy { $0.1 == "second turn" })
        XCTAssertEqual(events.utterances.map { $0.2 }, ["second turn"])
        let utterance = try XCTUnwrap(events.utterances.first)
        XCTAssertEqual(utterance.4, 3.3, accuracy: 0.0001)
        XCTAssertTrue(events.degraded.isEmpty)
    }

    func testStopJoinsBlockedPrefixAndNeverPublishesItsLateText() async throws {
        let entered = expectation(description: "prefix parked")
        let ready = expectation(description: "engine ready")
        let recognizer = BlockedRecognizer(firstCall: { entered.fulfill() })
        let engine = PichiMeetingBufferedTrackEngine(kind: .microphone, recognizer: recognizer)
        let events = Events()
        self.addTeardownBlock { await recognizer.release(); await engine.stop(); await recognizer.unload() }
        await engine.configure(onPartial: { _, id, text, _, _ in events.partial(id, text) },
            onUtterance: { kind, id, text, start, end in events.utterance(kind, id, text, start, end) },
            onDegraded: { _, reason in events.degraded(reason) }, onReady: { _ in ready.fulfill() })
        await engine.start()
        await fulfillment(of: [ready], timeout: 2)
        try self.offer(engine, start: 0, packets: 13, value: 0.1)
        await fulfillment(of: [entered], timeout: 2)
        var stopped = false
        let stopping = Task { await engine.stop(); stopped = true }
        stopping.cancel()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(stopped, "Stop must remain joined to noncooperative inference")
        await recognizer.release()
        await stopping.value
        XCTAssertTrue(stopped)
        XCTAssertTrue(events.partials.filter { !$0.1.isEmpty }.isEmpty)
        XCTAssertTrue(events.utterances.isEmpty)
    }

    func testCaptureEraHeadRejectsInvalidValuesAndRestartsAtBackwardClock() {
        let box = PichiMeetingCaptionInputEpoch()
        let epoch = box.recordOffer(end: .init(seconds: 12, preferredTimescale: 16_000))
        _ = box.recordOffer(end: .invalid)
        XCTAssertEqual(box.latestEnd(in: epoch), 12)
        _ = box.recordOffer(end: .init(seconds: 4, preferredTimescale: 16_000))
        XCTAssertEqual(box.latestEnd(in: epoch), 4)
        box.advance()
        XCTAssertNil(box.latestEnd(in: epoch))
        XCTAssertNil(box.latestEnd(in: box.current))
    }

    func testUnknownProviderEndpointMetadataFinalizesAfterShortAcousticPause() async throws {
        let provider = CaptionProvider(endOfUtteranceProbability: 0.9)
        let recognizer = PichiMeetingCaptionRecognizer(provider: provider)
        let engine = PichiMeetingBufferedTrackEngine(kind: .microphone, recognizer: recognizer)
        self.addTeardownBlock { @MainActor in
            await engine.stop()
            await recognizer.unload()
        }
        let events = Events()
        await self.configure(engine, events: events)
        try await recognizer.prepare()
        try await engine.consumeForTesting(self.sample(start: 4, seconds: 1.1, value: 0.1))
        try await engine.consumeForTesting(self.sample(start: 5.1, seconds: 0.1, value: 0))
        XCTAssertTrue(events.utterances.isEmpty)
        try await engine.consumeForTesting(self.sample(start: 5.2, seconds: 0.1, value: 0))

        let partial = try XCTUnwrap(events.partials.first { !$0.1.isEmpty })
        let utterance = try XCTUnwrap(events.utterances.first)
        XCTAssertEqual(events.utterances.count, 1)
        XCTAssertEqual(utterance.0, .microphone)
        XCTAssertEqual(utterance.1, partial.0)
        XCTAssertEqual(utterance.2, "Unknown provider caption")
        XCTAssertEqual(utterance.3, 4, accuracy: 0.0001)
        XCTAssertEqual(utterance.4, 5.3, accuracy: 0.0001)
        XCTAssertEqual(provider.streamingInputs.count, 1, "Endpoint finalization reuses the current streaming hypothesis")
        XCTAssertEqual(provider.streamingInputs.first?.count, 20_800)
        XCTAssertEqual(provider.ordinaryTranscriptionCalls, 0)
        XCTAssertTrue(events.degraded.isEmpty)
    }

    func testProviderWithoutEndpointMetadataKeepsRegularPauseFinalization() async throws {
        let provider = CaptionProvider()
        let recognizer = PichiMeetingCaptionRecognizer(provider: provider)
        let engine = PichiMeetingBufferedTrackEngine(kind: .microphone, recognizer: recognizer)
        self.addTeardownBlock { @MainActor in
            await engine.stop()
            await recognizer.unload()
        }
        let events = Events()
        await self.configure(engine, events: events)
        try await recognizer.prepare()
        try await engine.consumeForTesting(self.sample(start: 4, seconds: 1.1, value: 0.1))
        try await engine.consumeForTesting(self.sample(start: 5.1, seconds: 0.2, value: 0))

        let partial = try XCTUnwrap(events.partials.first { !$0.1.isEmpty })
        XCTAssertEqual(partial.1, "Unknown provider caption")
        XCTAssertTrue(events.utterances.isEmpty, "Absent endpoint metadata must not shorten the acoustic pause")
        XCTAssertEqual(provider.streamingInputs.count, 1)
        try await engine.consumeForTesting(self.sample(start: 5.3, seconds: 0.5, value: 0))

        let utterance = try XCTUnwrap(events.utterances.first)
        XCTAssertEqual(events.utterances.count, 1)
        XCTAssertEqual(utterance.1, partial.0)
        XCTAssertEqual(utterance.2, "Unknown provider caption")
        XCTAssertEqual(utterance.3, 4, accuracy: 0.0001)
        XCTAssertEqual(utterance.4, 5.8, accuracy: 0.0001)
        XCTAssertEqual(provider.streamingInputs.map(\.count), [20_800, 28_800])
        XCTAssertEqual(provider.ordinaryTranscriptionCalls, 0)
        XCTAssertTrue(events.degraded.isEmpty)
    }

    func testCaptionAdapterReleasesUnknownProviderOnceWithoutClearingArtifacts() async throws {
        let provider = CaptionProvider()
        let recognizer = PichiMeetingCaptionRecognizer(provider: provider)
        self.addTeardownBlock { @MainActor in await recognizer.unload() }
        try await recognizer.prepare()
        let result = try await recognizer.recognize([0.1, 0.2])
        XCTAssertEqual(result.text, "Unknown provider caption")
        XCTAssertNil(result.endOfUtteranceProbability)
        XCTAssertEqual(provider.prepareCalls, 1)
        XCTAssertEqual(provider.releaseCalls, 0)

        await recognizer.unload()
        await recognizer.unload()

        XCTAssertEqual(provider.releaseCalls, 1)
        XCTAssertEqual(provider.clearCacheCalls, 0)
        XCTAssertFalse(provider.isReady)
        XCTAssertEqual(provider.streamingInputs, [[0.1, 0.2]])
        XCTAssertEqual(provider.ordinaryTranscriptionCalls, 0)
    }

    func testCaptionAdapterSelectsGenericTimingsOnlyForBoundaryRequests() async throws {
        let provider = CaptionProvider()
        provider.supportsWordTimings = true
        let recognizer = PichiMeetingCaptionRecognizer(provider: provider)
        self.addTeardownBlock { @MainActor in await recognizer.unload() }
        _ = try await recognizer.recognize([0.1])
        XCTAssertEqual(provider.timedCalls, 0)
        let boundary = try await recognizer.recognizeWithWordTimings([0.1])
        XCTAssertEqual(boundary.words.count, 2)
        XCTAssertEqual(provider.timedCalls, 1)
        XCTAssertEqual(provider.streamingInputs.count, 1)
        XCTAssertEqual(provider.ordinaryTranscriptionCalls, 0)
        provider.supportsWordTimings = false
        let compatibility = try await recognizer.recognizeWithWordTimings([0.2])
        XCTAssertTrue(compatibility.words.isEmpty)
        XCTAssertEqual(provider.timedCalls, 1)
        XCTAssertEqual(provider.streamingInputs.count, 2)
    }

    func testPeriodicRussianCaptionAndPauseFinalizationKeepCaptureTimesAndTurnIdentity() async throws {
        let recognizer = Recognizer()
        let engine = PichiMeetingBufferedTrackEngine(kind: .microphone, recognizer: recognizer)
        let events = Events()
        await self.configure(engine, events: events)
        try await engine.consumeForTesting(self.sample(start: 4, seconds: 1.6, value: 0.1))
        try await engine.consumeForTesting(self.sample(start: 5.6, seconds: 0.8, value: 0))
        let partial = try XCTUnwrap(events.partials.first { !$0.1.isEmpty })
        let utterance = try XCTUnwrap(events.utterances.first)
        XCTAssertEqual(utterance.1, partial.0)
        XCTAssertEqual(utterance.2, "Русская встреча")
        XCTAssertEqual(utterance.3, 4, accuracy: 0.0001)
        XCTAssertEqual(utterance.4, 6.3, accuracy: 0.0001)
        XCTAssertTrue(events.degraded.isEmpty)
        await engine.stop()
    }

    func testSharedRecognizerNeverMixesOnlineCallTrackBuffers() async throws {
        let recognizer = Recognizer()
        let microphone = PichiMeetingBufferedTrackEngine(kind: .microphone, recognizer: recognizer)
        let application = PichiMeetingBufferedTrackEngine(kind: .applicationAudio, recognizer: recognizer)
        let events = Events()
        await self.configure(microphone, events: events)
        await self.configure(application, events: events)
        try await microphone.consumeForTesting(self.sample(start: 10, seconds: 1.6, value: 0.1))
        try await application.consumeForTesting(self.sample(start: 10, seconds: 1.6, value: 0.2))
        try await microphone.consumeForTesting(self.sample(start: 11.6, seconds: 0.8, value: 0))
        try await application.consumeForTesting(self.sample(start: 11.6, seconds: 0.8, value: 0))
        XCTAssertEqual(Set(events.utterances.map { $0.0 }), [.microphone, .applicationAudio])
        let inputs = await recognizer.inputs
        XCTAssertTrue(inputs.allSatisfy { samples in !(samples.contains(0.1) && samples.contains(0.2)) })
        await microphone.stop()
        await application.stop()
    }

    func testContinuousSpeechRotatesBoundedUtterancesAndSilenceIsNotDecoded() async throws {
        let recognizer = Recognizer()
        let engine = PichiMeetingBufferedTrackEngine(kind: .microphone, recognizer: recognizer)
        let events = Events()
        await self.configure(engine, events: events)
        try await engine.consumeForTesting(self.sample(start: 1, seconds: 3, value: 0))
        var inputs = await recognizer.inputs
        XCTAssertTrue(inputs.isEmpty)
        try await engine.consumeForTesting(self.sample(start: 4, seconds: 30, value: 0.1))
        let bufferedCount = await engine.bufferedSampleCountForTesting()
        inputs = await recognizer.inputs
        XCTAssertLessThanOrEqual(bufferedCount, 320_000)
        XCTAssertTrue(inputs.allSatisfy { $0.count <= 320_000 })
        XCTAssertEqual(events.utterances.count, 1)
        await engine.stop()
    }

    func testForcedRotationKeepsUnrecognizedWordAudioForTheNextTurn() async throws {
        actor TimedRecognizer: PichiMeetingCaptionRecognizing {
            var inputs: [Int] = []
            var timedCalls = 0
            func prepare() {}
            func recognize(_ samples: [Float]) -> PichiMeetingCaptionRecognition {
                self.inputs.append(samples.count)
                return .init(text: "посмотрим дальше", endOfUtteranceProbability: nil)
            }
            func recognizeWithWordTimings(_ samples: [Float]) -> PichiMeetingCaptionRecognition {
                self.timedCalls += 1
                self.inputs.append(samples.count)
                return .init(text: "Давайте посмотр", endOfUtteranceProbability: nil, words: [
                    .init(text: "Давайте", start: 17.8, end: 18.8),
                    .init(text: "посмотр", start: 19, end: 20),
                ])
            }
            func unload() {}
        }
        let recognizer = TimedRecognizer()
        let engine = PichiMeetingBufferedTrackEngine(kind: .microphone, recognizer: recognizer)
        let events = Events()
        await self.configure(engine, events: events)
        try await engine.consumeForTesting(self.sample(start: 4, seconds: 20, value: 0.1))
        XCTAssertEqual(events.utterances.count, 1)
        XCTAssertEqual(events.utterances.first?.2, "Давайте")
        XCTAssertEqual(try XCTUnwrap(events.utterances.first?.4), 22.9, accuracy: 0.0001)
        let retained = await engine.bufferedSampleCountForTesting()
        XCTAssertEqual(retained, 17_600)
        try await engine.consumeForTesting(self.sample(start: 24, seconds: 1, value: 0.1))
        try await engine.consumeForTesting(self.sample(start: 25, seconds: 0.8, value: 0))
        XCTAssertEqual(events.utterances.map { $0.2 }, ["Давайте", "посмотрим дальше"])
        XCTAssertEqual(try XCTUnwrap(events.utterances.last?.3), 22.9, accuracy: 0.0001)
        let timedCalls = await recognizer.timedCalls
        let inputs = await recognizer.inputs
        XCTAssertEqual(timedCalls, 1, "Ordinary partials keep the fast streaming operation")
        XCTAssertTrue(inputs.allSatisfy { $0 <= 320_000 })
        await engine.stop()
    }

    func testForcedWordBoundaryRequiresCompleteExactTimingEvidence() {
        func recognition(_ text: String, _ words: [ASRWordTiming]) -> PichiMeetingCaptionRecognition {
            .init(text: text, endOfUtteranceProbability: nil, words: words)
        }
        let valid = [ASRWordTiming(text: "Ёжик", start: 17, end: 18),
                     ASRWordTiming(text: "идё", start: 19.8, end: 20)]
        let cut = recognition("  Ёжик идё  ", valid).rotation(sampleCount: 320_000, sampleRate: 16_000)
        XCTAssertEqual(cut?.text, "Ёжик")
        XCTAssertEqual(cut?.sample, 302_400)
        XCTAssertNil(recognition("Ёжик идёт ещё", valid).rotation(sampleCount: 320_000, sampleRate: 16_000),
                     "Partial alignments must not drop unmatched wording")
        XCTAssertNil(recognition("Ёжик идё", [valid[0], .init(text: "идё", start: .nan, end: 20)])
            .rotation(sampleCount: 320_000, sampleRate: 16_000))
        XCTAssertNil(recognition("Ёжикидё", valid).rotation(sampleCount: 320_000, sampleRate: 16_000),
                     "A timed BPE fragment is not a complete word boundary")
        XCTAssertNil(recognition("Ёжик идё", [.init(text: "Ёжик", start: 17, end: 19.5), valid[1]])
            .rotation(sampleCount: 320_000, sampleRate: 16_000), "The last second remains revisable")
        XCTAssertNil(recognition("Ёжик идё", [valid[0], .init(text: "идё", start: 17.9, end: 20)])
            .rotation(sampleCount: 320_000, sampleRate: 16_000), "Overlapping evidence cannot own an acoustic split")
    }

    func testClockResetDiscardsTheUncommittedBoundaryTail() async throws {
        actor TimedRecognizer: PichiMeetingCaptionRecognizing {
            var mixedEras = false
            func prepare() {}
            func recognize(_ samples: [Float]) -> PichiMeetingCaptionRecognition {
                self.mixedEras = self.mixedEras || (samples.contains(0.1) && samples.contains(0.2))
                return .init(text: "new era", endOfUtteranceProbability: nil)
            }
            func recognizeWithWordTimings(_ samples: [Float]) -> PichiMeetingCaptionRecognition {
                .init(text: "closed tail", endOfUtteranceProbability: nil, words: [
                    .init(text: "closed", start: 17, end: 18), .init(text: "tail", start: 19, end: 20),
                ])
            }
            func unload() {}
        }
        let recognizer = TimedRecognizer()
        let engine = PichiMeetingBufferedTrackEngine(kind: .microphone, recognizer: recognizer)
        let events = Events()
        await self.configure(engine, events: events)
        try await engine.consumeForTesting(self.sample(start: 4, seconds: 20, value: 0.1))
        engine.requestReset()
        try await engine.consumeForTesting(self.sample(start: 1, seconds: 1.3, value: 0.2))
        try await engine.consumeForTesting(self.sample(start: 2.3, seconds: 0.8, value: 0))
        XCTAssertEqual(events.utterances.map { $0.2 }, ["closed", "new era"])
        XCTAssertEqual(try XCTUnwrap(events.utterances.last?.3), 1, accuracy: 0.0001)
        let mixed = await recognizer.mixedEras
        XCTAssertFalse(mixed)
        await engine.stop()
    }

    func testCaptureClockGapClearsUtteranceInsteadOfJoiningSeparateEras() async throws {
        let recognizer = Recognizer()
        let engine = PichiMeetingBufferedTrackEngine(kind: .microphone, recognizer: recognizer)
        let events = Events()
        await self.configure(engine, events: events)
        try await engine.consumeForTesting(self.sample(start: 1, seconds: 1.6, value: 0.1))
        try await engine.consumeForTesting(self.sample(start: 10, seconds: 1.6, value: 0.2))
        try await engine.consumeForTesting(self.sample(start: 11.6, seconds: 0.8, value: 0))
        let utterance = try XCTUnwrap(events.utterances.first)
        XCTAssertEqual(utterance.3, 10, accuracy: 0.0001)
        let inputs = await recognizer.inputs
        XCTAssertTrue(inputs.allSatisfy { !($0.contains(0.1) && $0.contains(0.2)) })
        await engine.stop()
    }
}

#if DEBUG
/// Tracks fake model allocations through the real ASR capture handoff and buffered workers.
/// No fixture downloads weights, records a microphone, or prepares a production model.
@MainActor
final class ASRServiceMeetingCaptureResidencyTests: XCTestCase {
    private enum FixtureError: Error { case suspensionFailed }

    @MainActor private final class Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        var isOpen: Bool
        init(open: Bool = false) { self.isOpen = open }
        func wait() async {
            if self.isOpen { return }
            await withCheckedContinuation { self.waiters.append($0) }
        }
        func open() {
            self.isOpen = true
            let waiters = self.waiters
            self.waiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    @MainActor private final class Allocations {
        var models: Set<String> = ["dictation"]
        var maximum = 1
        var events: [String] = []
        func load(_ model: String) {
            self.models.insert(model)
            self.maximum = max(self.maximum, self.models.count)
            self.events.append("load:\(model)")
        }
        func unload(_ model: String) {
            guard self.models.remove(model) != nil else { return }
            self.events.append("unload:\(model)")
        }
    }

    @MainActor private final class Fixture {
        let residency = MeetingModelResidencyCoordinator()
        lazy var service = ASRService(meetingModelResidency: self.residency)
        let allocations = Allocations()
        let snapshot: MeetingResidentModel
        let suspendEntered = Gate()
        let suspendGate = Gate(open: true)
        let restoreEntered = Gate()
        let restoreGate = Gate(open: true)
        var restored: [MeetingResidentModel] = []
        var restoreWasCancelled = false
        var suspensionFails = false

        init() {
            self.snapshot = MeetingResidentModel(
                id: SettingsStore.shared.selectedSpeechModel.id,
                configuration: "original-loaded-configuration"
            )
            self.service.meetingCaptureResidencyParticipantForTesting = MeetingModelParticipant(
                owner: "speech",
                snapshot: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return self.allocations.models.contains("dictation") ? self.snapshot : nil
                },
                suspend: { [weak self] in
                    guard let self else { throw CancellationError() }
                    self.allocations.unload("dictation")
                    self.suspendEntered.open()
                    await self.suspendGate.wait()
                    if self.suspensionFails {
                        self.suspensionFails = false
                        throw FixtureError.suspensionFailed
                    }
                },
                restore: { [weak self] model in
                    guard let self else { throw CancellationError() }
                    // Production restoration also checks that the current selection still
                    // matches the value captured before retirement.
                    guard SettingsStore.shared.selectedSpeechModel.id == model.id else { return }
                    self.restoreEntered.open()
                    await self.restoreGate.wait()
                    self.restoreWasCancelled = Task.isCancelled
                    self.restored.append(model)
                    self.allocations.load("dictation")
                }
            )
        }

        func openGates() {
            self.suspendGate.open()
            self.restoreGate.open()
        }
    }

    @MainActor private final class CaptionRecognizer: PichiMeetingCaptionRecognizing {
        let allocations: Allocations
        var prepareCalls = 0
        private var loaded = false
        init(allocations: Allocations) { self.allocations = allocations }
        @MainActor func prepare() async throws {
            self.prepareCalls += 1
            guard !self.loaded else { return }
            self.loaded = true
            self.allocations.load("captions")
        }
        @MainActor func recognize(_ samples: [Float]) async throws -> PichiMeetingCaptionRecognition {
            PichiMeetingCaptionRecognition(text: "", endOfUtteranceProbability: nil)
        }
        @MainActor func unload() async {
            self.loaded = false
            self.allocations.unload("captions")
        }
    }

    @MainActor private final class WarmupProvider: TranscriptionProvider {
        let name = "Capture warmup fixture"
        let isAvailable = true
        var isReady = false
        var prepareCalls = 0
        var artifactChecks = 0
        func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {
            self.prepareCalls += 1
            self.isReady = true
        }
        func modelsExistOnDisk() -> Bool {
            self.artifactChecks += 1
            return true
        }
        func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
            ASRTranscriptionResult(text: "", confidence: 0)
        }
    }

    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return predicate()
    }

    private func makeFixture() -> Fixture {
        let fixture = Fixture()
        self.addTeardownBlock { @MainActor in fixture.openGates() }
        return fixture
    }

    func testDictationRetiresBeforeBufferedCaptionAllocationAndRestoresAfterUnload() async throws {
        let fixture = self.makeFixture()
        let lease = try fixture.service.acquireExclusiveActivity(.meeting)
        defer { fixture.service.releaseExclusiveActivity(lease) }

        try await fixture.service.suspendDictationModelsForMeetingCapture(lease)
        XCTAssertTrue(fixture.allocations.models.isEmpty, "Handoff must finish retirement before caption allocation")

        let recognizer = CaptionRecognizer(allocations: fixture.allocations)
        let microphone = PichiMeetingBufferedTrackEngine(kind: .microphone, recognizer: recognizer)
        let application = PichiMeetingBufferedTrackEngine(kind: .applicationAudio, recognizer: recognizer)
        await microphone.start()
        await application.start()
        let didPrepareBothTracks = await self.waitUntil { recognizer.prepareCalls == 2 }
        XCTAssertTrue(didPrepareBothTracks)
        XCTAssertEqual(fixture.allocations.models, ["captions"])
        XCTAssertTrue(fixture.restored.isEmpty, "Capture must keep the dictation snapshot unloaded")

        await microphone.stop()
        await application.stop()
        await recognizer.unload()
        await fixture.service.finishDictationModelsAfterMeetingCapture(lease)
        // Joining a second finish cannot restore the same snapshot twice.
        await fixture.service.finishDictationModelsAfterMeetingCapture(lease)

        XCTAssertEqual(fixture.restored, [fixture.snapshot])
        XCTAssertEqual(fixture.allocations.models, ["dictation"])
        XCTAssertEqual(fixture.allocations.maximum, 1, "Loaded dictation and caption weights must never overlap")
        XCTAssertEqual(fixture.allocations.events, ["unload:dictation", "load:captions", "unload:captions", "load:dictation"])
    }

    func testCaptureBlocksAlreadyWarmedProviderReadinessAndDownloads() async throws {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        defer { settings.selectedSpeechModel = originalModel }
        settings.selectedSpeechModel = .whisperTiny
        let fixture = self.makeFixture()
        let provider = WarmupProvider()
        fixture.service.modelProvidersForTesting[.whisperTiny] = provider
        try await fixture.service.ensureAsrReady()
        XCTAssertEqual(provider.prepareCalls, 1)

        let lease = try fixture.service.acquireExclusiveActivity(.meeting)
        defer { fixture.service.releaseExclusiveActivity(lease) }
        try await fixture.service.suspendDictationModelsForMeetingCapture(lease)
        for operation in ["readiness", "download"] {
            do {
                if operation == "readiness" {
                    try await fixture.service.ensureAsrReady()
                } else {
                    try await fixture.service.downloadModel(.whisperTiny, progressHandler: nil)
                }
                XCTFail("Capture must reject ordinary \(operation) before reaching a provider")
            } catch MeetingModelResidencyError.busy {
            } catch {
                XCTFail("Expected the capture residency admission gate, got \(error)")
            }
        }
        XCTAssertEqual(provider.prepareCalls, 1)
        XCTAssertTrue(fixture.allocations.models.isEmpty)
        await fixture.service.finishDictationModelsAfterMeetingCapture(lease)
        XCTAssertEqual(fixture.restored, [fixture.snapshot])
    }

    func testChangedSelectionSkipsProductionRestorationBeforeReplacementArtifactLookup() async throws {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        defer { settings.selectedSpeechModel = originalModel }
        settings.selectedSpeechModel = .whisperTiny
        let service = ASRService(meetingModelResidency: MeetingModelResidencyCoordinator())
        let original = WarmupProvider()
        let replacement = WarmupProvider()
        service.modelProvidersForTesting[.whisperTiny] = original
        service.modelProvidersForTesting[.whisperBase] = replacement
        try await service.ensureAsrReady()
        let lease = try service.acquireExclusiveActivity(.meeting)
        defer { service.releaseExclusiveActivity(lease) }
        try await service.suspendDictationModelsForMeetingCapture(lease)
        settings.selectedSpeechModel = .whisperBase

        await service.finishDictationModelsAfterMeetingCapture(lease)

        XCTAssertEqual(original.prepareCalls, 1)
        XCTAssertEqual(replacement.artifactChecks, 0, "The production participant must veto a changed selection before inspecting its artifacts")
        XCTAssertEqual(replacement.prepareCalls, 0)
        XCTAssertFalse(service.isAsrReady)
    }

    func testFinalResidencyRestoresCapturedSnapshotAndHandbackDoesNotRestoreAgain() async throws {
        let fixture = self.makeFixture()
        let lease = try fixture.service.acquireExclusiveActivity(.meeting)
        defer { fixture.service.releaseExclusiveActivity(lease) }
        try await fixture.service.suspendDictationModelsForMeetingCapture(lease)
        XCTAssertTrue(fixture.allocations.models.isEmpty)

        let result = try await fixture.service.withMeetingModelResidency(attemptID: UUID()) {
            XCTAssertTrue(fixture.allocations.models.isEmpty)
            fixture.allocations.load("final-transcription")
            fixture.allocations.unload("final-transcription")
            return "saved transcript"
        }
        XCTAssertEqual(result, "saved transcript")
        XCTAssertEqual(fixture.restored, [fixture.snapshot], "Final processing must receive the pre-capture snapshot")

        await fixture.service.finishDictationModelsAfterMeetingCapture(lease)

        XCTAssertEqual(fixture.restored, [fixture.snapshot], "Handback must not reload a snapshot already restored by final processing")
        XCTAssertEqual(fixture.allocations.models, ["dictation"])
        XCTAssertEqual(fixture.allocations.maximum, 1)
    }

    func testFailedAndCancelledSuspensionJoinUncancelledRestoration() async throws {
        for failure in [false, true] {
            let fixture = self.makeFixture()
            fixture.suspendGate.isOpen = false
            fixture.restoreGate.isOpen = false
            fixture.suspensionFails = failure
            let lease = try fixture.service.acquireExclusiveActivity(.meeting)
            let handoff = Task { try await fixture.service.suspendDictationModelsForMeetingCapture(lease) }
            let didEnterSuspend = await self.waitUntil { fixture.suspendEntered.isOpen }
            XCTAssertTrue(didEnterSuspend)
            if !failure { handoff.cancel() }
            fixture.suspendGate.open()
            do {
                try await handoff.value
                XCTFail("Expected suspension \(failure ? "failure" : "cancellation")")
            } catch FixtureError.suspensionFailed {
                XCTAssertTrue(failure)
            } catch is CancellationError {
                XCTAssertFalse(failure)
            }

            var finished = false
            let handback = Task {
                await fixture.service.finishDictationModelsAfterMeetingCapture(lease)
                finished = true
            }
            let didEnterRestore = await self.waitUntil { fixture.restoreEntered.isOpen }
            XCTAssertTrue(didEnterRestore)
            handback.cancel()
            // Let the cancelled caller run while restoration is deliberately parked.
            // An immediate assertion in the same actor turn cannot detect early return.
            try? await Task.sleep(nanoseconds: 20_000_000)
            XCTAssertFalse(finished, "Cleanup must stay joined to non-cooperative restoration")
            XCTAssertTrue(fixture.allocations.models.isEmpty)
            fixture.restoreGate.open()
            await handback.value

            XCTAssertTrue(finished)
            XCTAssertFalse(fixture.restoreWasCancelled)
            XCTAssertEqual(fixture.restored, [fixture.snapshot])
            XCTAssertEqual(fixture.allocations.models, ["dictation"])
            XCTAssertEqual(fixture.allocations.maximum, 1)
            fixture.service.releaseExclusiveActivity(lease)
        }
    }

    func testAudioHandoffDropsProductionGigaAMCacheBeforeReturning() async throws {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        defer { settings.selectedSpeechModel = originalModel }
        settings.selectedSpeechModel = .gigaam
        let service = ASRService(meetingModelResidency: MeetingModelResidencyCoordinator())
        weak var cached = service.fileTranscriptionProvider as? PichiGigaAMProvider
        XCTAssertNotNil(cached, "The production provider must be held by the dictation cache")
        let lease = try service.acquireExclusiveActivity(.meeting)
        self.addTeardownBlock { @MainActor in
            await service.completeMeetingAudioHandback(lease)
            service.releaseExclusiveActivity(lease)
        }

        try await service.prepareMeetingAudioHandoff(lease)

        XCTAssertNil(cached, "Audio handoff must retire cached GigaAM before caption allocation is admitted")
        XCTAssertFalse(service.isAsrReady)
        await service.completeMeetingAudioHandback(lease)
    }
}
#endif

#if arch(arm64)
final class MeetingLiveBoundaryTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Double = 0
        func now() -> Double { self.lock.withLock { self.value } }
        func set(_ value: Double) { self.lock.withLock { self.value = value } }
        func advance() { self.set(120) }
    }

    private actor Recognizer: MeetingLiveRecognizer {
        private var partial: (@Sendable (String) -> Void)?
        private var end: (@Sendable (String) -> Void)?
        private var processing = false
        private var calls = 0
        private(set) var resetDuringProcessing = false
        private(set) var finishes = 0
        let naturalEnd: Bool
        let failFinish: Bool
        init(naturalEnd: Bool = false, failFinish: Bool = false) {
            self.naturalEnd = naturalEnd
            self.failFinish = failFinish
        }

        func prepareModels() async throws {}
        func appendAudio(_ buffer: AVAudioPCMBuffer) async throws {}
        func processBufferedAudio() async throws {
            self.processing = true
            self.calls += 1
            if self.calls == 1 {
                self.partial?("hello")
                if self.naturalEnd { self.end?("hello") }
            }
            for _ in 0..<20 {
                await Task.yield()
            }
            self.processing = false
        }

        func finish() async throws -> String {
            self.finishes += 1
            if self.failFinish { throw NSError(domain: "InjectedFinishFailure", code: 1) }
            self.partial?("hello final word")
            self.end?("hello final word")
            return "hello final word"
        }

        func reset() async { self.resetDuringProcessing = self.resetDuringProcessing || self.processing }
        func resumePartial() { self.partial?("hello resumed") }
        func setEouCallback(_ callback: @escaping @Sendable (String) -> Void) async { self.end = callback }
        func setPartialTranscriptCallback(_ callback: @escaping @Sendable (String) -> Void) async { self.partial = callback }
    }

    func testNaturalEndpointWaitsUntilInferenceReturns() async throws {
        let recognizer = Recognizer(naturalEnd: true)
        let engine = MeetingLiveTrackEngine(kind: .microphone, recognizer: recognizer)
        let final = expectation(description: "One completed phrase")
        final.assertForOverFulfill = true
        await engine.configure(
            onPartial: { _, _, _, _, _ in },
            onUtterance: { _, _, text, _, _ in
                XCTAssertEqual(text, "hello")
                final.fulfill()
            },
            onDegraded: { _, _ in XCTFail("No degradation expected") },
            onReady: { _ in }
        )
        await engine.diagnosticInstallCallbacks()
        try await engine.diagnosticConsume(self.sample(at: 0))
        await fulfillment(of: [final], timeout: 1)
        let raced = await recognizer.resetDuringProcessing
        XCTAssertFalse(raced, "An EOU callback must not reset a suspended inference")
    }

    func testForcedEndpointFlushesTailWithoutDuplicateCallbacks() async throws {
        try await self.checkForcedEndpoint(failFinish: false)
    }

    func testTemporaryModelPauseCanResumeWithoutReset() async throws {
        let recognizer = Recognizer()
        let clock = Clock()
        let engine = MeetingLiveTrackEngine(kind: .microphone, recognizer: recognizer, uptime: { clock.now() }, diagnosticsEnabled: true)
        let resumed = expectation(description: "Partial resumes after a long gap without premature reset")
        await engine.configure(
            onPartial: { _, _, text, _, _ in if text == "hello resumed" { resumed.fulfill() } },
            onUtterance: { _, _, _, _, _ in XCTFail("A temporary pause must not close the phrase") },
            onDegraded: { _, _ in XCTFail("A temporary pause is not an error") },
            onReady: { _ in }
        )
        await engine.diagnosticInstallCallbacks()
        try await engine.diagnosticConsume(self.sample(at: 0))
        clock.set(6)
        try await engine.diagnosticConsume(self.sample(at: 21))
        clock.set(119.999)
        try await engine.diagnosticConsume(self.sample(at: 121))
        await recognizer.resumePartial()
        try await engine.diagnosticConsume(self.sample(at: 1.1))
        await fulfillment(of: [resumed], timeout: 1)
        let snapshot = await engine.diagnosticSnapshotValue()
        XCTAssertEqual(snapshot.resetInvocations, 0)
        XCTAssertEqual(snapshot.textPauses, 1)
        XCTAssertEqual(snapshot.textResumptions, 1)
        await engine.stop()
    }

    func testFailedFlushPreservesPartialAndReportsDegradation() async throws {
        try await self.checkForcedEndpoint(failFinish: true)
    }

    func testPauseAndResumeEventsAreSavedWithoutDebugDiagnostics() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = MeetingSession(
            configuration: MeetingCaptureConfiguration(mode: .inRoom, title: "Diagnostic test", microphone: MeetingMicrophoneIdentity(captureDeviceID: "test", displayName: "Test")),
            timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil)
        )
        let probe = try MeetingAudioComparisonProbe(session: session, directory: root)
        let clock = Clock()
        let recognizer = Recognizer()
        let engine = MeetingLiveTrackEngine(kind: .microphone, recognizer: recognizer, uptime: { clock.now() }, diagnosticsEnabled: false)
        await engine.attachComparisonProbe(probe)
        await engine.diagnosticInstallCallbacks()
        try await engine.diagnosticConsume(self.sample(at: 0))
        clock.set(6)
        try await engine.diagnosticConsume(self.sample(at: 6))
        clock.set(7)
        await recognizer.resumePartial()
        try await engine.diagnosticConsume(self.sample(at: 7))
        clock.set(127)
        try await engine.diagnosticConsume(self.sample(at: 127))
        await engine.stop()
        await probe.stop()
        let lines = try String(contentsOf: root.appendingPathComponent("events.jsonl"), encoding: .utf8).split(separator: "\n")
        let events = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertTrue(events.contains { $0["step"] as? String == "model-text-pause" })
        XCTAssertTrue(events.contains { $0["step"] as? String == "model-text-resumed" })
        XCTAssertTrue(events.contains { $0["step"] as? String == "model-flow" && ($0["detail"] as? String)?.contains("decodeCompletions=") == true })
        XCTAssertTrue(events.contains { $0["step"] as? String == "recognizer-reset" && $0["detail"] as? String == "noTextTimeout" })
        XCTAssertTrue(events.contains { $0["step"] as? String == "recognizer-reset" && $0["detail"] as? String == "stopped" })
    }

    private func checkForcedEndpoint(failFinish: Bool) async throws {
        let recognizer = Recognizer(failFinish: failFinish)
        let clock = Clock()
        let engine = MeetingLiveTrackEngine(kind: .microphone, recognizer: recognizer, uptime: { clock.now() })
        let final = expectation(description: "One completed phrase")
        final.assertForOverFulfill = true
        let degraded = expectation(description: "Flush failure reported")
        degraded.isInverted = !failFinish
        await engine.configure(
            onPartial: { _, _, _, _, _ in },
            onUtterance: { _, _, text, _, _ in
                XCTAssertEqual(text, failFinish ? "hello" : "hello final word")
                final.fulfill()
            },
            onDegraded: { _, _ in degraded.fulfill() },
            onReady: { _ in }
        )
        await engine.diagnosticInstallCallbacks()
        try await engine.diagnosticConsume(self.sample(at: 0))
        clock.advance()
        try await engine.diagnosticConsume(self.sample(at: 1))
        try await engine.diagnosticConsume(self.sample(at: 1.1))
        await fulfillment(of: [final, degraded], timeout: 0.1)
        let finishes = await recognizer.finishes
        XCTAssertEqual(finishes, 1)
        let raced = await recognizer.resetDuringProcessing
        XCTAssertFalse(raced)
        await engine.stop()
    }

    private func sample(at seconds: Double) throws -> MeetingLiveSampleCopy.Sample {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320))
        pcm.frameLength = 320
        try XCTUnwrap(pcm.floatChannelData?[0]).update(repeating: 0, count: 320)
        return .init(buffer: pcm, pts: CMTime(seconds: seconds, preferredTimescale: 16_000), duration: CMTime(value: 320, timescale: 16_000))
    }
}
#endif

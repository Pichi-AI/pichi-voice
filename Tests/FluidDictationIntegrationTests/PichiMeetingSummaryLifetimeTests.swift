@testable import FluidVoice_Debug
import Foundation
import XCTest

final class PichiMeetingSummaryLifetimeTests: XCTestCase {
    @MainActor
    func testSessionLookupReattachesLiveViewsAndReleasesIdleDocuments() {
        let services = AppServices.shared
        let id = UUID()
        var first: PichiMeetingSummaryController? = services.meetingSummaryController(for: id)
        weak var released = first
        XCTAssertTrue(first === services.meetingSummaryController(for: id))
        XCTAssertFalse(first === services.meetingSummaryController(for: UUID()))
        // Visiting another meeting must not create a duplicate for a still-open view.
        XCTAssertTrue(first === services.meetingSummaryController(for: id))
        first = nil
        XCTAssertNil(released, "Idle visited meetings must not accumulate their documents in AppServices")
    }

    @MainActor
    func testAppOwnsAdmittedJobAcrossNavigationUntilJoinedCancellation() async throws {
        let session = self.session()
        let services = AppServices.shared
        let owner = MeetingModelResidencyCoordinator()
        let asr = ASRService(meetingModelResidency: owner)
        asr.meetingModelParticipantsForTesting = []
        var controller: PichiMeetingSummaryController? = services.meetingSummaryController(for: session.id)
        weak var retained = controller
        controller?.summarize(session: session, configuration: self.configuration(), asr: asr)
        XCTAssertTrue(controller?.generating == true)
        controller = nil
        XCTAssertNotNil(retained, "The admitted job must survive destruction of its view")
        for _ in 0..<20 { _ = services.meetingSummaryController(for: UUID()) }
        XCTAssertTrue(retained === services.meetingSummaryController(for: session.id))
        // Reproduce navigation rebuilding the outer Meet view: its history selection
        // and document tab are gone, while global selection admission stays locked.
        XCTAssertNotNil(MeetingSummaryActivityCoordinator.shared.selectionLock)
        let activeSnapshot = services.activeMeetingSummarySession
        let restored = MeetingTranscriptionView.summarySessionSelection(active: activeSnapshot,
            selectedID: nil, history: [], resumed: nil)
        XCTAssertEqual(restored, session, "The active snapshot must render even before history loads or for an unsaved session")
        XCTAssertEqual(MeetingResultCanvas.visibleDocumentSection(selected: .transcript, sessionID: session.id,
            activeSummarySessionID: activeSnapshot?.id), .summary, "A disabled tab bar must not strand Cancel behind Transcript")
        let unrelated = self.session()
        XCTAssertEqual(MeetingTranscriptionView.summarySessionSelection(active: activeSnapshot,
            selectedID: unrelated.id, history: [unrelated], resumed: nil)?.id, session.id,
            "The active meeting takes precedence over stale selection of another meeting")
        XCTAssertEqual(MeetingResultCanvas.visibleDocumentSection(selected: .transcript, sessionID: unrelated.id,
            activeSummarySessionID: activeSnapshot?.id), .transcript)
        retained?.cancel()
        XCTAssertNotNil(MeetingSummaryActivityCoordinator.shared.selectionLock,
                        "Cancel requests cancellation; it must not prematurely release admission")
        for _ in 0..<100 {
            if retained == nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(retained, "The app releases its strong reference after the task drains")
        XCTAssertNil(MeetingSummaryActivityCoordinator.shared.selectionLock)
        XCTAssertFalse(owner.isExclusive)
        XCTAssertNil(services.activeMeetingSummarySession)
        XCTAssertEqual(MeetingTranscriptionView.summarySessionSelection(active: nil, selectedID: session.id,
            history: [], resumed: activeSnapshot), session, "A restored unsaved meeting must not disappear when its job settles")
        XCTAssertNil(MeetingTranscriptionView.summarySessionSelection(active: nil, selectedID: unrelated.id,
            history: [], resumed: activeSnapshot), "A retained snapshot must never appear under another meeting's selection")
    }

    @MainActor
    func testRefreshAndSettingsChangesCannotRetargetAnActiveAttempt() async throws {
        let session = self.session()
        let config = self.configuration()
        let owner = MeetingModelResidencyCoordinator()
        let asr = ASRService(meetingModelResidency: owner)
        asr.meetingModelParticipantsForTesting = []
        let entered = expectation(description: "Inference entered")
        let settled = expectation(description: "Inference drained and resources restored")
        let drain = InferenceDrain()
        let controller = PichiMeetingSummaryController(sessionID: session.id, generator: .init { _ in
            entered.fulfill()
            await drain.wait()
            throw LLMError.invalidResponse
        })
        controller.generationStateChanged = { controller in
            if !controller.generating {
                XCTAssertFalse(owner.isExclusive)
                XCTAssertNil(MeetingSummaryActivityCoordinator.shared.selectionLock)
                settled.fulfill()
            }
        }
        controller.summarize(session: session, configuration: config, asr: asr)
        await fulfillment(of: [entered], timeout: 5)
        var changedSource = session
        changedSource.transcriptSegments[0].text = "Изменённая расшифровка."
        await controller.refresh(session: changedSource, configuration: self.configuration(model: "different-model"))
        await controller.refresh(session: nil, configuration: nil)
        XCTAssertTrue(controller.generating)
        XCTAssertEqual(controller.presentedConfiguration?.cacheIdentity, config.cacheIdentity)
        XCTAssertEqual(controller.sourceSession, session)
        XCTAssertTrue(owner.isExclusive)
        // A second meeting cannot admit inference while background work owns resources.
        let other = self.session()
        let second = PichiMeetingSummaryController(sessionID: other.id)
        second.summarize(session: other, configuration: config, asr: asr)
        XCTAssertFalse(second.generating)
        controller.cancel()
        XCTAssertTrue(controller.generating)
        XCTAssertNotNil(MeetingSummaryActivityCoordinator.shared.selectionLock)
        XCTAssertTrue(owner.isExclusive)
        drain.release()
        await fulfillment(of: [settled], timeout: 5)
        XCTAssertFalse(controller.generating)
        XCTAssertNil(controller.document)
        XCTAssertNil(controller.error)
    }

    @MainActor
    func testCancellationStillSurfacesJoinedCleanupFailure() async throws {
        let session = self.session()
        let owner = MeetingModelResidencyCoordinator()
        let asr = ASRService(meetingModelResidency: owner)
        asr.meetingModelParticipantsForTesting = []
        let entered = expectation(description: "Inference entered")
        let releaseEntered = expectation(description: "Release entered after inference drained")
        let settled = expectation(description: "Cleanup failure visible after resources restored")
        let inference = InferenceDrain()
        let cleanup = InferenceDrain()
        let underlying = URLError(.cannotConnectToHost)
        let generator = PichiMeetingSummaryGenerator(complete: { _ in
            entered.fulfill()
            await inference.wait()
            throw CancellationError()
        }, prepare: { configuration in
            .init(configuration: configuration, release: {
                releaseEntered.fulfill()
                await cleanup.wait()
                throw underlying
            })
        })
        let controller = PichiMeetingSummaryController(sessionID: session.id, generator: generator)
        controller.generationStateChanged = { controller in
            if !controller.generating {
                XCTAssertFalse(owner.isExclusive)
                XCTAssertNil(MeetingSummaryActivityCoordinator.shared.selectionLock)
                settled.fulfill()
            }
        }
        controller.summarize(session: session, configuration: self.configuration(), asr: asr)
        await fulfillment(of: [entered], timeout: 5)
        controller.cancel()
        // Give the cancelled timer a chance to finish while inference stays held.
        // Its CancellationError must not mask the later release failure.
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(controller.generating)
        inference.release()
        await fulfillment(of: [releaseEntered], timeout: 5)
        XCTAssertTrue(controller.generating)
        XCTAssertTrue(owner.isExclusive)
        XCTAssertNotNil(MeetingSummaryActivityCoordinator.shared.selectionLock)
        cleanup.release()
        await fulfillment(of: [settled], timeout: 5)
        XCTAssertNil(controller.document)
        XCTAssertEqual(controller.error, PichiMeetingSummaryCleanupError(underlying: underlying).localizedDescription)
    }

    @MainActor
    func testCompletedBackgroundSummaryDisclosesTheNextDestinationWithoutChangingDocumentProvenance() async throws {
        let session = self.session()
        let local = self.configuration()
        let remote = PichiMeetingSummaryConfiguration(providerID: "remote-fixture", modelID: "remote-model",
            baseURL: "https://summary.example.invalid/v1", apiKey: "synthetic-key", language: "en")
        let segment = try XCTUnwrap(session.transcriptSegments.first)
        let document = PichiMeetingSummaryDocument(summary: [.init(text: "Обсудили отчёт.",
            evidence: [.init(segmentID: segment.id, quote: segment.text)])], decisions: [], actions: [], openQuestions: [])
        let response = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
        let asr = ASRService(meetingModelResidency: MeetingModelResidencyCoordinator())
        asr.meetingModelParticipantsForTesting = []
        let entered = expectation(description: "Local generation entered")
        let settled = expectation(description: "Local document published and saved")
        let drain = InferenceDrain()
        let controller = PichiMeetingSummaryController(sessionID: session.id, generator: .init { configuration in
            try await drain.wait(configuration: configuration) { entered.fulfill() }
            return response
        })
        controller.generationStateChanged = { controller in
            if !controller.generating { settled.fulfill() }
        }
        try await MeetingSessionStore.shared.create(session)
        controller.summarize(session: session, configuration: local, asr: asr)
        await fulfillment(of: [entered], timeout: 5)
        // Settings changed elsewhere while navigation detached this view. Refresh
        // must preserve the active attempt, but cannot hide the next destination.
        await controller.refresh(session: session, configuration: remote)
        XCTAssertEqual(controller.requestConfiguration(current: remote)?.cacheIdentity, local.cacheIdentity)
        XCTAssertEqual(controller.requestConfiguration(current: nil)?.cacheIdentity, local.cacheIdentity)
        XCTAssertEqual(drain.stages, ["map"], "The first inference stays admitted with its original destination")
        drain.release()
        await fulfillment(of: [settled], timeout: 5)
        XCTAssertFalse(controller.generating)
        XCTAssertNil(controller.error)
        XCTAssertEqual(controller.document, document)
        XCTAssertEqual(controller.requestConfiguration(current: remote)?.cacheIdentity, remote.cacheIdentity)
        XCTAssertFalse(controller.requestConfiguration(current: remote)?.isOnDevice ?? true)
        XCTAssertNil(controller.requestConfiguration(current: nil), "Old document metadata must not enable an unconfigured request")
        XCTAssertEqual(controller.documentConfiguration?.cacheIdentity, local.cacheIdentity)
        XCTAssertEqual(controller.documentConfiguration?.language, "ru", "Copy uses the saved document's language")
        XCTAssertEqual(controller.documentSourceSession, session)
        XCTAssertEqual(drain.stages, ["map", "support-review"], "One admitted generation completes both real stages without retargeting or restarting")
        XCTAssertEqual(drain.requests.map(\.model), [local.modelID, local.modelID])
        XCTAssertEqual(drain.requests.map(\.baseURL), [local.baseURL, local.baseURL])
        XCTAssertEqual(drain.requests.map(\.apiKey), [local.apiKey, local.apiKey], "Changed remote credentials must not enter the admitted local attempt")
        try await MeetingSessionStore.shared.delete(id: session.id)
    }

    @MainActor
    func testBoundControllerCannotDisplayOrGenerateAnotherMeeting() async {
        let session = self.session()
        let controller = PichiMeetingSummaryController(sessionID: session.id)
        let other = self.session()
        await controller.refresh(session: other, configuration: self.configuration())
        XCTAssertNil(controller.sourceSession)
        XCTAssertNil(controller.document)
        let asr = ASRService(meetingModelResidency: MeetingModelResidencyCoordinator())
        asr.meetingModelParticipantsForTesting = []
        controller.summarize(session: other, configuration: self.configuration(), asr: asr)
        XCTAssertFalse(controller.generating)
        XCTAssertNil(MeetingSummaryActivityCoordinator.shared.selectionLock)
    }

    private func configuration(model: String = "fixture-model") -> PichiMeetingSummaryConfiguration {
        .init(providerID: "fixture", modelID: model, baseURL: "http://127.0.0.1:11434/v1", apiKey: "", language: "ru")
    }

    private func session() -> MeetingSession {
        let microphone = MeetingMicrophoneIdentity(captureDeviceID: "fixture", displayName: "Mic")
        var session = MeetingSession(configuration: .init(mode: .inRoom, title: "Synthetic meeting", languageCode: "ru", microphone: microphone),
                                     timebase: .init(startedHostTime: 1, machTimebaseNumerator: 1, machTimebaseDenominator: 1,
                                                     firstPresentationTime: .init(value: 0, timescale: 1000)))
        let trackID = UUID()
        session.audioTracks = [.init(id: trackID, kind: .microphone, sourceIdentifier: "fixture", sourceDisplayName: "Mic",
                                     format: nil, timebase: session.timebase, health: .waiting, chunks: [])]
        session.transcriptSegments = [.init(id: UUID(), start: .init(value: 0, timescale: 1000), end: .init(value: 1000, timescale: 1000),
                                            sourceTrackID: trackID, speakerID: nil, text: "Обсудили отчёт.", revision: 0,
                                            status: .final, overlap: .none, completeness: .complete)]
        return session
    }

    @MainActor
    private final class InferenceDrain {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        private(set) var stages: [String] = []
        private(set) var requests: [LLMClient.Config] = []
        func wait(configuration: LLMClient.Config, onFirstEnter: @Sendable () -> Void) async throws {
            guard let input = configuration.messages.last?["content"] as? String,
                  let fields = try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any]
            else { throw LLMError.invalidResponse }
            self.stages.append(fields["candidate"] == nil ? "map" : "support-review")
            self.requests.append(configuration)
            if self.stages.count == 1 { onFirstEnter() }
            await self.wait()
        }
        func wait() async {
            if self.released { return }
            await withCheckedContinuation { self.continuation = $0 }
        }
        func release() {
            self.released = true
            self.continuation?.resume()
            self.continuation = nil
        }
    }
}

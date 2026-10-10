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

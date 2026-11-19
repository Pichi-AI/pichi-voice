@testable import FluidVoice_Debug
import XCTest

/// A view that appears in a hosted unit test (the FluidMeet settings sheet, the meetings view) asks the speaker
/// model store to prepare itself in the background. In the empty test home that would download the pinned
/// model from the network, and the task outlives the test: it holds the ordinary model admission until the
/// download ends, so a later test that needs an exclusive model attempt fails with "busy" (issue 191).
@MainActor
final class HostedSpeakerModelPreparationTests: XCTestCase {
    func testViewTriggeredPreparationNeitherDownloadsNorHoldsModelAdmission() async throws {
        let store = MeetingDiarizationModelStore.shared
        let before = store.state
        let heldBefore = MeetingModelResidencyCoordinator.shared.hasOrdinaryOperations
        XCTAssertFalse(heldBefore, "An earlier test left the ordinary model admission held, so this test cannot judge the guard")
        store.prepareInBackground()
        // Without the hosted-test guard the task validates the empty home and reports a download within
        // milliseconds, then takes the admission before the first download byte.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(store.state, before, "A hosted test must not start the real model preparation")
        guard !heldBefore else { return }
        XCTAssertFalse(
            MeetingModelResidencyCoordinator.shared.hasOrdinaryOperations,
            "prepareInBackground in a hosted test must not take the ordinary model admission"
        )
        try await MeetingModelResidencyCoordinator.shared.withExclusive(attemptID: UUID(), participants: []) {}
    }
}

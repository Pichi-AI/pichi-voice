@testable import PichiVoiceMobile
import XCTest

@MainActor
final class MobileMicrophoneSelectionTests: XCTestCase {
    func testExplicitMicrophoneIsPreservedWhenSystemDefaultChanges() throws {
        let tablet = MeetingMicrophoneIdentity(captureDeviceID: "tablet", displayName: "Tablet")
        let headset = MeetingMicrophoneIdentity(captureDeviceID: "headset", displayName: "Headset")
        let catalog = MeetingMicrophoneCatalogSnapshot(identities: [tablet, headset], defaultCoreAudioUID: "tablet")
        let selected = try IOSMeetingCaptureEngine.resolveDefaultMicrophone(in: catalog, preferredUID: "headset")
        XCTAssertEqual(selected.captureDeviceID, "headset")
    }

    func testDisconnectedExplicitMicrophoneCannotFallBackSilently() {
        let tablet = MeetingMicrophoneIdentity(captureDeviceID: "tablet", displayName: "Tablet")
        let catalog = MeetingMicrophoneCatalogSnapshot(identities: [tablet], defaultCoreAudioUID: "tablet")
        XCTAssertThrowsError(try IOSMeetingCaptureEngine.resolveDefaultMicrophone(in: catalog, preferredUID: "headset"))
    }

    func testAutomaticMicrophoneFollowsSystemDefault() throws {
        let tablet = MeetingMicrophoneIdentity(captureDeviceID: "tablet", displayName: "Tablet")
        let headset = MeetingMicrophoneIdentity(captureDeviceID: "headset", displayName: "Headset")
        let catalog = MeetingMicrophoneCatalogSnapshot(identities: [tablet, headset], defaultCoreAudioUID: "headset")
        let selected = try IOSMeetingCaptureEngine.resolveDefaultMicrophone(in: catalog, preferredUID: nil)
        XCTAssertEqual(selected.captureDeviceID, "headset")
    }
}

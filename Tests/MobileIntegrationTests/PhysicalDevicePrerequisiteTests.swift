import AVFoundation
@testable import PichiVoiceMobile
import XCTest

@MainActor
final class PhysicalDevicePrerequisiteTests: XCTestCase {
    func testMicrophonePermissionWithoutModelInstallation() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("This prerequisite checks the physical iPad microphone permission")
        #else
        let capture = IOSMeetingCaptureEngine()
        try await capture.preflightPermissions()
        XCTAssertEqual(AVAudioApplication.shared.recordPermission, .granted)
        await capture.shutdownForTermination()
        #endif
    }
}

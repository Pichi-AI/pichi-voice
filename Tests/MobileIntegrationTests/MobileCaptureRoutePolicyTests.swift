@preconcurrency import AVFoundation
@testable import PichiVoiceMobile
import XCTest

final class MobileCaptureRoutePolicyTests: XCTestCase {
    func testFrozenNonHFPInputsCannotBeReplacedByHandsFreeInput() {
        for port: AVAudioSession.Port in [.builtInMic, .headsetMic, .usbAudio, .lineIn, .bluetoothLE] {
            let options = IOSMeetingCaptureEngine.captureCategoryOptions(for: port)
            XCTAssertFalse(options.contains(.allowBluetoothHFP), "HFP must not replace \(port.rawValue)")
            XCTAssertTrue(options.contains(.allowBluetoothA2DP), "Bluetooth output remains eligible for \(port.rawValue)")
        }
    }

    func testExplicitHandsFreeInputRemainsEligibleWithoutCompetingA2DP() {
        let options = IOSMeetingCaptureEngine.captureCategoryOptions(for: .bluetoothHFP)
        XCTAssertTrue(options.contains(.allowBluetoothHFP))
        XCTAssertFalse(options.contains(.allowBluetoothA2DP))
    }

    func testInputPolicyPreservesPresentationMixingAndNativeOutputDefaults() {
        for port: AVAudioSession.Port in [.builtInMic, .bluetoothHFP, .usbAudio] {
            let options = IOSMeetingCaptureEngine.captureCategoryOptions(for: port)
            XCTAssertTrue(options.contains(.mixWithOthers))
            XCTAssertTrue(options.contains(.allowAirPlay))
            XCTAssertTrue(options.contains(.defaultToSpeaker))
            XCTAssertFalse(options.contains(.duckOthers))
            XCTAssertFalse(options.contains(.interruptSpokenAudioAndMixWithOthers))
        }
    }
}

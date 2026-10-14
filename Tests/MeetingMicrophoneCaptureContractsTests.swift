import Foundation

@main
struct MeetingMicrophoneCaptureContractsTests {
    static func main() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let legacy = Data("{\"kind\":\"boundVerified\",\"deviceID\":4294967295}".utf8)
        let decoded = try decoder.decode(MeetingMicrophoneBindingOutcome.self, from: legacy)
        precondition(decoded == .boundVerified(UInt32.max), "the Core Audio UInt32 device scalar must remain exact")
        let roundTrip = try JSONSerialization.jsonObject(with: encoder.encode(decoded)) as! [String: Any]
        precondition(roundTrip["kind"] as? String == "boundVerified")
        precondition((roundTrip["deviceID"] as? NSNumber)?.uint64Value == UInt64(UInt32.max))
        precondition(Set(roundTrip.keys) == ["kind", "deviceID"], "binding schema must not gain a platform wrapper")
        for binding in [MeetingMicrophoneBindingOutcome.defaultMatchesRequested, .unavailable(reason: "Synthetic device unavailable")] {
            let decodedBinding = try decoder.decode(MeetingMicrophoneBindingOutcome.self, from: encoder.encode(binding))
            precondition(decodedBinding == binding)
        }
        let identity = MeetingMicrophoneIdentity(captureDeviceID: "synthetic-mic", coreAudioUID: "synthetic-mic",
                                                displayName: "Synthetic microphone")
        let settled = MeetingMicrophoneSettledConfig(requestedMicrophone: identity, bindingOutcome: decoded,
                                                     bindingOrder: "synthetic", settledInputDeviceUID: "synthetic-mic",
                                                     settledOutputDeviceUID: nil, sourceSampleRate: 48_000,
                                                     sourceChannelCount: 1, voiceProcessingEnabled: false,
                                                     outputChannelDecision: "mono")
        let decodedSettled = try decoder.decode(MeetingMicrophoneSettledConfig.self, from: encoder.encode(settled))
        precondition(decodedSettled == settled)
        print("Shared microphone capture schema: legacy Core Audio scalar and settled-configuration round trips passed.")
    }
}

import Foundation

// Persisted metadata is shared by the application and read-only meeting helper.
// These existing codecs perform no capture, inference, settings or filesystem work.
nonisolated enum MeetingMicrophoneBindingOutcome: Equatable, Sendable {
    case boundVerified(UInt32)
    /// Bind failed but the default input already IS the requested device (Bluetooth/aggregate).
    case defaultMatchesRequested
    case unavailable(reason: String)
}

extension MeetingMicrophoneBindingOutcome: Codable {
    private enum CodingKeys: String, CodingKey { case kind, deviceID, reason }
    private enum Kind: String, Codable { case boundVerified, defaultMatchesRequested, unavailable }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .boundVerified:
            self = try .boundVerified(container.decode(UInt32.self, forKey: .deviceID))
        case .defaultMatchesRequested:
            self = .defaultMatchesRequested
        case .unavailable:
            self = try .unavailable(reason: container.decode(String.self, forKey: .reason))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .boundVerified(deviceID):
            try container.encode(Kind.boundVerified, forKey: .kind)
            try container.encode(deviceID, forKey: .deviceID)
        case .defaultMatchesRequested:
            try container.encode(Kind.defaultMatchesRequested, forKey: .kind)
        case let .unavailable(reason):
            try container.encode(Kind.unavailable, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }
}

nonisolated struct MeetingMicrophoneSettledConfig: Codable, Equatable, Sendable {
    var requestedMicrophone: MeetingMicrophoneIdentity
    var bindingOutcome: MeetingMicrophoneBindingOutcome
    /// TODO(probe): hard-code the measured winner; the alternate order is probe-only, never shipped.
    var bindingOrder: String
    var settledInputDeviceUID: String?
    var settledOutputDeviceUID: String?
    var sourceSampleRate: Double
    var sourceChannelCount: Int
    var voiceProcessingEnabled: Bool
    /// Mono is a recorded decision: SCStream's config is stereo but its mic output observed mono.
    var outputChannelDecision: String
}

nonisolated struct MeetingPostProcessingOutput: Codable, Equatable, Sendable {
    let summary: String
    let sourceSegmentIDs: [UUID]
}

nonisolated struct MeetingPostProcessingArtifact: Codable, Equatable, Sendable {
    let attemptID: UUID
    let transcriptHash: String
    let providerID: String
    let modelID: String
    let output: MeetingPostProcessingOutput?
    let error: String?
}

nonisolated struct MeetingResultSidecarReference: Codable, Equatable {
    let formatVersion: Int
    let fileName: String
    let sha256: String
    let byteCount: Int
}

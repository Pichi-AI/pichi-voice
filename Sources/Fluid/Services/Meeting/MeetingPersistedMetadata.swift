import Foundation

// Persisted metadata is shared by the application and read-only meeting helper.
// These existing codecs perform no capture, inference, settings or filesystem work.
nonisolated enum MeetingSessionDateCodec {
    // Both local persistence consumers must agree on exact reference-time Doubles.
    // Whole-second ISO encoding can shorten a capture below its final segment.
    // Portable export, publication wire bytes and fingerprints retain their own codecs.
    static let encodingStrategy: JSONEncoder.DateEncodingStrategy = .deferredToDate
    static let decodingStrategy: JSONDecoder.DateDecodingStrategy = .custom { decoder in
        let value = try decoder.singleValueContainer()
        if let referenceSeconds = try? value.decode(Double.self) {
            guard referenceSeconds.isFinite else {
                throw DecodingError.dataCorruptedError(in: value, debugDescription: "Nonfinite meeting date")
            }
            return Date(timeIntervalSinceReferenceDate: referenceSeconds)
        }
        // The value parser avoids allocating a mutable formatter for every legacy date.
        // Existing manifests/indexes are not rewritten merely because they were read.
        let text = try value.decode(String.self)
        guard let date = try? Date.ISO8601FormatStyle().parse(text) else {
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid legacy meeting date")
        }
        return date
    }
}

/// Token emission envelopes locate decoder output, not measured spoken-word boundaries.
/// A recognition owner adds source context before filtering or rebasing the native word list.
/// Missing metadata retains the older provider contract without guessing its timing basis.
nonisolated struct ASRWordTimingProvenance: Codable, Equatable, Sendable {
    enum Basis: String, Codable, Sendable { case tokenEmission }

    let basis: Basis
    let sourceWindowID: String?
    let sourceWordIndex: Int?

    init(basis: Basis, sourceWindowID: String? = nil, sourceWordIndex: Int? = nil) {
        self.basis = basis
        self.sourceWindowID = sourceWindowID
        self.sourceWordIndex = sourceWordIndex
    }

    var hasValidSourceContext: Bool {
        guard let sourceWindowID, let sourceWordIndex,
              Self.validWindowID(sourceWindowID),
              (0..<8_192).contains(sourceWordIndex) else { return false }
        return true
    }

    var isValid: Bool {
        (self.sourceWindowID == nil && self.sourceWordIndex == nil) || self.hasValidSourceContext
    }

    private static func validWindowID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Namespace the provider's original inference context, never enumerate its filtered output.
    /// Basis-only metadata stays unscoped; missing native positions cannot be reconstructed here.
    func scoped(to namespace: String) -> Self? {
        guard self.isValid, Self.validWindowID(namespace) else { return nil }
        guard let sourceWindowID, let sourceWordIndex else { return self }
        let scoped = Self(basis: self.basis, sourceWindowID: "\(namespace)/\(sourceWindowID)",
                          sourceWordIndex: sourceWordIndex)
        return scoped.hasValidSourceContext ? scoped : nil
    }
}

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

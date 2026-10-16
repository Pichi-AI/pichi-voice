import Foundation

// Shared value contracts for the app and transcript readers. This file owns no inference,
// capture, persistence or identity resolution; source tokens remain anonymous and scoped.

/// Versioned, length-framed key/value encoding so arbitrary string fields cannot collide on
/// delimiters (`asr=a@b,lang=c` vs `asr=a,lang=b@c`). Values stay human-readable; no hashing.
/// Strings are canonicalized to precomposed form because Swift `==` treats canonically
/// equivalent Unicode as equal while raw UTF8 lengths differ.
nonisolated enum MeetingConfigFingerprintEncoding {
    static let version = 1

    static func encode(_ pairs: [(key: String, value: String)]) -> String {
        let framed = pairs.map { pair in
            let key = pair.key.precomposedStringWithCanonicalMapping
            let value = pair.value.precomposedStringWithCanonicalMapping
            return "\(key.utf8.count):\(key)=\(value.utf8.count):\(value)"
        }
        return (["v\(Self.version)"] + framed).joined(separator: ";")
    }
}

nonisolated enum MeetingEvidenceInterval {
    static func isValid(start: TimeInterval, end: TimeInterval) -> Bool {
        start.isFinite && end.isFinite && start >= 0 && end > start
    }
}

nonisolated enum MeetingTextUnitPrecision: String, Codable, Sendable {
    case word
    case utterance
}

/// Analysis epoch, scoped to its track. A new epoch starts for missing audio, a real clock
/// discontinuity, a microphone device replacement or an inadmissible microphone interval, so
/// timing is never mapped across one. Speaker identity crosses an epoch only through an explicit
/// link. Encoding the track here is what makes the token-scoping check below meaningful.
nonisolated struct MeetingAnalysisEpochID: Hashable, Codable, CustomStringConvertible, Sendable {
    let trackID: MeetingAudioTrackID
    let ordinal: Int
    /// Changes when this epoch's model evidence is replayed under the same attempt. Product
    /// speaker IDs include it, so recomputed slot labels can never inherit an earlier alias merely
    /// because the track and ordinal stayed the same.
    let generation: Int

    init(trackID: MeetingAudioTrackID, ordinal: Int, generation: Int = 0) {
        self.trackID = trackID
        self.ordinal = ordinal
        self.generation = generation
    }

    var description: String {
        "\(self.trackID.uuidString)#\(self.ordinal)@\(self.generation)"
    }
}

nonisolated struct MeetingAnalysisEpochGenerationKey: Hashable {
    let trackID: MeetingAudioTrackID
    let ordinal: Int
}

/// Anonymous, backend-local speaker slot. Never a `SessionSpeakerID`: only the assembler creates
/// product speaker IDs, and never by slot equality across tracks or epochs.
nonisolated struct MeetingBackendSpeakerToken: Hashable, Codable, Sendable {
    let analysisEpochID: MeetingAnalysisEpochID
    let label: String
}

nonisolated enum MeetingBackendSpeakerAssignment: Equatable, Sendable {
    case assigned(MeetingBackendSpeakerToken)
    /// Two or more candidate slots the backend could not separate. Ambiguity is reported, never
    /// resolved by picking one.
    case ambiguous([MeetingBackendSpeakerToken])
    /// The backend produced text but no speaker evidence at all.
    case unassigned

    var tokens: [MeetingBackendSpeakerToken] {
        switch self {
        case let .assigned(token): return [token]
        case let .ambiguous(tokens): return tokens
        case .unassigned: return []
        }
    }
}

nonisolated extension MeetingBackendSpeakerAssignment: Codable {
    /// Stable keyed encoding; the raw-value `Kind` decode already throws on an unknown case,
    /// so a payload can never decode into a speaker assignment the backend never made.
    private enum CodingKeys: String, CodingKey {
        case kind
        case token
        case candidates
    }

    private enum Kind: String, Codable {
        case assigned
        case ambiguous
        case unassigned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .assigned:
            guard container.contains(.token), !container.contains(.candidates) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .kind,
                    in: container,
                    debugDescription: "An assigned speaker requires exactly one token payload."
                )
            }
            self = try .assigned(container.decode(MeetingBackendSpeakerToken.self, forKey: .token))
        case .ambiguous:
            guard container.contains(.candidates), !container.contains(.token) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .kind,
                    in: container,
                    debugDescription: "An ambiguous speaker requires only a candidates payload."
                )
            }
            self = try .ambiguous(container.decode([MeetingBackendSpeakerToken].self, forKey: .candidates))
        case .unassigned:
            guard !container.contains(.token), !container.contains(.candidates) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .kind,
                    in: container,
                    debugDescription: "An unassigned speaker cannot carry token payloads."
                )
            }
            self = .unassigned
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .assigned(token):
            try container.encode(Kind.assigned, forKey: .kind)
            try container.encode(token, forKey: .token)
        case let .ambiguous(tokens):
            try container.encode(Kind.ambiguous, forKey: .kind)
            try container.encode(tokens, forKey: .candidates)
        case .unassigned:
            try container.encode(Kind.unassigned, forKey: .kind)
        }
    }
}

/// One final timed text unit. `analysisStart`/`analysisEnd` are seconds in the unit's track's
/// gap-removed analysis stream — the domain `MeetingAnalysisSpan.analysisInterval` defines — and
/// `analysisSpanIDs` is the exact, contiguous set of manifest spans the unit's audio came from.
nonisolated struct MeetingFinalTextUnit: Equatable, Identifiable {
    /// Stable within an attempt and, for resumed ASR chunks, across retries of that attempt.
    let id: String
    let trackID: MeetingAudioTrackID
    let analysisEpochID: MeetingAnalysisEpochID
    let precision: MeetingTextUnitPrecision
    let text: String
    let analysisStart: TimeInterval
    let analysisEnd: TimeInterval
    let speaker: MeetingBackendSpeakerAssignment
    /// Exact manifest analysis spans backing this unit. Contiguous within the unit's epoch, never
    /// bridging a missing or inadmissible span; validation proves the references exist, and the
    /// quarantine classification proves their union really covers the unit's bounds.
    let analysisSpanIDs: [String]
    /// Whatever the backend actually reported. `nil` when it reports none — never substituted.
    let confidence: Double?

    init(
        id: String,
        trackID: MeetingAudioTrackID,
        analysisEpochID: MeetingAnalysisEpochID,
        precision: MeetingTextUnitPrecision,
        text: String,
        analysisStart: TimeInterval,
        analysisEnd: TimeInterval,
        speaker: MeetingBackendSpeakerAssignment,
        analysisSpanIDs: [String],
        confidence: Double? = nil
    ) {
        self.id = id
        self.trackID = trackID
        self.analysisEpochID = analysisEpochID
        self.precision = precision
        self.text = text
        self.analysisStart = analysisStart
        self.analysisEnd = analysisEnd
        self.speaker = speaker
        self.analysisSpanIDs = analysisSpanIDs
        self.confidence = confidence
    }

    /// Initial acoustic projection changes only the assignment, preserving native source facts.
    func assigningSpeaker(_ assignment: MeetingBackendSpeakerAssignment) -> Self {
        Self(id: self.id, trackID: self.trackID, analysisEpochID: self.analysisEpochID,
            precision: self.precision, text: self.text, analysisStart: self.analysisStart,
            analysisEnd: self.analysisEnd, speaker: assignment, analysisSpanIDs: self.analysisSpanIDs,
            confidence: self.confidence)
    }
}

/// Optional supporting evidence, in the same per-track analysis-time domain as the text units.
/// Its absence is not a defect, and its presence does not by itself assign any text.
nonisolated struct MeetingBackendSpeakerActivity: Equatable {
    let token: MeetingBackendSpeakerToken
    let start: TimeInterval
    let end: TimeInterval
}

nonisolated extension MeetingFinalTextUnit: Codable {}
nonisolated extension MeetingBackendSpeakerActivity: Codable {}

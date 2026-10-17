import Foundation

nonisolated enum MeetingDiarizerCheckpointError: Error { case invalidCheckpoint }

/// Optional, backend-owned continuation of one stopped recording's diarizer state.
/// The owner binds the opaque bytes to the immutable recording and model artifact before
/// storing or restoring them. Implementations validate their own format and source length.
/// Checkpoints can contain model features and a bounded PCM frontend tail, so the owner may
/// persist them only for recordings whose audio retention policy permits durable audio.
nonisolated protocol MeetingResumableNemotronDiarizerSession: MeetingNemotronDiarizerSession {
    func diarize(
        source: any MeetingPCMReplaySource,
        restoring: Data?,
        checkpoint: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> [MeetingNemotronSpeakerSegment]
}

/// A byte-size cap alone cannot bound expanded plist arrays: references to one scalar
/// can repeat cheaply. Check declared counts before materializing checkpoint buffers.
nonisolated enum MeetingDiarizerCheckpointDecoding {
    static func array<Value: Decodable, Key: CodingKey>(
        _ type: Value.Type, from container: KeyedDecodingContainer<Key>,
        forKey key: Key, maximumCount: Int
    ) throws -> [Value] {
        var values = try container.nestedUnkeyedContainer(forKey: key)
        if let count = values.count, count > maximumCount {
            throw DecodingError.dataCorrupted(.init(codingPath: values.codingPath,
                                                    debugDescription: "Checkpoint array exceeds capacity"))
        }
        var result: [Value] = []
        result.reserveCapacity(values.count ?? 0)
        while !values.isAtEnd {
            guard result.count < maximumCount else {
                throw DecodingError.dataCorrupted(.init(codingPath: values.codingPath,
                                                        debugDescription: "Checkpoint array exceeds capacity"))
            }
            result.append(try values.decode(Value.self))
        }
        return result
    }
}

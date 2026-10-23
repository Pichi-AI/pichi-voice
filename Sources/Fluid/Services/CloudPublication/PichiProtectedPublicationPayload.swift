import CoreFoundation
import Foundation

nonisolated enum PichiProtectedPublicationPayload {
    enum Failure: String, Error, Sendable { case emptyTranscript, invalidTranscript, limitExceeded }

    /// Durable recovery supplies exact bytes, not a re-encoded transcript. This bounded
    /// structural allowlist prevents another internal/audio export from reaching transport.
    /// It does not prove native completeness, redaction quality or N2 capture ownership.
    static func validate(_ data: Data) throws -> Set<UUID> {
        try Task.checkCancellation()
        guard data.count <= 750_000 else { throw Failure.limitExceeded }
        guard data.count > 0, String(data: data, encoding: .utf8) != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["format", "schemaVersion", "sessionID", "title", "languageCode", "startedAt", "endedAt", "durationSeconds", "speakers", "segments", "privacy"]),
              object["format"] as? String == "pichi-voice-transcript", self.number(object["schemaVersion"]) == 1,
              let session = object["sessionID"] as? String, UUID(uuidString: session) != nil,
              let title = object["title"] as? String, title.utf16.count <= 200,
              let language = object["languageCode"] as? String, language.utf16.count <= 35,
              let started = object["startedAt"] as? String, let ended = object["endedAt"] as? String,
              let startDate = ISO8601DateFormatter().date(from: started), let endDate = ISO8601DateFormatter().date(from: ended), endDate >= startDate,
              let duration = self.number(object["durationSeconds"]), duration >= 0,
              let privacy = object["privacy"] as? [String: Any], Set(privacy.keys) == Set(["transcriptPIIRedacted", "includesAudio", "metadataMayContainPersonalData"]),
              self.boolean(privacy["transcriptPIIRedacted"]) == true, self.boolean(privacy["includesAudio"]) == false,
              self.boolean(privacy["metadataMayContainPersonalData"]) == true,
              let speakers = object["speakers"] as? [[String: Any]], let segments = object["segments"] as? [[String: Any]], segments.count <= 10_000 else {
            throw Failure.invalidTranscript
        }
        guard duration <= 86_400, speakers.count <= 100 else { throw Failure.limitExceeded }
        guard !segments.isEmpty else { throw Failure.emptyTranscript }
        var speakerIDs = Set<UUID>()
        for speaker in speakers {
            try Task.checkCancellation()
            guard Set(speaker.keys).isSubset(of: ["id", "displayName", "isLocalUser", "identityIsProvisional"]),
                  let id = speaker["id"] as? String, let uuid = UUID(uuidString: id), speakerIDs.insert(uuid).inserted,
                  let name = speaker["displayName"] as? String, name.utf16.count <= 200,
                  self.boolean(speaker["isLocalUser"]) != nil,
                  speaker["identityIsProvisional"] == nil || self.boolean(speaker["identityIsProvisional"]) != nil else {
                throw Failure.invalidTranscript
            }
        }
        var represented = Set<UUID>(), segmentIDs = Set<UUID>(), textUnits = 0
        for segment in segments {
            try Task.checkCancellation()
            guard Set(segment.keys).isSubset(of: ["id", "startSeconds", "endSeconds", "speakerID", "text"]),
                  let id = segment["id"] as? String, let uuid = UUID(uuidString: id), segmentIDs.insert(uuid).inserted,
                  let start = self.number(segment["startSeconds"]), let end = self.number(segment["endSeconds"]), start >= 0, end > start,
                  let text = segment["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.invalidTranscript }
            textUnits += text.utf16.count
            guard textUnits <= 100_000 else { throw Failure.limitExceeded }
            if let raw = segment["speakerID"] {
                guard let id = raw as? String, let uuid = UUID(uuidString: id), speakerIDs.contains(uuid) else {
                    throw Failure.invalidTranscript
                }
                represented.insert(uuid)
            }
        }
        return represented
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}

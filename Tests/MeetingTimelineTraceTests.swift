import Foundation

@main struct MeetingTimelineTraceTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: message, code: 1) }
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try require(!MeetingTimelineTrace.enabled && MeetingTimelineTrace.shared == nil, "default-disabled")
        try require(!FileManager.default.fileExists(atPath: root.path), "disabled-no-file")
        let trace = MeetingTimelineTrace(directory: root, limits: .init(events: 3, fileBytes: 8_192,
            queuedEvents: 16, queuedBytes: 65_536))
        trace.record("asr_hypothesis", fields: ["sourceOffsetSample": "16000", "sealed": "false"], text: "Synthetic private example",
            words: [.init(text: "Synthetic", start: 0.1, end: 0.4)])
        trace.record("asr_hypothesis", fields: ["sealed": "true"], text: "Synthetic revised example")
        trace.record("protected_publication", fields: ["transcriptRevision": "1"])
        trace.record("must_drop")
        await trace.finish()
        trace.record("later-user-meeting", text: "must-not-enter-closed-trace")
        try require(trace.status.closed, "terminal-close")
        let data = try Data(contentsOf: trace.fileURL)
        let rows = try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
        try require(rows.first?["kind"] as? String == "trace_start", "schema-header")
        try require(rows.first?["schema"] as? Int == 1, "schema-version")
        try require(rows.filter { $0["kind"] as? String == "asr_hypothesis" }.count == 2, "all-returned-revisions")
        try require(rows.last?["kind"] as? String == "trace_status", "terminal-counters")
        try require(trace.status.accepted == 3 && trace.status.written == 3 && trace.status.dropped == 1, "event-bound")
        try require(data.count <= 8_192, "file-byte-bound")
        let attributes = try FileManager.default.attributesOfItem(atPath: trace.fileURL.path)
        try require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "private-file-mode")
        let blocked = MeetingTimelineTrace(directory: root.appendingPathComponent("blocked"),
            limits: .init(events: 10, fileBytes: 8_192, queuedEvents: 0, queuedBytes: 0))
        blocked.record("capture_pcm", text: "must-not-be-written")
        await blocked.flush()
        try require(blocked.status.dropped == 1 && !FileManager.default.fileExists(atPath: blocked.fileURL.path), "queue-overflow-no-IO")
        let clipped = MeetingTimelineTrace(directory: root.appendingPathComponent("clipped"),
            limits: .init(events: 10, fileBytes: 4_096, queuedEvents: 16, queuedBytes: 1_048_576))
        clipped.record("oversize", text: String(repeating: "x", count: 60_000))
        clipped.record("after-oversize")
        await clipped.flush()
        try require(clipped.status.truncated == 1 && clipped.status.dropped >= 1, "truncation-and-file-overflow-accounted")
        let clippedData = try Data(contentsOf: clipped.fileURL)
        try require(clippedData.count <= 4_096, "hard-file-cap")
        print("MeetingTimelineTrace: default-disabled/private-format/event-byte-queue-limits passed")
    }
}

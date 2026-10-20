import Foundation

/// Explicit local investigation only. This private cache is deliberately separate from
/// DebugLogger, support exports and meeting persistence because hypotheses may contain PII.
/// It never receives PCM. Calls copy bounded values then enqueue without capture-side IO.
final nonisolated class MeetingTimelineTrace: @unchecked Sendable {
    static let enabled = ProcessInfo.processInfo.environment["PICHI_MEETING_TIMELINE_PROFILE"] == "1"
    static let shared: MeetingTimelineTrace? = enabled ? MeetingTimelineTrace() : nil
    /// Explicit segment identity only. Never select a diagnostic target from transcript text.
    static let readingTargetWordID: UUID? = enabled
        ? ProcessInfo.processInfo.environment["PICHI_MEETING_READING_TARGET_WORD_ID"].flatMap(UUID.init(uuidString:)) : nil

    struct Word: Codable, Sendable {
        let text: String
        let start: Double
        let end: Double
        var wordID: String? = nil
        var speakerID: String? = nil
    }
    struct Limits: Sendable {
        var events = 30_000
        var fileBytes = 16 * 1_024 * 1_024
        var queuedEvents = 512
        var queuedBytes = 1_024 * 1_024
    }
    struct Status: Sendable {
        let accepted: Int
        let written: Int
        let dropped: Int
        let truncated: Int
        let writeFailed: Bool
        let closed: Bool
        let flushTimedOut: Bool
    }
    private struct Event: Encodable, Sendable {
        let schema = 1
        let runID: UUID
        let sequence: Int
        let uptimeSeconds: Double
        let kind: String
        let fields: [String: String]
        let text: String?
        let words: [Word]?
    }
    private let id = UUID()
    private let queue = DispatchQueue(label: "meeting.private-timeline", qos: .utility)
    private let lock = NSLock()
    private let limits: Limits
    private let directory: URL
    private var pending: [(Event, Int)] = []
    private var pendingBytes = 0
    private var scheduled = false
    private var accepted = 0
    private var written = 0
    private var dropped = 0
    private var truncated = 0
    private var writeFailed = false
    private var closed = false
    private var claimedSession: String?
    private var flushTimedOut = false
    // Writer queue owns the file and byte count. Capacity reserves a final status marker.
    private var file: FileHandle?
    private var fileBytes = 0
    private var opened = false
    private var fileFull = false
    let fileURL: URL

    init(directory: URL? = nil, limits: Limits = .init()) {
        let root = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingTimelineTrace", isDirectory: true)
        self.directory = root
        self.limits = limits
        self.fileURL = root.appendingPathComponent("\(id.uuidString).private.jsonl")
    }

    func record(_ kind: String, fields: [String: String] = [:], text: String? = nil, words: [Word] = []) {
        // Timestamp belongs to the caller, never to delayed disk IO.
        let uptime = ProcessInfo.processInfo.systemUptime
        var clipped = false
        func bounded(_ value: String, _ count: Int) -> String {
            if value.utf8.count <= count { return value }
            clipped = true
            // Prefixing Unicode scalars preserves UTF-8 validity and bounds storage.
            return String(String.UnicodeScalarView(value.unicodeScalars.prefix(count / 4)))
        }
        var metadata: [String: String] = [:]
        for key in fields.keys.sorted().prefix(40) {
            metadata[bounded(key, 96)] = bounded(fields[key]!, 2_048)
        }
        if fields.count > 40 { clipped = true }
        let safeText = text.map { bounded($0, 32_768) }
        let safeWords = words.prefix(256).compactMap { word -> Word? in
            guard word.start.isFinite, word.end.isFinite else { clipped = true; return nil }
            return Word(text: bounded(word.text, 512), start: word.start, end: word.end,
                wordID: word.wordID.map { bounded($0, 128) }, speakerID: word.speakerID.map { bounded($0, 128) })
        }
        if words.count > 256 { clipped = true }
        if clipped { metadata["payloadTruncated"] = "true" }
        let estimate = 2_048 + metadata.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
            + (safeText?.utf8.count ?? 0) + safeWords.reduce(0) { $0 + $1.text.utf8.count + 128 }
        let start = lock.withLock { () -> Bool in
            guard !closed else { return false }
            guard !writeFailed, accepted < max(0, limits.events), pending.count < max(0, limits.queuedEvents),
                  estimate <= max(0, limits.queuedBytes) - pendingBytes else { dropped += 1; return false }
            accepted += 1
            if clipped { truncated += 1 }
            pending.append((Event(runID: id, sequence: accepted, uptimeSeconds: uptime,
                kind: String(kind.prefix(96)), fields: metadata, text: safeText,
                words: safeWords.isEmpty ? nil : safeWords), estimate))
            pendingBytes += estimate
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        if start { queue.async { [self] in drain() } }
    }

    /// A process can investigate only its first admitted meeting. This also protects a later
    /// user recording if an unusual terminal path failed to reach its explicit finish hook.
    func claimSession(_ sessionID: String) async {
        let admitted = lock.withLock { () -> Bool in
            guard !closed else { return false }
            if let claimedSession { return claimedSession == sessionID }
            claimedSession = sessionID
            return true
        }
        if !admitted { await finish() }
        else { record("meeting_scope", fields: ["sessionID": sessionID]) }
    }

    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
        func complete(before: () -> Void = {}) {
            let reply = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                guard let value = continuation else { return nil }
                before(); continuation = nil; return value
            }
            reply?.resume()
        }
    }

    /// Diagnostic IO never blocks the product indefinitely. Timeout does not claim a complete
    /// file: the owned writer still closes later and records the timeout in its final marker.
    func flush() async { await joinWriter(close: false) }
    func finish() async {
        lock.withLock { closed = true }
        await joinWriter(close: true)
    }
    private func joinWriter(close: Bool) async {
        await withCheckedContinuation { continuation in
            let reply = Reply(continuation)
            queue.async { [self] in
                drain()
                writeStatus()
                try? file?.synchronize()
                if close { try? file?.close(); file = nil }
                reply.complete()
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [self] in
                reply.complete {
                    lock.withLock { flushTimedOut = true }
                    FileHandle.standardError.write(Data("meeting_timeline_flush_timed_out=true\n".utf8))
                }
            }
        }
    }
    var status: Status {
        lock.withLock { .init(accepted: accepted, written: written, dropped: dropped,
            truncated: truncated, writeFailed: writeFailed, closed: closed, flushTimedOut: flushTimedOut) }
    }
    private func drain() {
        while let next = lock.withLock({ () -> Event? in
            guard !pending.isEmpty else { scheduled = false; return nil }
            let item = pending.removeFirst(); pendingBytes -= item.1; return item.0
        }) {
            do {
                if !opened { try open() }
                let data = try encode(next)
                guard !fileFull, data.count <= max(0, limits.fileBytes - 2_048 - fileBytes) else {
                    fileFull = true; lock.withLock { dropped += 1 }; continue
                }
                try file?.write(contentsOf: data)
                fileBytes += data.count
                lock.withLock { written += 1 }
            } catch {
                lock.withLock { writeFailed = true; dropped += pending.count + 1; pending.removeAll(); pendingBytes = 0 }
                // Metadata only. Do not forward a filesystem/provider error or payload into support logs.
                FileHandle.standardError.write(Data("meeting_timeline_write_failed=true\n".utf8))
            }
        }
    }
    private func open() throws {
        opened = true
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var root = directory
        var resources = URLResourceValues(); resources.isExcludedFromBackup = true
        try root.setResourceValues(resources)
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil,
            attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        file = try FileHandle(forWritingTo: fileURL)
        let metadata = Event(runID: id, sequence: 0, uptimeSeconds: ProcessInfo.processInfo.systemUptime,
            kind: "trace_start", fields: ["sourceRevision": Bundle.main.object(forInfoDictionaryKey: "AppSourceRevision") as? String ?? "unavailable",
                "clock": "process-systemUptime-seconds", "cpuScope": "whole-process", "memoryScope": "whole-process-physical-footprint",
                "hypothesisScope": "returned-model-results-only-no-internal-beam-alternatives", "audioPersisted": "false",
                "maximumEvents": String(limits.events), "maximumFileBytes": String(limits.fileBytes)], text: nil, words: nil)
        let data = try encode(metadata)
        guard data.count <= max(0, limits.fileBytes - 2_048) else { throw CocoaError(.fileWriteOutOfSpace) }
        try file?.write(contentsOf: data); fileBytes += data.count
    }
    private func writeStatus() {
        guard opened, !status.writeFailed, let file else { return }
        let counters = status
        let marker = Event(runID: id, sequence: counters.accepted, uptimeSeconds: ProcessInfo.processInfo.systemUptime,
            kind: "trace_status", fields: ["accepted": String(counters.accepted), "written": String(counters.written),
                "dropped": String(counters.dropped), "truncated": String(counters.truncated), "fileLimitReached": String(fileFull),
                "closed": String(counters.closed), "flushTimedOut": String(counters.flushTimedOut)], text: nil, words: nil)
        do {
            let data = try encode(marker)
            guard data.count <= max(0, limits.fileBytes - fileBytes) else { return }
            try file.write(contentsOf: data); fileBytes += data.count
        } catch { lock.withLock { writeFailed = true } }
    }
    private func encode(_ event: Event) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(event); data.append(0x0A); return data
    }
}

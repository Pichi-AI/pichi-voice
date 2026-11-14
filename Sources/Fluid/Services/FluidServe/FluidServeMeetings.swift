import Darwin
import Foundation

/// Read-only view of saved meetings for the `fv-serve` command.
///
/// Shares the persisted meeting and grounded-summary codecs with the application.
/// The helper never prepares models, captures audio or writes application data.
nonisolated enum FluidServeMeetings {
    static let toolName = "fv-serve"
    static let accessDefaultsKey = "FluidServeMeetingAccessEnabled"

    struct Speaker: Decodable, Equatable {
        var id: UUID
        var displayName: String
        var isLocalUser: Bool
        var mergedIntoSpeakerID: UUID?
    }

    struct MediaTime: Decodable, Equatable {
        var value: Int64
        var timescale: Int32

        var seconds: TimeInterval {
            self.timescale > 0 ? TimeInterval(self.value) / TimeInterval(self.timescale) : 0
        }
    }

    /// Keeps the canonical segment beside the compatibility fields. The reader never reconstructs
    /// a speaker decision from a reduced DTO or substitutes a presentation choice for evidence.
    struct Segment: Equatable {
        fileprivate let source: MeetingTranscriptSegment

        var start: MediaTime { .init(value: self.source.start.value, timescale: self.source.start.timescale) }
        var end: MediaTime { .init(value: self.source.end.value, timescale: self.source.end.timescale) }
        var speakerID: UUID? { self.source.speakerID }
        var text: String { self.source.text }
        var isLikelyEcho: Bool? { self.source.isLikelyEcho }
        var attributionState: String? { self.source.attributionState?.rawValue }
    }

    struct Meeting: Decodable, Equatable {
        fileprivate let source: MeetingSession
        fileprivate let speakerNames: [SessionSpeakerID: String]
        fileprivate let speakerPresentations: [MeetingTranscriptSegmentID: MeetingSpeakerPresentation]

        init(source: MeetingSession) {
            self.source = source
            self.speakerNames = Dictionary(source.activeSpeakers.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
            self.speakerPresentations = MeetingTranscriptExporter.speakerPresentations(in: source)
        }

        init(from decoder: Decoder) throws {
            self.init(source: try MeetingSession(from: decoder))
        }

        var id: UUID { self.source.id }
        var title: String { self.source.title }
        var languageCode: String { self.source.languageCode }
        var startedAt: Date { self.source.startedAt }
        var endedAt: Date? { self.source.endedAt }
        var state: String { self.source.state.rawValue }
        var speakers: [Speaker] {
            self.source.speakers.map {
                .init(id: $0.id, displayName: $0.displayName, isLocalUser: $0.isLocalUser,
                      mergedIntoSpeakerID: $0.mergedIntoSpeakerID)
            }
        }
        var transcriptSegments: [Segment] { self.source.transcriptSegments.map { .init(source: $0) } }

        /// Turns the reader prints: echoes of the other side dropped, oldest first. Equal native
        /// bounds keep source order, matching the shared exporter's chronological projection.
        var turns: [Segment] {
            self.source.transcriptSegments
                .enumerated().filter { !$0.element.isEcho }
                .sorted { ($0.element.start, $0.element.end, $0.offset) < ($1.element.start, $1.element.end, $1.offset) }
                .map { .init(source: $0.element) }
        }

        var activeSpeakers: [Speaker] {
            self.speakers.filter { $0.mergedIntoSpeakerID == nil }
        }

        /// A meeting that was interrupted has no end time; its last turn is the best measure of its length.
        var durationSeconds: TimeInterval {
            if let endedAt = self.endedAt { return max(0, endedAt.timeIntervalSince(self.startedAt)) }
            return self.turns.map(\.end.seconds).max() ?? 0
        }

        /// A meeting that is still being recorded or processed is not served.
        var isFinished: Bool {
            ["completed", "interrupted", "failed"].contains(self.state)
        }
    }

    struct SavedSummary: Equatable {
        var style: String
        var text: String
        var modelName: String?
        var generatedAt: Date?
    }

    // Word-level provenance can exceed 4 MiB in an ordinary long meeting. A single manifest
    // may use the whole existing command-wide 64 MiB read budget; that aggregate cap, the
    // session/entry limits and the no-follow descriptor checks remain unchanged.
    static let maximumManifestBytes = 64 * 1024 * 1024
    static let maximumSummaryBytes = 2 * 1024 * 1024
    static let maximumDirectoryEntries = 1024
    static let maximumSessions = 256
    static let maximumTotalReadBytes = 64 * 1024 * 1024

    struct Entry: Equatable {
        var meeting: Meeting
        var directory: URL
        fileprivate let source: MeetingSession
        fileprivate let ownedRoot: URL
        fileprivate let rootIdentity: FluidServeFileBoundary.Identity
        fileprivate let directoryIdentity: FluidServeFileBoundary.Identity
        fileprivate let budget: FluidServeFileBoundary.Budget
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.meeting == rhs.meeting && lhs.directory == rhs.directory
                && lhs.rootIdentity == rhs.rootIdentity && lhs.directoryIdentity == rhs.directoryIdentity
        }
    }

    struct SearchHit: Equatable {
        var meeting: Meeting
        var line: String
    }

    enum ReadError: LocalizedError, Equatable {
        case accessOff
        case accessUnavailable
        case noMeetings
        case notFound(String)
        case ambiguous(String, Int)

        var errorDescription: String? {
            switch self {
            case .accessOff:
                return "Meeting sharing is off. Open the application's meeting settings > Integrations and add your agent."
            case .accessUnavailable:
                return "Could not verify application meeting-sharing permission. The setting may be unset or blocked by a sandbox. "
                    + "Check meeting settings > Integrations; if sharing is on, check the agent's sandbox permissions. No meeting data was read."
            case .noMeetings:
                return "No finished meetings with a transcript were found."
            case let .notFound(reference):
                return "No meeting matches \"\(reference)\". Run `\(FluidServeMeetings.toolName) meet list` to see the ids."
            case let .ambiguous(reference, count):
                return "\"\(reference)\" matches \(count) meetings. Use more characters of the id."
            }
        }
    }

    /// The enclosing app supplies its trusted AppBrand.storageNamespace. The
    /// helper resolves that same bundle identifier from its real executable path.
    static func defaultRoot(storageNamespace: String, fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent(storageNamespace, isDirectory: true)
            .appendingPathComponent("Meetings", isDirectory: true)
    }

    /// This increment serves legacy guest data only. Missing marker preserves existing guest
    /// installations; every malformed, concealed or account marker denies all private reads.
    /// The bounded no-follow reader is shared with meeting manifests.
    static func guestAccessToken(root: URL) throws -> Data {
        struct Marker: Decodable {
            let schemaVersion: Int
            let profileID: String
            let generation: UUID
            let isReadable: Bool
        }
        let legacy: FluidServeFileBoundary.Directory
        do { legacy = try .open(root.deletingLastPathComponent()) }
        catch FluidServeFileBoundary.Rejection.missing { return Data() }
        let profiles: FluidServeFileBoundary.Directory
        do { profiles = try legacy.child("Profiles") }
        catch FluidServeFileBoundary.Rejection.missing { return Data() }
        guard let file = try profiles.read("active-profile-v1.json", maximumBytes: 4_096) else { return Data() }
        guard let marker = try? JSONDecoder().decode(Marker.self, from: file.data),
              marker.schemaVersion == 1, marker.profileID == "guest", marker.isReadable else {
            throw ReadError.accessOff
        }
        return file.data
    }

    /// Reads the switch the way the app itself sees it (including a value an administrator has forced),
    /// but through CFPreferences rather than `UserDefaults`, which would also honour a
    /// `-FluidServeMeetingAccessEnabled YES` argument and let a caller switch it on.
    /// This is a consent switch, not a lock: anything running as the user could read the files anyway.
    /// A missing value cannot distinguish an unset preference from a sandbox-denied read.
    /// Only an explicit true grants access; nil is unknown, not proof that sharing is off.
    static func isAccessEnabled(bundleIdentifier: String) -> Bool? {
        guard (try? self.guestAccessToken(root: self.defaultRoot(storageNamespace: bundleIdentifier))) != nil else { return false }
        return CFPreferencesCopyAppValue(self.accessDefaultsKey as CFString, bundleIdentifier as CFString) as? Bool
    }

    static let customSummaryPromptDefaultsKey = "MeetingSummaryCustomPrompt"

    /// The prompt in the app's custom-summary box, needed to tell whether a saved custom summary is still the current one.
    static func customSummaryPrompt(bundleIdentifier: String) -> String {
        guard (try? self.guestAccessToken(root: self.defaultRoot(storageNamespace: bundleIdentifier))) != nil else { return "" }
        return (CFPreferencesCopyAppValue(self.customSummaryPromptDefaultsKey as CFString, bundleIdentifier as CFString) as? String) ?? ""
    }

    /// This Mac's time zone as the app sees it. A `TZ` variable in an agent's shell must not change
    /// which summaries count as current, so the zone is read from the system setting, not the environment.
    static func systemTimeZone(fileManager: FileManager = .default) -> TimeZone {
        if let target = try? fileManager.destinationOfSymbolicLink(atPath: "/etc/localtime"),
           let range = target.range(of: "/zoneinfo/"),
           let zone = TimeZone(identifier: String(target[range.upperBound...]))
        {
            return zone
        }
        return .current
    }

    // MARK: - Reading

    /// Compatibility convenience for presentation/tests. The actual command uses
    /// checkedEntries so unsafe paths and exceeded bounds produce a failure status.
    static func entries(root: URL, since: Date? = nil, fileManager: FileManager = .default) -> [Entry] {
        (try? self.checkedEntries(root: root, since: since)) ?? []
    }

    static func checkedEntries(root: URL, since: Date? = nil) throws -> [Entry] {
        _ = try self.guestAccessToken(root: root)
        let owned: FluidServeFileBoundary.Directory
        do { owned = try .open(root) }
        catch FluidServeFileBoundary.Rejection.missing { return [] }
        let budget = FluidServeFileBoundary.Budget(maximumBytes: self.maximumTotalReadBytes)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = MeetingSessionDateCodec.decodingStrategy
        var entries: [Entry] = []
        var inspected = 0
        for name in try owned.names(maximumEntries: self.maximumDirectoryEntries) {
            guard let id = UUID(uuidString: name) else { continue }
            inspected += 1
            guard inspected <= self.maximumSessions else { throw FluidServeFileBoundary.Rejection.limitExceeded }
            let directory = try owned.child(name)
            guard let file = try directory.read("session.json", maximumBytes: self.maximumManifestBytes, budget: budget),
                  let session = try? decoder.decode(MeetingSession.self, from: file.data),
                  session.id == id,
                  (try? session.validateTranscriptStructure()) != nil else { continue }
            let meeting = Meeting(source: session)
            guard meeting.isFinished, !session.transcriptSegments.allSatisfy(\.isEcho) else { continue }
            if let since, meeting.startedAt < since { continue }
            entries.append(Entry(meeting: meeting, directory: root.appendingPathComponent(name), source: session,
                ownedRoot: root, rootIdentity: owned.identity, directoryIdentity: directory.identity, budget: budget))
        }
        return entries.sorted { $0.meeting.startedAt > $1.meeting.startedAt }
    }

    /// `reference` is `latest`, a full id, or the first characters of one.
    static func resolve(_ reference: String, in entries: [Entry]) throws -> Entry {
        guard !entries.isEmpty else { throw ReadError.noMeetings }
        let wanted = reference.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if wanted.isEmpty || wanted == "latest" { return entries[0] }
        let matches = entries.filter { $0.meeting.id.uuidString.lowercased().hasPrefix(wanted) }
        switch matches.count {
        case 1: return matches[0]
        case 0: throw ReadError.notFound(reference)
        default: throw ReadError.ambiguous(reference, matches.count)
        }
    }

    /// Saved summaries the app itself would still show for this meeting: written by a known provider,
    /// for the transcript as it is now, and (for a custom summary) with the prompt as it is now.
    /// A summary from before an edit, a speaker rename or a prompt change is left out.
    static func savedSummaries(for entry: Entry, customPrompt: String = "", fileManager: FileManager = .default) -> [SavedSummary] {
        (try? self.checkedSavedSummaries(for: entry, customPrompt: customPrompt)) ?? []
    }

    static func checkedSavedSummaries(for entry: Entry, customPrompt: String = "") throws -> [SavedSummary] {
        _ = try self.guestAccessToken(root: entry.ownedRoot)
        guard entry.directory.deletingLastPathComponent().pathComponents == entry.ownedRoot.pathComponents,
              UUID(uuidString: entry.directory.lastPathComponent) == entry.meeting.id else { throw FluidServeFileBoundary.Rejection.unsafe }
        let root = try FluidServeFileBoundary.Directory.open(entry.ownedRoot)
        guard root.identity == entry.rootIdentity else { throw FluidServeFileBoundary.Rejection.changed }
        let directory = try root.child(entry.directory.lastPathComponent)
        guard directory.identity == entry.directoryIdentity else { throw FluidServeFileBoundary.Rejection.changed }
        struct Stored: Decodable {
            var transcriptHash: String
            var transcriptHashVersion: Int?
            var text: String
            var promptHash: String?
            var providerID: String?
            var promptVersion: Int?
            var providerName: String?
            var modelName: String?
            var generatedAt: Date?
        }
        let prefix = "manual-summary-"
        let names = try directory.names(maximumEntries: self.maximumDirectoryEntries)
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") }
        let timeZone = self.systemTimeZone()
        let legacyHash = MeetingSummaryInput.fingerprint(MeetingSummaryInput.transcript(for: entry.source, timeZone: timeZone))
        let contentHash = MeetingSummaryInput.contentFingerprint(for: entry.source, timeZone: timeZone)
        let customPromptHash = MeetingSummaryInput.fingerprint(customPrompt.trimmingCharacters(in: .whitespacesAndNewlines))
        var summaries = try names.compactMap { name -> SavedSummary? in
            let style = String(name.dropFirst(prefix.count).dropLast(".json".count))
            guard let file = try directory.read(name, maximumBytes: self.maximumSummaryBytes, budget: entry.budget),
                  let stored = try? JSONDecoder().decode(Stored.self, from: file.data),
                  stored.providerID != nil, stored.promptVersion == MeetingSummaryInput.currentPromptVersion,
                  stored.promptHash == (style == "custom" ? customPromptHash : nil),
                  !stored.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            let currentHash: String
            switch stored.transcriptHashVersion {
            case nil: currentHash = legacyHash
            case 2: currentHash = contentHash
            default: return nil
            }
            guard stored.transcriptHash == currentHash else { return nil }
            return SavedSummary(
                style: style,
                text: stored.text,
                modelName: stored.modelName ?? stored.providerName,
                generatedAt: stored.generatedAt
            )
        }
        if let file = try directory.read("pichi-meeting-summary.json", maximumBytes: self.maximumSummaryBytes, budget: entry.budget),
           let artifact = try? JSONDecoder().decode(PichiMeetingSummaryArtifact.self, from: file.data),
           let current = try? artifact.validated(for: entry.source) {
            summaries.append(SavedSummary(style: "sources",
                text: current.document.copyMarkdown(language: .english, sources: PichiMeetingSummaryInput.turns(for: entry.source)),
                modelName: nil, generatedAt: current.generatedAt))
        }
        return summaries
    }

    // MARK: - Rendering

    /// Reuses the full meeting's reading-owner projection for JSON, search and single lines.
    static func speakerLabel(for segment: Segment, in meeting: Meeting) -> String {
        if let presentation = meeting.speakerPresentations[segment.source.id] {
            return MeetingTranscriptExporter.speakerLabel(for: presentation)
        }
        return MeetingTranscriptExporter.speakerLabel(for: segment.source, in: meeting.source,
                                                      speakerNames: meeting.speakerNames)
    }

    /// Additive CLI JSON projection. The canonical exporter resolves speaker aliases and preserves
    /// native precision and attribution provenance. One ID index avoids a source scan per word.
    static func jsonTurns(for meeting: Meeting, from: TimeInterval? = nil, to: TimeInterval? = nil) throws -> [[String: Any]] {
        let data = try MeetingTranscriptExporter.json(for: meeting.source)
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let segments = document["segments"] as? [[String: Any]] else {
            throw CocoaError(.coderReadCorrupt)
        }
        var exportedByID: [String: [String: Any]] = [:]
        exportedByID.reserveCapacity(segments.count)
        for segment in segments {
            guard let id = segment["id"] as? String else { throw CocoaError(.coderReadCorrupt) }
            exportedByID[id] = segment
        }
        return try meeting.turns.filter { segment in
            segment.start.seconds >= (from ?? 0) && segment.start.seconds <= (to ?? .infinity)
        }.map { segment in
            guard var object = exportedByID[segment.source.id.uuidString] else { throw CocoaError(.coderReadCorrupt) }
            object["speaker"] = Self.speakerLabel(for: segment, in: meeting)
            return object
        }
    }

    static func timestampText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    static func line(for segment: Segment, in meeting: Meeting) -> String {
        "[\(self.timestampText(segment.start.seconds))] \(self.speakerLabel(for: segment, in: meeting)): \(segment.text)"
    }

    /// The shared readable projection groups timed fragments without discarding their evidence.
    /// A range still includes turns by their native start, matching the existing CLI options.
    static func transcript(for meeting: Meeting, from: TimeInterval? = nil, to: TimeInterval? = nil) -> String {
        if from == nil, to == nil {
            return MeetingTranscriptExporter.text(for: meeting.source)
        }
        let segmentIDs = Set(meeting.turns.filter { segment in
            if let from, segment.start.seconds < from { return false }
            if let to, segment.start.seconds > to { return false }
            return true
        }.map { $0.source.id })
        return MeetingTranscriptExporter.text(for: meeting.source, segmentIDs: segmentIDs)
    }

    static func header(for entry: Entry, timeZone: TimeZone = .current) -> String {
        let meeting = entry.meeting
        let speakers = meeting.activeSpeakers.map(\.displayName).joined(separator: ", ")
        return """
        Title: \(meeting.title)
        Id: \(meeting.id.uuidString)
        Date: \(self.dateText(meeting.startedAt, timeZone: timeZone))
        Length: \(self.lengthText(meeting.durationSeconds))
        Speakers: \(speakers.isEmpty ? "unknown" : speakers)
        """
    }

    static func listing(
        _ entries: [Entry],
        customPrompt: String = "",
        timeZone: TimeZone = .current,
        fileManager: FileManager = .default
    ) throws -> String {
        guard !entries.isEmpty else { return "No finished meetings with a transcript were found." }
        var rows = [["ID", "DATE", "LENGTH", "SPEAKERS", "TITLE", "SUMMARIES"]]
        for entry in entries {
            let meeting = entry.meeting
            let summaries = try self.checkedSavedSummaries(for: entry, customPrompt: customPrompt).map(\.style)
            rows.append([
                String(meeting.id.uuidString.prefix(8)),
                self.dateText(meeting.startedAt, timeZone: timeZone),
                self.lengthText(meeting.durationSeconds),
                String(meeting.activeSpeakers.count),
                meeting.title,
                summaries.isEmpty ? "-" : summaries.joined(separator: ", "),
            ])
        }
        // Widths are counted in characters and cells are only ever widened, so an emoji or a long
        // value is never cut. The last column is left unpadded.
        let widths = (0..<5).map { column in rows.map { $0[column].count }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { index, cell in
                index < widths.count ? cell + String(repeating: " ", count: widths[index] - cell.count) : cell
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }

    /// Case-insensitive search through transcripts, newest meeting first, stopping at `limit` lines.
    static func search(_ query: String, in entries: [Entry], limit: Int) -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, limit > 0 else { return [] }
        var hits: [SearchHit] = []
        for entry in entries {
            for segment in entry.meeting.turns where segment.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                hits.append(SearchHit(meeting: entry.meeting, line: self.line(for: segment, in: entry.meeting)))
                if hits.count == limit { return hits }
            }
        }
        return hits
    }

    static func dateText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    static func lengthText(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes < 1 ? "<1 min" : "\(minutes) min"
    }

    // MARK: - Arguments

    /// `90`, `12:30` or `1:02:03` as seconds from the start of the meeting.
    static func seconds(fromClock text: String) -> TimeInterval? {
        let fields = text.split(separator: ":", omittingEmptySubsequences: false)
        let parts = fields.compactMap { Int($0) }.filter { $0 >= 0 }
        guard !parts.isEmpty, parts.count <= 3, parts.count == fields.count else { return nil }
        var seconds = 0
        for part in parts {
            let multiplied = seconds.multipliedReportingOverflow(by: 60)
            guard !multiplied.overflow else { return nil }
            let added = multiplied.partialValue.addingReportingOverflow(part)
            guard !added.overflow else { return nil }
            seconds = added.partialValue
        }
        return TimeInterval(seconds)
    }

    /// `7d`, `24h` or `2026-10-01` as the earliest start time to include.
    static func sinceDate(from text: String, now: Date = Date(), timeZone: TimeZone = .current) -> Date? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let unit = value.last, let amount = Double(value.dropLast()), amount >= 0 {
            switch unit {
            case "d": return now.addingTimeInterval(-amount * 86_400)
            case "h": return now.addingTimeInterval(-amount * 3600)
            default: break
            }
        }
        // Four-digit year only: "26-1-1" would otherwise parse as the year 26 and filter nothing.
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.isLenient = false
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
}

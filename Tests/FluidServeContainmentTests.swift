import Darwin
import Foundation

/// Synthetic filesystem boundary regression. Each command runs in a child process
/// so a FIFO regression is reported within a deadline instead of hanging the suite.
@main
struct FluidServeContainmentTests {
    private static let foreignSentinel = "ForeignFixtureMustNeverBeServed7E6B"
    private static let transcriptSentinel = "ValidSyntheticTranscript35A2"
    private static let summarySentinel = "ValidSyntheticGroundedSummaryA89C"
    private static let manifestLimit = 4 * 1024 * 1024
    private static let summaryLimit = 2 * 1024 * 1024
    private static let directoryLimit = 1024
    private static let sessionLimit = 256
    private static let manager = FileManager.default

    private struct Failure: Error, CustomStringConvertible { let description: String }
    private struct Report: Codable {
        let commandExit: Int32
        let foreign: Bool
        let transcript: Bool
        let summary: Bool
        let meetings: Int?
        let entries: Int?
        let summaries: Int?
    }
    private struct Fixture {
        let base: URL
        let root: URL
        let directory: URL
        let session: MeetingSession
    }
    private struct Case {
        let name: String
        let run: (URL) throws -> Int
    }

    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--command" || arguments.first == "--public" {
            try self.child(arguments)
            return
        }
        let cases = self.cases()
        let selected: [Case]
        if arguments.count == 2, arguments.first == "--only" {
            selected = cases.filter { $0.name == arguments[1] }
            guard !selected.isEmpty else { throw Failure(description: "Unknown case") }
        } else {
            guard arguments.isEmpty else { throw Failure(description: "Use --only <case> to select one regression") }
            selected = cases
        }
        let canonical = try self.canonicalTemporaryDirectory()
        let base = canonical.appendingPathComponent("fluidserve-containment-" + UUID().uuidString, isDirectory: true)
        try self.manager.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? self.manager.removeItem(at: base) }
        var checks = 0
        var failures = 0
        for test in selected {
            let directory = base.appendingPathComponent(test.name, isDirectory: true)
            try self.manager.createDirectory(at: directory, withIntermediateDirectories: false)
            do {
                checks += try test.run(directory)
                print("PASS \(test.name)")
            } catch {
                failures += 1
                print("FAIL \(test.name): \(error)")
            }
        }
        print("FluidServe containment: \(selected.count) cases, \(checks) checks, \(failures) failures")
        if failures != 0 { exit(1) }
    }

    private static func canonicalTemporaryDirectory() throws -> URL {
        guard let path = realpath(self.manager.temporaryDirectory.path, nil) else {
            throw Failure(description: "Cannot resolve the existing temporary directory")
        }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    private static func child(_ arguments: [String]) throws {
        guard arguments.count >= 2 else { throw Failure(description: "Missing owned fixture root") }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let report: Report
        if arguments[0] == "--public" {
            let entries = FluidServeMeetings.entries(root: root)
            let summaries = entries.flatMap { FluidServeMeetings.savedSummaries(for: $0) }
            report = Report(commandExit: 0, foreign: summaries.contains { $0.text.contains(self.foreignSentinel) }
                            || entries.contains { $0.meeting.title.contains(self.foreignSentinel) },
                            transcript: false, summary: false, meetings: nil,
                            entries: entries.count, summaries: summaries.count)
        } else {
            let result = FluidServeCommand.run(arguments: Array(arguments.dropFirst(2)), root: root,
                                              accessEnabled: true, now: Date(timeIntervalSince1970: 1_700_000_000),
                                              timeZone: TimeZone(secondsFromGMT: 0)!)
            let object = (try? JSONSerialization.jsonObject(with: Data(result.output.utf8))) as? [String: Any]
            report = Report(commandExit: result.exitCode, foreign: result.output.contains(self.foreignSentinel),
                            transcript: result.output.contains(self.transcriptSentinel),
                            summary: result.output.contains(self.summarySentinel), meetings: object?["meetings"] as? Int,
                            entries: nil, summaries: nil)
        }
        print(String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
    }

    private static func command(_ root: URL, _ arguments: [String], publicRead: Bool = false) throws -> Report {
        let process = Process()
        let output = Pipe()
        let completion = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.arguments = [publicRead ? "--public" : "--command", root.path] + arguments
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { _ in completion.signal() }
        try process.run()
        guard completion.wait(timeout: .now() + 3) == .success else {
            process.terminate()
            if completion.wait(timeout: .now() + 0.25) != .success {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + 1)
            }
            throw Failure(description: "Command exceeded its 3-second deadline")
        }
        guard process.terminationStatus == 0 else {
            throw Failure(description: "Command crashed instead of returning a boundary error")
        }
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        guard bytes.count < 4096 else { throw Failure(description: "Unexpected child report size") }
        do { return try JSONDecoder().decode(Report.self, from: bytes) }
        catch { throw Failure(description: "Command did not return a complete report") }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(description: message) }
    }

    private static func reject(_ root: URL, commands: [[String]], publicEntries: Int? = nil) throws -> Int {
        var checks = 0
        for arguments in commands {
            let report = try self.command(root, arguments)
            try self.require(!report.foreign, "Command exposed foreign fixture content")
            try self.require(report.commandExit != 0, "Unsafe input was reported as success for \(arguments.joined(separator: " "))")
            checks += 2
        }
        if let publicEntries {
            let report = try self.command(root, [], publicRead: true)
            try self.require(report.entries == publicEntries, "Convenience entries must fail closed")
            try self.require(report.summaries == 0 && !report.foreign, "Convenience summaries must fail closed")
            checks += 2
        }
        return checks
    }

    private static var manifestCommands: [[String]] {
        [["meet", "list", "--json"], ["status", "--json"], ["meet", "show", "latest", "--json"],
         ["meet", "search", self.foreignSentinel]]
    }
    private static var summaryCommands: [[String]] {
        [["meet", "summary", "latest"], ["meet", "list", "--json"], ["meet", "show", "latest", "--json"]]
    }

    private static func fixture(_ base: URL, text: String = transcriptSentinel) throws -> Fixture {
        let root = base.appendingPathComponent("Meetings", isDirectory: true)
        try self.manager.createDirectory(at: root, withIntermediateDirectories: true)
        let timebase = MeetingTimebaseMetadata(startedHostTime: 1, machTimebaseNumerator: 1,
                                               machTimebaseDenominator: 1, firstPresentationTime: .init(value: 0, timescale: 1))
        var session = MeetingSession(configuration: .init(mode: .inRoom, title: text,
                                      microphone: .init(captureDeviceID: "synthetic-mic", displayName: "Synthetic microphone")),
                                     startedAt: Date(timeIntervalSince1970: 1_700_000_000), timebase: timebase)
        let trackID = UUID()
        let speakerID = UUID()
        session.audioTracks = [.init(id: trackID, kind: .microphone, sourceIdentifier: "synthetic-mic",
                                    sourceDisplayName: "Synthetic microphone", format: nil, timebase: timebase,
                                    health: .waiting, chunks: [])]
        session.speakers = [.init(id: speakerID, displayName: "Synthetic speaker", diarizationClusterID: nil,
                                 trackKind: .microphone, isLocalUser: true, identityCandidates: [])]
        session.transcriptSegments = [.init(id: UUID(), start: .init(value: 1, timescale: 1), end: .init(value: 5, timescale: 1),
                                           sourceTrackID: trackID, speakerID: speakerID, text: text, revision: 0,
                                           status: .final, overlap: .none, completeness: .complete)]
        session.state = .completed
        session.endedAt = session.startedAt.addingTimeInterval(60)
        let directory = root.appendingPathComponent(session.id.uuidString, isDirectory: true)
        try self.manager.createDirectory(at: directory, withIntermediateDirectories: false)
        try self.save(session, to: directory.appendingPathComponent("session.json"))
        return Fixture(base: base, root: root, directory: directory, session: session)
    }

    private static func sessionBytes(_ session: MeetingSession) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(session)
    }
    private static func save(_ session: MeetingSession, to path: URL) throws {
        try self.sessionBytes(session).write(to: path)
    }
    private static func artifact(_ fixture: Fixture, text: String = summarySentinel) throws -> Data {
        let segment = fixture.session.transcriptSegments[0]
        let document = PichiMeetingSummaryDocument(summary: [.init(text: text,
            evidence: [.init(segmentID: segment.id, quote: segment.text)])], decisions: [], actions: [], openQuestions: [])
        let artifact = PichiMeetingSummaryArtifact(version: 6, transcriptHash: PichiMeetingSummaryInput.fingerprint(fixture.session),
            configurationIdentity: "synthetic-configuration", generatedAt: Date(timeIntervalSince1970: 1_700_000_030), document: document)
        return try JSONEncoder().encode(artifact)
    }
    private static func manualSummary(_ fixture: Fixture, text: String = foreignSentinel) throws -> Data {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meeting = try decoder.decode(FluidServeMeetings.Meeting.self, from: self.sessionBytes(fixture.session))
        return try JSONSerialization.data(withJSONObject: [
            "transcriptHash": FluidServeMeetings.fingerprint(FluidServeMeetings.summaryInput(for: meeting)),
            "text": text, "providerID": "synthetic-provider", "modelName": "synthetic-model",
        ], options: .sortedKeys)
    }
    private static func replace(_ path: URL, withSymlinkTo target: URL) throws {
        if self.manager.fileExists(atPath: path.path) { try self.manager.removeItem(at: path) }
        try self.manager.createSymbolicLink(at: path, withDestinationURL: target)
    }
    private static func sparse(_ path: URL, bytes: Int) throws {
        try Data().write(to: path)
        let file = try FileHandle(forWritingTo: path)
        defer { try? file.close() }
        try file.truncate(atOffset: UInt64(bytes))
    }
    private static func emptyFiles(_ directory: URL, count: Int) throws {
        for index in 0..<count { try Data().write(to: directory.appendingPathComponent("ignored-\(index)")) }
    }

    private static func cases() -> [Case] {
        var cases: [Case] = []
        cases.append(Case(name: "valid-pichi-artifact") { base in
            let fixture = try self.fixture(base)
            let path = fixture.directory.appendingPathComponent("pichi-meeting-summary.json")
            let artifact = try self.artifact(fixture)
            try artifact.write(to: path)
            let manifest = try Data(contentsOf: fixture.directory.appendingPathComponent("session.json"))
            let report = try self.command(fixture.root, ["meet", "summary", "latest"])
            try self.require(report.commandExit == 0 && report.summary && report.transcript && !report.foreign,
                             "The actual current Pichi artifact and its literal sources remain readable")
            let publicReport = try self.command(fixture.root, [], publicRead: true)
            try self.require(publicReport.entries == 1 && publicReport.summaries == 1, "Shared codec continuity")
            try self.require(try Data(contentsOf: path) == artifact, "Summary remains unchanged")
            try self.require(try Data(contentsOf: fixture.directory.appendingPathComponent("session.json")) == manifest, "Transcript remains unchanged")
            return 4
        })
        cases.append(Case(name: "escaped-session-directory") { base in
            let own = try self.fixture(base.appendingPathComponent("own"))
            let foreign = try self.fixture(base.appendingPathComponent("foreign"), text: self.foreignSentinel)
            try self.replace(own.root.appendingPathComponent(foreign.directory.lastPathComponent), withSymlinkTo: foreign.directory)
            return try self.reject(own.root, commands: self.manifestCommands, publicEntries: 0)
        })
        cases.append(Case(name: "escaped-manifest") { base in
            let own = try self.fixture(base.appendingPathComponent("own"))
            let foreign = try self.fixture(base.appendingPathComponent("foreign"), text: self.foreignSentinel)
            try self.replace(own.directory.appendingPathComponent("session.json"), withSymlinkTo: foreign.directory.appendingPathComponent("session.json"))
            return try self.reject(own.root, commands: self.manifestCommands, publicEntries: 0)
        })
        for name in ["pichi", "manual"] {
            cases.append(Case(name: "escaped-\(name)-summary") { base in
                let fixture = try self.fixture(base)
                let foreign = base.appendingPathComponent("foreign-summary.json")
                let data = name == "pichi" ? try self.artifact(fixture, text: self.foreignSentinel) : try self.manualSummary(fixture)
                try data.write(to: foreign)
                let name = name == "pichi" ? "pichi-meeting-summary.json" : "manual-summary-executive.json"
                try self.replace(fixture.directory.appendingPathComponent(name), withSymlinkTo: foreign)
                return try self.reject(fixture.root, commands: self.summaryCommands, publicEntries: 1)
            })
        }
        for name in ["root", "ancestor"] {
            cases.append(Case(name: "escaped-\(name)") { base in
                let foreign = try self.fixture(base.appendingPathComponent("foreign"), text: self.foreignSentinel)
                let link = base.appendingPathComponent("link", isDirectory: true)
                try self.replace(link, withSymlinkTo: name == "root" ? foreign.root : foreign.base)
                let root = name == "root" ? link : link.appendingPathComponent("Meetings", isDirectory: true)
                return try self.reject(root, commands: self.manifestCommands, publicEntries: 0)
            })
        }
        for name in ["manifest", "pichi", "manual"] {
            for kind in ["fifo", "directory", "dense-oversized", "sparse-oversized", "hardlink"] {
                cases.append(Case(name: "\(name)-\(kind)") { base in
                    let fixture = try self.fixture(base)
                    let fileName = name == "manifest" ? "session.json" : name == "pichi" ? "pichi-meeting-summary.json" : "manual-summary-executive.json"
                    let path = fixture.directory.appendingPathComponent(fileName)
                    if self.manager.fileExists(atPath: path.path) { try self.manager.removeItem(at: path) }
                    switch kind {
                    case "fifo":
                        try self.require(mkfifo(path.path, 0o600) == 0, "Create owned FIFO")
                    case "directory":
                        try self.manager.createDirectory(at: path, withIntermediateDirectories: false)
                    case "dense-oversized":
                        try Data(repeating: 0x20, count: (name == "manifest" ? self.manifestLimit : self.summaryLimit) + 1).write(to: path)
                    case "sparse-oversized":
                        try self.sparse(path, bytes: 1024 * 1024 * 1024)
                    case "hardlink":
                        let foreign = base.appendingPathComponent("foreign-hardlink.json")
                        let bytes = name == "manifest" ? try self.sessionBytes(fixture.session)
                            : name == "pichi" ? try self.artifact(fixture, text: self.foreignSentinel) : try self.manualSummary(fixture)
                        try bytes.write(to: foreign)
                        try self.require(link(foreign.path, path.path) == 0, "Create owned hardlink")
                    default: throw Failure(description: "Unknown fixture kind")
                    }
                    return try self.reject(fixture.root, commands: name == "manifest" ? self.manifestCommands : self.summaryCommands,
                                           publicEntries: name == "manifest" ? 0 : 1)
                })
            }
        }
        cases.append(Case(name: "root-directory-limit") { base in
            let fixture = try self.fixture(base)
            try self.emptyFiles(fixture.root, count: self.directoryLimit)
            return try self.reject(fixture.root, commands: self.manifestCommands, publicEntries: 0)
        })
        cases.append(Case(name: "summary-directory-limit") { base in
            let fixture = try self.fixture(base)
            try self.emptyFiles(fixture.directory, count: self.directoryLimit)
            return try self.reject(fixture.root, commands: self.summaryCommands, publicEntries: 1)
        })
        cases.append(Case(name: "session-limit") { base in
            let fixture = try self.fixture(base)
            for _ in 0..<self.sessionLimit {
                var session = fixture.session
                session.id = UUID()
                let directory = fixture.root.appendingPathComponent(session.id.uuidString, isDirectory: true)
                try self.manager.createDirectory(at: directory, withIntermediateDirectories: false)
                try self.save(session, to: directory.appendingPathComponent("session.json"))
            }
            return try self.reject(fixture.root, commands: self.manifestCommands, publicEntries: 0)
        })
        cases.append(Case(name: "exact-session-limit-is-readable") { base in
            let fixture = try self.fixture(base)
            for _ in 0..<(self.sessionLimit - 1) {
                var session = fixture.session
                session.id = UUID()
                let directory = fixture.root.appendingPathComponent(session.id.uuidString, isDirectory: true)
                try self.manager.createDirectory(at: directory, withIntermediateDirectories: false)
                try self.save(session, to: directory.appendingPathComponent("session.json"))
            }
            let report = try self.command(fixture.root, ["status", "--json"])
            try self.require(report.commandExit == 0 && report.meetings == self.sessionLimit,
                             "The allowed session boundary must preserve every valid session")
            return 1
        })
        cases.append(Case(name: "total-read-limit") { base in
            let fixture = try self.fixture(base)
            for index in 0..<22 {
                var session = fixture.session
                if index != 0 { session.id = UUID() }
                let directory = fixture.root.appendingPathComponent(session.id.uuidString, isDirectory: true)
                try self.manager.createDirectory(at: directory, withIntermediateDirectories: true)
                var bytes = try self.sessionBytes(session)
                bytes.append(Data(repeating: 0x20, count: 3 * 1024 * 1024 - bytes.count))
                try bytes.write(to: directory.appendingPathComponent("session.json"))
            }
            return try self.reject(fixture.root, commands: [["status", "--json"], ["meet", "show", "latest"]], publicEntries: 0)
        })
        let malformed: [(String, (inout MeetingSession) -> Void)] = [
            ("duplicate-speakers", { $0.speakers.append($0.speakers[0]) }),
            ("duplicate-segments", { $0.transcriptSegments.append($0.transcriptSegments[0]) }),
            ("invalid-timescale", { $0.transcriptSegments[0].start.timescale = 0 }),
            ("overflow-time", { $0.transcriptSegments[0].end.value = Int64.max }),
            ("reversed-time", { $0.transcriptSegments[0].end.value = 0 }),
            ("invalid-source-track", { $0.transcriptSegments[0].sourceTrackID = UUID() }),
            ("invalid-speaker-reference", { $0.transcriptSegments[0].speakerID = UUID() }),
            ("duplicate-track", { $0.audioTracks.append($0.audioTracks[0]) }),
            ("invalid-session-time", { $0.endedAt = $0.startedAt.addingTimeInterval(-1) }),
        ]
        for (name, mutate) in malformed {
            cases.append(Case(name: name) { base in
                let fixture = try self.fixture(base)
                var session = fixture.session
                mutate(&session)
                try self.save(session, to: fixture.directory.appendingPathComponent("session.json"))
                // Structural corruption is skipped by listing; selecting its missing
                // meeting or summary must return an ordinary failure without a crash.
                return try self.reject(fixture.root, commands: [["meet", "show", "latest"], ["meet", "summary", "latest"]], publicEntries: 0)
            })
        }
        cases.append(Case(name: "exact-directory-limit-is-readable") { base in
            let fixture = try self.fixture(base)
            try self.emptyFiles(fixture.root, count: self.directoryLimit - 1)
            try self.emptyFiles(fixture.directory, count: self.directoryLimit - 1)
            let report = try self.command(fixture.root, ["meet", "show", "latest", "--json"])
            try self.require(report.commandExit == 0 && report.transcript, "The allowed directory boundary must not truncate valid data")
            return 1
        })
        return cases
    }
}

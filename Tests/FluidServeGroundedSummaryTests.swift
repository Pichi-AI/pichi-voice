import Darwin
import Foundation

@main
struct FluidServeGroundedSummaryTests {
    static func main() throws {
        let manager = FileManager.default
        guard let physical = realpath(manager.temporaryDirectory.path, nil) else { fatalError("Missing fixture parent") }
        defer { free(physical) }
        let base = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("pichi-serve-regression-" + UUID().uuidString)
        let root = base.appendingPathComponent("Meetings")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            checks += 1
        }
        let ordinaryClocks: [(String, TimeInterval)] = [("90", 90), ("12:30", 750), ("1:02:03", 3723)]
        let overflowClocks = ["\(Int.max):59", "\(Int.max / 60):\(Int.max % 60 + 1)"]
        for (text, expected) in ordinaryClocks {
            check(FluidServeMeetings.seconds(fromClock: text) == expected, "Ordinary clock semantics are preserved")
        }
        check(FluidServeMeetings.seconds(fromClock: "\(Int.max)") == TimeInterval(Int.max), "Largest single clock field remains valid")
        check(FluidServeMeetings.seconds(fromClock: "\(Int.max / 60):\(Int.max % 60)") == TimeInterval(Int.max), "Largest accumulated clock remains valid")
        for text in overflowClocks {
            check(FluidServeMeetings.seconds(fromClock: text) == nil, "Overflowing clock arithmetic is rejected")
        }
        func time(_ seconds: Int64) -> MeetingMediaTime { .init(value: seconds, timescale: 1) }
        var session = MeetingSession(configuration: .init(mode: .inRoom, title: "Synthetic fixture", microphone: .init(captureDeviceID: "fixture", displayName: "Fixture microphone")),
                                     startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                     timebase: .init(startedHostTime: 1, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: time(0)))
        session.state = .completed
        session.endedAt = session.startedAt.addingTimeInterval(60)
        let speakerID = UUID()
        session.speakers = [.init(id: speakerID, displayName: "Fixture speaker", diarizationClusterID: nil, trackKind: .microphone, isLocalUser: false, identityCandidates: [])]
        let trackID = UUID()
        session.audioTracks = [.init(id: trackID, kind: .microphone, sourceIdentifier: "fixture", sourceDisplayName: "Fixture microphone",
                                     format: nil, timebase: session.timebase, health: .waiting, chunks: [])]
        let segment = MeetingTranscriptSegment(id: UUID(), start: time(1), end: time(5), sourceTrackID: trackID, speakerID: speakerID,
            text: "Synthetic source quote.", revision: 0, status: .final, overlap: .none, completeness: .complete)
        session.transcriptSegments = [segment]
        let directory = root.appendingPathComponent(session.id.uuidString)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        func saveSession() throws {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(session).write(to: directory.appendingPathComponent("session.json"))
        }
        var document = PichiMeetingSummaryDocument(summary: [.init(text: "Grounded fixture summary", evidence: [.init(segmentID: segment.id, quote: segment.text)])], decisions: [], actions: [], openQuestions: [])
        func saveArtifact(hash: String? = nil, version: Int = 6) throws {
            let artifact = PichiMeetingSummaryArtifact(version: version, transcriptHash: hash ?? PichiMeetingSummaryInput.fingerprint(session), configurationIdentity: "synthetic", generatedAt: Date(timeIntervalSince1970: 1_700_000_030), document: document)
            try JSONEncoder().encode(artifact).write(to: directory.appendingPathComponent("pichi-meeting-summary.json"))
        }
        try saveSession(); try saveArtifact()
        let sourceBytes = try Data(contentsOf: directory.appendingPathComponent("session.json"))
        let artifactBytes = try Data(contentsOf: directory.appendingPathComponent("pichi-meeting-summary.json"))
        let entries = try FluidServeMeetings.checkedEntries(root: root)
        check(entries.count == 1, "Saved session must be readable")
        let summaries = try FluidServeMeetings.checkedSavedSummaries(for: entries[0])
        check(summaries.count == 1 && summaries[0].style == "sources", "Actual Pichi artifact must be discovered")
        check(summaries[0].text == document.copyMarkdown(language: .english, sources: PichiMeetingSummaryInput.turns(for: session)), "CLI must reuse canonical Markdown rendering")
        check(summaries[0].text.contains("Synthetic source quote"), "Literal source citation is preserved")
        let result = FluidServeCommand.run(arguments: ["meet", "summary", "latest"], root: root, accessEnabled: true)
        check(result.exitCode == 0 && result.output.contains("Grounded fixture summary"), "Actual command must expose the Pichi summary")
        check(try Data(contentsOf: directory.appendingPathComponent("session.json")) == sourceBytes, "Source remains immutable")
        check(try Data(contentsOf: directory.appendingPathComponent("pichi-meeting-summary.json")) == artifactBytes, "Artifact remains immutable")
        check(FluidServeCommand.run(arguments: ["meet", "summary", "latest"], root: root, accessEnabled: false).exitCode == 2, "Consent must remain closed")
        try saveArtifact(hash: "stale")
        check(FluidServeMeetings.savedSummaries(for: entries[0]).isEmpty, "Stale transcript is rejected")
        try saveArtifact(version: 5)
        check(FluidServeMeetings.savedSummaries(for: entries[0]).isEmpty, "Old artifact version is rejected")
        document.summary[0].evidence = [.init(segmentID: UUID(), quote: segment.text)]
        try saveArtifact()
        check(FluidServeMeetings.savedSummaries(for: entries[0]).isEmpty, "Unknown citation is rejected")
        document.summary[0].evidence = [.init(segmentID: segment.id, quote: "Not in source")]
        try saveArtifact()
        check(FluidServeMeetings.savedSummaries(for: entries[0]).isEmpty, "Nonliteral citation is rejected")
        document.summary[0].evidence = [.init(segmentID: segment.id, quote: segment.text)]
        try saveArtifact()
        session.speakers[0].displayName = "Renamed speaker"
        try saveSession()
        check(FluidServeMeetings.savedSummaries(for: FluidServeMeetings.entries(root: root)[0]).isEmpty, "Speaker rename invalidates the artifact")
        try saveArtifact()
        check(FluidServeMeetings.savedSummaries(for: FluidServeMeetings.entries(root: root)[0]).count == 1, "Regenerated artifact is current")

        let suiteName = "ai.pichi.fluidserve-fixture." + UUID().uuidString.lowercased()
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName); CFPreferencesAppSynchronize(suiteName as CFString) }
        let supportRoot = FluidServeMeetings.defaultRoot(storageNamespace: suiteName)
        let namespace = supportRoot.deletingLastPathComponent()
        check(namespace.lastPathComponent == suiteName, "Root follows explicit trusted namespace")
        check(!manager.fileExists(atPath: namespace.path), "Fixture namespace must be owned and new")
        try manager.createDirectory(at: supportRoot, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: namespace) }
        try manager.copyItem(at: directory, to: supportRoot.appendingPathComponent(directory.lastPathComponent))
        let contents = base.appendingPathComponent("Fixture voice.app/Contents")
        let tool = contents.appendingPathComponent("Helpers/fv-serve")
        try manager.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), to: tool)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": suiteName, "CFBundleDisplayName": "Synthetic voice app"], format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        func run(_ arguments: [String]) throws -> (Int32, String, Process.TerminationReason) {
            let process = Process(); let output = Pipe()
            process.executableURL = tool; process.arguments = arguments
            process.standardOutput = output; process.standardError = output
            try process.run()
            let deadline = Date().addingTimeInterval(10)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), process.terminationReason)
        }
        let capabilities = ModelTemperatureSupport(defaults: defaults)
        let endpoint = "https://gateway.test/TeamA/v1?Scope=AbC"
        capabilities.record(["ModelA": false], baseURL: endpoint)
        check(capabilities.isSupported("ModelA", baseURL: "HTTPS://GATEWAY.TEST/TeamA/v1/?Scope=AbC") == false, "Scheme and host normalize")
        for variant in ["https://gateway.test/teama/v1?Scope=AbC", "https://gateway.test/TeamA/V1?Scope=AbC",
                        "https://gateway.test/TeamA/v1?scope=AbC", "https://gateway.test/TeamA/v1?Scope=abc",
                        "https://gateway.test/TeamA/v1?Scope=AbC/", "https://gateway.test/TeamA/v1%2F?Scope=AbC"] {
            check(capabilities.isSupported("ModelA", baseURL: variant) == nil, "Case-sensitive route/query is independent")
        }
        check(capabilities.isSupported("modela", baseURL: endpoint) == nil, "Model IDs remain case-sensitive")
        check(ModelTemperatureSupport(defaults: defaults).isSupported("ModelA", baseURL: endpoint) == false, "Capabilities survive a fresh store")
        let key = FluidServeMeetings.accessDefaultsKey
        defaults.set(false, forKey: key); CFPreferencesAppSynchronize(suiteName as CFString)
        let off = try run(["status", "--json"])
        check(off.0 == 0 && off.1.contains("\"access\" : false"), "Isolated helper obeys sharing off")
        let injected = try run(["status", "-" + key, "YES"])
        check(injected.1.contains("Meeting access: off"), "Argument cannot enable sharing")
        defaults.set(true, forKey: key); CFPreferencesAppSynchronize(suiteName as CFString)
        let on = try run(["status", "--json"])
        check(on.0 == 0 && on.1.contains("\"meetings\" : 1"), "Isolated helper reads only its synthetic namespace")
        let printed = try run(["skill"])
        check(printed.0 == 0 && printed.1.contains(FluidServeSkill.marker(ownerBundleIdentifier: suiteName)), "CLI skill records its trusted bundle ownership")
        check(!FluidServeSkill.isOurs(printed.1, ownerBundleIdentifier: "com.FluidApp.app"), "A foreign distribution never owns the skill")
        check(printed.1.contains("Synthetic voice app"), "CLI uses enclosing display name")
        let actual = try run(["meet", "summary", "latest"])
        check(actual.0 == 0 && actual.1.contains("Grounded fixture summary"), "Real helper serves actual grounded artifact")
        for option in ["--from", "--to"] {
            for (text, _) in ordinaryClocks {
                let clock = try run(["meet", "show", "latest", option, text])
                check(clock.0 == 0 && clock.2 == .exit, "Real helper accepts ordinary clock arguments without a signal")
            }
            for text in overflowClocks {
                let clock = try run(["meet", "show", "latest", option, text])
                check(clock.0 == 1 && clock.2 == .exit, "Real helper rejects clock overflow with usage exit 1, without a signal")
                check(clock.1.contains("\(option) takes a time like 12:30.") && clock.1.contains(FluidServeCommand.usage), "Clock overflow reports the existing usage error")
            }
        }
        let supportBytes = try Data(contentsOf: supportRoot.appendingPathComponent(directory.lastPathComponent + "/session.json"))
        check(supportBytes == (try Data(contentsOf: directory.appendingPathComponent("session.json"))), "Real helper never rewrites source")
        print("FluidServe grounded summary tests: \(checks) checks passed")
    }
}

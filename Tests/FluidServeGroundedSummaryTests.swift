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
        try self.checkSpeakerTurnPresentation(check)
        try self.checkLegacyReadingAndEvidenceTurns(check)
        try self.checkSpeakerAttributionProjection(check, root: base.appendingPathComponent("AttributionMeetings"))
        try self.checkLongWordManifest(check, root: base.appendingPathComponent("LongMeetings"))
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
        func run(_ arguments: [String], environment: [String: String]? = nil) throws -> (Int32, String, Process.TerminationReason) {
            let process = Process(); let output = Pipe()
            process.executableURL = tool; process.arguments = arguments
            if let environment { process.environment = environment }
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

        // Exercise the same template input/version contract through the actual isolated helper.
        // These fixtures deliberately include fractions that disappear in the saved manifest.
        let supportDirectory = supportRoot.appendingPathComponent(directory.lastPathComponent)
        let templateFile = supportDirectory.appendingPathComponent("manual-summary-executive.json")
        let manifestFile = supportDirectory.appendingPathComponent("session.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        for language in ["en", "ru", "auto", "invalid-code"] {
            session.languageCode = language
            session.startedAt = Date(timeIntervalSince1970: 1_700_000_000.7)
            session.endedAt = Date(timeIntervalSince1970: 1_700_001_800.3)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let manifest = try encoder.encode(session)
            try manifest.write(to: manifestFile)
            let reloaded = try decoder.decode(MeetingSession.self, from: manifest)
            let input = MeetingSummaryInput.transcript(for: session, timeZone: FluidServeMeetings.systemTimeZone())
            check(input == MeetingSummaryInput.transcript(for: reloaded, timeZone: FluidServeMeetings.systemTimeZone()), "Reloaded whole seconds keep the app's \(language) template input")
            check(input.contains("Duration: 30 minutes"), "Template duration rounds dates before counting whole minutes")
            let hash = MeetingSummaryInput.fingerprint(input)
            for version in [nil, 1, MeetingSummaryInput.currentPromptVersion + 1, MeetingSummaryInput.currentPromptVersion] as [Int?] {
                var stored: [String: Any] = ["transcriptHash": hash, "text": "Versioned \(language) synthetic template.",
                                           "providerID": "synthetic-provider", "modelName": "synthetic-model"]
                if let version { stored["promptVersion"] = version }
                let bytes = try JSONSerialization.data(withJSONObject: stored, options: .sortedKeys)
                try bytes.write(to: templateFile)
                let current = version == MeetingSummaryInput.currentPromptVersion
                let printed = try run(["meet", "summary", "latest", "--style", "executive"])
                check(printed.0 == (current ? 0 : 1) && printed.2 == .exit, "Real helper accepts only the current template contract")
                check(printed.1.contains("Versioned \(language) synthetic template.") == current, "Old, missing and future versions stay hidden")
                check(try Data(contentsOf: templateFile) == bytes, "Rejecting a stale template leaves the saved output intact")
            }
            for zone in ["UTC", "Asia/Tokyo"] {
                var environment = ProcessInfo.processInfo.environment
                environment["TZ"] = zone
                let printed = try run(["meet", "summary", "latest", "--style", "executive"], environment: environment)
                check(printed.0 == 0 && printed.1.contains("Versioned \(language) synthetic template."), "Agent TZ must not hide an app-current template")
            }
            check(try Data(contentsOf: manifestFile) == manifest, "Template reads never rewrite the source")
            session.languageCode = language == "ru" ? "fr" : "ru"
            try encoder.encode(session).write(to: manifestFile)
            let changed = try run(["meet", "summary", "latest", "--style", "executive"])
            check(changed.0 == 1 && !changed.1.contains("Versioned \(language) synthetic template."), "Changed capture language requires template regeneration")
        }
        print("FluidServe grounded summary tests: \(checks) checks passed")
    }

    /// Compare the actual read-only command with the application's canonical reading projection.
    private static func checkSpeakerAttributionProjection(_ check: (Bool, String) -> Void, root: URL) throws {
        let manager = FileManager.default
        let track = UUID(), first = UUID(), second = UUID(), mergedSecond = UUID()
        let epoch = MeetingAnalysisEpochID(trackID: track, ordinal: 0, generation: 0)
        let a = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "anonymous-a")
        let b = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "anonymous-b")
        var session = MeetingSession(configuration: .init(mode: .inRoom, title: "Synthetic attribution projection",
            microphone: .init(captureDeviceID: "fixture", displayName: "Fixture")),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil))
        session.state = .completed
        session.endedAt = session.startedAt.addingTimeInterval(60)
        session.audioTracks = [.init(id: track, kind: .microphone, sourceIdentifier: "fixture", sourceDisplayName: "Fixture",
            format: nil, timebase: session.timebase, health: .waiting, chunks: [])]
        session.speakers = [
            .init(id: first, displayName: "First", diarizationClusterID: nil, trackKind: .microphone, isLocalUser: false, identityCandidates: []),
            .init(id: second, displayName: "Saved owner alias", diarizationClusterID: nil, trackKind: .microphone, isLocalUser: true, identityCandidates: []),
            .init(id: mergedSecond, displayName: "Merged anonymous slot", diarizationClusterID: nil,
                  trackKind: .microphone, isLocalUser: false, identityCandidates: [], mergedIntoSpeakerID: second),
        ]
        func unit(_ index: Int, text: String, selected: MeetingBackendSpeakerToken?, raw: MeetingBackendSpeakerAssignment,
                  relation: MeetingSpeakerAttributionRelation, rule: MeetingSpeakerAttributionRule,
                  background: [MeetingBackendSpeakerToken] = []) -> MeetingTranscriptSegment {
            let start = Double(index * 2)
            let decision = MeetingSpeakerAttributionDecision(unitID: "native-unit-\(index)", rawAssignment: raw,
                candidates: [a, b].map { .init(token: $0, intervals: [.init(start: start, end: start + 1)], supportSeconds: 1, isSuppressed: false) },
                activeSupportSeconds: 1, simultaneousIntervals: [], relation: relation, selectedToken: selected,
                rule: rule, cueUnitIDs: [], backgroundTokens: background, policyVersion: 1, policyFingerprint: "synthetic-policy")
            return .init(id: UUID(), start: .init(value: Int64(start * 1000), timescale: 1000),
                end: .init(value: Int64((start + 1) * 1000), timescale: 1000), sourceTrackID: track,
                speakerID: selected == a ? first : selected == b ? mergedSecond : nil, text: text,
                revision: 0, status: .final, overlap: selected == nil ? .ambiguous : .none, completeness: .complete,
                attributionState: selected == nil ? .overlappingSpeakers : .assigned,
                nativePrecision: .word, nativeUnitID: decision.unitID, nativeTiming: .init(start: start, end: start + 1),
                speakerAttribution: .init(decision: decision, speakerIDs: [a: first, b: mergedSecond]))
        }
        let foreground = unit(0, text: "Foreground fixture.", selected: b, raw: .ambiguous([a, b]),
                              relation: .simultaneous, rule: .briefInterruption, background: [a])
        let estimated = unit(1, text: "Estimated fixture.", selected: a, raw: .unassigned,
                             relation: .none, rule: .incomingSpeaker)
        let multiple = unit(2, text: "Multiple fixture.", selected: nil, raw: .ambiguous([a, b]),
                            relation: .simultaneous, rule: .ambiguous)
        var corrected = foreground
        corrected.id = UUID()
        corrected.start = .init(value: 6000, timescale: 1000)
        corrected.end = .init(value: 7000, timescale: 1000)
        corrected.nativeTiming = .init(start: 6, end: 7)
        corrected.nativeUnitID = "corrected-native-unit"
        corrected.text = "Manually corrected fixture."
        corrected.originalText = "Private initial text"
        corrected.revision = 1
        corrected.speakerID = first
        corrected.speakerAttribution = nil
        session.transcriptSegments = [foreground, estimated, multiple, corrected]
        try session.validateTranscriptStructure()
        let directory = root.appendingPathComponent(session.id.uuidString)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let manifest = try encoder.encode(session)
        let file = directory.appendingPathComponent("session.json")
        try manifest.write(to: file)
        let entries = try FluidServeMeetings.checkedEntries(root: root)
        check(entries.count == 1, "Canonical attribution is admitted through the real persisted reader")
        let meeting = entries[0].meeting
        check(FluidServeMeetings.transcript(for: meeting) == MeetingTranscriptExporter.text(for: session),
              "CLI text shares the application's foreground, estimate, multi-speaker and corrected labels")
        let expectedLabels = ["You (interrupting; background: First)", "First", "Simultaneous speech: First + You", "First"]
        check(meeting.turns.map { FluidServeMeetings.speakerLabel(for: $0, in: meeting) } == expectedLabels,
              "Labels retain unknown/background states and resolved owner/merged aliases")
        let show = FluidServeCommand.run(arguments: ["meet", "show", "latest"], root: root, accessEnabled: true)
        check(show.exitCode == 0 && show.output.hasSuffix(MeetingTranscriptExporter.text(for: session)),
              "Actual CLI text uses the shared projection")
        let searched = FluidServeCommand.run(arguments: ["meet", "search", "fixture"], root: root, accessEnabled: true)
        check(searched.exitCode == 0 && expectedLabels.dropLast().allSatisfy { searched.output.contains($0) },
              "Search results carry the same shared labels")
        let json = FluidServeCommand.run(arguments: ["meet", "show", "latest", "--json"], root: root, accessEnabled: true)
        let document = try JSONSerialization.jsonObject(with: Data(json.output.utf8)) as! [String: Any]
        let turns = document["turns"] as! [[String: Any]]
        let exported = try JSONSerialization.jsonObject(with: MeetingTranscriptExporter.json(for: session)) as! [String: Any]
        let canonical = exported["segments"] as! [[String: Any]]
        check(json.exitCode == 0 && turns.count == session.transcriptSegments.count, "CLI JSON retains every native timed fragment")
        for (index, turn) in turns.enumerated() {
            var withoutLabel = turn
            check(withoutLabel.removeValue(forKey: "speaker") as? String == expectedLabels[index], "JSON keeps the legacy speaker field with the shared participant label")
            check(NSDictionary(dictionary: withoutLabel).isEqual(to: canonical[index]), "All JSON native/provenance fields reuse the exact canonical export projection")
        }
        let foregroundMetadata = turns[0]["speakerAttribution"] as! [String: Any]
        check(foregroundMetadata["selectedSpeakerID"] as? String == second.uuidString,
              "JSON selected foreground resolves the merged speaker to the active identity")
        check(turns[3]["speakerAttribution"] == nil && turns[3]["revision"] as? Int == 1,
              "A manual correction is not relabeled by stale automatic provenance")
        check(!json.output.contains("Private initial text"), "CLI JSON does not expose the prior corrected wording")
        let range = try FluidServeMeetings.jsonTurns(for: meeting, from: 2, to: 4)
        check(range.map { $0["text"] as! String } == [estimated.text, multiple.text], "JSON range retains native start filtering")
        check(try Data(contentsOf: file) == manifest, "Text, JSON and search leave persisted evidence unchanged")
    }

    /// Real production projection of synthetic legacy archives and current word provenance.
    private static func checkLegacyReadingAndEvidenceTurns(_ check: (Bool, String) -> Void) throws {
        let track = UUID(), speaker = UUID(), other = UUID()
        var session = MeetingSession(configuration: .init(mode: .inRoom, title: "Synthetic reading compatibility",
            microphone: .init(captureDeviceID: "fixture", displayName: "Fixture")),
            timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1,
                            firstPresentationTime: nil))
        session.state = .completed
        session.endedAt = session.startedAt.addingTimeInterval(120)
        session.speakers = [speaker, other].map {
            .init(id: $0, displayName: "Speaker", diarizationClusterID: nil, trackKind: .microphone,
                  isLocalUser: false, identityCandidates: [])
        }
        session.processingAttempts = [.init(id: UUID(), startedAt: session.startedAt, completedAt: session.startedAt,
            stage: .completed, pipelineVersion: 13)]
        func segment(_ text: String, _ start: Double, _ end: Double, speakerID: UUID? = speaker) -> MeetingTranscriptSegment {
            .init(id: UUID(), start: .init(value: Int64((start * 1000).rounded()), timescale: 1000),
                end: .init(value: Int64((end * 1000).rounded()), timescale: 1000), sourceTrackID: track,
                speakerID: speakerID, text: text, revision: 0, status: .final, overlap: .none,
                completeness: .complete, attributionState: speakerID == nil ? .unassigned : .assigned)
        }
        let originals = [segment("A", 2.86, 2.96), segment("bridge", 3.28, 3.32, speakerID: nil), segment("B", 3.44, 3.54)]
        session.transcriptSegments = originals
        let before = try MeetingTranscriptExporter.json(for: session)
        let paragraphs = MeetingTranscriptExporter.displayParagraphs(for: originals, in: session)
        check(paragraphs.count == 1 && paragraphs[0].text == "A bridge B", "Legacy same-speaker gap flows inside one readable turn")
        check(paragraphs[0].containsLegacySpeakerBridge, "A legacy reading bridge retains its internal estimate marker")
        check(paragraphs.flatMap(\.segments) == originals && originals[1].speakerID == nil, "Original gap stays unknown in canonical evidence and editor members")
        check(MeetingTranscriptExporter.speakerLabel(for: paragraphs[0], in: session, speakerNames: [speaker: "Speaker"]) == "Speaker",
              "The paragraph uses the selected participant name without an estimate prefix")
        check(MeetingTranscriptExporter.text(for: session) == "[00:02] Speaker: A bridge B", "Text export shares the exact readable turn")
        let after = try MeetingTranscriptExporter.json(for: session)
        check(try JSONSerialization.jsonObject(with: before) as! NSDictionary == JSONSerialization.jsonObject(with: after) as! NSDictionary,
              "Reading projection never changes JSON evidence semantics")
        func staysSplit(_ rows: [MeetingTranscriptSegment], in changed: MeetingSession? = nil) {
            check(MeetingTranscriptExporter.displayParagraphs(for: rows, in: changed ?? session).count == rows.count,
                  "Unsafe, manual or nonlegacy evidence must remain a boundary")
        }
        for index in 0..<3 {
            var rows = originals; rows[index].revision = 1; staysSplit(rows)
            rows = originals; rows[index].originalText = "Original"; staysSplit(rows)
            rows = originals; rows[index].status = .provisional; staysSplit(rows)
            rows = originals; rows[index].completeness = .incompleteTrack; staysSplit(rows)
            rows = originals; rows[index].overlap = .ambiguous; staysSplit(rows)
            rows = originals; rows[index].sourceTrackID = UUID(); staysSplit(rows)
            rows = originals; rows[index].attributionState = .timingUncertain; staysSplit(rows)
            rows = originals; rows[index].nativePrecision = .word; staysSplit(rows)
        }
        var changed = session; changed.state = .processing; staysSplit(originals, in: changed)
        changed = session; changed.processingAttempts = []; staysSplit(originals, in: changed)
        changed = session; changed.processingAttempts[0].pipelineVersion = 15; staysSplit(originals, in: changed)
        changed = session; changed.speakers = []; staysSplit(originals, in: changed)
        changed = session; changed.transcriptIsComplete = false; staysSplit(originals, in: changed)
        changed = session; changed.transcriptCoverageGaps = [.init(trackID: track, start: 3.1, end: 3.2, reason: .missingOrUnreadableAudio)]; staysSplit(originals, in: changed)
        changed = session
        var hiddenEcho = segment("Echo", 3.1, 3.2); hiddenEcho.isLikelyEcho = true
        changed.transcriptSegments.insert(hiddenEcho, at: 1); staysSplit(originals, in: changed)
        var rows = originals; rows[2].speakerID = other
        let incoming = MeetingTranscriptExporter.displayParagraphs(for: rows, in: session)
        check(incoming.count == 2 && incoming[0].segments == [rows[0]] && incoming[1].segments == Array(rows.dropFirst()),
              "A bounded legacy gap at a voice change belongs to the incoming reading turn")
        check(incoming[1].projectedSpeakerID == other && incoming[1].firstSegment.speakerID == nil,
              "The projected speaker remains separate from the unresolved first member")
        for language in [PichiInterfaceLanguage.english, .russian] {
            check(MeetingTranscriptExporter.speakerLabel(for: incoming[1], in: session,
                speakerNames: [speaker: "Анна", other: "Борис"], language: language) == "Борис",
                  "An incoming paragraph beginning with an unknown word has a plain known label")
        }
        check(incoming.flatMap(\.segments) == rows && rows[1].speakerID == nil,
              "Incoming projection preserves exact member IDs, text, timing and original unknown evidence")
        var mixed = rows; mixed[1].attributionState = .overlappingSpeakers; staysSplit(mixed)
        rows = originals; rows[1].start = .init(value: 2000, timescale: 1000); staysSplit(rows)
        rows = originals; rows[2].start = .init(value: 8200, timescale: 1000); rows[2].end = .init(value: 8300, timescale: 1000); staysSplit(rows)
        rows = originals; rows[1].end = .init(value: 7000, timescale: 1000); rows[2].start = .init(value: 7100, timescale: 1000); rows[2].end = .init(value: 7200, timescale: 1000); staysSplit(rows)

        let nested = [segment("Enclosing speaker", 0, 10, speakerID: other),
                      segment("Anchor", 1, 2), segment("gap", 2, 2.1, speakerID: nil), segment("Anchor", 2.1, 3)]
        changed = session; changed.transcriptSegments = nested
        staysSplit(nested, in: changed)
        check(MeetingTranscriptExporter.displayParagraphs(for: nested, in: changed).allSatisfy { !$0.containsLegacySpeakerBridge },
              "An earlier enclosing speaker blocks every nested reading gap despite adjacent end touches")
        var hiddenNested = nested; hiddenNested[0].isLikelyEcho = true
        changed.transcriptSegments = hiddenNested
        staysSplit(Array(hiddenNested.dropFirst()), in: changed)
        var invalidNested = nested; invalidNested[0].end = .init(value: -1, timescale: 1000)
        changed.transcriptSegments = invalidNested
        staysSplit(Array(invalidNested.dropFirst()), in: changed)
        var touching = nested; touching[0].end = .init(value: 1000, timescale: 1000)
        changed.transcriptSegments = touching
        let touchingParagraphs = MeetingTranscriptExporter.displayParagraphs(for: touching, in: changed)
        check(touchingParagraphs.count == 2 && touchingParagraphs[1].segments == Array(touching.dropFirst())
            && touchingParagraphs[1].containsLegacySpeakerBridge,
              "A genuinely half-open end touch is not an overlap barrier")

        let epoch = MeetingAnalysisEpochID(trackID: track, ordinal: 0)
        let token = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "a")
        let background = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "b")
        func provenance(_ segment: MeetingTranscriptSegment, rule: MeetingSpeakerAttributionRule,
                        candidates: [MeetingBackendSpeakerToken] = [], backgroundTokens: [MeetingBackendSpeakerToken] = []) -> MeetingTranscriptSegment {
            var result = segment; result.speakerID = speaker; result.attributionState = .assigned; result.nativePrecision = .word
            let decision = MeetingSpeakerAttributionDecision(unitID: result.id.uuidString, rawAssignment: .unassigned,
                candidates: candidates.map { .init(token: $0, intervals: [], supportSeconds: 0, isSuppressed: true) },
                activeSupportSeconds: 0, simultaneousIntervals: [], relation: backgroundTokens.isEmpty ? .none : .simultaneous,
                selectedToken: token, rule: rule, cueUnitIDs: [], backgroundTokens: backgroundTokens,
                policyVersion: 2, policyFingerprint: MeetingSpeakerAttributionPolicy.standard.fingerprint)
            result.speakerAttribution = .init(decision: decision, speakerIDs: [token: speaker, background: other])
            return result
        }
        changed = session; changed.processingAttempts[0].pipelineVersion = 15
        rows = [originals[0], provenance(originals[1], rule: .neighborAgreement), originals[2]]
        let current = MeetingTranscriptExporter.displayParagraphs(for: rows, in: changed)
        check(current.count == 1 && !current[0].containsLegacySpeakerBridge, "Current direct and neighbor words form the same speaker turn")
        check(MeetingTranscriptExporter.speakerLabel(for: current[0], in: changed, speakerNames: [speaker: "Speaker"]) == "Speaker",
              "Current turn uses the participant name while retaining per-word heuristic evidence")
        check(current.flatMap(\.segments) == rows, "Current provenance remains per word")
        rows = [provenance(originals[0], rule: .neighborAgreement), provenance(originals[1], rule: .incomingSpeaker, candidates: [token, background])]
        check(MeetingTranscriptExporter.displayParagraphs(for: rows, in: changed).count == 1,
              "Per-word heuristic names and suppressed candidate sets do not invent speaker changes")
        rows = [originals[0], provenance(originals[1], rule: .briefInterruption, backgroundTokens: [background]), originals[2]]
        staysSplit(rows, in: changed)
    }

    /// Genuine production codec payload, not whitespace padding: long word-level transcripts
    /// with compact provenance must remain readable within explicit aggregate limits.
    private static func checkLongWordManifest(_ check: (Bool, String) -> Void, root: URL) throws {
        let track = UUID(), speaker = UUID()
        var session = MeetingSession(configuration: .init(mode: .inRoom, title: "Synthetic long word transcript",
            microphone: .init(captureDeviceID: "fixture", displayName: "Fixture")),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil))
        session.state = .completed
        session.endedAt = session.startedAt.addingTimeInterval(7200)
        session.audioTracks = [.init(id: track, kind: .microphone, sourceIdentifier: "fixture", sourceDisplayName: "Fixture",
            format: nil, timebase: session.timebase, health: .waiting, chunks: [])]
        session.speakers = [.init(id: speaker, displayName: "Synthetic speaker", diarizationClusterID: nil,
                                 trackKind: .microphone, isLocalUser: false, identityCandidates: [])]
        session.transcriptSegments = (0..<10_000).map { index in
            let start = Double(index) * 0.6
            return .init(id: UUID(), start: .init(value: Int64(index * 600), timescale: 1000),
                end: .init(value: Int64(index * 600 + 400), timescale: 1000), sourceTrackID: track,
                speakerID: speaker, text: index == 9999 ? "LongManifestLastWord" : "SyntheticWord\(index)",
                revision: 0, status: .final, overlap: .none, completeness: .complete,
                attributionState: .assigned, nativePrecision: .word,
                nativeUnitID: "synthetic-native-word-\(index)", nativeTiming: .init(start: start, end: start + 0.4))
        }
        let directory = root.appendingPathComponent(session.id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(session)
        check(bytes.count > 4 * 1024 * 1024 && bytes.count < FluidServeMeetings.maximumManifestBytes,
              "The real compact 10,000-word fixture exceeds the previous 4 MiB reader limit")
        try bytes.write(to: directory.appendingPathComponent("session.json"))
        let entries = try FluidServeMeetings.checkedEntries(root: root)
        check(entries.count == 1 && entries[0].meeting.turns.count == 10_000, "Long native word transcripts remain fully readable")
        let text = FluidServeCommand.run(arguments: ["meet", "show", "latest"], root: root, accessEnabled: true)
        check(text.exitCode == 0 && text.output.contains("LongManifestLastWord"), "Long transcript text reaches the final native word")
        let search = FluidServeCommand.run(arguments: ["meet", "search", "LongManifestLastWord"], root: root, accessEnabled: true)
        check(search.exitCode == 0 && search.output.contains("LongManifestLastWord"), "Long transcript search remains available")
        let json = FluidServeCommand.run(arguments: ["meet", "show", "latest", "--json"], root: root, accessEnabled: true)
        let object = try JSONSerialization.jsonObject(with: Data(json.output.utf8)) as! [String: Any]
        let turns = object["turns"] as! [[String: Any]]
        check(json.exitCode == 0 && turns.count == 10_000 && turns.last?["text"] as? String == "LongManifestLastWord",
              "Long JSON projection preserves every fragment and ends at the final word")
        check(FluidServeMeetings.maximumManifestBytes <= FluidServeMeetings.maximumTotalReadBytes,
              "A per-file allowance never bypasses the unchanged aggregate read budget")
    }

    /// Uses production codecs/projection/export without an app host, audio, models or user data.
    private static func checkSpeakerTurnPresentation(_ check: (Bool, String) -> Void) throws {
        let track = UUID(), firstID = UUID(), secondID = UUID()
        var session = MeetingSession(configuration: .init(mode: .inRoom, title: "Synthetic speaker turns",
            microphone: .init(captureDeviceID: "fixture", displayName: "Fixture")),
            timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1,
                            firstPresentationTime: nil))
        session.speakers = [firstID, secondID].map {
            .init(id: $0, displayName: $0 == firstID ? "First" : "Second", diarizationClusterID: nil,
                  trackKind: .microphone, isLocalUser: false, identityCandidates: [])
        }
        func segment(_ text: String, _ start: Int64, speaker: UUID? = firstID, source: UUID = track) -> MeetingTranscriptSegment {
            .init(id: UUID(), start: .init(value: start, timescale: 1), end: .init(value: start + 1, timescale: 1),
                  sourceTrackID: source, speakerID: speaker, text: text, originalText: "Private original wording",
                  revision: 2, status: .final, overlap: .none, completeness: .complete,
                  attributionState: speaker == nil ? .unassigned : .assigned)
        }
        var monologue = (0..<600).map { segment("слово\($0)", Int64($0) * 4) }
        monologue[80].text += "\n\n"
        monologue[160].text += "."
        session.transcriptSegments = monologue
        let before = session
        let turns = MeetingTranscriptExporter.displayParagraphs(for: monologue, in: session)
        check(turns.count == 1, "Long monologue remains one speaker block across pauses and sentence boundaries")
        check(turns[0].segments == monologue, "Reading projection preserves every canonical member and revision")
        check(turns[0].text.contains("слово80\n\nслово81"), "Explicit user line breaks remain inside the speaker block")
        let text = MeetingTranscriptExporter.text(for: session)
        check(text == "[00:00] First: " + turns[0].text, "Readable export uses exactly one speaker header for the turn")
        check(!text.contains("Private original wording"), "Export contains only currently approved transcript text")
        let json = try JSONSerialization.jsonObject(with: MeetingTranscriptExporter.json(for: session)) as! [String: Any]
        let exported = json["segments"] as! [[String: Any]]
        check(exported.count == monologue.count, "JSON export retains every canonical timed fragment")
        check(exported.map { $0["id"] as! String } == monologue.map { $0.id.uuidString }, "JSON keeps exact member identities")
        check(session == before, "Presentation and both exports do not mutate stored evidence")

        let dialogue = [segment("First speaker.", 0), segment("Still first.", 40),
                        segment("Second speaker.", 41, speaker: secondID), segment("First again.", 42),
                        segment("to", 43, speaker: nil), segment("First continues.", 44)]
        session.transcriptSegments = dialogue
        let dialogueTurns = MeetingTranscriptExporter.displayParagraphs(for: dialogue, in: session)
        check(dialogueTurns.map(\.segments) == [Array(dialogue[0...1]), [dialogue[2]], [dialogue[3]], [dialogue[4]], [dialogue[5]]],
              "Actual speaker switches and unknown attribution remain distinct turns")
        check(MeetingTranscriptExporter.text(for: session).contains("[00:43] Unknown speaker: to"),
              "An unknown word never acquires the neighboring speaker's name")

        let changedSource = [segment("Source one.", 0), segment("Source two.", 1, source: UUID())]
        check(MeetingTranscriptExporter.displayParagraphs(for: changedSource, in: session).count == 2,
              "Matching speaker IDs do not merge across source tracks")
        var echo = segment("Echo.", 1); echo.isLikelyEcho = true
        session.transcriptSegments = [dialogue[0], echo, segment("Continued.", 2)]
        check(MeetingTranscriptExporter.text(for: session) == "[00:00] First: First speaker. Continued.",
              "Default readable export excludes echoes before grouping")
        check(MeetingTranscriptExporter.text(for: session, includeEchoes: true).components(separatedBy: "\n\n").count == 3,
              "Explicit echo export retains evidence boundaries")
    }
}

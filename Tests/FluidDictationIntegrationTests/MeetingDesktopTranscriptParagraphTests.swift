import AppKit
import Foundation
import SwiftUI
@testable import FluidVoice_Debug
import XCTest

final class MeetingDesktopTranscriptParagraphTests: XCTestCase {
    private func session() -> MeetingSession {
        let configuration = MeetingCaptureConfiguration(mode: .inRoom, title: "Synthetic reading fixture",
            languageCode: "ru", microphone: .init(captureDeviceID: "fixture", displayName: "Fixture"))
        var session = MeetingSession(configuration: configuration, startedAt: Date(timeIntervalSince1970: 0),
            timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1,
                            firstPresentationTime: nil))
        session.state = .completed
        session.endedAt = Date(timeIntervalSince1970: 60)
        session.speakers = (0..<2).map { _ in
            .init(id: UUID(), displayName: "Same name", diarizationClusterID: nil,
                  trackKind: .microphone, isLocalUser: false, identityCandidates: [])
        }
        let track = UUID()
        session.transcriptSegments = ["Привет", ",", "обсудим", "план.", "Да.", "Продолжим."].enumerated().map { index, text in
            .init(id: UUID(), start: .init(value: Int64(index * 500), timescale: 1000),
                  end: .init(value: Int64(index * 500 + 400), timescale: 1000), sourceTrackID: track,
                  speakerID: session.speakers[index == 4 ? 1 : 0].id, text: text, revision: 0,
                  status: .final, overlap: .none, completeness: .complete, attributionState: .assigned,
                  nativePrecision: .word, nativeUnitID: "synthetic-word-\(index)",
                  nativeTiming: .init(start: Double(index) / 2, end: Double(index) / 2 + 0.4))
        }
        return session
    }

    private func projection(_ session: MeetingSession) async throws -> MeetingResultTranscriptProjection {
        try await MeetingResultTranscriptProjection.make(for: session)
    }

    func testDesktopRowsGroupWordsAndKeepGenuineOneWordReply() async throws {
        let source = self.session()
        let projection = try await self.projection(source)
        let rows = projection.rows(matching: .init(source), includeEchoes: false)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map { $0.paragraph.text }, ["Привет, обсудим план.", "Да.", "Продолжим."])
        XCTAssertEqual(rows.map(\.memberIDs), [Array(source.transcriptSegments.prefix(4).map(\.id)),
            [source.transcriptSegments[4].id], [source.transcriptSegments[5].id]])
        XCTAssertEqual(rows.flatMap { $0.paragraph.segments }, source.transcriptSegments)
        XCTAssertEqual(rows[0].presentation.participantID, source.speakers[0].id)
        XCTAssertEqual(rows[1].presentation.participantID, source.speakers[1].id,
                       "Equal display names cannot collapse different participants")
        let interval = try MeetingSegmentPlaybackPlan.segmentRange(in: source, segmentIDs: rows[0].memberIDs)
        XCTAssertEqual(interval.start, source.transcriptSegments[0].start)
        XCTAssertEqual(interval.end, source.transcriptSegments[3].end)
    }

    func testRetiredSessionOrEditedSourceCannotRenderCachedRows() async throws {
        let source = self.session(), projection = try await self.projection(source)
        var changed = source
        changed.id = UUID()
        XCTAssertTrue(projection.rows(matching: .init(changed), includeEchoes: false).isEmpty)
        changed = source
        changed.transcriptSegments[0].revision += 1
        changed.transcriptSegments[0].text = "Changed"
        XCTAssertTrue(projection.rows(matching: .init(changed), includeEchoes: true).isEmpty)
        changed = source
        changed.title = "Title changes do not change transcript membership"
        XCTAssertEqual(projection.rows(matching: .init(changed), includeEchoes: false).count, 3)
    }

    func testEchoEvidenceViewKeepsOriginalOrderAndSingleMemberPlayback() async throws {
        var source = self.session()
        var echo = source.transcriptSegments[0]
        echo.id = UUID(); echo.text = "Echo"; echo.isLikelyEcho = true
        echo.start = .init(value: 450, timescale: 1000)
        echo.end = .init(value: 490, timescale: 1000)
        source.transcriptSegments.insert(echo, at: 1)
        let projection = try await self.projection(source)
        let reading = projection.rows(matching: .init(source), includeEchoes: false)
        XCTAssertEqual(reading.count, 3)
        XCTAssertFalse(reading.flatMap(\.memberIDs).contains(echo.id))
        let evidence = projection.rows(matching: .init(source), includeEchoes: true)
        XCTAssertEqual(evidence.map(\.id), source.transcriptSegments.map(\.id))
        for row in evidence {
            XCTAssertEqual(row.memberIDs, [row.id])
            XCTAssertEqual(try MeetingSegmentPlaybackPlan.segmentRange(in: source, segmentIDs: row.memberIDs),
                           row.paragraph.firstSegment)
        }
        XCTAssertEqual(projection.rows(matching: .init(source), includeEchoes: false), reading)
    }

    func testMemberSearchKeepsCapturedRevisionAndDoesNotMutateParagraph() async throws {
        let source = self.session(), projection = try await self.projection(source)
        let paragraph = try XCTUnwrap(projection.rows(matching: .init(source), includeEchoes: false).first?.paragraph)
        let selection = MeetingTranscriptMemberSelection(paragraph: paragraph, purpose: .editText)
        XCTAssertEqual(selection.members(matching: "ОБСУДИМ"), [source.transcriptSegments[2]])
        XCTAssertEqual(selection.members(matching: "   "), paragraph.segments)
        XCTAssertEqual(selection.member(id: source.transcriptSegments[2].id)?.revision,
                       source.transcriptSegments[2].revision)
        XCTAssertNil(selection.member(id: source.transcriptSegments[5].id),
                     "Another paragraph's member cannot enter this edit draft")
        XCTAssertEqual(selection.paragraph.segments, Array(source.transcriptSegments.prefix(4)))
        XCTAssertEqual(paragraph.segments, Array(source.transcriptSegments.prefix(4)),
                       "Searching or abandoning a selection is presentation-only")
    }

    func testCoverageDetailsMergeOverlappingReasonsWithoutChangingEvidence() throws {
        var source = self.session()
        let microphone = try XCTUnwrap(source.transcriptSegments.first?.sourceTrackID), application = UUID()
        source.audioTracks = [MeetingAudioTrack(id: microphone, kind: .microphone, sourceIdentifier: "fixture",
            sourceDisplayName: "Fixture", format: nil, timebase: source.timebase, health: .waiting, chunks: [])]
        source.transcriptIsComplete = false
        source.transcriptCoverageGaps = [
            .init(trackID: microphone, start: 0, end: 0.5, reason: .inadmissibleCaptureEra),
            .init(trackID: microphone, start: 0.25, end: 1, reason: .processingSkipped),
            .init(trackID: microphone, start: 1, end: 2, reason: .processingFailed),
            .init(trackID: microphone, start: 5, end: 6, reason: .providerTruncated),
            .init(trackID: application, start: 0, end: 0.5, reason: .missingOrUnreadableAudio),
            .init(trackID: microphone, start: .nan, end: 8, reason: .processingFailed),
            .init(trackID: microphone, start: 7, end: 7, reason: .processingFailed)
        ]
        let originalSegments = source.transcriptSegments
        let values = MeetingTranscriptExporter.coverageDetails(in: source)
        XCTAssertEqual(values.count, 2)
        let mic = try XCTUnwrap(values.first(where: { $0.trackID == microphone }))
        XCTAssertEqual(mic.kind, .microphone)
        XCTAssertEqual(mic.omittedSeconds, 3, accuracy: 0.000001)
        XCTAssertEqual(mic.intervalCount, 2)
        XCTAssertEqual(values.first(where: { $0.trackID == application })?.omittedSeconds, 0.5)
        XCTAssertEqual(source.transcriptSegments, originalSegments)
        XCTAssertEqual(source.transcriptCoverageGaps?.count, 7)
        XCTAssertEqual(source.transcriptIsComplete, false, "Presenting a count cannot erase a real warning")
        let english = try XCTUnwrap(MeetingTranscriptExporter.coverageDescription(in: source))
        XCTAssertTrue(english.contains("Microphone: 3.0 s. Audio intervals: 2."))
        let russian = try XCTUnwrap(MeetingTranscriptExporter.coverageDescription(in: source, language: .russian))
        XCTAssertTrue(russian.contains("Микрофон: 3,0 с. Участков: 2."))
    }

    func testAbsentOrInvalidCoverageDoesNotInventOmittedTime() {
        var source = self.session()
        XCTAssertTrue(MeetingTranscriptExporter.coverageDetails(in: source).isEmpty)
        XCTAssertNil(MeetingTranscriptExporter.coverageDescription(in: source))
        source.transcriptCoverageGaps = [.init(trackID: UUID(), start: -1, end: 1, reason: .processingFailed),
            .init(trackID: UUID(), start: 0, end: .infinity, reason: .processingFailed)]
        XCTAssertNil(MeetingTranscriptExporter.coverageDescription(in: source))
    }

    func testMarkdownUsesTheSameReadingParagraphsAsDesktopAndPlainText() async throws {
        let source = self.session()
        let rows = try await self.projection(source).rows(matching: .init(source), includeEchoes: false)
        let markdown = MeetingTranscriptExporter.markdown(for: source)
        XCTAssertEqual(markdown.components(separatedBy: "\n").filter { $0.hasPrefix("### ") }.count, rows.count)
        XCTAssertTrue(markdown.contains("Привет, обсудим план\\."))
        XCTAssertEqual(MeetingTranscriptExporter.text(for: source).components(separatedBy: "\n\n").count, rows.count)
        XCTAssertEqual(rows.flatMap { $0.paragraph.segments }, source.transcriptSegments)
    }

    func testEqualStartTimesUseTheSameStableOrderInEveryReadingSurface() async throws {
        var source = self.session()
        source.transcriptSegments = Array(source.transcriptSegments.prefix(2))
        source.transcriptSegments[0].text = "Longer"
        source.transcriptSegments[0].start = .init(value: 0, timescale: 1)
        source.transcriptSegments[0].end = .init(value: 2, timescale: 1)
        source.transcriptSegments[1].text = "Shorter"
        source.transcriptSegments[1].speakerID = source.speakers[1].id
        source.transcriptSegments[1].start = .init(value: 0, timescale: 1)
        source.transcriptSegments[1].end = .init(value: 1, timescale: 1)
        let rows = try await self.projection(source).rows(matching: .init(source), includeEchoes: false)
        XCTAssertEqual(rows.map { $0.paragraph.text }, ["Shorter", "Longer"])
        for text in [MeetingTranscriptExporter.text(for: source), MeetingTranscriptExporter.markdown(for: source)] {
            XCTAssertLessThan(try XCTUnwrap(text.range(of: "Shorter")?.lowerBound),
                              try XCTUnwrap(text.range(of: "Longer")?.lowerBound))
        }
    }

    func testCancelledProjectionDoesNotPublishOrLeaveUnjoinedWork() async {
        let source = self.session()
        let task = Task { try await MeetingResultTranscriptProjection.make(for: source) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled source must not publish a projection") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    /// Explicit local fixture only. No source session, recording, model or preference is changed.
    @MainActor
    func testNativeReadingPreviewForExplicitLongTranscript() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let fixture = environment["PICHI_TRANSCRIPT_READING_FIXTURE"],
              let output = environment["PICHI_TRANSCRIPT_READING_OUTPUT"] else {
            throw XCTSkip("Opt-in native transcript preview requires an explicit local fixture and output directory")
        }
        let settings = SettingsStore.shared
        let previousTheme = settings.themePreference
        let previousThemeValue = settings.defaults.object(forKey: SettingsStore.Keys.themePreference)
        let previousAppearance = NSApplication.shared.appearance
        let previousLanguage = environment["PICHI_INTERFACE_LANGUAGE"]
        setenv("PICHI_INTERFACE_LANGUAGE", "ru", 1)
        defer {
            settings.themePreference = previousTheme
            settings.defaults.set(previousThemeValue, forKey: SettingsStore.Keys.themePreference)
            NSApplication.shared.appearance = previousAppearance
            if let previousLanguage { setenv("PICHI_INTERFACE_LANGUAGE", previousLanguage, 1) }
            else { unsetenv("PICHI_INTERFACE_LANGUAGE") }
        }
        XCTAssertTrue(fixture.hasPrefix("/") && output.hasPrefix("/"))
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = MeetingSessionDateCodec.decodingStrategy
        let source = try decoder.decode(MeetingSession.self, from: Data(contentsOf: URL(fileURLWithPath: fixture)))
        let start = ProcessInfo.processInfo.systemUptime
        let projection = try await MeetingResultTranscriptProjection.make(for: source)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let rows = projection.rows(matching: .init(source), includeEchoes: false)
        XCTAssertFalse(rows.isEmpty)
        XCTAssertLessThan(rows.count, source.transcriptSegments.count)
        let memberIDs = rows.flatMap(\.memberIDs)
        XCTAssertEqual(memberIDs.count, Set(memberIDs).count, "Reading rows must not duplicate source words")
        XCTAssertEqual(Set(rows.flatMap(\.memberIDs)), Set(MeetingTranscriptExporter.displayParagraphs(
            for: source.transcriptSegments.filter { !$0.isEcho }.sorted { ($0.start, $0.end) < ($1.start, $1.end) },
            in: source).flatMap { $0.segments.map(\.id) }))
        let audit: [String: Any] = ["sessionID": source.id.uuidString, "sourceSegments": source.transcriptSegments.count,
            "readingRows": rows.count, "memberCount": rows.reduce(0) { $0 + $1.memberIDs.count },
            "singleWordRows": rows.filter { $0.paragraph.text.split(whereSeparator: \.isWhitespace).count == 1 }.count,
            "fullProjectionSeconds": elapsed, "coverageDetails": MeetingTranscriptExporter.coverageDetails(in: source).map {
                ["seconds": $0.omittedSeconds, "intervals": $0.intervalCount] as [String: Any]
            }]
        try JSONSerialization.data(withJSONObject: audit, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("projection.json"), options: .atomic)
        try MeetingTranscriptExporter.text(for: source)
            .write(to: directory.appendingPathComponent("readable-transcript.txt"), atomically: true, encoding: .utf8)
        let hold = min(180, max(0, Int(environment["PICHI_TRANSCRIPT_READING_HOLD_SECONDS"] ?? "0") ?? 0))
        let previousPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.regular)
        defer { NSApplication.shared.setActivationPolicy(previousPolicy) }
        for (label, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            settings.themePreference = scheme == .light ? .light : .dark
            NSApplication.shared.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            let content = AdaptiveAppTheme(accent: SettingsStore.shared.accentColor) {
                MeetingResultCanvas(session: source, isQuiescent: true, canUndo: false,
                    onCopyTranscript: { _, _ in }, onExportTranscript: { _, _, _ in },
                    onReassignSegments: { _, _ in }, onEditTranscriptSegment: { _, _, _ in nil },
                    onNameUnknownSegment: { _, _ in }, onUndo: { false }, onRenameSession: { _ in },
                    onAssignSpeakers: { _ in nil }, onClose: nil)
                .environment(\.locale, Locale(identifier: "ru"))
                .preferredColorScheme(scheme)
            }.environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 850),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Transcript paragraph audit - \(label)"
            window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            host.appearance = window.appearance
            window.contentView = host
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            defer { window.contentView = nil; window.close() }
            // The actual view owns its separate cancellable projection. Give its task/run loop
            // a bounded opportunity to render before retaining this first native view frame.
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            }
            let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("\(label)-native.png"), options: .atomic)
            let reviewToken = UUID().uuidString
            try JSONSerialization.data(withJSONObject: ["phase": label, "pid": ProcessInfo.processInfo.processIdentifier,
                "window": window.title, "reviewToken": reviewToken], options: [.prettyPrinted])
                .write(to: directory.appendingPathComponent("ready.json"), options: .atomic)
            if environment["PICHI_TRANSCRIPT_READING_REVIEW"] == "1" {
                // Native capture/review is external to this test. Only an acknowledgement
                // for this exact window generation may advance the light/dark sequence.
                let acknowledgement = directory.appendingPathComponent("\(label)-reviewed.json")
                let deadline = ProcessInfo.processInfo.systemUptime + 600
                var accepted = false
                while window.isVisible, ProcessInfo.processInfo.systemUptime < deadline {
                    if let data = try? Data(contentsOf: acknowledgement),
                       let review = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                       review["reviewToken"] == reviewToken, review["phase"] == label,
                       let frameHash = review["frameSHA256"], frameHash.count == 64,
                       frameHash.allSatisfy({ $0.isHexDigit }) {
                        accepted = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(200))
                }
                XCTAssertTrue(accepted, "Native frame must be captured and reviewed before advancing")
            } else if hold > 0 {
                let deadline = ProcessInfo.processInfo.systemUptime + Double(hold)
                while window.isVisible, ProcessInfo.processInfo.systemUptime < deadline {
                    try await Task.sleep(for: .milliseconds(200))
                }
            }
            window.contentView = nil
            window.close()
        }
    }
}

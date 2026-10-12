@testable import FluidVoice_Debug
import Combine
import Foundation
import XCTest

final class PichiLocalizationPresentationTests: XCTestCase {
    func testCachedSummaryMessagesRenderInTheNewLanguageWithTheSameArguments() throws {
        try self.withLocalizedBundle { bundle in
            let progress = PichiMeetingSummaryProgress(index: 2, total: 7)
            let issue = PichiMeetingSummaryDiscoveryIssue.noInstalledModels
            XCTAssertEqual(progress.text(language: .english, bundle: bundle), "Processing transcript part 2 of 7…")
            XCTAssertEqual(progress.text(language: .russian, bundle: bundle), "Обработка части 2 из 7…")
            XCTAssertEqual(issue.text(language: .russian, bundle: bundle), "Установленных моделей нет.")
            let french = try XCTUnwrap(PichiInterfaceLanguage(rawValue: "fr"))
            XCTAssertEqual(progress.text(language: french, bundle: bundle), "Traitement de la partie 2 sur 7…")
            XCTAssertEqual(issue.text(language: .english, bundle: bundle), "No installed models found. Install a model in Ollama or LM Studio, then refresh.")
            XCTAssertEqual(progress, .init(index: 2, total: 7))
        }
    }

    func testStoredCapacityUsesThePresentationLocaleWithoutRepeatingTheStorageProbe() throws {
        try self.withLocalizedBundle { bundle in
            let capacity: Int64 = 1_500_000_000
            let status = MeetingStorageStatus.available(bytes: capacity)
            let englishSize = capacity.formatted(.byteCount(style: .file).locale(PichiInterfaceLanguage.english.locale))
            let russianSize = capacity.formatted(.byteCount(style: .file).locale(PichiInterfaceLanguage.russian.locale))
            XCTAssertEqual(status.text(language: .english, bundle: bundle), "\(englishSize) available")
            XCTAssertEqual(status.text(language: .russian, bundle: bundle), "Доступно: \(russianSize)")
            XCTAssertEqual(status, .available(bytes: capacity))
            XCTAssertEqual(MeetingStorageStatus.checking.text(language: .russian, bundle: bundle), "Проверка…")
            XCTAssertEqual(MeetingStorageStatus.unavailable.text(language: .russian, bundle: bundle), "Объём хранилища неизвестен")
        }
    }

    func testFileProgressUsesStableKeysRatherThanReverseTranslatingRenderedEnglish() throws {
        try self.withLocalizedBundle { bundle in
            let duration = FileTranscriptionStatus.transcribingAudio(durationSeconds: 73)
            let percent = FileTranscriptionStatus.transcribing(percent: 42)
            let speakers = FileTranscriptionStatus.transcribingSpeakerSegments(index: 2, total: 9)
            XCTAssertEqual(duration.text(language: .english, bundle: bundle), "Transcribing audio (73s)...")
            XCTAssertEqual(duration.text(language: .russian, bundle: bundle), "Распознавание аудио (73 с)...")
            XCTAssertEqual(percent.text(language: .russian, bundle: bundle), "Распознавание... 42%")
            XCTAssertEqual(speakers.text(language: .russian, bundle: bundle), "Распознавание реплик участников (2/9)...")
            XCTAssertEqual(speakers.text(language: .english, bundle: bundle), "Transcribing speaker segments (2/9)...")
            XCTAssertEqual(FileTranscriptionStatus.idle.text(language: .russian, bundle: bundle), "")
        }
    }

    @MainActor
    func testBrandNamesThatCollideWithUIKeysStayVerbatimInNavigation() throws {
        try self.withLocalizedBundle { bundle in
            let profile = BrandProfile(
                appName: "Dashboard", meetingName: "Settings", assistantName: "File Transcription",
                tagline: "My product", accentLight: "#123456", accentDark: "#654321",
                website: "https://example.invalid", support: "https://example.invalid/support"
            )
            XCTAssertEqual(SidebarItem.meetingTranscription.title(profile: profile, language: .russian, bundle: bundle), "Settings")
            XCTAssertEqual(SidebarItem.meetingTranscription.title(profile: profile, language: .english, bundle: bundle), "Settings")
            XCTAssertEqual(SidebarItem.welcome.title(profile: profile, language: .russian, bundle: bundle), "Главная")
            XCTAssertEqual(SidebarItem.fileTranscription.title(profile: profile, language: .russian, bundle: bundle), "Распознавание файлов")
            XCTAssertEqual(profile.meetingName, "Settings")
        }
    }

    @MainActor
    func testDiscoveryFailureStaysTypedAndDoesNotChangeSummarySelectionWhenRendered() async throws {
        let suite = "PichiLocalizationPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = PichiMeetingSummarySettings(defaults: defaults)
        settings.baseURL = "https://example.invalid/v1" // Fails loopback validation without any network request.
        let originalSelection = settings.selectionIdentity
        await settings.discoverModels()
        XCTAssertEqual(settings.discoveryIssue, .localServerUnavailable)
        try self.withLocalizedBundle { bundle in
            let issue = try XCTUnwrap(settings.discoveryIssue)
            XCTAssertEqual(issue.text(language: .russian, bundle: bundle), "Не удалось получить локальные модели.")
            XCTAssertEqual(issue.text(language: .english, bundle: bundle), "Could not list local models. Start Ollama or LM Studio's local server and check the endpoint.")
        }
        XCTAssertEqual(settings.selectionIdentity, originalSelection)
        XCTAssertFalse(settings.discovering)
        XCTAssertTrue(settings.models.isEmpty)
    }

    @MainActor
    func testRenderingAnotherLanguageKeepsTheActiveSummaryGenerationAndResidencyLease() async throws {
        let entered = expectation(description: "Synthetic inference entered")
        let finished = expectation(description: "The same generation finished")
        let gate = InferenceGate()
        let session = self.session()
        let evidence = PichiMeetingSummaryEvidence(segmentID: session.transcriptSegments[0].id, quote: "Решили оставить цену.")
        let expected = PichiMeetingSummaryDocument(summary: [.init(text: "Обсудили цену.", evidence: [evidence])],
                                                   decisions: [], actions: [], openQuestions: [])
        let response = String(decoding: try JSONEncoder().encode(expected), as: UTF8.self)
        let controller = PichiMeetingSummaryController(generator: .init { configuration in
            try await gate.wait(configuration: configuration) { entered.fulfill() }
            try Task.checkCancellation()
            return response
        })
        let owner = MeetingModelResidencyCoordinator()
        let asr = ASRService(meetingModelResidency: owner)
        asr.meetingModelParticipantsForTesting = []
        let completion = controller.$generating.dropFirst().filter { !$0 }.first().sink { _ in finished.fulfill() }
        defer { completion.cancel(); controller.cancel(); Task { await gate.release() } }
        controller.summarize(session: session, configuration: .init(providerID: "fixture", modelID: "fixture-model",
                                                                    baseURL: "http://127.0.0.1:11434/v1", apiKey: "", language: "ru"), asr: asr)
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertTrue(controller.generating)
        XCTAssertEqual(owner.phase, .summary)
        let progress = try XCTUnwrap(controller.progressState)
        try self.withLocalizedBundle { bundle in
            XCTAssertEqual(progress.text(language: .english, bundle: bundle), "Processing transcript part 1 of 1…")
            XCTAssertEqual(progress.text(language: .russian, bundle: bundle), "Обработка части 1 из 1…")
        }
        NotificationCenter.default.post(name: PichiLocalization.languageChanged, object: nil)
        await Task.yield()
        XCTAssertTrue(controller.generating, "Changing presentation must not cancel or restart inference")
        XCTAssertEqual(controller.progressState, progress)
        XCTAssertTrue(owner.isExclusive)
        XCTAssertEqual(owner.phase, .summary)
        let callsBeforeRelease = await gate.calls
        XCTAssertEqual(callsBeforeRelease, 1)
        let stagesBeforeRelease = await gate.stages
        XCTAssertEqual(stagesBeforeRelease, ["map"], "Presentation changes must not start another map or review while the first inference is held")
        await gate.release()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(controller.document, expected)
        XCTAssertFalse(owner.isExclusive)
        XCTAssertEqual(owner.phase, .normal)
        let callsAfterCompletion = await gate.calls
        XCTAssertEqual(callsAfterCompletion, 2, "The same generation completes one map and one source-support review")
        let stagesAfterCompletion = await gate.stages
        XCTAssertEqual(stagesAfterCompletion, ["map", "support-review"], "Changing language must not duplicate or skip either inference stage")
        let requests = await gate.requests
        XCTAssertEqual(requests.map(\.model), ["fixture-model", "fixture-model"])
        XCTAssertEqual(requests.map(\.baseURL), ["http://127.0.0.1:11434/v1", "http://127.0.0.1:11434/v1"])
    }

    func testOnlyMissingSpeakerNamesAreLocalizedAndExistingNamesStayVerbatim() throws {
        let session = self.session()
        var segment = try XCTUnwrap(session.transcriptSegments.first)
        let speakerID = try XCTUnwrap(segment.speakerID)
        for name in ["Speaker 1", "Room Speaker 2", "Settings", "Участник 1"] {
            for language in [PichiInterfaceLanguage.russian, .english] {
                XCTAssertEqual(MeetingTranscriptExporter.speakerLabel(for: segment, in: session, speakerNames: [speakerID: name], language: language), name)
            }
        }
        for state in [MeetingTranscriptAttributionState.assigned, .unassigned, .overlappingSpeakers, .timingUncertain] {
            segment.attributionState = state
            XCTAssertEqual(MeetingTranscriptExporter.speakerLabel(for: segment, in: session, speakerNames: [:], language: .russian), "Неизвестный участник")
            XCTAssertEqual(MeetingTranscriptExporter.speakerLabel(for: segment, in: session, speakerNames: [:], language: .english), "Unknown speaker")
        }
        XCTAssertEqual(session.speakers.first?.displayName, "Иван")
        XCTAssertEqual(session.transcriptSegments.first?.text, "Решили оставить цену.")
    }

    func testUnknownSpeakerSummaryInputAndFingerprintStayStableAcrossUILocalePresentation() throws {
        var session = self.session()
        session.transcriptSegments[0].speakerID = nil
        session.transcriptSegments[0].attributionState = .unassigned
        let segment = try XCTUnwrap(session.transcriptSegments.first)
        let fingerprint = PichiMeetingSummaryInput.fingerprint(session)
        let canonicalTurns = PichiMeetingSummaryInput.turns(for: session)
        XCTAssertEqual(canonicalTurns.first?.speaker, "Unknown speaker")
        for (language, expected) in [(PichiInterfaceLanguage.russian, "Неизвестный участник"), (.english, "Unknown speaker")] {
            XCTAssertEqual(MeetingTranscriptExporter.speakerLabel(for: segment, in: session, speakerNames: [:], language: language), expected)
            XCTAssertEqual(MeetingTranscriptExporter.speakerLabel(for: segment, in: session, speakerNames: [:]), "Unknown speaker")
            XCTAssertEqual(PichiMeetingSummaryInput.turns(for: session), canonicalTurns)
            XCTAssertEqual(PichiMeetingSummaryInput.fingerprint(session), fingerprint)
        }
        session.transcriptSegments[0].text += " Исправление."
        XCTAssertNotEqual(PichiMeetingSummaryInput.fingerprint(session), fingerprint)
    }

    private actor InferenceGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        private(set) var calls = 0
        private(set) var stages: [String] = []
        private(set) var requests: [LLMClient.Config] = []
        func wait(configuration: LLMClient.Config, onFirstEnter: @Sendable () -> Void) async throws {
            guard let input = configuration.messages.last?["content"] as? String,
                  let fields = try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any]
            else { throw LLMError.invalidResponse }
            self.calls += 1
            self.requests.append(configuration)
            self.stages.append(fields["candidate"] == nil ? "map" : "support-review")
            if self.calls == 1 { onFirstEnter() }
            if self.released { return }
            await withCheckedContinuation { self.continuation = $0 }
        }
        func release() {
            self.released = true
            self.continuation?.resume()
            self.continuation = nil
        }
    }

    private func session() -> MeetingSession {
        let microphone = MeetingMicrophoneIdentity(captureDeviceID: "fixture-mic", displayName: "Mic")
        var session = MeetingSession(configuration: .init(mode: .inRoom, title: "Synthetic localization fixture", languageCode: "ru", microphone: microphone),
                                     timebase: .init(startedHostTime: 1, machTimebaseNumerator: 1, machTimebaseDenominator: 1,
                                                     firstPresentationTime: .init(value: 0, timescale: 1000)))
        let trackID = UUID()
        let speakerID = UUID()
        session.audioTracks = [.init(id: trackID, kind: .microphone, sourceIdentifier: "fixture", sourceDisplayName: "Mic",
                                     format: nil, timebase: session.timebase, health: .waiting, chunks: [])]
        session.speakers = [.init(id: speakerID, displayName: "Иван", diarizationClusterID: "fixture",
                                  trackKind: .microphone, isLocalUser: false, identityCandidates: [])]
        session.transcriptSegments = [.init(id: UUID(), start: .init(value: 0, timescale: 1000), end: .init(value: 1000, timescale: 1000),
                                            sourceTrackID: trackID, speakerID: speakerID, text: "Решили оставить цену.",
                                            revision: 0, status: .final, overlap: .none, completeness: .complete)]
        return session
    }

    private func withLocalizedBundle(_ body: (Bundle) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PichiPresentation-\(UUID().uuidString).bundle")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "ai.pichi.presentation.fixture", "CFBundleDevelopmentRegion": "en"], format: .xml, options: 0)
        try info.write(to: directory.appendingPathComponent("Info.plist"))
        let strings = [
            "Settings": "Настройки",
            "Dashboard": "Главная",
            "File Transcription": "Распознавание файлов",
            "Processing transcript part %lld of %lld…": "Обработка части %lld из %lld…",
            "No installed models found. Install a model in Ollama or LM Studio, then refresh.": "Установленных моделей нет.",
            "Could not list local models. Start Ollama or LM Studio's local server and check the endpoint.": "Не удалось получить локальные модели.",
            "Checking…": "Проверка…",
            "Storage availability unavailable": "Объём хранилища неизвестен",
            "%@ available": "Доступно: %@",
            "Transcribing audio (%llds)...": "Распознавание аудио (%lld с)...",
            "Transcribing... %lld%%": "Распознавание... %lld%%",
            "Transcribing speaker segments (%lld/%lld)...": "Распознавание реплик участников (%lld/%lld)...",
        ]
        for (language, values) in ["ru": strings, "fr": ["Processing transcript part %lld of %lld…": "Traitement de la partie %lld sur %lld…"]] {
            let translations = directory.appendingPathComponent("\(language).lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: translations, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
            try data.write(to: translations.appendingPathComponent("Localizable.strings"))
        }
        try body(XCTUnwrap(Bundle(path: directory.path)))
    }
}

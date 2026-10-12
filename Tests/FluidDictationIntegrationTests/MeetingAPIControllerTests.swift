@testable import FluidVoice_Debug
import Foundation
import AVFoundation
import Network
import XCTest

@MainActor
final class MeetingAPIControllerTests: XCTestCase {
    func testListReturnsNewestMeetingsWithIDsAndBoundedLimit() async throws {
        try await self.withStore { store in
            let older = self.makeSession(startedAt: Date(timeIntervalSince1970: 1_700_000_000))
            let newer = self.makeSession(startedAt: older.startedAt.addingTimeInterval(120))
            try await store.create(newer)
            try await store.create(older)
            let router = LocalAPIRouter(meetingStore: store)

            for limit in ["1", "0", "-1"] {
                let response = await router.route(self.request(path: "/v1/meetings", query: ["limit": limit]))
                XCTAssertEqual(response.status, 200)
                let body = try self.json(response)
                XCTAssertEqual(body["count"] as? Int, 1)
                let items = try XCTUnwrap(body["items"] as? [[String: Any]])
                XCTAssertEqual(items.count, 1)
                XCTAssertEqual(items.first?["id"] as? String, newer.id.uuidString)
                XCTAssertEqual(items.first?["state"] as? String, "completed")
                XCTAssertEqual(items.first?["segmentCount"] as? Int, 1)
                XCTAssertEqual(items.first?["transcriptIsComplete"] as? Bool, true)
                XCTAssertNil(items.first?["audioTracks"])
            }

            let response = await router.route(self.request(path: "/v1/meetings"))
            let items = try XCTUnwrap(self.json(response)["items"] as? [[String: Any]])
            XCTAssertEqual(items.compactMap { $0["id"] as? String }, [newer.id.uuidString, older.id.uuidString])
        }
    }

    func testJSONTranscriptPreservesTextTimestampsSpeakersAndEchoFlags() async throws {
        try await self.withStore { store in
            var session = self.makeSession()
            session.transcriptSegments[0].text = String(repeating: "Résumé 👋\n", count: 2000)
            var earlier = session.transcriptSegments[0]
            earlier.id = UUID()
            earlier.start = MeetingMediaTime(value: 0, timescale: 1000)
            earlier.end = MeetingMediaTime(value: 500, timescale: 1000)
            earlier.text = "Echo"
            earlier.isLikelyEcho = true
            session.transcriptSegments.append(earlier)
            try await store.create(session)

            let router = LocalAPIRouter(meetingStore: store)
            let response = await router.route(self.request(query: ["id": session.id.uuidString.lowercased()]))
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(response.headers["Content-Type"], "application/json; charset=utf-8")
            let body = try self.json(response)
            XCTAssertEqual(body["schemaVersion"] as? Int, 1)
            XCTAssertEqual(body["title"] as? String, "API meeting")
            let segments = try XCTUnwrap(body["segments"] as? [[String: Any]])
            XCTAssertEqual(segments.count, 2)
            XCTAssertEqual(segments[0]["text"] as? String, "Echo")
            XCTAssertEqual(segments[0]["isLikelyEcho"] as? Bool, true)
            XCTAssertEqual(segments[1]["text"] as? String, session.transcriptSegments[0].text)
            XCTAssertEqual(segments[1]["startSeconds"] as? Double, 1.25)
            XCTAssertEqual(segments[1]["endSeconds"] as? Double, 2.5)
            XCTAssertEqual(segments[1]["speakerID"] as? String, session.speakers[0].id.uuidString)
            let speakers = try XCTUnwrap(body["speakers"] as? [[String: Any]])
            XCTAssertEqual(speakers.first?["displayName"] as? String, "Maya")
            XCTAssertNil(body["selectedMicrophone"])
            XCTAssertNil(body["audioTracks"])
        }
    }

    func testTextTranscriptReflectsSavedCorrectionsAndOmitsEchoes() async throws {
        try await self.withStore { store in
            var session = self.makeSession()
            try await store.create(session)
            let router = LocalAPIRouter(meetingStore: store)
            _ = await router.route(self.request(query: ["id": session.id.uuidString, "format": "text"]))

            session.speakers[0].displayName = "Renée"
            session.transcriptSegments[0].text = "Corrected words 👋"
            var echo = session.transcriptSegments[0]
            echo.id = UUID()
            echo.text = "Hidden echo"
            echo.isLikelyEcho = true
            session.transcriptSegments.append(echo)
            try await store.save(session)

            let response = await router.route(self.request(query: ["id": session.id.uuidString, "format": "text"]))
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(response.headers["Content-Type"], "text/plain; charset=utf-8")
            XCTAssertEqual(String(data: response.body, encoding: .utf8), "[00:01] Renée: Corrected words 👋")
        }
    }

    func testExistingMeetingWithoutTranscriptReturnsEmptyExport() async throws {
        try await self.withStore { store in
            var session = self.makeSession()
            session.state = .recording
            session.endedAt = nil
            session.transcriptSegments = []
            session.transcriptIsComplete = nil
            try await store.create(session)
            let router = LocalAPIRouter(meetingStore: store)

            let response = await router.route(self.request(query: ["id": session.id.uuidString]))
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(try (self.json(response)["segments"] as? [Any])?.count, 0)
            let text = await router.route(self.request(query: ["id": session.id.uuidString, "format": "text"]))
            XCTAssertEqual(text.status, 200)
            XCTAssertTrue(text.body.isEmpty)
        }
    }

    func testInvalidIDAndFormatReturnBadRequest() async throws {
        try await self.withStore { store in
            let router = LocalAPIRouter(meetingStore: store)
            let queries = [
                [:], ["id": ""], ["id": "../session.json"],
                ["id": UUID().uuidString, "format": "xml"],
            ]
            for query in queries {
                let response = await router.route(self.request(query: query))
                XCTAssertEqual(response.status, 400)
                XCTAssertNotNil(try self.json(response)["error"] as? String)
            }
        }
    }

    func testMissingAndDeletedMeetingsReturnNotFound() async throws {
        try await self.withStore { store in
            let session = self.makeSession()
            let router = LocalAPIRouter(meetingStore: store)
            let request = self.request(query: ["id": session.id.uuidString])
            let missing = await router.route(request)
            XCTAssertEqual(missing.status, 404)

            try await store.create(session)
            try await store.delete(id: session.id)
            let deleted = await router.route(request)
            XCTAssertEqual(deleted.status, 404)
        }
    }

    func testRoutesRejectWritesAndUnknownPaths() async throws {
        try await self.withStore { store in
            let router = LocalAPIRouter(meetingStore: store)
            for path in ["/v1/meetings", "/v1/meetings/transcript"] {
                for method in ["POST", "DELETE", "PUT"] {
                    let response = await router.route(self.request(method: method, path: path))
                    XCTAssertEqual(response.status, 405)
                }
            }
            let unknown = await router.route(self.request(path: "/v1/meetings/unknown"))
            XCTAssertEqual(unknown.status, 404)
            let health = await router.route(self.request(path: "/v1/health"))
            XCTAssertEqual(health.status, 200)
        }
    }

    func testCorruptMeetingReturnsServiceUnavailable() async throws {
        try await self.withStore { store in
            let session = self.makeSession()
            try await store.create(session)
            let directory = try await store.sessionDirectory(for: session.id)
            try Data("invalid private manifest".utf8).write(to: directory.appendingPathComponent("session.json"))
            let response = await LocalAPIRouter(meetingStore: store).route(self.request(query: ["id": session.id.uuidString]))
            XCTAssertEqual(response.status, 503)
            let body = try XCTUnwrap(String(data: response.body, encoding: .utf8))
            XCTAssertFalse(body.contains(directory.path))
        }
    }

    func testEmptyListAndUnavailableStore() async throws {
        try await self.withStore { store in
            let response = await LocalAPIRouter(meetingStore: store).route(self.request(path: "/v1/meetings"))
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(try self.json(response)["count"] as? Int, 0)
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root)
        let store = MeetingSessionStore(rootDirectory: root)
        let response = await LocalAPIRouter(meetingStore: store).route(self.request(path: "/v1/meetings"))
        XCTAssertEqual(response.status, 503)
    }

    private func withStore(_ body: (MeetingSessionStore) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(MeetingSessionStore(rootDirectory: root))
    }

    private func request(
        method: String = "GET",
        path: String = "/v1/meetings/transcript",
        query: [String: String] = [:]
    ) -> LocalAPI.Request {
        LocalAPI.Request(method: method, path: path, query: query, headers: [:], body: Data())
    }

    private func json(_ response: LocalAPI.Response) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    private func makeSession(startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> MeetingSession {
        let configuration = MeetingCaptureConfiguration(
            mode: .inRoom,
            title: "API meeting",
            microphone: MeetingMicrophoneIdentity(captureDeviceID: "mic", displayName: "Mic")
        )
        var session = MeetingSession(
            configuration: configuration,
            startedAt: startedAt,
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil
            )
        )
        session.state = .completed
        session.endedAt = startedAt.addingTimeInterval(60)
        session.transcriptIsComplete = true
        let trackID = UUID()
        let speakerID = UUID()
        session.audioTracks = [MeetingAudioTrack(
            id: trackID,
            kind: .microphone,
            sourceIdentifier: "mic",
            sourceDisplayName: "Mic",
            format: nil,
            timebase: session.timebase,
            health: .waiting,
            chunks: []
        )]
        session.speakers = [MeetingSessionSpeaker(
            id: speakerID,
            displayName: "Maya",
            diarizationClusterID: nil,
            trackKind: .microphone,
            isLocalUser: false,
            identityCandidates: []
        )]
        session.transcriptSegments = [MeetingTranscriptSegment(
            id: UUID(),
            start: MeetingMediaTime(value: 1250, timescale: 1000),
            end: MeetingMediaTime(value: 2500, timescale: 1000),
            sourceTrackID: trackID,
            speakerID: speakerID,
            text: "Hello",
            revision: 1,
            status: .final,
            overlap: .none,
            completeness: .complete
        )]
        return session
    }
}

@MainActor
private final class APIRequestGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    func wait() async {
        if self.isOpen { return }
        await withCheckedContinuation { self.waiters.append($0) }
    }
    func open() {
        self.isOpen = true
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private final nonisolated class APICancellationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { self.lock.withLock { self.value } }
    func mark() { self.lock.withLock { self.value = true } }
}

@MainActor
private func waitForAPICondition(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await condition()) {
        if ContinuousClock.now >= deadline { throw APIWaitError.timedOut }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private enum APIWaitError: Error { case timedOut }

@MainActor
final class TranscriptionExecutorCancellationTests: XCTestCase {
    func testQueuedCallerCancellationNeverInvokesItsOperationOrCancelsPredecessor() async throws {
        let executor = TranscriptionExecutor()
        let gate = APIRequestGate()
        var events: [String] = []
        let first = Task { @MainActor in
            try await executor.run {
                events.append("first")
                await gate.wait()
                XCTAssertFalse(Task.isCancelled)
                return "first-result"
            }
        }
        self.addTeardownBlock { @MainActor in
            gate.open()
            await executor.cancelAndAwaitPending()
            _ = await first.result
        }
        try await waitForAPICondition { events == ["first"] }
        let queued = Task { @MainActor in
            try await executor.run { events.append("queued"); return "wrong" }
        }
        self.addTeardownBlock { @MainActor in gate.open(); _ = await queued.result }
        try await waitForAPICondition { await executor.pendingOperationCountForTesting == 2 }
        queued.cancel()
        gate.open()
        let firstResult = try await first.value
        XCTAssertEqual(firstResult, "first-result")
        do { _ = try await queued.value; XCTFail("Queued cancelled work must not run") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(events, ["first"])
    }

    func testCancellationJoinsNoncooperativeOperationAndRejectsLateSuccess() async throws {
        let executor = TranscriptionExecutor()
        let gate = APIRequestGate()
        var entered = false
        var returned = false
        var observedCancellation = false
        let task = Task { @MainActor in
            defer { returned = true }
            return try await executor.run {
                entered = true
                await gate.wait()
                observedCancellation = Task.isCancelled
                return "late-success"
            }
        }
        self.addTeardownBlock { @MainActor in gate.open(); _ = await task.result }
        try await waitForAPICondition { entered }
        task.cancel()
        XCTAssertFalse(returned)
        let pendingBeforeRelease = await executor.pendingOperationCountForTesting
        XCTAssertEqual(pendingBeforeRelease, 1)
        gate.open()
        do { _ = try await task.value; XCTFail("Late cancelled success must be suppressed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(observedCancellation)
        XCTAssertTrue(returned)
        let pendingAfterRelease = await executor.pendingOperationCountForTesting
        XCTAssertEqual(pendingAfterRelease, 0)
    }

    func testAlreadyCancelledCallerIsNotAdmitted() async throws {
        let executor = TranscriptionExecutor()
        var called = false
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await executor.run { called = true; return "wrong" }
        }
        do { _ = try await task.value; XCTFail("Cancelled admission must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(called)
        let pending = await executor.pendingOperationCountForTesting
        XCTAssertEqual(pending, 0)
    }

    func testDrainingOldWorkPreservesCancellationOwnershipOfNewQueuedWork() async throws {
        let executor = TranscriptionExecutor()
        let oldGate = APIRequestGate()
        let newGate = APIRequestGate()
        let oldCancelled = APICancellationSignal()
        let newCancelled = APICancellationSignal()
        var oldEntered = false
        var newEntered = false
        let old = Task { @MainActor in
            try await executor.run {
                oldEntered = true
                await withTaskCancellationHandler { await oldGate.wait() }
                onCancel: { oldCancelled.mark() }
                return "old"
            }
        }
        self.addTeardownBlock { @MainActor in
            oldGate.open(); newGate.open()
            await executor.cancelAndAwaitPending()
            _ = await old.result
        }
        try await waitForAPICondition { oldEntered }
        let firstDrain = Task { await executor.cancelAndAwaitPending() }
        try await waitForAPICondition { oldCancelled.isCancelled }
        let newer = Task { @MainActor in
            try await executor.run {
                newEntered = true
                await withTaskCancellationHandler { await newGate.wait() }
                onCancel: { newCancelled.mark() }
                return "new"
            }
        }
        self.addTeardownBlock { @MainActor in
            oldGate.open(); newGate.open()
            _ = await newer.result
            await firstDrain.value
        }
        try await waitForAPICondition { await executor.pendingOperationCountForTesting == 2 }
        oldGate.open()
        await firstDrain.value
        try await waitForAPICondition { newEntered }
        let newerPending = await executor.pendingOperationCountForTesting
        XCTAssertEqual(newerPending, 1)
        let secondDrain = Task { await executor.cancelAndAwaitPending() }
        try await waitForAPICondition { newCancelled.isCancelled }
        newGate.open()
        await secondDrain.value
        for task in [old, newer] {
            do { _ = try await task.value; XCTFail("The corresponding drain must cancel owned work") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
    }
}

@MainActor
final class LocalAPIRequestLifetimeTests: XCTestCase {
    private final class Route: LocalAPIRouteHandler {
        let body: (LocalAPI.Request) async -> LocalAPI.Response
        init(_ body: @escaping (LocalAPI.Request) async -> LocalAPI.Response) { self.body = body }
        func handle(_ request: LocalAPI.Request) async -> LocalAPI.Response { await self.body(request) }
    }

    private final class Transport {
        let handler: LocalAPIConnectionHandler
        var receives: [LocalAPIConnectionHandler.ReceiveCompletion] = []
        var responses: [Data] = []
        var cancellationCount = 0

        init(router: LocalAPIRouter, server: LocalAPIServer) {
            self.handler = LocalAPIConnectionHandler(
                connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), router: router
            )
            self.handler.receiveForTesting = { [weak self] completion in self?.receives.append(completion) }
            self.handler.sendForTesting = { [weak self] data, completion in
                self?.responses.append(data)
                completion(nil)
            }
            self.handler.cancelForTesting = { [weak self] in self?.cancellationCount += 1 }
            server.retainConnectionForTesting(self.handler)
            self.handler.startForTesting()
        }

        func deliver(_ data: Data? = nil, complete: Bool = false, error: NWError? = nil) throws {
            let completion = try XCTUnwrap(self.receives.first)
            self.receives.removeFirst()
            completion(data, complete, error)
        }

        func request(_ path: String, method: String = "GET", body: Data = Data(), complete: Bool = false) throws {
            var bytes = Data("\(method) \(path) HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
            bytes.append(body)
            try self.deliver(bytes, complete: complete)
        }
    }

    private final class BlockingProvider: TranscriptionProvider {
        let name = "Synthetic noncooperative API provider"
        let isAvailable = true
        let isReady = true
        let gate: APIRequestGate
        var entered = false
        var observedCancellation = false
        var callCount = 0
        init(gate: APIRequestGate) { self.gate = gate }
        func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {}
        func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
            self.callCount += 1
            self.entered = true
            await self.gate.wait()
            self.observedCancellation = Task.isCancelled
            return ASRTranscriptionResult(text: "late-result")
        }
    }

    func testServerStopJoinsNativeOwnerAndRetainsASRLeaseUntilInferenceDrains() async throws {
        let settings = SettingsStore.shared
        let oldModel = settings.selectedSpeechModel
        settings.selectedSpeechModel = .gigaam
        let gate = APIRequestGate()
        let provider = BlockingProvider(gate: gate)
        let asr = ASRService(meetingModelResidency: MeetingModelResidencyCoordinator())
        asr.modelProvidersForTesting[.gigaam] = provider
        asr.isAsrReady = true
        let router = LocalAPIRouter()
        router.register(method: "GET", path: "/v1/wait", handler: Route { _ in
            do {
                let result = try await asr.transcribeSamplesForAPI([Float](repeating: 0.125, count: 16_000))
                return LocalAPI.Response(status: 200, body: Data(result.text.utf8))
            } catch { return LocalAPI.error("cancelled", status: 503) }
        })
        let server = LocalAPIServer(router: router)
        let transport = Transport(router: router, server: server)
        self.addTeardownBlock { @MainActor in
            gate.open()
            await server.stop().value
            await asr.shutdownForTermination()
            settings.selectedSpeechModel = oldModel
        }
        try transport.request("/v1/wait")
        try await waitForAPICondition { provider.entered }
        XCTAssertEqual(asr.activeExclusiveActivity, .localAPI)
        let drain = server.stop()
        XCTAssertEqual(transport.cancellationCount, 1)
        XCTAssertEqual(server.activeConnectionCountForTesting, 1)
        XCTAssertEqual(asr.activeExclusiveActivity, .localAPI, "The retiring request still owns native inference")
        XCTAssertThrowsError(try asr.acquireExclusiveActivity(.dictation))
        gate.open()
        await drain.value
        XCTAssertTrue(provider.observedCancellation)
        XCTAssertTrue(transport.responses.isEmpty)
        XCTAssertNil(asr.activeExclusiveActivity)
        XCTAssertEqual(server.activeConnectionCountForTesting, 0)
    }

    func testDefinitePeerFailureCancelsOnlyItsRouteAndSuppressesLateResponse() async throws {
        let gate = APIRequestGate()
        var entered = false
        var cancelled = false
        let router = LocalAPIRouter()
        router.register(method: "GET", path: "/v1/wait", handler: Route { _ in
            entered = true
            await gate.wait()
            cancelled = Task.isCancelled
            return LocalAPI.Response(status: 200)
        })
        let server = LocalAPIServer(router: router)
        let waiting = Transport(router: router, server: server)
        self.addTeardownBlock { @MainActor in gate.open(); await server.stop().value }
        try waiting.request("/v1/wait")
        try await waitForAPICondition { entered }
        try waiting.deliver(error: .posix(.ECONNRESET))
        try await waitForAPICondition { waiting.cancellationCount == 1 }
        XCTAssertEqual(server.activeConnectionCountForTesting, 1)

        let healthy = Transport(router: router, server: server)
        try healthy.request("/v1/health")
        try await waitForAPICondition { healthy.responses.count == 1 && healthy.cancellationCount == 1 }
        XCTAssertEqual(server.activeConnectionCountForTesting, 1)
        gate.open()
        await waiting.handler.waitForPendingRequest()
        XCTAssertTrue(cancelled)
        XCTAssertTrue(waiting.responses.isEmpty)
        XCTAssertEqual(waiting.cancellationCount, 1)
        XCTAssertEqual(server.activeConnectionCountForTesting, 0)
    }

    func testCompleteRequestWithFinalBytesAndEOFStillReceivesResponse() async throws {
        var calls = 0
        let router = LocalAPIRouter()
        router.register(method: "GET", path: "/v1/final", handler: Route { _ in
            calls += 1
            return LocalAPI.Response(status: 200, body: Data("complete".utf8))
        })
        let server = LocalAPIServer(router: router)
        let transport = Transport(router: router, server: server)
        self.addTeardownBlock { @MainActor in await server.stop().value }
        try transport.request("/v1/final", complete: true)
        try await waitForAPICondition { transport.responses.count == 1 && transport.cancellationCount == 1 }
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(transport.handler.readEndedForTesting)
        XCTAssertEqual(server.activeConnectionCountForTesting, 0)
        XCTAssertTrue(String(data: transport.responses[0], encoding: .utf8)?.hasSuffix("complete") == true)
    }

    func testSendHalfCloseWhileRouteRunsDoesNotCancelValidHTTPWork() async throws {
        let gate = APIRequestGate()
        var entered = false
        var cancelled = false
        let router = LocalAPIRouter()
        router.register(method: "GET", path: "/v1/wait", handler: Route { _ in
            entered = true
            await gate.wait()
            cancelled = Task.isCancelled
            return LocalAPI.Response(status: 200)
        })
        let server = LocalAPIServer(router: router)
        let transport = Transport(router: router, server: server)
        self.addTeardownBlock { @MainActor in gate.open(); await server.stop().value }
        try transport.request("/v1/wait")
        try await waitForAPICondition { entered }
        try transport.deliver(complete: true)
        try await waitForAPICondition { transport.handler.readEndedForTesting }
        XCTAssertEqual(transport.cancellationCount, 0)
        XCTAssertEqual(server.activeConnectionCountForTesting, 1)
        gate.open()
        await transport.handler.waitForPendingRequest()
        try await waitForAPICondition { transport.cancellationCount == 1 }
        XCTAssertFalse(cancelled)
        XCTAssertEqual(transport.responses.count, 1)
        XCTAssertEqual(server.activeConnectionCountForTesting, 0)
    }

    func testCancellingFileRequestDoesNotStartAnotherChunkAfterNoncooperativeInference() async throws {
        let settings = SettingsStore.shared
        let oldModel = settings.selectedSpeechModel
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("APIFileCancellation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        settings.selectedSpeechModel = .gigaam
        let file = directory.appendingPathComponent("synthetic.wav")
        let gate = APIRequestGate()
        let provider = BlockingProvider(gate: gate)
        let asr = ASRService(meetingModelResidency: MeetingModelResidencyCoordinator())
        asr.modelProvidersForTesting[.gigaam] = provider
        asr.isAsrReady = true
        let router = LocalAPIRouter()
        let controller = InferenceAPIController { url in
            let output = try await asr.transcribeFileForAPI(url)
            return .init(text: output.result.text, confidence: output.result.confidence,
                         sampleCount: output.sampleCount, provider: provider.name)
        }
        router.register(method: "POST", path: "/v1/transcribe", handler: controller)
        let server = LocalAPIServer(router: router)
        let transport = Transport(router: router, server: server)
        self.addTeardownBlock { @MainActor in
            gate.open()
            await server.stop().value
            await asr.shutdownForTermination()
            settings.selectedSpeechModel = oldModel
            try? FileManager.default.removeItem(at: directory)
        }
        try Self.writeLongAudio(to: file)
        let body = try JSONSerialization.data(withJSONObject: ["path": file.path])
        try transport.request("/v1/transcribe", method: "POST", body: body)
        try await waitForAPICondition { provider.entered }
        let drain = server.stop()
        XCTAssertEqual(asr.activeExclusiveActivity, .localAPI)
        gate.open()
        await drain.value
        XCTAssertEqual(provider.callCount, 1, "A cancelled first chunk must not dispatch the remaining tail")
        XCTAssertTrue(provider.observedCancellation)
        XCTAssertTrue(transport.responses.isEmpty)
        XCTAssertNil(asr.activeExclusiveActivity)
        XCTAssertEqual(server.activeConnectionCountForTesting, 0)
    }

    private static func writeLongAudio(to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        channel.update(repeating: 0.125, count: 16_000)
        var remaining = 20 * 60 * 16_000 + 4_000
        while remaining > 0 {
            let count = min(16_000, remaining)
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            remaining -= count
        }
    }

    func testOldListenerCallbacksCannotRetireNewGenerationOrConnection() async throws {
        let router = LocalAPIRouter()
        let server = LocalAPIServer(router: router)
        let old = server.beginListenerGenerationForTesting()
        await server.stop().value
        let current = server.beginListenerGenerationForTesting()
        let transport = Transport(router: router, server: server)
        self.addTeardownBlock { @MainActor in await server.stop().value }
        server.handleStateForTesting(.cancelled, generation: old)
        server.handleStateForTesting(.failed(.posix(.ECONNRESET)), generation: old)
        server.handleConnectionForTesting(NWConnection(host: "127.0.0.1", port: 9, using: .tcp), generation: old)
        XCTAssertEqual(server.listenerGenerationForTesting, current)
        XCTAssertEqual(transport.cancellationCount, 0)
        XCTAssertEqual(server.activeConnectionCountForTesting, 1)
        try transport.request("/v1/health")
        try await waitForAPICondition { transport.responses.count == 1 }
    }

    func testLateReceiveAfterCloseCannotDispatchAndRepeatedCloseIsHarmless() async throws {
        var calls = 0
        let router = LocalAPIRouter()
        router.register(method: "GET", path: "/v1/late", handler: Route { _ in
            calls += 1
            return LocalAPI.Response(status: 200)
        })
        let server = LocalAPIServer(router: router)
        let transport = Transport(router: router, server: server)
        transport.handler.cancel()
        transport.handler.cancel()
        try transport.request("/v1/late")
        await server.stop().value
        // Let the already-delivered transport callback reach its production closed guard.
        await Task { @MainActor in }.value
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(transport.cancellationCount, 1)
        XCTAssertTrue(transport.responses.isEmpty)
        XCTAssertEqual(server.activeConnectionCountForTesting, 0)
    }
}

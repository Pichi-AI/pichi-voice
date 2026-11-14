import CryptoKit
@testable import FluidVoice_Debug
import Foundation
import XCTest

final nonisolated class UpdateDownloadTests: XCTestCase {
    func testWorkspaceIsExclusiveAndReclaimsOnlyOwnedStaleFilesAcrossRestarts() throws {
        let fixture = try DownloadFixture()
        defer { fixture.close() }
        let installation = fixture.root.appendingPathComponent("Fixture.app")
        var first: UpdateDownload.Workspace? = try .open(installation: installation, namespace: "fixture", temporaryDirectory: fixture.root)
        let directory = try XCTUnwrap(first?.directory)
        let payload = directory.appendingPathComponent("previous.dmg")
        try Data("orphaned download".utf8).write(to: payload)
        try withExtendedLifetime(first) {
            XCTAssertThrowsError(try UpdateDownload.Workspace.open(installation: installation, namespace: "fixture", temporaryDirectory: fixture.root))
        }
        first = nil
        let next = try UpdateDownload.Workspace.open(installation: installation, namespace: "fixture", temporaryDirectory: fixture.root)
        XCTAssertEqual(next.directory, directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
    }

    func testWorkspacePreservesUnownedStagingInsteadOfDeletingIt() throws {
        let fixture = try DownloadFixture()
        defer { fixture.close() }
        let installation = fixture.root.appendingPathComponent("Fixture.app")
        var first: UpdateDownload.Workspace? = try .open(installation: installation, namespace: "fixture", temporaryDirectory: fixture.root)
        let directory = try XCTUnwrap(first?.directory)
        first = nil
        let marker = directory.appendingPathComponent("ownership")
        let unrelated = Data("different owner".utf8)
        try unrelated.write(to: marker)
        XCTAssertThrowsError(try UpdateDownload.Workspace.open(installation: installation, namespace: "fixture", temporaryDirectory: fixture.root))
        XCTAssertEqual(try Data(contentsOf: marker), unrelated)
    }

    func testDownloadStreamsExactBytesAndChecksOptionalGitHubDigest() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.close() }
        let payload = Data(repeating: 0x37, count: 150_001)
        fixture.responseData = payload
        let hash = "sha256:" + SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        try await UpdateDownload.fetch(fixture.selection(digest: hash), session: fixture.session, to: fixture.destination)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), payload)
        XCTAssertEqual(fixture.requests, 1)
    }

    func testDownloadRejectsHTTPErrorOversizedResponseAndDigestMismatch() async throws {
        for mode in ["http", "oversized", "digest"] {
            let fixture = try DownloadFixture()
            defer { fixture.close() }
            fixture.status = mode == "http" ? 503 : 200
            fixture.contentLength = mode == "oversized" ? UpdateDownload.maximumBytes + 1 : nil
            do {
                try await UpdateDownload.fetch(fixture.selection(digest: mode == "digest" ? "sha256:wrong" : nil), session: fixture.session, to: fixture.destination)
                XCTFail("The \(mode) response must fail")
            } catch {}
        }
    }

    func testMetadataRejectsHTTPErrorAndOversizedResponse() async throws {
        for oversized in [false, true] {
            let fixture = try DownloadFixture()
            defer { fixture.close() }
            fixture.status = oversized ? 200 : 429
            fixture.contentLength = oversized ? 8 * 1024 * 1024 + 1 : nil
            do {
                _ = try await UpdateDownload.metadata(URLRequest(url: fixture.url), session: fixture.session)
                XCTFail("Untrusted release metadata must fail")
            } catch {}
        }
    }

    func testCancellationJoinsTransportWithoutWaitingForDeadline() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.close() }
        fixture.hold = true
        let task = Task { try await UpdateDownload.fetch(fixture.selection(), session: fixture.session, to: fixture.destination) }
        for _ in 0..<200 {
            if fixture.requests > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(fixture.requests, 1)
        task.cancel()
        do { try await task.value; XCTFail("Cancelled download must fail") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        // URLSession stops the transport on its own queue, so the stop can land just after fetch returns.
        // It must still arrive promptly, long before the 60 second request deadline.
        var activeTasks = await fixture.session.allTasks
        for _ in 0..<400 where !activeTasks.isEmpty || fixture.cancellations == 0 {
            try await Task.sleep(for: .milliseconds(5))
            activeTasks = await fixture.session.allTasks
        }
        XCTAssertTrue(activeTasks.isEmpty, "Cancellation leaves no owned URLSession transport task active")
        XCTAssertGreaterThanOrEqual(fixture.cancellations, 1)
    }
}

private final nonisolated class DownloadFixture: @unchecked Sendable {
    let token = UUID().uuidString
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateDownloadTests-" + UUID().uuidString)
    let url = URL(string: "https://github.com/Pichi-AI/pichi-voice/releases/download/v0.1.0+71-public.1/Pichi-Voice-0.1.0-71-macos-arm64.dmg")!
    var destination: URL { root.appendingPathComponent("fixture.dmg") }
    let session: URLSession
    private let lock = NSLock()
    private var bytes = Data("synthetic".utf8)
    private var httpStatus = 200
    private var length: Int64?
    private var held = false
    private var count = 0
    private var cancelled = 0
    var responseData: Data { get { lock.withLock { bytes } } set { lock.withLock { bytes = newValue } } }
    var status: Int { get { lock.withLock { httpStatus } } set { lock.withLock { httpStatus = newValue } } }
    var contentLength: Int64? { get { lock.withLock { length } } set { lock.withLock { length = newValue } } }
    var hold: Bool { get { lock.withLock { held } } set { lock.withLock { held = newValue } } }
    var requests: Int { lock.withLock { count } }
    var cancellations: Int { lock.withLock { cancelled } }
    init() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Download-Fixture": token]
        session = URLSession(configuration: configuration)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        DownloadProtocol.add(self, token: token)
    }
    func selection(digest: String? = nil) -> UpdateReleaseSelection {
        .init(tag: "v0.1.0+71-public.1", version: "0.1.0", build: "71", assetName: url.lastPathComponent, assetURL: url, digest: digest)
    }
    func respond(_ loading: DownloadProtocol) {
        let (data, status, length, held) = lock.withLock {
            count += 1
            return (bytes, httpStatus, length ?? Int64(bytes.count), self.held)
        }
        guard !held else { return }
        let response = HTTPURLResponse(url: loading.request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Length": String(length)])!
        loading.client?.urlProtocol(loading, didReceive: response, cacheStoragePolicy: .notAllowed)
        loading.client?.urlProtocol(loading, didLoad: data)
        loading.client?.urlProtocolDidFinishLoading(loading)
    }
    func stop() { lock.withLock { cancelled += 1 } }
    func close() {
        session.invalidateAndCancel()
        DownloadProtocol.remove(token)
        try? FileManager.default.removeItem(at: root)
    }
}

private final nonisolated class DownloadProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var fixtures: [String: DownloadFixture] = [:]
    private var owner: DownloadFixture?
    static func add(_ fixture: DownloadFixture, token: String) { lock.withLock { fixtures[token] = fixture } }
    static func remove(_ token: String) { _ = lock.withLock { fixtures.removeValue(forKey: token) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let token = request.value(forHTTPHeaderField: "X-Download-Fixture"),
              let fixture = Self.lock.withLock({ Self.fixtures[token] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        owner = fixture
        fixture.respond(self)
    }
    override func stopLoading() { owner?.stop() }
}

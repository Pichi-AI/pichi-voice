@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Server discovery exercises the shared repository through an isolated session.
/// No real server, model inference, user settings or credentials are accessed.
private final class LocalTextModelDiscoveryProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "model-catalog.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = self.request.url else { return }
        let body = self.request.value(forHTTPHeaderField: "Authorization") == nil && url.path == "/v1/models"
            ? #"{"data":[{"id":"qwen3.5:9b"},{"id":"user-imported:latest"},{"id":"qwen3.5:4b"}]}"#
            : #"{"data":[]}"#
        self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                                 headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: Data(body.utf8))
        self.client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class LocalTextModelDiscoveryTests: XCTestCase {
    func testDiscoveryUsesProvidedSessionAndKeepsUnknownInstalledIDs() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalTextModelDiscoveryProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let models = try await ModelRepository.shared.fetchModels(for: "ollama", baseURL: "https://model-catalog.invalid/v1",
                                                                  apiKey: nil, session: session)
        XCTAssertEqual(models, ["qwen3.5:4b", "qwen3.5:9b", "user-imported:latest"])
        XCTAssertEqual(ModelRepository.selectionAfterRefresh(preferred: "qwen3.5:4b", models: models, isLocal: true), "qwen3.5:4b")
        XCTAssertEqual(ModelRepository.selectionAfterRefresh(preferred: "", models: models, isLocal: true), "")
    }

    func testBundledMetadataDoesNotClaimUndiscoveredAvailability() throws {
        let catalog = ModelRepository.shared.localTextModels
        XCTAssertFalse(catalog.models.isEmpty, "The metadata resource must be included in the app bundle")
        let model = try XCTUnwrap(catalog.models.first { $0.aliases.contains("qwen3.5:4b") })
        XCTAssertNil(model.installedID(in: ["qwen3.5:9b"]))
        XCTAssertEqual(model.installedID(in: ["qwen3.5:4b"]), "qwen3.5:4b")
        XCTAssertEqual(catalog.displayName(for: "private-import", providerID: "ollama"), "private-import")
    }

    func testLocalRefreshPreservesExplicitUnavailableChoiceAndRemoteBehavior() {
        let models = ["large-first", "compact-second"]
        XCTAssertEqual(ModelRepository.selectionAfterRefresh(preferred: "previous-local", models: models, isLocal: true), "previous-local")
        XCTAssertEqual(ModelRepository.selectionAfterRefresh(preferred: "compact-second", models: models, isLocal: false), "compact-second")
        XCTAssertEqual(ModelRepository.selectionAfterRefresh(preferred: "missing", models: models, isLocal: false), "large-first")
    }
}

@testable import FluidVoice_Debug
import XCTest

final class FeedbackClientTests: XCTestCase {
    private var draft: FeedbackSubmission {
        FeedbackSubmission(email: " TEAM@example.com ", message: " Test message ", category: .issue, appDetails: nil)
    }

    func testPayloadPreservesBackendContractAndOptIn() throws {
        let data = try JSONEncoder().encode(self.draft)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(Set(object.keys), ["email_id", "feedback"])
        XCTAssertEqual(object["email_id"], "team@example.com")
        XCTAssertEqual(object["feedback"], "[Report an issue]\nTest message")
        XCTAssertFalse(self.draft.content.contains("macOS"))
        let detailed = FeedbackSubmission(email: "team@example.com", message: "hello", category: .idea, appDetails: "macOS test")
        XCTAssertTrue(detailed.content.contains("macOS test"))
    }

    func testValidationMatchesServerLimitsIncludingEmoji() {
        for email in ["bad", "a@b", ".a@example.com", "a..b@example.com", "a b@example.com"] {
            XCTAssertFalse(FeedbackSubmission.isValidEmail(email), email)
        }
        XCTAssertTrue(FeedbackSubmission.isValidEmail(" first.last+test@example.com "))
        for message in ["  \n", String(repeating: "a", count: 4501), String(repeating: "😀", count: 2251)] {
            XCTAssertFalse(FeedbackSubmission(email: "a@example.com", message: message, category: .issue, appDetails: nil).isValid)
        }
        XCTAssertTrue(FeedbackSubmission(email: "a@example.com", message: String(repeating: "a", count: 4500), category: .issue, appDetails: FeedbackSubmission.appDetails).isValid)
        XCTAssertFalse(FeedbackSubmission(email: "a@example.com", message: "hello", category: .issue, appDetails: String(repeating: "x", count: 5000)).isValid)
    }

    func testSuccessRequiresReceiptAndUsesExpectedRequest() async throws {
        let client = self.client { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.invalid/feedback")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.timeoutInterval, 30)
            return (200, #"{"message":"Feedback submitted successfully"}"#)
        }
        defer { client.session.invalidateAndCancel() }
        try await client.send(self.draft)
    }

    func testHTTPFailuresAndFalseSuccess() async {
        for (status, body, expected) in [
            (429, "{}", FeedbackClient.Failure.rateLimited),
            (400, "{}", .rejected), (500, "{}", .server),
            (200, "<html>Sign in</html>", .unconfirmed), (200, "{}", .unconfirmed),
        ] {
            let client = self.client { _ in (status, body) }
            do {
                try await client.send(self.draft)
                XCTFail("Expected a failure for \(status)")
            } catch {
                XCTAssertEqual(error.localizedDescription, expected.localizedDescription)
            }
            client.session.invalidateAndCancel()
        }
    }

    func testTimeoutDoesNotAutomaticallyRetry() async {
        var requests = 0
        let client = self.client { _ in
            requests += 1
            throw URLError(.timedOut)
        }
        defer { client.session.invalidateAndCancel() }
        do {
            try await client.send(self.draft)
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error.localizedDescription, FeedbackClient.Failure.connection.localizedDescription)
        }
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(self.draft.message, " Test message ")
    }

    func testInvalidDraftNeverHitsNetwork() async {
        let client = self.client { _ in XCTFail("No network expected"); return (200, "{}") }
        defer { client.session.invalidateAndCancel() }
        do {
            try await client.send(FeedbackSubmission(email: "invalid", message: "hello", category: .issue, appDetails: nil))
            XCTFail("Expected validation failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, FeedbackClient.Failure.invalid.localizedDescription)
        }
    }

    func testDistributionWithoutEndpointNeverHitsNetwork() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FeedbackURLProtocol.self]
        FeedbackURLProtocol.handler = { _ in XCTFail("Disabled feedback must not upload"); return (200, "{}") }
        let client = FeedbackClient(session: URLSession(configuration: config))
        defer { client.session.invalidateAndCancel() }
        do {
            try await client.send(self.draft)
            XCTFail("Expected unavailable endpoint")
        } catch {
            XCTAssertEqual(error.localizedDescription, FeedbackClient.Failure.notConfigured.localizedDescription)
        }
    }

    func testFeedbackRoutesRespectDistributionConfiguration() throws {
        var distribution = BrandDistribution.unconfigured
        XCTAssertEqual(FeedbackDelivery(distribution: distribution), .support)
        distribution.feedbackEmail = "team@example.com"
        XCTAssertEqual(FeedbackDelivery(distribution: distribution), .email("team@example.com"))
        for invalid in ["a@b.com,b@c.com", "Name <a@b.com>", "a@b.com\r\n", "a@b.com?bcc=c@d.com"] {
            distribution.feedbackEmail = invalid
            XCTAssertThrowsError(try distribution.validate(), invalid)
        }
        distribution.feedbackEmail = "team@example.com"
        distribution.feedbackEndpoint = "https://example.invalid/feedback"
        try distribution.validate()
        XCTAssertEqual(FeedbackDelivery(distribution: distribution), .endpoint(try XCTUnwrap(URL(string: "https://example.invalid/feedback"))))
    }

    @MainActor
    func testPackagedFormHandsUserDraftToMailWithoutPostingOrClaimingReceipt() async throws {
        let delivery = FeedbackDelivery(distribution: AppBrand.distribution)
        XCTAssertEqual(delivery, .email("hello@pichi.ai"))
        let client = self.client { _ in XCTFail("Mail handoff must not POST"); return (200, "{}") }
        defer { client.session.invalidateAndCancel() }
        for details in [nil, "Test app and macOS versions"] as [String?] {
            let submission = FeedbackSubmission(email: "", message: "  Example report  ", category: .idea, appDetails: details)
            XCTAssertTrue(delivery.accepts(submission))
            XCTAssertFalse(submission.isValid, "The HTTPS API still requires a reply address")
            var handoffs = 0
            let outcome = try await delivery.submit(submission, session: client.session) { recipient, subject, body in
                handoffs += 1
                XCTAssertEqual(recipient, "hello@pichi.ai")
                XCTAssertTrue(subject.contains(PichiLocalization.text(FeedbackCategory.idea.rawValue)))
                XCTAssertEqual(body, "[Suggest an idea]\nExample report" + (details.map { "\n\n--- App details ---\n" + $0 } ?? ""))
                return true
            }
            XCTAssertEqual(handoffs, 1)
            XCTAssertEqual(outcome, .handedToMail)
        }
    }

    @MainActor
    func testUnavailableMailAndBlankDraftDoNotReportDelivery() async {
        let delivery = FeedbackDelivery.email("support@example.com")
        do {
            _ = try await delivery.submit(self.draft) { _, _, _ in false }
            XCTFail("Unavailable mail must preserve an actionable failure")
        } catch {
            XCTAssertEqual(error as? FeedbackClient.Failure, .mailUnavailable)
        }
        let empty = FeedbackSubmission(email: "", message: "  ", category: .issue, appDetails: nil)
        XCTAssertFalse(delivery.accepts(empty))
        do {
            _ = try await delivery.submit(empty) { _, _, _ in XCTFail("Empty draft composed"); return true }
            XCTFail("Empty draft accepted")
        } catch {
            XCTAssertEqual(error as? FeedbackClient.Failure, .invalid)
        }
    }

    @MainActor
    func testEndpointDeliveryUsesReceiptWithoutOpeningMail() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://example.invalid/feedback"))
        let client = self.client { request in
            XCTAssertEqual(request.url, endpoint)
            return (200, #"{"message":"Feedback submitted successfully"}"#)
        }
        defer { client.session.invalidateAndCancel() }
        let outcome = try await FeedbackDelivery.endpoint(endpoint).submit(self.draft, session: client.session) { _, _, _ in
            XCTFail("Configured API must use the existing HTTPS client")
            return false
        }
        XCTAssertEqual(outcome, .received)
    }

    @MainActor
    func testHistoryReportOpensConfiguredBugFormWithoutPreparingAnExample() {
        var opened: [URL] = []
        TranscriptionFeedbackReporter.presentReport(
            openExample: { XCTFail("No dictation text should be prepared for an unconfigured collector") },
            openIssuePage: { opened.append($0) }
        )
        XCTAssertEqual(opened, [AppBrand.issueReportURL])
    }

    private func client(_ handler: @escaping (URLRequest) throws -> (Int, String)) -> FeedbackClient {
        FeedbackURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FeedbackURLProtocol.self]
        return FeedbackClient(session: URLSession(configuration: config), endpoint: URL(string: "https://example.invalid/feedback"))
    }
}

private class FeedbackURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler, let url = self.request.url else { throw URLError(.badURL) }
            let (status, body) = try handler(self.request)
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else { throw URLError(.badServerResponse) }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

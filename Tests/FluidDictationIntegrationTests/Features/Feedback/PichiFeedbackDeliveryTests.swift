@testable import FluidVoice_Debug
import XCTest

final class PichiFeedbackDeliveryTests: XCTestCase {
    private var apiSubmission: FeedbackSubmission {
        FeedbackSubmission(email: "user@example.com", message: "Example", category: .issue, appDetails: nil)
    }

    private func isolatedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedbackReceiptProtocol.self]
        return URLSession(configuration: configuration)
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
        let session = self.isolatedSession()
        defer { session.invalidateAndCancel() }
        for details in [nil, "Test app and macOS versions"] as [String?] {
            let submission = FeedbackSubmission(email: "", message: "  Example report  ", category: .idea, appDetails: details)
            XCTAssertTrue(delivery.accepts(submission))
            XCTAssertFalse(submission.isValid, "The HTTPS API still requires a reply address")
            var handoffs = 0
            let outcome = try await delivery.submit(submission, session: session) { recipient, subject, body in
                handoffs += 1
                XCTAssertEqual(recipient, "hello@pichi.ai")
                XCTAssertTrue(subject.contains(PichiLocalization.text(FeedbackCategory.idea.rawValue)))
                XCTAssertEqual(body, "Example report" + (details.map { "\n\n" + $0 } ?? ""))
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
            _ = try await delivery.submit(self.apiSubmission) { _, _, _ in false }
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
        let session = self.isolatedSession()
        defer { session.invalidateAndCancel() }
        let outcome = try await FeedbackDelivery.endpoint(endpoint).submit(self.apiSubmission, session: session) { _, _, _ in
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

    func testOtherSupportBrandsOpenTheConfiguredURLVerbatim() {
        // Set a custom appearance without depending on the active user's profile.
        let website = "https://help.example.org"
        let help = website + "/contact"
        let profile = BrandProfile(appName: "Example", meetingName: "Meet", assistantName: "AI", tagline: "Example",
                                   accentLight: "#555555", accentDark: "#AAAAAA", website: website, support: help)
        var package = BrandPackage(profile: profile)
        XCTAssertEqual(AppBrand.issueReportURL(for: package)?.absoluteString, help)
        let form = website + "/bugs/new"
        package.links = BrandLinks(issueReport: form)
        XCTAssertEqual(AppBrand.issueReportURL(for: package)?.absoluteString, form)
    }
}

private final class FeedbackReceiptProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = self.request.url, url.absoluteString == "https://example.invalid/feedback",
              self.request.httpMethod == "POST",
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            XCTFail("Unexpected request from feedback form")
            self.client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: Data(#"{"message":"Feedback submitted successfully"}"#.utf8))
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

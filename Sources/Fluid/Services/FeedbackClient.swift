import Foundation

enum FeedbackCategory: String, CaseIterable {
    case issue = "Report an issue"
    case idea = "Suggest an idea"
    case other = "Something else"

    var icon: String {
        switch self {
        case .issue: "flag"
        case .idea: "lightbulb"
        case .other: "bubble.left"
        }
    }

    var prompt: String {
        switch self {
        case .issue: "What happened?"
        case .idea: "What would you like to do?"
        case .other: "What would you like us to know?"
        }
    }

    var hint: String {
        switch self {
        case .issue: "What were you trying to do? What happened instead? A few steps help us reproduce it."
        case .idea: "Tell us what would make your day easier, and how you’d use it."
        case .other: "The small details count. Share what’s working—or what isn’t."
        }
    }
}

struct FeedbackSubmission: Encodable {
    static let messageLimit = 4500
    let email: String
    let message: String
    let category: FeedbackCategory
    let appDetails: String?

    static var appDetails: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return AppBrand.text("FluidVoice \(version) (\(build))\nmacOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    static func isValidEmail(_ value: String) -> Bool {
        BrandDistribution.isValidFeedbackEmail(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var content: String {
        var text = "[\(self.category.rawValue)]\n\(self.message.trimmingCharacters(in: .whitespacesAndNewlines))"
        if let appDetails { text += "\n\n--- App details ---\n\(appDetails)" }
        return text
    }

    var isValid: Bool { Self.isValidEmail(self.email) && self.hasValidMessage }

    var hasValidMessage: Bool {
        !self.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && self.message.utf16.count <= Self.messageLimit
            && self.content.utf16.count <= 5000
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), forKey: .email)
        try container.encode(self.content, forKey: .feedback)
    }

    private enum CodingKeys: String, CodingKey {
        case email = "email_id"
        case feedback
    }
}

/// Both deliveries use the same native form. Only the HTTPS service can acknowledge receipt.
enum FeedbackDelivery: Equatable {
    case endpoint(URL), email(String), support

    init(distribution: BrandDistribution) {
        if let endpoint = distribution.feedbackEndpoint.flatMap(URL.init(string:)) {
            self = .endpoint(endpoint)
        } else if let recipient = distribution.feedbackEmail {
            self = .email(recipient)
        } else {
            self = .support
        }
    }

    func accepts(_ submission: FeedbackSubmission) -> Bool {
        switch self {
        case .endpoint: submission.isValid
        case .email: submission.hasValidMessage
        case .support: false
        }
    }

    enum Outcome { case received, handedToMail }

    @MainActor
    func submit(
        _ submission: FeedbackSubmission,
        session: URLSession = .shared,
        composeEmail: (String, String, String) -> Bool
    ) async throws -> Outcome {
        switch self {
        case let .endpoint(url):
            try await FeedbackClient(session: session, endpoint: url).send(submission)
            return .received
        case let .email(recipient):
            guard submission.hasValidMessage else { throw FeedbackClient.Failure.invalid }
            let subject = "\(AppBrand.appName): \(PichiLocalization.text(submission.category.rawValue))"
            guard composeEmail(recipient, subject, submission.content) else {
                throw FeedbackClient.Failure.mailUnavailable
            }
            return .handedToMail
        case .support:
            throw FeedbackClient.Failure.notConfigured
        }
    }
}

struct FeedbackClient {
    let session: URLSession
    private let endpoint: URL?

    init(session: URLSession = .shared, endpoint: URL? = AppBrand.feedbackEndpoint) {
        self.session = session
        self.endpoint = endpoint
    }

    func send(_ submission: FeedbackSubmission) async throws {
        guard submission.isValid else { throw Failure.invalid }
        guard let url = self.endpoint else { throw Failure.notConfigured }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(submission)
        do {
            let (data, response) = try await self.session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw Failure.unconfirmed }
            switch response.statusCode {
            case 200...299:
                // A redirected HTML page is not a delivery receipt.
                let receipt = try? JSONDecoder().decode(Receipt.self, from: data)
                guard receipt?.message == "Feedback submitted successfully" else { throw Failure.unconfirmed }
            case 429: throw Failure.rateLimited
            case 400...499: throw Failure.rejected
            default: throw Failure.server
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            // A timeout can happen after storage. Never automatically retry a POST.
            throw Failure.connection
        }
    }

    private struct Receipt: Decodable { let message: String }

    enum Failure: LocalizedError {
        case notConfigured, mailUnavailable, invalid, rateLimited, rejected, server, connection, unconfirmed

        var errorDescription: String? {
            switch self {
            case .mailUnavailable: PichiLocalization.text("Couldn’t open your mail app. Your draft is still here.")
            case .notConfigured: PichiLocalization.text("Use the support link for this distribution.")
            case .invalid: PichiLocalization.text("Add a valid email and a message within the character limit.")
            case .rateLimited: PichiLocalization.text("Too many messages at once. Please wait a minute, then try again. Your draft is still here.")
            case .rejected: PichiLocalization.text("The server couldn’t accept this message. Check your email and message length. Your draft is still here.")
            case .server: PichiLocalization.text("Feedback is temporarily unavailable. Please try again later. Your draft is still here.")
            case .connection: PichiLocalization.text("Delivery couldn’t be confirmed. Check your connection before retrying; your message may already have arrived. Your draft is still here.")
            case .unconfirmed: PichiLocalization.text("We couldn’t confirm delivery. Your draft is still here; please try again later.")
            }
        }
    }
}

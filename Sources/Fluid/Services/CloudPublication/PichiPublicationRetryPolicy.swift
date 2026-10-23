import Foundation

nonisolated enum PichiPublicationRetryAfter: Equatable, Sendable {
    case seconds(TimeInterval)
    case beyondAutomaticWindow
}

nonisolated enum PichiPublicationRetryPause: String, Codable, Sendable {
    case retryBudgetExhausted, retryAfterBeyondBudget
}

nonisolated enum PichiPublicationRetryDecision: Equatable, Sendable {
    case retry(afterSeconds: TimeInterval)
    case pause(PichiPublicationRetryPause)
}

/// No timers or hidden retries. The durable worker must persist the attempt count and
/// obey this decision for the same operation. Cancellation never enters this policy.
nonisolated enum PichiPublicationRetryPolicy {
    static let maximumAutomaticAttempts = 5
    static let maximumAutomaticDelay: TimeInterval = 3_600

    static func decision(afterAttempt attempt: Int, retryAfter: PichiPublicationRetryAfter?) -> PichiPublicationRetryDecision {
        guard (1..<self.maximumAutomaticAttempts).contains(attempt) else { return .pause(.retryBudgetExhausted) }
        let backoff = 5 * pow(2, Double(attempt - 1))
        switch retryAfter {
        case .beyondAutomaticWindow: return .pause(.retryAfterBeyondBudget)
        case let .seconds(value):
            guard value.isFinite, value >= 0, value <= self.maximumAutomaticDelay else { return .pause(.retryAfterBeyondBudget) }
            return .retry(afterSeconds: max(backoff, value))
        case nil: return .retry(afterSeconds: backoff)
        }
    }

    static func parseRetryAfter(_ header: String?, now: Date) -> PichiPublicationRetryAfter? {
        guard let header, !header.isEmpty, now.timeIntervalSince1970.isFinite else { return nil }
        guard header.utf8.count <= 128 else { return .beyondAutomaticWindow }
        let value = header.trimmingCharacters(in: .whitespaces)
        let delay: TimeInterval
        if !value.isEmpty && value.utf8.allSatisfy({ (48...57).contains($0) }) {
            guard let parsed = Double(value), parsed.isFinite else { return .beyondAutomaticWindow }
            delay = parsed
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            formatter.isLenient = false
            guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
            delay = max(0, date.timeIntervalSince(now))
        }
        return delay <= self.maximumAutomaticDelay ? .seconds(delay) : .beyondAutomaticWindow
    }
}

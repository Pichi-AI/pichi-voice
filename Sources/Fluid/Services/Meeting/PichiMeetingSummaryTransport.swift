import Foundation

// Summary destinations are user-selected. Never forward private transcript bodies
// through a redirect, even if the original URL was localhost.
final nonisolated class PichiMeetingSummaryRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

nonisolated enum PichiMeetingSummaryTransport {
    static let redirectPolicy = PichiMeetingSummaryRedirectPolicy()
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration, delegate: redirectPolicy, delegateQueue: nil)
    }()
    static let client = LLMClient(session: session)
}

import AuthenticationServices
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The system browser owns cookies. Shared devices default to ephemeral sessions. Trusted
/// personal-device composition can reuse the browser session; explicit switching requests a fresh one.
@MainActor final class AccountSystemBrowser: NSObject, AccountBrowserAuthenticating, ASWebAuthenticationPresentationContextProviding {
    private let policy: AccountBrowserSessionPolicy
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var sessionID = UUID()
    private var anchor: ASPresentationAnchor?

    init(policy: AccountBrowserSessionPolicy = .sharedDevice) { self.policy = policy; super.init() }

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await authenticate(url: url, callbackScheme: callbackScheme, requiresExplicitIdentity: false)
    }
    func authenticate(url: URL, callbackScheme: String, requiresExplicitIdentity: Bool) async throws -> URL {
        let ephemeral = policy.prefersEphemeralSession(requiresExplicitIdentity: requiresExplicitIdentity)
        guard session == nil else { throw AccountError.busy }
        #if os(macOS)
        anchor = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow
        #else
        anchor = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        #endif
        guard anchor != nil else { throw AccountError.invalidState }
        let id = UUID(); sessionID = id
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending in
                continuation = pending
                let operation = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callback, error in
                    Task { @MainActor in
                        guard let self, self.sessionID == id else { return }
                        if let callback { self.finish(.success(callback)) }
                        else { self.finish(.failure(error is ASWebAuthenticationSessionError ? AccountError.cancelled : AccountError.invalidCallback)) }
                    }
                }
                operation.presentationContextProvider = self
                operation.prefersEphemeralWebBrowserSession = ephemeral
                session = operation
                if !operation.start() { finish(.failure(AccountError.invalidState)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == id else { return }
                self.cancel()
            }
        }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor! }
    func cancel() { session?.cancel(); finish(.failure(AccountError.cancelled)) }
    private func finish(_ result: Result<URL, Error>) {
        let pending = continuation; continuation = nil; session = nil; anchor = nil
        pending?.resume(with: result)
    }
}

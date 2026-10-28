import Foundation

/// A signed-out projection alone cannot establish guest readiness while restore or cleanup is unfinished.
@MainActor enum DesktopAccountGuestContinuation {
    static func prepare(using account: AccountSessionService) async -> UUID? {
        await account.logout()
        let generation = account.generation
        return isCurrent(generation, using: account) ? generation : nil
    }

    static func isCurrent(_ generation: UUID, using account: AccountSessionService) -> Bool {
        account.generation == generation && account.state == .signedOut && account.context == nil &&
            (account.presentationError == nil || account.presentationError == .revocationUnavailable)
    }
}

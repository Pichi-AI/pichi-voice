import Foundation

/// Guest rollback can restore visibility before N1 finishes clearing a previous account projection.
@MainActor enum DesktopAccountProjection {
    static func isVisible(account: AccountSessionService, isPrivateDataVisible: Bool, isTransitioning: Bool) -> Bool {
        guard isPrivateDataVisible, !isTransitioning,
              account.state == .signedIn || account.state == .reauthenticationRequired,
              let context = account.context, let snapshot = account.account else { return false }
        return context.generation == account.generation && snapshot.stableIdentity == context.identity
    }
}

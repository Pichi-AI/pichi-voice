import Combine
import Foundation

// Synthetic account/storage contracts for the exact production inline owner.
// These fixtures never select a production profile or access user audio files.
struct PrivateProfileSnapshot: Equatable, Sendable {
    let id: String
    let generation: UUID
}
@MainActor enum PrivateProfileStorage {
    static var current = PrivateProfileSnapshot(id: "synthetic-guest", generation: UUID())
    static var acceptsNewWork = true
    static var visible = true
    static func isReadable(_ value: PrivateProfileSnapshot) -> Bool { visible && current == value }
}
@MainActor protocol PrivateProfileTransitionParticipant: AnyObject {
    func prepareForPrivateProfileTransition() async throws
}
@MainActor final class PrivateProfileService {
    static let shared = PrivateProfileService()
    static let willConceal = Notification.Name("synthetic.inlineAudioWillConceal")
    var projectionRevision = UUID()
    var isPrivateDataVisible = true
    var isTransitioning = false
    private struct WeakParticipant { weak var value: (any PrivateProfileTransitionParticipant)? }
    private var participants: [WeakParticipant] = []
    func register(_ participant: any PrivateProfileTransitionParticipant) { participants.append(.init(value: participant)) }
    func conceal() {
        isPrivateDataVisible = false
        PrivateProfileStorage.visible = false
        PrivateProfileStorage.acceptsNewWork = false
        projectionRevision = UUID()
        NotificationCenter.default.post(name: Self.willConceal, object: nil)
    }
    func prepareRegistered() async throws {
        for participant in participants.compactMap(\.value) { try await participant.prepareForPrivateProfileTransition() }
    }
    func select(_ id: String) {
        PrivateProfileStorage.current = .init(id: id, generation: UUID())
        PrivateProfileStorage.visible = true
        PrivateProfileStorage.acceptsNewWork = true
        isPrivateDataVisible = true
        isTransitioning = false
        projectionRevision = UUID()
    }
}
nonisolated struct TranscriptionHistoryEntry: Sendable { let id = UUID() }
enum DictationAudioHistoryError: Error { case audioMissing }

nonisolated final class HistoryInlineLookupFixture: @unchecked Sendable {
    private let condition = NSCondition()
    private var blocked = false
    private var requests: [String] = []
    private var lifecycleEvents: [String] = []
    var requestedProfiles: [String] { condition.lock(); defer { condition.unlock() }; return requests }
    var events: [String] { condition.lock(); defer { condition.unlock() }; return lifecycleEvents }
    func block() { condition.lock(); blocked = true; condition.unlock() }
    func release() { condition.lock(); blocked = false; condition.broadcast(); condition.unlock() }
    func resolve(profile: String) -> URL? {
        condition.lock(); defer { condition.unlock() }
        requests.append(profile)
        lifecycleEvents.append("start:" + profile)
        while blocked { condition.wait() }
        lifecycleEvents.append("finish:" + profile)
        return URL(fileURLWithPath: "/synthetic-inline-audio/" + profile + ".wav")
    }
}
nonisolated final class DictationAudioHistoryStore: @unchecked Sendable {
    static let lookup = HistoryInlineLookupFixture()
    private let profile: PrivateProfileSnapshot
    private init(profile: PrivateProfileSnapshot) { self.profile = profile }
    static func scoped(to profile: PrivateProfileSnapshot) -> DictationAudioHistoryStore { .init(profile: profile) }
    func audioFileURL(for _: TranscriptionHistoryEntry) -> URL? { Self.lookup.resolve(profile: profile.id) }
}

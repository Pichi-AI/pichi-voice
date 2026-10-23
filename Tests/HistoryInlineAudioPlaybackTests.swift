import Combine
import Foundation

// Synthetic AV contracts only. Production AVFoundation is typechecked separately;
// this executable never constructs a real AVPlayer, asset, audio session or UI.
nonisolated struct CMTime: Sendable {
    let seconds: Double
    init(seconds: Double, preferredTimescale _: Int32) { self.seconds = seconds }
    static let zero = CMTime(seconds: 0, preferredTimescale: 600)
}
@MainActor final class HistoryInlineAssetGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.started = true
        }
    }
    func release() { continuation?.resume(); continuation = nil }
}
@MainActor enum HistoryInlineAssetScenario {
    static var gate: HistoryInlineAssetGate?
    static var fail = false
    static var loaded: [AVURLAsset] = []
    enum Failure: Error { case synthetic }
}
nonisolated final class AVURLAsset: @unchecked Sendable {
    enum Property { case isPlayable, duration }
    let url: URL
    private let lock = NSLock()
    private var cancellations = 0
    var cancellationCount: Int { lock.lock(); defer { lock.unlock() }; return cancellations }
    init(url: URL) { self.url = url }
    func cancelLoading() { lock.lock(); cancellations += 1; lock.unlock() }
    @MainActor func load(_: Property, _: Property) async throws -> (Bool, CMTime) {
        HistoryInlineAssetScenario.loaded.append(self)
        if let gate = HistoryInlineAssetScenario.gate { await gate.wait() }
        if HistoryInlineAssetScenario.fail { throw HistoryInlineAssetScenario.Failure.synthetic }
        return (true, CMTime(seconds: 60, preferredTimescale: 600))
    }
}
@MainActor final class AVPlayerItem {
    let asset: AVURLAsset
    private(set) var cancelledSeeks = 0
    init(asset: AVURLAsset) { self.asset = asset }
    func cancelPendingSeeks() { cancelledSeeks += 1 }
}
@MainActor final class AVPlayer {
    static var created: [AVPlayer] = []
    private(set) var currentItem: AVPlayerItem?
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var seekCount = 0
    private(set) var observerRemovals = 0
    private(set) var itemRetirements = 0
    var observer: (@Sendable (CMTime) -> Void)?
    init(playerItem: AVPlayerItem) { currentItem = playerItem; Self.created.append(self) }
    func play() { playCount += 1 }
    func pause() { pauseCount += 1 }
    func seek(to _: CMTime) { seekCount += 1 }
    func replaceCurrentItem(with item: AVPlayerItem?) {
        currentItem = item
        if item == nil { itemRetirements += 1 }
    }
    func addPeriodicTimeObserver(forInterval _: CMTime, queue _: DispatchQueue?,
                                using callback: @escaping @Sendable (CMTime) -> Void) -> Any {
        observer = callback
        return UUID()
    }
    func removeTimeObserver(_: Any) { observerRemovals += 1; observer = nil }
}

@main struct HistoryInlineAudioPlaybackTests {
    @MainActor static var checks = 0
    @MainActor static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(value(), message)
    }
    @MainActor static func until(_ condition: () -> Bool) async {
        for _ in 0..<10000 {
            if condition() { return }
            await Task.yield()
        }
        preconditionFailure("Synthetic inline audio checkpoint did not complete")
    }
    @MainActor static func main() async throws {
        let profiles = PrivateProfileService.shared
        let entry = TranscriptionHistoryEntry()
        let owner = HistoryInlineAudioPlayback()
        owner.start(entry: entry)
        await until { owner.hasPlayer }
        let player = AVPlayer.created.last!
        let item = player.currentItem!
        let oldTick = player.observer!
        expect(owner.isPlaying && owner.duration == 60 && player.playCount == 1, "Unchanged guest pipeline publishes one playing synthetic player")
        oldTick(CMTime(seconds: 20, preferredTimescale: 600))
        expect(owner.elapsed == 20, "Current periodic callback updates elapsed")
        owner.setPosition(500)
        expect(owner.elapsed == 60, "Seek position clamps to loaded duration")
        owner.setPosition(.nan)
        expect(owner.elapsed == 60, "Non-finite seek position is rejected")
        owner.seek(editing: true)
        oldTick(CMTime(seconds: 5, preferredTimescale: 600))
        expect(owner.elapsed == 60, "Periodic callback does not overwrite an active seek")
        owner.seek(editing: false)
        expect(player.seekCount == 1, "Current completed seek uses existing player")
        owner.togglePlayback()
        expect(!owner.isPlaying && player.pauseCount == 1, "Current pause uses owned player")
        owner.togglePlayback()
        expect(owner.isPlaying && owner.elapsed == 0 && player.seekCount == 2, "Replay seeks to the beginning before playing")
        owner.didReachEnd(AVPlayerItem(asset: AVURLAsset(url: URL(fileURLWithPath: "/synthetic-unrelated.wav"))))
        expect(owner.isPlaying, "Unrelated completion notification is ignored")
        owner.didFail(AVPlayerItem(asset: AVURLAsset(url: URL(fileURLWithPath: "/synthetic-unrelated.wav"))))
        expect(owner.errorMessage == nil, "Unrelated failure notification is ignored")
        let oldRevision = profiles.projectionRevision
        profiles.projectionRevision = UUID()
        let playsBefore = player.playCount
        let seeksBefore = player.seekCount
        owner.togglePlayback(); owner.setPosition(14); owner.seek(editing: false)
        oldTick(CMTime(seconds: 17, preferredTimescale: 600))
        owner.didReachEnd(item); owner.didFail(item)
        expect(owner.elapsed == 0 && owner.isPlaying && owner.errorMessage == nil, "Revision-stale periodic/end/error callbacks cannot publish")
        expect(player.playCount == playsBefore && player.seekCount == seeksBefore, "Revision-stale user actions cannot seek or start playback")
        profiles.projectionRevision = oldRevision
        profiles.conceal()
        expect(!owner.hasPlayer && !owner.isPlaying && owner.elapsed == 0 && owner.duration == 0, "Conceal synchronously removes player and visible playback state")
        expect(player.currentItem == nil && player.itemRetirements == 1 && item.cancelledSeeks == 1, "Conceal retires exact owned item and pending seeks")
        expect(player.observerRemovals == 1 && player.observer == nil, "Conceal removes exact owned observer")
        oldTick(CMTime(seconds: 35, preferredTimescale: 600))
        owner.didReachEnd(item); owner.didFail(item); owner.togglePlayback()
        expect(owner.elapsed == 0 && owner.errorMessage == nil && !owner.isPlaying, "Queued callbacks and stale controls cannot republish after retirement")
        try await profiles.prepareRegistered()
        profiles.select("synthetic-account-b")
        let countAfterConceal = DictationAudioHistoryStore.lookup.requestedProfiles.count
        owner.start(entry: entry)
        expect(DictationAudioHistoryStore.lookup.requestedProfiles.count == countAfterConceal, "Retired owner cannot rebind to another person")

        // A blocked detached filesystem lookup ignores cancellation until explicitly
        // released. The registered participant must wait and reject the late URL.
        let lookupOwner = HistoryInlineAudioPlayback()
        let lookupsBefore = DictationAudioHistoryStore.lookup.requestedProfiles.count
        DictationAudioHistoryStore.lookup.block()
        lookupOwner.start(entry: entry)
        await until { DictationAudioHistoryStore.lookup.requestedProfiles.count > lookupsBefore }
        profiles.conceal()
        var lookupCleanupStarted = false
        var lookupCleanupFinished = false
        let lookupCleanup = Task { @MainActor in
            lookupCleanupStarted = true
            try await profiles.prepareRegistered()
            lookupCleanupFinished = true
        }
        await until { lookupCleanupStarted }
        expect(!lookupCleanupFinished, "Transition joins a cancellation-ignoring detached URL lookup")
        let playerCountBeforeLookupRelease = AVPlayer.created.count
        DictationAudioHistoryStore.lookup.release()
        try await lookupCleanup.value
        expect(lookupCleanupFinished && !lookupOwner.hasPlayer && AVPlayer.created.count == playerCountBeforeLookupRelease,
            "Late detached URL cannot publish or play after joined cleanup")
        expect(DictationAudioHistoryStore.lookup.requestedProfiles.last == "synthetic-account-b", "Lookup used its captured immutable profile store")

        for fail in [false, true] {
            profiles.select(fail ? "synthetic-load-failure" : "synthetic-load-success")
            let loadingOwner = HistoryInlineAudioPlayback()
            let gate = HistoryInlineAssetGate()
            HistoryInlineAssetScenario.gate = gate
            HistoryInlineAssetScenario.fail = fail
            loadingOwner.start(entry: entry)
            await until { gate.started }
            let asset = HistoryInlineAssetScenario.loaded.last!
            profiles.conceal()
            expect(asset.cancellationCount > 0, "Conceal cancels the exact active AVAsset loader")
            var began = false
            var finished = false
            let cleanup = Task { @MainActor in
                began = true
                try await profiles.prepareRegistered()
                finished = true
            }
            await until { began }
            expect(!finished, "Transition joins an asset loader that delays cancellation completion")
            let count = AVPlayer.created.count
            gate.release()
            try await cleanup.value
            expect(!loadingOwner.hasPlayer && loadingOwner.errorMessage == nil && AVPlayer.created.count == count,
                "Late asset success/failure cannot publish player or error after retirement")
        }
        HistoryInlineAssetScenario.gate = nil
        HistoryInlineAssetScenario.fail = false

        profiles.select("synthetic-reopen")
        let reopen = HistoryInlineAudioPlayback()
        let beforeReopen = DictationAudioHistoryStore.lookup.requestedProfiles.count
        DictationAudioHistoryStore.lookup.block()
        reopen.start(entry: entry)
        await until { DictationAudioHistoryStore.lookup.requestedProfiles.count == beforeReopen + 1 }
        reopen.stop()
        reopen.start(entry: entry)
        expect(!reopen.hasPlayer && !reopen.isPlaying, "Rapid reopen does not retain the retired player")
        DictationAudioHistoryStore.lookup.release()
        await until { reopen.hasPlayer }
        expect(DictationAudioHistoryStore.lookup.requestedProfiles.count == beforeReopen + 2, "Replacement lookup starts after old reader is joined")
        expect(Array(DictationAudioHistoryStore.lookup.events.suffix(4)) == [
            "start:synthetic-reopen", "finish:synthetic-reopen", "start:synthetic-reopen", "finish:synthetic-reopen"
        ], "Replacement lookup starts only after the previous lookup has actually finished")
        let reopenedPlayer = AVPlayer.created.last!
        let reopenedItem = reopenedPlayer.currentItem!
        reopen.didReachEnd(reopenedItem)
        expect(!reopen.isPlaying && reopen.elapsed == 60, "Current end notification still works")
        reopen.didFail(reopenedItem)
        expect(reopen.errorMessage != nil && !reopen.isPlaying, "Current failure remains visible")
        reopen.stop()
        expect(reopenedPlayer.currentItem == nil && reopen.errorMessage == nil, "Disappearance retires item and private error")
        try await reopen.prepareForPrivateProfileTransition()

        profiles.select("synthetic-same-id")
        let staleGeneration = HistoryInlineAudioPlayback()
        PrivateProfileStorage.current = .init(id: "synthetic-same-id", generation: UUID())
        let beforeStale = DictationAudioHistoryStore.lookup.requestedProfiles.count
        staleGeneration.start(entry: entry)
        expect(DictationAudioHistoryStore.lookup.requestedProfiles.count == beforeStale, "Same profile ID with another generation cannot start a reader")
        let admissionOwner = HistoryInlineAudioPlayback()
        PrivateProfileStorage.acceptsNewWork = false
        admissionOwner.start(entry: entry)
        expect(DictationAudioHistoryStore.lookup.requestedProfiles.count == beforeStale, "Closed admission refuses a new playback pipeline")
        profiles.conceal()
        try await profiles.prepareRegistered()
        print("History inline audio: \(checks) synthetic assertions passed; no actual AVFoundation playback, audio, profile, device or UI.")
    }
}

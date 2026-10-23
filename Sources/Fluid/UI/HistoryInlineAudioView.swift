import AVFoundation
import Combine
import SwiftUI

/// Playback belongs only to this visible history entry, never to dictation capture.
struct HistoryInlineAudioView: View {
    @Environment(\.theme) private var theme
    let entry: TranscriptionHistoryEntry
    @StateObject private var playback = HistoryInlineAudioPlayback()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recording").font(self.theme.typography.bodyStrong).foregroundStyle(self.theme.palette.secondaryText)
            if let errorMessage = self.playback.errorMessage {
                Label(PichiLocalization.text(errorMessage), systemImage: "exclamationmark.triangle")
                    .font(.fluidSystem(.callout)).foregroundStyle(self.theme.palette.secondaryText)
            } else if self.playback.hasPlayer {
                HStack(spacing: 12) {
                    Button { self.playback.togglePlayback() } label: {
                        Image(systemName: self.playback.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .fluidGlassAction(circular: true)
                    .accessibilityLabel(PichiLocalization.text(self.playback.isPlaying ? "Pause recording" : "Play recording"))
                    Text(Self.timeLabel(self.playback.elapsed)).monospacedDigit().frame(width: 42)
                    Slider(value: Binding(get: { self.playback.elapsed }, set: { self.playback.setPosition($0) }),
                           in: 0...max(self.playback.duration, 0.01)) { editing in
                        self.playback.seek(editing: editing)
                    }
                    .tint(self.theme.palette.accent)
                    .accessibilityLabel(PichiLocalization.text("Recording position"))
                    Text(Self.timeLabel(self.playback.duration)).monospacedDigit().frame(width: 42)
                }
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
                .frame(minHeight: 40)
            } else {
                ProgressView("Loading recording…").controlSize(.small)
            }
        }
        .onAppear { self.playback.start(entry: self.entry) }
        .onChange(of: self.entry.id) { _, _ in self.playback.start(entry: self.entry) }
        .onDisappear { self.playback.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            self.playback.didReachEnd(notification.object)
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { notification in
            self.playback.didFail(notification.object)
        }
    }

    private static func timeLabel(_ seconds: Double) -> String {
        let value = Int(max(seconds, 0))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

// MARK: - Joined inline playback lifetime

/// Owns only this inline AVPlayer and its loading work. Capture and the shared
/// audio/history services keep their independent composition-owned lifetimes.
@MainActor
final class HistoryInlineAudioPlayback: ObservableObject, PrivateProfileTransitionParticipant {
    private struct Ticket: Sendable {
        let profile: PrivateProfileSnapshot
        let projectionRevision: UUID
        let operation: UUID
    }

    @Published private(set) var errorMessage: String?
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private var player: AVPlayer?
    private var isSeeking = false
    private var timeObserver: Any?
    private var playerTicket: Ticket?
    private var operation: UUID?
    private var retired = false
    private let profile: PrivateProfileSnapshot
    private let audioStore: DictationAudioHistoryStore
    private let profiles: PrivateProfileService
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var concealObserver: AnyCancellable?

    init() {
        self.profile = PrivateProfileStorage.current
        self.audioStore = DictationAudioHistoryStore.scoped(to: self.profile)
        self.profiles = PrivateProfileService.shared
        self.profiles.register(self)
        self.concealObserver = NotificationCenter.default.publisher(for: PrivateProfileService.willConceal)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.retired = true
                    self?.stop()
                }
            }
    }

    var hasPlayer: Bool { self.player != nil }

    private func isCurrent(_ ticket: Ticket) -> Bool {
        !Task.isCancelled && !self.retired && self.operation == ticket.operation &&
            self.profile == ticket.profile && PrivateProfileStorage.isReadable(ticket.profile) &&
            PrivateProfileStorage.acceptsNewWork && self.profiles.isPrivateDataVisible &&
            !self.profiles.isTransitioning && self.profiles.projectionRevision == ticket.projectionRevision
    }

    func start(entry: TranscriptionHistoryEntry) {
        self.stop()
        guard !self.retired, PrivateProfileStorage.isReadable(self.profile),
              PrivateProfileStorage.acceptsNewWork, self.profiles.isPrivateDataVisible,
              !self.profiles.isTransitioning else { return }
        let id = UUID()
        self.operation = id
        let ticket = Ticket(profile: self.profile, projectionRevision: self.profiles.projectionRevision, operation: id)
        let previous = Array(self.tasks.values)
        self.tasks[id] = Task { @MainActor in
            // A rapid hide/reopen joins the old loader before creating another one.
            for task in previous { await task.value }
            if self.isCurrent(ticket) { await self.load(entry: entry, ticket: ticket) }
            self.tasks.removeValue(forKey: id)
        }
    }

    private func load(entry: TranscriptionHistoryEntry, ticket: Ticket) async {
        let audioStore = self.audioStore
        // Capture the immutable source store before leaving the main actor.
        let lookup = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return Optional<URL>.none }
            return audioStore.audioFileURL(for: entry)
        }
        var deadline: Task<Void, Never>?
        do {
            let url = await withTaskCancellationHandler {
                await lookup.value
            } onCancel: {
                lookup.cancel()
            }
            try Task.checkCancellation()
            guard self.isCurrent(ticket) else { return }
            guard let url else { throw DictationAudioHistoryError.audioMissing }
            let asset = AVURLAsset(url: url)
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                asset.cancelLoading()
            }
            deadline = timeout
            let (playable, mediaDuration) = try await withTaskCancellationHandler {
                try await asset.load(.isPlayable, .duration)
            } onCancel: {
                timeout.cancel()
                asset.cancelLoading()
            }
            deadline?.cancel()
            await deadline?.value
            deadline = nil
            try Task.checkCancellation()
            guard self.isCurrent(ticket) else { return }
            guard playable, mediaDuration.seconds.isFinite, mediaDuration.seconds > 0 else {
                throw DictationAudioHistoryError.audioMissing
            }
            self.duration = mediaDuration.seconds
            let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            self.player = player
            self.playerTicket = ticket
            self.timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
            ) { [weak self, weak player] time in
                // AVPlayer delivers this observer on the explicitly requested main queue.
                MainActor.assumeIsolated {
                    guard let self, let player, self.isCurrent(ticket), self.player === player,
                          !self.isSeeking, time.seconds.isFinite else { return }
                    self.elapsed = min(max(time.seconds, 0), self.duration)
                }
            }
            player.play()
            self.isPlaying = true
        } catch {
            deadline?.cancel()
            await deadline?.value
            guard self.isCurrent(ticket) else { return }
            // Disappearance/cancellation is silent; the bounded load deadline is a failure.
            self.errorMessage = "This recording could not be played. It may have been removed."
        }
    }

    func togglePlayback() {
        guard let ticket = self.playerTicket, self.isCurrent(ticket), let player else { return }
        if self.isPlaying {
            player.pause()
            self.isPlaying = false
        } else {
            if self.elapsed >= self.duration - 0.1 {
                player.seek(to: .zero)
                self.elapsed = 0
            }
            player.play()
            self.isPlaying = true
        }
    }

    func setPosition(_ seconds: Double) {
        guard let ticket = self.playerTicket, self.isCurrent(ticket), seconds.isFinite else { return }
        self.elapsed = min(max(seconds, 0), self.duration)
    }

    func seek(editing: Bool) {
        guard let ticket = self.playerTicket, self.isCurrent(ticket), let player else { return }
        self.isSeeking = editing
        if !editing { player.seek(to: CMTime(seconds: self.elapsed, preferredTimescale: 600)) }
    }

    func didReachEnd(_ object: Any?) {
        guard let ticket = self.playerTicket, self.isCurrent(ticket),
              let item = object as? AVPlayerItem, item === self.player?.currentItem else { return }
        self.isPlaying = false
        self.elapsed = self.duration
    }

    func didFail(_ object: Any?) {
        guard let ticket = self.playerTicket, self.isCurrent(ticket),
              let item = object as? AVPlayerItem, item === self.player?.currentItem else { return }
        self.player?.pause()
        self.isPlaying = false
        self.errorMessage = "This recording could not be played."
    }

    /// Immediately retires owned playback. The task registry keeps cancelled
    /// loaders alive until the registered transition participant joins them.
    func stop() {
        self.operation = nil
        for task in self.tasks.values { task.cancel() }
        self.player?.pause()
        self.player?.currentItem?.cancelPendingSeeks()
        if let timeObserver { self.player?.removeTimeObserver(timeObserver) }
        self.timeObserver = nil
        self.player?.replaceCurrentItem(with: nil)
        self.player = nil
        self.playerTicket = nil
        self.elapsed = 0; self.duration = 0; self.isPlaying = false; self.isSeeking = false
        self.errorMessage = nil
    }

    func prepareForPrivateProfileTransition() async throws {
        self.retired = true
        self.stop()
        for task in Array(self.tasks.values) { await task.value }
        self.tasks.removeAll()
    }
}

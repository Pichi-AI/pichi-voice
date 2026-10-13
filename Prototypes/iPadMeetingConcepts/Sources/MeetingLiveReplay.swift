import SwiftUI

/// Design-only playback of synthetic callbacks, using the application's actual live snapshot
/// and row composer. No microphone, inference engine, speaker recognition or audio storage.
@MainActor
final class MeetingLiveReplayController: ObservableObject {
    @Published private(set) var snapshot = MeetingLiveTranscriptSnapshot.empty
    @Published private(set) var isPlaying = false
    @Published private(set) var isFinished = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var delivery: Delivery = .partial

    enum Delivery: String, Decodable { case partial, buffered }

    private struct Fixture: Decodable {
        struct Event: Decodable {
            enum Action: String, Decodable { case partial, final }
            let time: TimeInterval
            let action: Action
            let delivery: Delivery
            let id: UUID
            let text: String
            let start: TimeInterval
            let end: TimeInterval?
        }
        let duration: TimeInterval
        let events: [Event]

        var isValid: Bool {
            guard duration.isFinite, duration > 0, duration <= 120,
                  !events.isEmpty, events.count <= 128 else { return false }
            var previousTime: TimeInterval = 0
            var finishedIDs: Set<UUID> = []
            for event in events {
                guard event.time.isFinite, event.time >= previousTime, event.time <= duration,
                      event.start.isFinite, event.start >= 0,
                      !event.text.isEmpty, event.text.count <= 4096,
                      !finishedIDs.contains(event.id) else { return false }
                if event.action == .final {
                    guard let end = event.end, end.isFinite, end >= event.start else { return false }
                    finishedIDs.insert(event.id)
                }
                previousTime = event.time
            }
            return true
        }
    }

    private let fixture: Fixture?
    private let clock = ContinuousClock()
    private var resumedAt: ContinuousClock.Instant?
    private var elapsedBeforeResume: TimeInterval = 0
    private var eventIndex = 0
    private var generation: UInt64 = 0
    private var playbackTask: Task<Void, Never>?

    init() {
        if let url = Bundle.main.url(forResource: "live-replay", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Fixture.self, from: data), decoded.isValid {
            fixture = decoded
            snapshot = .empty.settingAvailability(.available)
        } else {
            fixture = nil
            snapshot = .empty.settingAvailability(.unavailable(reason: Copy.text("live_demo_unavailable")))
        }
    }

    deinit { playbackTask?.cancel() }

    var isAvailable: Bool { fixture != nil }
    var hasPartial: Bool { !snapshot.partials.isEmpty }

    func start() async { await restart() }

    func restart() async {
        let request = await cancelPlayback()
        guard generation == request, fixture != nil else { return }
        snapshot = .empty.settingAvailability(.available)
        currentTime = 0
        elapsedBeforeResume = 0
        eventIndex = 0
        delivery = .partial
        isFinished = false
        beginPlayback(generation: request)
    }

    func pause() async {
        advanceToClockTime()
        elapsedBeforeResume = currentTime
        resumedAt = nil
        _ = await cancelPlayback()
    }

    func resume() async {
        guard !isPlaying, !isFinished, fixture != nil else { return }
        let request = await cancelPlayback()
        guard generation == request, fixture != nil, !isFinished else { return }
        beginPlayback(generation: request)
    }

    /// Retains the visible live text. A new demo is an explicit restart, never an infinite loop.
    func stop() async { await pause() }

    @discardableResult
    private func cancelPlayback() async -> UInt64 {
        generation &+= 1
        let request = generation
        let oldTask = playbackTask
        playbackTask = nil
        isPlaying = false
        oldTask?.cancel()
        if let oldTask { await oldTask.value }
        return request
    }

    private func beginPlayback(generation request: UInt64) {
        resumedAt = clock.now
        isPlaying = true
        playbackTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, self.generation == request else { return }
                self.advanceToClockTime()
                if self.isFinished {
                    self.isPlaying = false
                    self.resumedAt = nil
                    self.playbackTask = nil
                    return
                }
            }
        }
    }

    private func advanceToClockTime() {
        guard let fixture, let resumedAt else { return }
        let duration = resumedAt.duration(to: clock.now).components
        let elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        currentTime = min(fixture.duration, elapsedBeforeResume + max(0, elapsed))
        var next = snapshot
        while eventIndex < fixture.events.count, fixture.events[eventIndex].time <= currentTime {
            let event = fixture.events[eventIndex]
            // `.you` is the existing internal microphone source tag, not an identified speaker.
            switch event.action {
            case .partial:
                next = next.settingPartial(MeetingLivePartial(id: event.id, text: event.text, start: event.start), for: .you)
            case .final:
                next = next.settingPartial(nil, for: .you).inserting(MeetingLiveUtterance(
                    id: event.id, speaker: .you, text: event.text, start: event.start, end: event.end!
                ))
            }
            next.revision &+= 1
            delivery = event.delivery
            eventIndex += 1
        }
        // Events sharing one delivery time are published together, like a buffered ASR callback.
        if next != snapshot { snapshot = next }
        if currentTime >= fixture.duration {
            elapsedBeforeResume = fixture.duration
            isFinished = true
        }
    }
}

/// Thin design wrapper around the unchanged Meet live renderer. This prototype does not
/// create a second caption UI or claim that microphone-source captions identify speakers.
struct PrototypeLiveTranscriptView: View {
    @ObservedObject var replay: MeetingLiveReplayController
    let theme: PrototypeTheme
    var compact = false

    @Environment(\.locale) private var locale

    private var rows: [MeetingLiveBubbleComposer.Row] { MeetingLiveBubbleComposer.rows(for: replay.snapshot) }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.gap) {
            HStack(spacing: 12) {
                Text(PichiLocalization.text("Live transcript", locale: locale)).font(theme.font(.section))
                Spacer(minLength: 0)
                Text(Copy.text("live_demo"))
                    .font(theme.font(.caption)).foregroundStyle(theme.color("secondaryText"))
            }
            if rows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(replay.isAvailable ? PichiLocalization.text("Listening for conversation", locale: locale) : Copy.text("live_demo_unavailable"))
                        .font(theme.font(.body)).foregroundStyle(theme.color("secondaryText"))
                    Text(PichiLocalization.text("Your conversation will appear here as people speak.", locale: locale))
                        .font(theme.font(.caption)).foregroundStyle(theme.color("tertiaryText"))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                MeetingLiveBubbleScrollList(rows: rows, documentStyle: true)
                    .environment(\.theme, PrototypeCaptionTheme(theme))
                    .frame(minHeight: 120, maxHeight: .infinity)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(Copy.text(replay.delivery == .buffered ? "buffered_demo" : replay.hasPartial ? "live_partial" : "live_committed"))
                    .font(theme.font(.caption)).foregroundStyle(theme.color("secondaryText"))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: compact ? 12 : 16) {
                    Button {
                        Task { if replay.isPlaying { await replay.pause() } else { await replay.resume() } }
                    } label: {
                        Label(Copy.text(replay.isPlaying ? "demo_pause" : "demo_play"), systemImage: replay.isPlaying ? "pause" : "play")
                            .font(theme.font(.caption)).frame(minHeight: 44)
                    }
                    .disabled(!replay.isAvailable || replay.isFinished)
                    Spacer(minLength: 0)
                    Button { Task { await replay.restart() } } label: {
                        Label(Copy.text("replay_demo"), systemImage: "arrow.counterclockwise")
                            .font(theme.font(.caption)).frame(minHeight: 44)
                    }.disabled(!replay.isAvailable)
                }
                .buttonStyle(.plain).foregroundStyle(theme.accent)
            }
        }
    }
}

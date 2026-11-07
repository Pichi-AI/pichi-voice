import AVFoundation
import Combine
import Foundation

@MainActor
protocol MeetingPlaybackAudioSessionControlling {
    func activate() throws
    func deactivate()
}

/// Playback owns activation only while playing. Capture retains its own category and route policy.
@MainActor
final class MeetingPlaybackAudioSession: MeetingPlaybackAudioSessionControlling {
#if os(iOS)
    private let session: any MeetingPlaybackSystemAudioSession
    private var ownsActivation = false

    init(session: any MeetingPlaybackSystemAudioSession = AVAudioSession.sharedInstance()) {
        self.session = session
    }
#endif

    func activate() throws {
#if os(iOS)
        // The default/previous recording category can respect Silent or use an input route.
        // Media playback remains audible in Silent and lets iOS keep the user's headphones.
        try self.session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        self.ownsActivation = true
        do { try self.session.setActive(true, options: []) }
        catch { self.deactivate(); throw error }
#endif
    }

    func deactivate() {
#if os(iOS)
        guard self.ownsActivation else { return }
        self.ownsActivation = false
        // A newer capture owner must never be deactivated by an old playback callback.
        guard self.session.category == .playback, self.session.mode == .default,
              self.session.categoryOptions == [.mixWithOthers] else { return }
        try? self.session.setActive(false, options: [.notifyOthersOnDeactivation])
#endif
    }
}

#if os(iOS)
@MainActor
protocol MeetingPlaybackSystemAudioSession {
    var category: AVAudioSession.Category { get }
    var mode: AVAudioSession.Mode { get }
    var categoryOptions: AVAudioSession.CategoryOptions { get }
    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                     options: AVAudioSession.CategoryOptions) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

extension AVAudioSession: MeetingPlaybackSystemAudioSession {}
#endif

/// Only the expanded player observes the clock; transcript rows do not redraw every tick.
@MainActor
final class MeetingPlaybackProgress: ObservableObject {
    @Published var elapsed: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
}

/// One player for the visible transcript. Never changes capture, speaker or persisted state.
@MainActor
final class MeetingSegmentPlayback: ObservableObject, PrivateProfileTransitionParticipant {
    @Published private(set) var activeSegmentID: MeetingTranscriptSegmentID?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    let progress = MeetingPlaybackProgress()
    private var timeObserver: Any?
    private var isSeeking = false
    private var seekRevision = 0
    private var player: AVPlayer?
    private var loadTask: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var requestID = UUID()
    private var activeSegmentIDs: [MeetingTranscriptSegmentID] = []
    private var activeOwnership: MeetingProfileOwnership?
    private let profile = PrivateProfileStorage.current
    private let store: any MeetingSessionStoring
    private let audioSession: any MeetingPlaybackAudioSessionControlling

    init(store: any MeetingSessionStoring = MeetingSessionStore.shared,
         audioSession: any MeetingPlaybackAudioSessionControlling = MeetingPlaybackAudioSession()) {
        self.store = store
        self.audioSession = audioSession
        PrivateProfileService.shared.register(self)
    }

    func prepareForPrivateProfileTransition() async throws {
        let task = loadTask
        stop()
        await task?.value
    }

    func toggle(sessionID: MeetingSessionID, segmentID: MeetingTranscriptSegmentID) {
        self.toggle(sessionID: sessionID, segmentIDs: [segmentID])
    }

    /// UI actions pin the source actually displayed before the first asynchronous lookup.
    func toggle(session: MeetingSession, segmentIDs: [MeetingTranscriptSegmentID]) {
        self.toggle(sessionID: session.id, segmentIDs: segmentIDs,
                    expectedOwnership: session.profileOwnership ?? .guest)
    }

    /// Read the requested paragraph from fresh canonical data before resolving audio. The first
    /// member remains the playback identity; the verified mapping covers the paragraph's range.
    func toggle(sessionID: MeetingSessionID, segmentIDs: [MeetingTranscriptSegmentID]) {
        self.toggle(sessionID: sessionID, segmentIDs: segmentIDs, expectedOwnership: .init(profile: self.profile))
    }

    private func toggle(sessionID: MeetingSessionID, segmentIDs: [MeetingTranscriptSegmentID], expectedOwnership: MeetingProfileOwnership) {
        guard PrivateProfileStorage.isReadable(profile) else { return }
        guard let segmentID = segmentIDs.first else { return }
        let wasActive = self.activeSegmentID == segmentID && self.activeSegmentIDs == segmentIDs
            && self.activeOwnership == expectedOwnership
        if wasActive {
            self.togglePause()
            return
        }
        self.stop()
        self.activeSegmentID = segmentID
        self.activeSegmentIDs = segmentIDs
        self.activeOwnership = expectedOwnership
        self.isLoading = true
        let requestID = self.requestID
        let store = self.store
        self.loadTask = Task { [weak self] in
            do {
                guard let source = try await store.loadExistingSource(id: sessionID,
                    expectedOwnership: expectedOwnership)
                else { throw MeetingSegmentPlaybackError.unavailable }
                let session = source.session, directory = source.directory
                let segment = try MeetingSegmentPlaybackPlan.segmentRange(in: session, segmentIDs: segmentIDs)
                let composition = try await Self.composition(session: session, segment: segment, directory: directory)
                try Task.checkCancellation()
                guard let self, self.requestID == requestID else { return }
                defer { self.loadTask = nil }
                let item = AVPlayerItem(asset: composition)
                let player = AVPlayer(playerItem: item)
                self.player = player
                self.progress.duration = composition.duration.seconds
                self.isLoading = false
                self.timeObserver = player.addPeriodicTimeObserver(
                    forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main
                ) { [weak self] time in
                    Task { @MainActor [weak self] in
                        guard let self, self.requestID == requestID, !self.isSeeking, time.seconds.isFinite else { return }
                        self.progress.elapsed = min(max(0, time.seconds), self.progress.duration)
                    }
                }
                self.endObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.requestID == requestID else { return }
                        guard !self.isSeeking else { return }
                        self.player?.pause()
                        self.progress.isPlaying = false
                        self.audioSession.deactivate()
                        self.progress.elapsed = self.progress.duration
                    }
                }
                self.failureObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.requestID == requestID else { return }
                        self.stop()
                        self.errorMessage = "This audio chunk could not be played."
                    }
                }
                self.statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    guard item.status == .failed else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.requestID == requestID else { return }
                        self.stop()
                        self.errorMessage = "This audio chunk could not be played."
                    }
                }
                self.resume()
            } catch {
                guard let self, !Task.isCancelled, self.requestID == requestID else { return }
                self.stop()
                self.errorMessage = "This audio chunk is unavailable. Its recording may have been deleted or its timing could not be verified."
            }
        }
    }

    func togglePause() {
        guard let player, !self.isLoading else { return }
        if self.progress.isPlaying {
            player.pause()
            self.progress.isPlaying = false
            self.audioSession.deactivate()
        } else {
            guard self.activateAudioSession() else { return }
            self.progress.isPlaying = true
            if self.progress.elapsed >= self.progress.duration - 0.05 {
                self.seek(to: 0)
            } else if !self.isSeeking {
                player.play()
            }
        }
    }

    private func activateAudioSession() -> Bool {
        do { try self.audioSession.activate(); return true }
        catch {
            self.stop()
            self.errorMessage = "This audio chunk could not be played."
            return false
        }
    }

    private func resume() {
        guard self.activateAudioSession() else { return }
        self.progress.isPlaying = true
        self.player?.play()
    }

    func seek(to seconds: Double) {
        guard let player, seconds.isFinite, self.progress.duration > 0 else { return }
        self.seekRevision += 1
        let revision = self.seekRevision
        let requestID = self.requestID
        let position = min(max(0, seconds), self.progress.duration)
        self.isSeeking = true
        self.progress.elapsed = position
        player.pause()
        player.seek(to: CMTime(seconds: position, preferredTimescale: 48_000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.requestID == requestID, self.seekRevision == revision else { return }
                self.isSeeking = false
                if finished, self.progress.isPlaying, position < self.progress.duration {
                    self.player?.play()
                } else if position >= self.progress.duration || !finished {
                    self.progress.isPlaying = false
                    self.audioSession.deactivate()
                }
            }
        }
    }

    func skip(by seconds: Double) {
        self.seek(to: self.progress.elapsed + seconds)
    }

    func stop() {
        self.requestID = UUID()
        self.errorMessage = nil
        self.activeOwnership = nil
        self.loadTask?.cancel()
        self.loadTask = nil
        self.player?.pause()
        self.audioSession.deactivate()
        if let timeObserver { self.player?.removeTimeObserver(timeObserver) }
        self.timeObserver = nil
        self.isSeeking = false
        self.seekRevision += 1
        self.progress.isPlaying = false
        self.progress.elapsed = 0
        self.progress.duration = 0
        self.statusObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        self.endObserver = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        self.failureObserver = nil
        self.player?.replaceCurrentItem(with: nil)
        self.player = nil
        self.activeSegmentID = nil
        self.activeSegmentIDs = []
        self.isLoading = false
    }

    private nonisolated static func composition(
        session: MeetingSession, segment: MeetingTranscriptSegment, directory: URL
    ) async throws -> AVMutableComposition {
        // Sidecar verification and path resolution are disk work, outside the main actor.
        let plan = try await Task.detached(priority: .userInitiated) {
            try MeetingSegmentPlaybackPlan.slices(session: session, segment: segment, directory: directory)
        }.value
        try Task.checkCancellation()
        let composition = AVMutableComposition()
        guard let output = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw MeetingSegmentPlaybackError.unavailable }
        var cursor = CMTime.zero
        for slice in plan {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: slice.url)
            let deadline = Task {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                asset.cancelLoading()
            }
            defer { deadline.cancel() }
            let tracks = try await withTaskCancellationHandler {
                try await asset.loadTracks(withMediaType: .audio)
            } onCancel: { asset.cancelLoading() }
            guard let track = tracks.first else { throw MeetingSegmentPlaybackError.unavailable }
            let range = CMTimeRange(
                start: CMTime(seconds: slice.start, preferredTimescale: 48_000),
                duration: CMTime(seconds: slice.end - slice.start, preferredTimescale: 48_000)
            )
            try output.insertTimeRange(range, of: track, at: cursor)
            cursor = CMTimeAdd(cursor, range.duration)
        }
        return composition
    }
}

nonisolated enum MeetingSegmentPlaybackError: Error {
    case unavailable
}

nonisolated enum MeetingSegmentPlaybackPlan {
    struct Slice: Equatable {
        let url: URL
        let start: Double
        let end: Double
    }

    /// A transient interval only. Do not rewrite or persist grouped transcript members.
    /// Recomposition refuses stale membership, reordered IDs or a changed attribution boundary.
    static func segmentRange(in session: MeetingSession, segmentIDs: [MeetingTranscriptSegmentID]) throws -> MeetingTranscriptSegment {
        guard !segmentIDs.isEmpty, Set(segmentIDs).count == segmentIDs.count else {
            throw MeetingSegmentPlaybackError.unavailable
        }
        if segmentIDs.count == 1 {
            guard let segment = session.transcriptSegments.first(where: { $0.id == segmentIDs[0] }) else {
                throw MeetingSegmentPlaybackError.unavailable
            }
            return segment
        }
        let ordered = session.transcriptSegments.filter { !$0.isEcho }.enumerated().sorted {
            ($0.element.start, $0.element.end, $0.offset) < ($1.element.start, $1.element.end, $1.offset)
        }.map(\.element)
        guard let paragraph = MeetingTranscriptExporter.displayParagraphs(for: ordered, in: session)
            .first(where: { $0.segments.map(\.id) == segmentIDs }) else {
            throw MeetingSegmentPlaybackError.unavailable
        }
        var interval = paragraph.firstSegment
        interval.end = paragraph.segments.map(\.end).max() ?? interval.end
        return interval
    }

    static func slices(session: MeetingSession, segment: MeetingTranscriptSegment, directory: URL) throws -> [Slice] {
        guard session.retention.audioDeletedAt == nil,
              segment.start.seconds.isFinite, segment.end.seconds.isFinite,
              segment.end > segment.start
        else { throw MeetingSegmentPlaybackError.unavailable }
        if let reference = session.resultSidecarReference {
            guard session.transcriptTimeDomain == .meetingRelative,
                  let attempt = session.processingAttempts.last(where: {
                      MeetingResultSidecarStore.fileName(for: $0.id) == reference.fileName
                  }), let backendID = attempt.backendID
            else { throw MeetingSegmentPlaybackError.unavailable }
            let sidecar = try MeetingResultSidecarStore(sessionDirectory: directory).read(
                expectedAttemptID: attempt.id, expectedBackendID: MeetingBackendID(rawValue: backendID), reference: reference
            )
            return try self.slices(segment: segment, spans: sidecar.analysisManifest.allSpans, directory: directory)
        }
        // Legacy transcripts use chunk-relative offsets. Refuse drift-corrected legacy audio
        // without a verified span mapping rather than silently playing the wrong words.
        guard let track = session.audioTracks.first(where: { $0.id == segment.sourceTrackID }),
              track.clockDrift == nil,
              track.captureEras?.contains(where: { $0.clockDrift != nil }) != true
        else { throw MeetingSegmentPlaybackError.unavailable }
        let origin = MeetingAnalysisManifest.presentationOrigin(of: session)
        var slices: [Slice] = []
        for chunk in track.chunks.sorted(by: { $0.presentationStart < $1.presentationStart }) {
            let offset = chunk.presentationStart.seconds - origin
            let start = max(segment.start.seconds, offset)
            let end = min(segment.end.seconds, chunk.presentationEnd.seconds - origin)
            guard end > start, let path = MeetingAudioPresentation.relativePlaybackPath(for: chunk) else { continue }
            let url = try MeetingChunkPathConfinement.containedURL(sessionDirectory: directory, relativePath: path)
            slices.append(Slice(url: url, start: start - offset, end: end - offset))
        }
        guard !slices.isEmpty else { throw MeetingSegmentPlaybackError.unavailable }
        return slices
    }

    static func slices(segment: MeetingTranscriptSegment, spans: [MeetingAnalysisSpan], directory: URL) throws -> [Slice] {
        var slices: [Slice] = []
        for span in spans.filter({ $0.trackID == segment.sourceTrackID }).sorted(by: { $0.presentationInterval.start < $1.presentationInterval.start }) {
            let start = max(segment.start.seconds, span.presentationInterval.start)
            let end = min(segment.end.seconds, span.presentationInterval.end)
            guard end > start else { continue }
            let rate = span.presentationMapping.rateRatio
            guard rate.isFinite, rate > 0 else { throw MeetingSegmentPlaybackError.unavailable }
            let sourceStart = span.sourceLocalInterval.start + (start - span.presentationInterval.start) / rate
            let sourceEnd = min(span.sourceLocalInterval.end, span.sourceLocalInterval.start + (end - span.presentationInterval.start) / rate)
            guard sourceStart.isFinite, sourceEnd.isFinite, sourceStart >= 0, sourceEnd > sourceStart else {
                throw MeetingSegmentPlaybackError.unavailable
            }
            let url = try MeetingChunkPathConfinement.containedURL(sessionDirectory: directory, relativePath: span.chunk.relativeFilePath)
            slices.append(Slice(url: url, start: sourceStart, end: sourceEnd))
        }
        guard !slices.isEmpty else { throw MeetingSegmentPlaybackError.unavailable }
        return slices
    }
}

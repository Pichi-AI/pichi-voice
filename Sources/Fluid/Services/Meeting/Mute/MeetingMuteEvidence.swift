import CoreGraphics
import Foundation

/// An external application's control action, not an audio-device mute flag.
nonisolated enum MeetingMuteSemanticState: Equatable, Sendable {
    case muted
    case unmuted
    case unknown
}

/// External UI adapters keep their selectors here. Unrecognized/localized or contradictory
/// controls remain unknown; these strings are never used as Pichi interface copy.
nonisolated enum MeetingMuteUISemantics {
    static func zoom(title: String?, description: String?, help: String?) -> MeetingMuteSemanticState {
        var states: [MeetingMuteSemanticState] = []
        for label in [title, description].compactMap({ $0 }) {
            let label = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if self.action(label, prefix: "unmute my audio") { states.append(.muted) }
            else if self.action(label, prefix: "mute my audio") { states.append(.unmuted) }
        }
        if let help = help?.lowercased() {
            if help.range(of: #"\bmute my audio\b"#, options: .regularExpression) != nil { states.append(.unmuted) }
            if help.contains("to unmute") || self.action(help, prefix: "unmute my audio") { states.append(.muted) }
        }
        return self.consensus(states)
    }

    static func meet(title: String?, description: String?) -> MeetingMuteSemanticState {
        self.consensus([title, description].compactMap { label in
            guard let label else { return nil }
            if self.isMeetMicrophoneLabel(label, prefix: "Turn on microphone") { return .muted }
            if self.isMeetMicrophoneLabel(label, prefix: "Turn off microphone") { return .unmuted }
            return nil
        })
    }

    static func isMeetMicrophoneLabel(_ label: String) -> Bool {
        self.isMeetMicrophoneLabel(label, prefix: "Turn on microphone")
            || self.isMeetMicrophoneLabel(label, prefix: "Turn off microphone")
    }

    private static func isMeetMicrophoneLabel(_ label: String, prefix: String) -> Bool {
        label == prefix || label.hasPrefix(prefix + " (")
    }

    private static func action(_ label: String, prefix: String) -> Bool {
        guard label.hasPrefix(prefix) else { return false }
        let suffix = label.dropFirst(prefix.count)
        return suffix.isEmpty || suffix.first.map { " (,.".contains($0) } == true
    }

    private static func consensus(_ states: [MeetingMuteSemanticState]) -> MeetingMuteSemanticState {
        guard let first = states.first, states.allSatisfy({ $0 == first }) else { return .unknown }
        return first
    }
}

nonisolated enum MeetingMuteVisualState: Equatable, Sendable {
    case muted
    case unmuted
    case unknown
}

/// A recording attempt remembers the last explicit conference transition. Missing evidence is
/// not a transition. Space can identify a temporary grant, but cannot itself open microphone PCM.
nonisolated struct MeetingMuteTransitionState {
    private(set) var state = MeetingMicrophoneMuteState.unmuted
    private(set) var latestEvidenceAt: UInt64 = 0
    private(set) var held = false
    private(set) var possiblePTT = false
    private(set) var temporaryUnmute = false
    private(set) var historicalReleaseUnmuteAt: UInt64?
    private(set) var historicalReleaseUntilAt: UInt64?
    private var persistentState = MeetingMicrophoneMuteState.unmuted
    private var lastVisibleState: MeetingMicrophoneMuteState?
    private var lastUnmuteFromMutedAt: UInt64?
    private var lastRenderedMuteAt: UInt64?
    private var lastRenderedUnmuteAt: UInt64?
    private var excludedThrough: UInt64 = 0
    private var hudVisible = false
    private var temporaryObservedDuringHold = false
    private var awaitingMutedAfterRelease = false
    private struct MutedSegment { var first: UInt64; var last: UInt64; var resumed: UInt64? }
    private var mutedSegments: [MutedSegment] = []
    private var mutedHistoryRetiredThrough: UInt64 = 0
    private static let maximumMutedSegments = 64
    var retainedMutedSegmentCount: Int { self.mutedSegments.count }

    static func releaseBoundary(eventTime: UInt64?, processedAt now: UInt64) -> (fence: UInt64, unsafeStart: UInt64) {
        guard let eventTime, eventTime > 0, eventTime <= now else { return (now, 0) }
        return (eventTime, eventTime)
    }

    /// Returns true only for a newly observed visible transition which changes effective state.
    @discardableResult
    mutating func observe(_ visible: MeetingMicrophoneMuteState?, at time: UInt64) -> Bool {
        guard let visible, visible == .muted || visible == .unmuted, time >= self.latestEvidenceAt else { return false }
        guard visible != .unmuted || (time > self.excludedThrough && !self.awaitingMutedAfterRelease) else { return false }
        if visible == .muted, time > self.excludedThrough { self.awaitingMutedAfterRelease = false }
        self.latestEvidenceAt = time
        if visible == .muted {
            self.lastRenderedMuteAt = time
            if self.lastVisibleState == .muted, !self.mutedSegments.isEmpty {
                self.mutedSegments[self.mutedSegments.count - 1].last = time
            } else {
                self.mutedSegments.append(MutedSegment(first: time, last: time, resumed: nil))
                if self.mutedSegments.count > Self.maximumMutedSegments {
                    let retired = self.mutedSegments.removeFirst()
                    self.mutedHistoryRetiredThrough = retired.resumed ?? retired.last
                }
            }
        }
        guard visible != self.lastVisibleState else { return false }
        if visible == .unmuted {
            self.lastRenderedUnmuteAt = time
            if !self.mutedSegments.isEmpty { self.mutedSegments[self.mutedSegments.count - 1].resumed = time }
        }
        self.lastVisibleState = visible
        if visible == .muted {
            self.persistentState = .muted
            self.temporaryUnmute = false
            self.lastUnmuteFromMutedAt = nil
        } else if (self.held && self.possiblePTT) || self.temporaryUnmute {
            self.temporaryUnmute = true
            self.temporaryObservedDuringHold = true
        } else {
            self.lastUnmuteFromMutedAt = self.persistentState == .muted ? time : nil
            self.persistentState = .unmuted
        }
        return self.change(to: visible)
    }

    /// The HUD is a separate visible source. Only a new appearance can grant temporary unmute;
    /// disappearance merely rearms its next appearance and never invents a mute transition.
    @discardableResult
    mutating func observeTemporaryHUD(_ visible: Bool?, at time: UInt64, corroboratedUnmute: Bool = false) -> Bool {
        guard let visible, time >= self.latestEvidenceAt else { return false }
        guard visible != self.hudVisible else { return false }
        self.hudVisible = visible
        guard visible, time > self.excludedThrough, !self.awaitingMutedAfterRelease,
              self.held || corroboratedUnmute else { return false }
        self.latestEvidenceAt = time
        self.persistentState = .muted
        self.temporaryUnmute = true
        self.temporaryObservedDuringHold = true
        return self.change(to: .unmuted)
    }

    mutating func keyDown(at eventTime: UInt64?) {
        guard !self.held else { return }
        self.held = true
        let delayedPTT = eventTime.flatMap { event in self.lastUnmuteFromMutedAt.map { event <= $0 } } ?? false
        self.possiblePTT = self.persistentState == .muted || self.temporaryUnmute || delayedPTT || self.lastVisibleState == nil
        if self.possiblePTT, let eventTime, eventTime > self.excludedThrough { self.awaitingMutedAfterRelease = false }
        if delayedPTT {
            self.persistentState = .muted
            self.temporaryUnmute = self.state == .unmuted
            self.temporaryObservedDuringHold = self.temporaryUnmute
        }
    }

    /// A known temporary grant returns to its persistent muted base on the actual Space release.
    /// True also refines an already observed mute with an earlier key boundary for PCM quarantine.
    @discardableResult
    mutating func keyUp(processedAt now: UInt64, releasedAt: UInt64? = nil) -> Bool {
        self.historicalReleaseUnmuteAt = nil
        self.historicalReleaseUntilAt = nil
        defer { self.held = false; self.possiblePTT = false; self.temporaryObservedDuringHold = false }
        let hadTemporaryGrant = self.temporaryUnmute || self.temporaryObservedDuringHold
        guard (self.held && self.possiblePTT) || hadTemporaryGrant else { return false }
        if let releasedAt, releasedAt > 0, releasedAt <= now, self.state == .unmuted,
           let mutedAt = self.lastRenderedMuteAt, mutedAt >= releasedAt,
           let unmutedAt = self.lastRenderedUnmuteAt, unmutedAt > mutedAt {
            // A full rendered mute/unmute cycle after this old key release is newer evidence.
            self.temporaryUnmute = false
            self.persistentState = .unmuted
            self.lastUnmuteFromMutedAt = nil
            self.hudVisible = true
            if releasedAt > self.mutedHistoryRetiredThrough,
               let firstMute = self.mutedSegments.first(where: { $0.resumed.map({ $0 >= releasedAt && $0 <= unmutedAt }) == true }) {
                self.historicalReleaseUnmuteAt = unmutedAt
                self.historicalReleaseUntilAt = firstMute.resumed
            }
            return false
        }
        // Fence every owned PTT release, including a press too short for a sampled grant.
        // Otherwise its first delayed HUD/unmuted frame could open after the key is already up.
        self.hudVisible = true
        self.awaitingMutedAfterRelease = true
        self.excludedThrough = max(self.excludedThrough, now)
        self.latestEvidenceAt = max(self.latestEvidenceAt, now)
        guard hadTemporaryGrant else { return false }
        self.temporaryUnmute = false
        self.persistentState = .muted
        _ = self.change(to: .muted)
        return true
    }

    /// Align the reducer with the PCM gate's negative processing fence. A pending old positive
    /// cannot make the icon green while the downstream gate still rejects that old snapshot.
    mutating func negativeWasProcessed(at time: UInt64) {
        self.excludedThrough = max(self.excludedThrough, time)
        self.latestEvidenceAt = max(self.latestEvidenceAt, time)
    }

    /// An unavailable key listener supplies no conference transition. Keep the rendered state.
    mutating func keyListenerUnavailable() { self.held = false; self.possiblePTT = false }

    private mutating func change(to state: MeetingMicrophoneMuteState) -> Bool {
        guard self.state != state else { return false }
        self.state = state
        return true
    }
}

/// Tiny, synthetic geometric glyph proof. No screenshot reference, model or OCR is bundled.
/// A positive microphone shape is required for either result; a missing red line is not proof.
nonisolated enum MeetingMuteIconProof {
    static let side = 24
    static let componentCount = side * side * 3

    private struct Template: Sendable {
        let muted: Bool
        let pixels: [Bool]
        let dilated: [Bool]
        let count: Int
    }

    private static let templates: [Template] = {
        var result: [Template] = []
        for muted in [false, true] {
            for family in 0...1 {
                for scale in [0.85, 0.95, 1.05, 1.15] {
                    for dx in -1...1 {
                        for dy in -1...1 {
                            var pixels = [Bool](repeating: false, count: MeetingMuteIconProof.side * MeetingMuteIconProof.side)
                            for y in 0..<MeetingMuteIconProof.side {
                                for x in 0..<MeetingMuteIconProof.side {
                                    let px = (Double(x) + 0.5 - Double(dx) - 11.5) / scale + 11.5
                                    let py = (Double(y) + 0.5 - Double(dy) - 11.5) / scale + 11.5
                                    pixels[y * MeetingMuteIconProof.side + x] = MeetingMuteIconProof.glyph(x: px, y: py, family: family, muted: muted)
                                }
                            }
                            result.append(Template(muted: muted, pixels: pixels,
                                dilated: MeetingMuteIconProof.dilate(pixels), count: pixels.filter { $0 }.count))
                        }
                    }
                }
            }
        }
        return result
    }()

    static func classify(rgb: [UInt8]) -> MeetingMuteVisualState {
        guard rgb.count == self.componentCount else { return .unknown }
        var corners: [[Int]] = [[], [], []]
        for y in [0, 1, 22, 23] {
            for x in [0, 1, 22, 23] {
                for channel in 0..<3 { corners[channel].append(Int(rgb[(y * self.side + x) * 3 + channel])) }
            }
        }
        let background = corners.map { $0.sorted()[$0.count / 2] }
        var mask = [Bool](repeating: false, count: self.side * self.side)
        for pixel in mask.indices {
            let offset = pixel * 3
            mask[pixel] = ((0..<3).map { abs(Int(rgb[offset + $0]) - background[$0]) }.max() ?? 0) > 45
        }
        let count = mask.filter { $0 }.count
        guard (28...200).contains(count) else { return .unknown }
        let dilated = self.dilate(mask)
        var unmuted = 0.0
        var muted = 0.0
        for template in self.templates {
            var matchedActual = 0
            var matchedTemplate = 0
            for index in mask.indices {
                if mask[index], template.dilated[index] { matchedActual += 1 }
                if template.pixels[index], dilated[index] { matchedTemplate += 1 }
            }
            let score = min(Double(matchedActual) / Double(count), Double(matchedTemplate) / Double(template.count))
            if template.muted { muted = max(muted, score) }
            else { unmuted = max(unmuted, score) }
        }
        let slash = self.hasDiagonalStroke(dilated)
        if slash, muted >= 0.92, muted - unmuted >= 0.06 { return .muted }
        if !slash, unmuted >= 0.92, unmuted - muted >= 0.06 { return .unmuted }
        return .unknown
    }

    static func sample(_ image: CGImage) -> [UInt8]? {
        guard (16...128).contains(image.width), (16...128).contains(image.height) else { return nil }
        var rgba = [UInt8](repeating: 0, count: self.side * self.side * 4)
        let succeeded = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: self.side, height: self.side,
                bitsPerComponent: 8, bytesPerRow: self.side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: self.side, height: self.side))
            return true
        }
        guard succeeded else { return nil }
        var rgb: [UInt8] = []
        rgb.reserveCapacity(self.componentCount)
        for offset in stride(from: 0, to: rgba.count, by: 4) { rgb.append(contentsOf: rgba[offset..<(offset + 3)]) }
        return rgb
    }

    private static func dilate(_ mask: [Bool]) -> [Bool] {
        var result = [Bool](repeating: false, count: self.side * self.side)
        for y in 0..<self.side {
            for x in 0..<self.side where mask[y * self.side + x] {
                for dy in -1...1 {
                    for dx in -1...1 where (0..<self.side).contains(x + dx) && (0..<self.side).contains(y + dy) {
                        result[(y + dy) * self.side + x + dx] = true
                    }
                }
            }
        }
        return result
    }

    private static func hasDiagonalStroke(_ dilated: [Bool]) -> Bool {
        for orientation in [-1, 1] {
            let intercepts = orientation < 0 ? Array(0...27) : Array(-4...4)
            for intercept in intercepts {
                var total = 0, supported = 0, lower = 0, upper = 0
                for x in 4...19 {
                    let y = orientation * x + intercept
                    guard (2...21).contains(y) else { continue }
                    total += 1
                    if dilated[y * self.side + x] {
                        supported += 1
                        if x <= 7 { lower += 1 }
                        if x >= 16 { upper += 1 }
                    }
                }
                if total >= 13, Double(supported) / Double(total) >= 0.8, lower >= 2, upper >= 2 { return true }
            }
        }
        return false
    }

    private static func glyph(x: Double, y: Double, family: Int, muted: Bool) -> Bool {
        let microphone: Bool
        let slash: Bool
        if family == 0 {
            microphone = abs(self.roundedRectangleDistance(x: x, y: y, cx: 12, cy: 7.5, width: 4.9, height: 8.8, radius: 2.45)) <= 0.67
                || (y >= 9.6 && abs(hypot(x - 12, y - 9.6) - 4.3) <= 0.67)
                || self.lineDistance(x: x, y: y, x1: 12, y1: 14, x2: 12, y2: 16.7) <= 0.67
                || self.lineDistance(x: x, y: y, x1: 10, y1: 16.7, x2: 14, y2: 16.7) <= 0.67
            slash = self.lineDistance(x: x, y: y, x1: 5.5, y1: 16.8, x2: 18.2, y2: 3.2) <= 0.95
        } else {
            microphone = self.roundedRectangleDistance(x: x, y: y, cx: 12, cy: 8.6, width: 4.4, height: 9.2, radius: 2.2) <= 0
                || (y >= 11.5 && abs(hypot(x - 12, y - 11.5) - 4.35) <= 0.65)
                || self.lineDistance(x: x, y: y, x1: 12, y1: 15.8, x2: 12, y2: 18.2) <= 0.65
            slash = self.lineDistance(x: x, y: y, x1: 4.5, y1: 5.5, x2: 18.5, y2: 19) <= 0.85
        }
        return microphone || (muted && slash)
    }

    private static func lineDistance(x: Double, y: Double, x1: Double, y1: Double, x2: Double, y2: Double) -> Double {
        let dx = x2 - x1, dy = y2 - y1
        let fraction = min(1, max(0, ((x - x1) * dx + (y - y1) * dy) / (dx * dx + dy * dy)))
        return hypot(x - x1 - fraction * dx, y - y1 - fraction * dy)
    }

    private static func roundedRectangleDistance(x: Double, y: Double, cx: Double, cy: Double,
        width: Double, height: Double, radius: Double) -> Double {
        let qx = abs(x - cx) - (width / 2 - radius), qy = abs(y - cy) - (height / 2 - radius)
        return hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - radius
    }
}

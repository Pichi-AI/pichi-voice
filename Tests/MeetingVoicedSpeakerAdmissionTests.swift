import Foundation

/// Synthetic native evidence only, not a model-quality or hardware-performance test.
@main struct MeetingVoicedSpeakerAdmissionTests {
    typealias Tail = MeetingStreamingProtectedWordTail
    static let attempt = UUID(uuidString: "00000000-0000-0000-0000-000000000161")!
    static let epoch = MeetingAnalysisEpochID(trackID: UUID(uuidString: "00000000-0000-0000-0000-000000000162")!, ordinal: 0)
    static var a: MeetingBackendSpeakerToken { .init(analysisEpochID: epoch, label: "a") }
    static var b: MeetingBackendSpeakerToken { .init(analysisEpochID: epoch, label: "b") }
    static var checks = 0

    static func check(_ condition: Bool, _ message: String = #function, line: Int = #line) {
        checks += 1
        if !condition { fatalError("Line \(line): \(message)") }
    }

    static func word(_ index: Int, _ start: Double, _ end: Double,
                     token: MeetingBackendSpeakerToken, text: String = "synthetic") -> MeetingTranscriptSegment {
        .init(id: UUID(uuidString: String(format: "00000000-0000-0000-0002-%012lld", Int64(index)))!,
            start: .init(value: Int64((start * 1_000).rounded()), timescale: 1_000),
            end: .init(value: Int64((end * 1_000).rounded()), timescale: 1_000), sourceTrackID: epoch.trackID,
            speakerID: nil, text: text, revision: 0, status: .final, overlap: .none, completeness: .complete,
            attributionState: .unassigned, nativePrecision: .word, nativeUnitID: "synthetic-\(index)",
            nativeSpeakerAssignment: .assigned(token), nativeTiming: .init(start: start, end: end))
    }

    static func tail(policy: MeetingSpeakerAttributionPolicy = .standard,
                     limits: Tail.Limits = .init()) throws -> Tail {
        try Tail(attemptID: attempt, epoch: epoch, speakerNameFormat: "Speaker %lld", policy: policy, limits: limits)
    }

    static func window(_ index: Int, sparse: Bool = false, bDuration: Double = 1,
                       bText: String = "reply") -> ([MeetingTranscriptSegment], [MeetingBackendSpeakerActivity]) {
        let offset = Double(index * 20)
        var words = (0..<10).map { position in
            word(index * 100 + position, offset + Double(position) * 0.6,
                 offset + Double(position) * 0.6 + (sparse ? 0.04 : 0.6), token: a)
        }
        words.append(word(index * 100 + 10, offset + 6.5, offset + 6.54, token: b, text: bText))
        return (words, [.init(token: a, start: offset, end: offset + 6),
                        .init(token: b, start: offset + 6.5, end: offset + 6.5 + bDuration)])
    }

    static func update(_ value: inout Tail, words: [MeetingTranscriptSegment],
                       activity: [MeetingBackendSpeakerActivity], end: Double) throws -> Tail.Update {
        try value.update(safeWords: .init(segments: words), activity: activity,
            watermarks: .init(asrStableThrough: end, diarizationProcessedThrough: end, privacySafeThrough: end),
            attemptID: attempt, epoch: epoch, activityAvailableFrom: value.retainActivityFrom)
    }

    static func main() async throws {
        try repeatedBriefReplies()
        try actualDurationAndNoise()
        try duplicateAndBackdatedSnapshots()
        try sourceGuards()
        try limitsAndAtomicity()
        try policyCompatibility()
        try await cancellation()
        print("Voiced speaker admission: \(checks) checks passed")
    }

    static func repeatedBriefReplies() throws {
        for enabled in [false, true] {
            var value = try tail(policy: .init(enableVoicedSpeakerAdmission: enabled))
            var speaker: UUID?
            var nanoseconds: [Double] = []
            for index in 0..<8 {
                let (words, activity) = window(index)
                let began = ContinuousClock.now
                let result = try update(&value, words: words, activity: activity, end: Double(index * 20 + 20))
                let elapsed = began.duration(to: .now).components
                nanoseconds.append(Double(elapsed.seconds) * 1e9 + Double(elapsed.attoseconds) / 1e9)
                let reply = result.inserted.last!
                check(reply.nativeSpeakerAssignment == .assigned(b))
                check(reply.nativeTiming == words.last!.nativeTiming && reply.text == words.last!.text)
                if enabled && index >= 4 {
                    check(reply.speakerID != nil, "Repeated brief voice never earned its real five seconds")
                    if let speaker { check(reply.speakerID == speaker) } else { speaker = reply.speakerID }
                    check(value.admittedVoiceSeconds(for: b) == 5)
                } else {
                    check(reply.speakerID == nil, "Unqualified voice was admitted early")
                }
                check(result.inserted.first?.speakerID != reply.speakerID)
                check(value.retainedAdmissionTokenCount <= 2 && value.retainedAdmissionIntervalCount <= 4)
            }
            if enabled {
                print("ADMISSION_SYNTHETIC_TIMING updates=8 medianMS=\(nanoseconds.sorted()[4] / 1e6) maxMS=\(nanoseconds.max()! / 1e6) tokens=\(value.retainedAdmissionTokenCount) intervals=\(value.retainedAdmissionIntervalCount)")
            }
            _ = try value.finish(activity: [], watermarks: .init(asrStableThrough: 160,
                diarizationProcessedThrough: 160, privacySafeThrough: 160), attemptID: attempt, epoch: epoch,
                activityAvailableFrom: value.retainActivityFrom)
            check(value.retainedAdmissionTokenCount == 0 && value.retainedAdmissionIntervalCount == 0)
        }
    }

    static func actualDurationAndNoise() throws {
        let (words, activity) = window(0, sparse: true, bDuration: 0.2, bText: ".")
        let current = try MeetingTranscriptAssembler(speakerNameFormat: "Speaker %lld")
            .assemblePCMWindow(attemptID: attempt, epoch: epoch, offset: 0, duration: 20,
                units: words.map { .init(id: $0.nativeUnitID!, trackID: epoch.trackID, analysisEpochID: epoch,
                    precision: .word, text: $0.text, analysisStart: $0.nativeTiming!.start,
                    analysisEnd: $0.nativeTiming!.end, speaker: $0.nativeSpeakerAssignment!, analysisSpanIDs: []) },
                activity: activity)
        check(current.speakers.count == 1 && current.segments.last?.speakerID == nil,
              "Sparse CTC spikes caused the all-brief fallback to mint a punctuation voice")
        var value = try tail()
        for index in 0..<8 {
            var (rows, bouts) = window(index, bDuration: 0.2)
            bouts.append(.init(token: b, start: Double(index * 20 + 10), end: Double(index * 20 + 19)))
            if index % 2 == 0 { rows[10].text = "..." }
            _ = try update(&value, words: rows, activity: bouts, end: Double(index * 20 + 20))
        }
        check(abs(value.admittedVoiceSeconds(for: b) - 0.8) < 0.000001,
              "Unrelated cough/background bouts or punctuation earned voiced admission")
    }

    static func duplicateAndBackdatedSnapshots() throws {
        var value = try tail()
        let (words, activity) = window(0)
        _ = try update(&value, words: words, activity: activity, end: 20)
        for _ in 0..<5 { _ = try update(&value, words: [], activity: activity + activity, end: 20) }
        check(abs(value.admittedVoiceSeconds(for: b) - 1) < 0.000001, "Repeated snapshots counted twice")
        var backdated = try tail()
        _ = try update(&backdated, words: Array(words.dropLast()), activity: [activity[0]], end: 20)
        let reply = word(2000, 20.05, 20.09, token: b)
        let later = [MeetingBackendSpeakerActivity(token: b, start: 19.85, end: 20.4)]
        _ = try update(&backdated, words: [reply], activity: later, end: 20.6)
        check(abs(backdated.admittedVoiceSeconds(for: b) - 0.55) < 0.000001,
              "Backdated admitted onset was clipped to the prior processed cursor")
        _ = try update(&backdated, words: [], activity: later, end: 20.6)
        check(abs(backdated.admittedVoiceSeconds(for: b) - 0.55) < 0.000001)
    }

    static func sourceGuards() throws {
        for unsafe in 0..<6 {
            var value = try tail()
            for index in 0..<6 {
                var (words, activity) = window(index)
                switch unsafe {
                case 0: words[10].isUserTextEdited = true
                case 1: words[10].originalText = "Legacy manual correction"
                case 2: words[10].status = .provisional
                case 3: words[10].completeness = .incompleteTrack
                case 4: words[10].isLikelyEcho = true
                default: words[10].nativeSpeakerAssignment = .unassigned
                }
                _ = try update(&value, words: words, activity: activity, end: Double(index * 20 + 20))
            }
            check(value.admittedVoiceSeconds(for: b) == 0, "Unsafe/context-only evidence earned identity support")
        }
        var value = try tail()
        let (words, _) = window(0)
        let foreign = MeetingBackendSpeakerToken(analysisEpochID: .init(trackID: epoch.trackID, ordinal: 0, generation: 1), label: "b")
        do {
            _ = try update(&value, words: words, activity: [.init(token: foreign, start: 6.5, end: 7.5)], end: 20)
            check(false)
        } catch let error as Tail.Failure { check(error == .invalidActivity) }
        check(value.retainedAdmissionTokenCount == 0)
    }

    static func limitsAndAtomicity() throws {
        var value = try tail(limits: .init(maximumActivityIntervals: 3))
        for index in 0..<3 {
            let (words, activity) = window(index, bDuration: 0.2)
            _ = try update(&value, words: words, activity: activity, end: Double(index * 20 + 20))
        }
        check(value.retainedAdmissionIntervalCount == 3)
        let prior = value.committedThrough
        let (words, activity) = window(3, bDuration: 0.2)
        do { _ = try update(&value, words: words, activity: activity, end: 80); check(false) }
        catch let error as Tail.Failure { check(error == .activityLimit) }
        check(value.retainedAdmissionIntervalCount == 3 && value.committedThrough == prior,
              "Failed admission modified the attempt's counters/cursors")
        value.cancel()
        check(value.retainedAdmissionTokenCount == 0 && value.retainedAdmissionIntervalCount == 0)
        let fresh = try tail()
        check(fresh.retainedAdmissionTokenCount == 0)
    }

    static func policyCompatibility() throws {
        let old = MeetingSpeakerAttributionPolicy(enableVoicedSpeakerAdmission: false)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        object["enableVoicedSpeakerAdmission"] = nil
        let decoded = try JSONDecoder().decode(MeetingSpeakerAttributionPolicy.self,
            from: JSONSerialization.data(withJSONObject: object))
        check(!decoded.enableVoicedSpeakerAdmission && decoded.fingerprint == old.fingerprint)
        check(decoded.fingerprint != MeetingSpeakerAttributionPolicy.standard.fingerprint)
        check(try JSONDecoder().decode(MeetingSpeakerAttributionPolicy.self,
            from: JSONEncoder().encode(MeetingSpeakerAttributionPolicy.standard)) == .standard)
    }

    static func cancellation() async throws {
        let task = Task { () throws -> Bool in
            var value = try tail()
            withUnsafeCurrentTask { $0?.cancel() }
            let (words, activity) = window(0)
            do { _ = try update(&value, words: words, activity: activity, end: 20); return false }
            catch is CancellationError { return value.retainedAdmissionTokenCount == 0 && value.committedThrough == 0 }
        }
        check(try await task.value)
    }
}

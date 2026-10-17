import Foundation

private struct SyntheticMaskingRedactor: TranscriptTextRedacting {
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        let source = text as NSString
        let pattern = NSRegularExpression.escapedPattern(for: "private@example.test")
        let expression = try NSRegularExpression(pattern: pattern)
        let spans = expression.matches(in: text, range: NSRange(location: 0, length: source.length))
            .map { TranscriptRedactedSpan(range: $0.range, replacement: "<EMAIL>") }
        var safe = text
        for span in spans.reversed() {
            safe = (safe as NSString).replacingCharacters(in: span.range, with: span.replacement)
        }
        return .init(text: safe, spans: spans, provisionalSafeUTF16: source.length)
    }
}

private actor BlockedRedactor: TranscriptTextRedacting {
    let started: AsyncStream<Void>.Continuation
    var waiter: CheckedContinuation<Void, Never>?
    var didBlock = false
    init(_ started: AsyncStream<Void>.Continuation) { self.started = started }
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        if !self.didBlock {
            self.didBlock = true
            self.started.yield(())
            await withCheckedContinuation { self.waiter = $0 }
        }
        try Task.checkCancellation()
        return await .init(text: text, spans: [])
    }
    func release() { self.waiter?.resume(); self.waiter = nil }
}

private struct RejectedRedactor: TranscriptTextRedacting {
    enum Failure: Error { case rejected }
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction { throw Failure.rejected }
}

@main
struct MeetingStreamingTranscriptStateTests {
    typealias State = MeetingStreamingTranscriptState
    static let attempt = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
    static let trackID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let epoch = MeetingAnalysisEpochID(trackID: trackID, ordinal: 0)
    static var checks = 0
    static func check(_ condition: Bool, _ message: String = #function, line: Int = #line) {
        checks += 1
        if !condition { fatalError("Line \(line): \(message)") }
    }
    static func track() -> MeetingAudioTrack {
        .init(id: trackID, kind: .microphone, sourceIdentifier: "synthetic", sourceDisplayName: "Synthetic",
            format: nil, timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1,
                machTimebaseDenominator: 1, firstPresentationTime: nil), health: .waiting, chunks: [])
    }
    static func state(privacy: MeetingTranscriptPrivacyContext? = nil, limits: State.Limits = .init()) throws -> State {
        try .init(attemptID: attempt, track: track(),
            configuration: .init(speakerProcessingMode: .streaming), privacyContext: privacy,
            limits: limits, speakerNameFormat: "Speaker %lld")
    }
    static func word(_ index: Int, start: Double? = nil, end: Double? = nil,
                     text: String? = nil) -> MeetingTranscriptSegment {
        let start = start ?? Double(index) * 0.5
        let end = end ?? start + 0.4
        return .init(id: UUID(uuidString: String(format: "00000000-0000-0000-0002-%012lld", Int64(index)))!,
            start: .init(value: Int64((start * 1_000).rounded()), timescale: 1_000),
            end: .init(value: Int64((end * 1_000).rounded()), timescale: 1_000),
            sourceTrackID: trackID, speakerID: nil, text: text ?? "safe-\(index)", originalText: nil,
            revision: 0, status: .final, overlap: .none, completeness: .complete, attributionState: .unassigned,
            nativePrecision: .word, nativeUnitID: "word-\(index)", nativeSpeakerAssignment: .unassigned,
            nativeTiming: .init(start: start, end: end))
    }
    static func observation(_ words: [MeetingTranscriptSegment] = [], accepted: Double,
                            processed: Double? = nil, asr: Double? = nil,
                            final: Bool = false, activity: [MeetingBackendSpeakerActivity]? = nil,
                            retained: Int = 0) -> MeetingStreamingPCMObservation {
        let processed = processed ?? accepted
        return .init(batch: .init(segments: words), activity: activity ?? (processed > 0 ? [
            .init(token: .init(analysisEpochID: epoch, label: "a"), start: 0, end: processed)] : []),
            acceptedThroughSample: Int((accepted * 16_000).rounded()),
            processedThroughSample: Int((processed * 16_000).rounded()), retainedFromSample: retained,
            isFinal: final, asrStableThroughSample: asr.map { Int(($0 * 16_000).rounded()) })
    }
    static func expect(_ error: State.Failure, _ work: () async throws -> Void) async {
        do { try await work(); check(false, "Expected \(error)") }
        catch let actual as State.Failure { check(actual == error, "Expected \(error), got \(actual)") }
        catch { check(false, "Expected \(error), got \(error)") }
    }
    static func main() async throws {
        try await noInventedASRProgress()
        try await diarizationLagAndWordClusters()
        try await privacyDrainAndLongSilence()
        try await fractionalPrivacyBoundary()
        try await privacyAcrossWindows()
        try await privacyAcrossLongPause()
        try await identityRefinementWithoutTextRollback()
        try await longBoundedStream()
        try await guardsAndLimits()
        try await cancellationAndReentry()
        print("Streaming transcript state: \(checks) checks passed")
    }

    static func noInventedASRProgress() async throws {
        let value = try state()
        let first = try await value.observe(observation(accepted: 20))
        check(first.safeBatch.segments.isEmpty)
        check(first.diagnostics.asrStableThroughSample == 0)
        check(first.diagnostics.privacySafeThroughSample == 0)
        check(first.retainActivityFromSample == 0)
        let silence = try await value.observe(observation(accepted: 40, asr: 40))
        check(silence.diagnostics.asrStableThroughSample == 640_000)
        check(silence.diagnostics.privacySafeThroughSample == 640_000)
        check(silence.safeBatch.segments.isEmpty)
        let final = try await value.finish(observation(accepted: 40, asr: 40, final: true))
        check(final.diagnostics.isFinal && final.diagnostics.pendingProtectedWords == 0)
        check(final.retainActivityFromSample == 640_000)
        await expect(.alreadyFinished) { _ = try await value.finish(observation(accepted: 40, asr: 40, final: true)) }
    }

    static func diarizationLagAndWordClusters() async throws {
        let value = try state()
        let originals = (0..<40).map { word($0) }
        let first = try await value.observe(observation(originals, accepted: 20, processed: 10, asr: 20))
        check(first.safeBatch.segments.count == 20)
        check(first.diagnostics.pendingProtectedWords == 20)
        check(first.diagnostics.privacySafeThroughSample == 160_000)
        let second = try await value.observe(observation(accepted: 30, processed: 20))
        check(second.safeBatch.segments.map(\.id) == originals.suffix(20).map(\.id))
        check(second.diagnostics.asrStableThroughSample == 320_000)
        check(second.diagnostics.pendingProtectedWords == 0)
        check(originals[20].nativeSpeakerAssignment == .unassigned)
        check(second.safeBatch.segments.first?.nativeSpeakerAssignment?.tokens.first?.label == "a",
            "A delayed private word published stale unscored native evidence")
        check(first.safeBatch.segments.first?.nativeSpeakerAssignment?.tokens.first?.label == "a")
        check(second.safeBatch.segments.map(\.nativeUnitID) == originals.suffix(20).map(\.nativeUnitID))
        let final = try await value.finish(observation(accepted: 30, asr: 30, final: true))
        check(final.safeBatch.segments.isEmpty)
        let combined = first.safeBatch.segments + second.safeBatch.segments
        check(combined.map(\.id) == originals.map(\.id))
        check(combined.map(\.nativeTiming) == originals.map(\.nativeTiming))
        check(combined.map(\.text) == originals.map(\.text))

        let cluster = try state()
        let overlapping = [word(1, start: 9, end: 10.1), word(2, start: 10, end: 10.4)]
        let blocked = try await cluster.observe(observation(overlapping, accepted: 11, processed: 10.2, asr: 11))
        check(blocked.safeBatch.segments.isEmpty, "Cannot split a native overlap cluster across the safe prefix")
        check(blocked.diagnostics.privacySafeThroughSample == 144_000)
        let released = try await cluster.observe(observation(accepted: 11, processed: 11))
        check(released.safeBatch.segments.count == 2)
        check(released.safeBatch.segments.map(\.nativeTiming) == overlapping.map(\.nativeTiming))
        _ = try await cluster.finish(observation(accepted: 11, asr: 11, final: true))

        let nested = try state()
        let words = [word(0, start: 0, end: 10), word(1, start: 1, end: 2), word(2, start: 3, end: 11)]
        let waits = try await nested.observe(observation(words, accepted: 11, processed: 10.5, asr: 11))
        check(waits.safeBatch.segments.isEmpty, "A long earlier word must not cross the pending cluster boundary")
        let releasedNested = try await nested.observe(observation(accepted: 11, processed: 11))
        check(releasedNested.safeBatch.segments.map(\.nativeTiming) == words.map(\.nativeTiming))
        check(releasedNested.safeBatch.segments.map(\.id) == words.map(\.id))
        _ = try await nested.finish(observation(accepted: 11, asr: 11, final: true))
    }

    static func privacyDrainAndLongSilence() async throws {
        let privacy = MeetingTranscriptPrivacyContext(redactor: SyntheticMaskingRedactor())
        let value = try state(privacy: privacy)
        let firstWords = (0..<40).map { word($0, text: $0 == 2 ? "private@example.test" : nil) }
        let first = try await value.observe(observation(firstWords, accepted: 20, asr: 20))
        check(first.safeBatch.segments.count == 8)
        check(first.safeBatch.segments[2].text == "<EMAIL>")
        check(first.safeBatch.segments.allSatisfy { $0.originalText == nil })
        check(first.diagnostics.privacySafeThroughSample == 64_000)
        check(await privacy.earliestHeldWordStart == 4)
        let silence = try await value.observe(observation(accepted: 620, asr: 620))
        check(silence.safeBatch.segments.isEmpty, "Ten-minute silence must not publish held PII words")
        check(silence.diagnostics.privacySafeThroughSample == 64_000)
        check(silence.retainActivityFromSample <= 64_000)
        let final = try await value.finish(observation(accepted: 620, asr: 620, final: true))
        check(final.safeBatch.segments.count == 32)
        let all = first.safeBatch.segments + final.safeBatch.segments
        check(all.map(\.id) == firstWords.map(\.id))
        check(all.map(\.nativeTiming) == firstWords.map(\.nativeTiming))
        check(all.map(\.nativeUnitID) == firstWords.map(\.nativeUnitID))
        check(all.map(\.status) == firstWords.map(\.status))
        check(all[2].text == "<EMAIL>")
        check(final.retainActivityFromSample == 620 * 16_000)
        check(await privacy.earliestHeldWordStart == nil)
        check(final.diagnostics.retainedAttributionWords == 0)
    }

    static func privacyAcrossWindows() async throws {
        let value = try state(privacy: .init(redactor: SyntheticMaskingRedactor()))
        let originals = (0..<80).map { word($0, text: $0 == 5 || $0 == 45 ? "private@example.test" : nil) }
        let a = try await value.observe(observation(Array(originals.prefix(40)), accepted: 20, asr: 20))
        let b = try await value.observe(observation(Array(originals.suffix(40)), accepted: 40, asr: 40))
        check(a.safeBatch.segments.count == 8 && b.safeBatch.segments.count == 40)
        let final = try await value.finish(observation(accepted: 40, asr: 40, final: true))
        let all = a.safeBatch.segments + b.safeBatch.segments + final.safeBatch.segments
        check(all.count == 80 && Set(all.map(\.id)).count == 80)
        check(all.map(\.id) == originals.map(\.id))
        check(all.map(\.nativeTiming) == originals.map(\.nativeTiming))
        check(all[5].text == "<EMAIL>" && all[45].text == "<EMAIL>")
        check(final.diagnostics.pendingProtectedWords == 0)
        check(a.safeBatch.segments[5].text == "<EMAIL>", "A later privacy window rewrote admitted source text")
    }

    static func privacyAcrossLongPause() async throws {
        let value = try state(privacy: .init(redactor: SyntheticMaskingRedactor()))
        let first = (0..<40).map { word($0) }
        let second = (40..<80).map { index in
            word(index, start: 620 + Double(index - 40) * 0.5, end: 620 + Double(index - 40) * 0.5 + 0.4)
        }
        let a = try await value.observe(observation(first, accepted: 20, asr: 20))
        _ = try await value.observe(observation(accepted: 620, asr: 620))
        let b = try await value.observe(observation(second, accepted: 640, asr: 640))
        let final = try await value.finish(observation(accepted: 640, asr: 640, final: true))
        let all = a.safeBatch.segments + b.safeBatch.segments + final.safeBatch.segments
        check(all.map(\.id) == (first + second).map(\.id))
        check(all.map(\.nativeTiming) == (first + second).map(\.nativeTiming))
        check(all.map(\.text) == (first + second).map(\.text))
        check(b.safeBatch.segments.count == 40 && b.diagnostics.pendingProtectedWords == 0)
        check(final.retainActivityFromSample == 640 * 16_000)
        check(a.diagnostics.privacyMilliseconds > 0 && a.diagnostics.attributionMilliseconds > 0)
    }

    static func fractionalPrivacyBoundary() async throws {
        let value = try state(privacy: .init(redactor: SyntheticMaskingRedactor()))
        let words = (0..<33).map { index in
            word(index, start: Double(index) * 0.5 + 0.00001,
                end: Double(index + 1) * 0.5 + 0.00001)
        }
        let first = try await value.observe(observation(words, accepted: 17, asr: 17))
        check(first.safeBatch.segments.count == 1)
        check(first.safeBatch.segments[0].nativeTiming == words[0].nativeTiming,
            "Rounding a privacy cursor to PCM samples lost native sub-sample precision")
        check(first.diagnostics.privacySafeThroughSample == 8_000)
        let final = try await value.finish(observation(accepted: 17, asr: 17, final: true))
        check(final.safeBatch.segments.count == 32)
    }

    static func identityRefinementWithoutTextRollback() async throws {
        let value = try state()
        let original = [word(0, start: 0, end: 0.8, text: "<EMAIL>"), word(1, start: 0.8, end: 1, text: "по")]
        let first = try await value.observe(observation(original, accepted: 1, asr: 1, activity: [
            .init(token: .init(analysisEpochID: epoch, label: "a"), start: 0, end: 0.8)]))
        check(first.safeBatch.segments[1].speakerID == nil)
        let second = try await value.observe(observation([word(2, start: 1, end: 1.8)], accepted: 1.8, asr: 1.8,
            activity: [.init(token: .init(analysisEpochID: epoch, label: "a"), start: 0, end: 0.8),
                       .init(token: .init(analysisEpochID: epoch, label: "b"), start: 1, end: 1.8)]))
        check(second.safeBatch.segments.count == 1)
        let patch = second.safeBatch.speakerRevisions.first { $0.segmentID == original[1].id }
        check(patch?.speakerAttribution?.rule == .incomingSpeaker)
        var edited = first.safeBatch.segments[1]
        edited.text = "User safe correction"
        edited.revision = 7
        check(try patch!.apply(to: &edited))
        check(edited.text == "User safe correction" && edited.revision == 8)
        check(edited.nativeTiming == original[1].nativeTiming)
        check(await value.retainActivityFromSample == second.retainActivityFromSample)
        check(await value.metadataDiagnostics?.revisedWords == second.diagnostics.revisedWords)
        await value.cancel()
        await expect(.cancelled) { _ = try await value.observe(observation(accepted: 2, asr: 2)) }
    }

    static func longBoundedStream() async throws {
        let value = try state()
        var total = 0
        var identities = Set<UUID>()
        var maximumTail = 0
        var retained = 0
        for window in 0..<50 {
            let words = (window * 40..<(window + 1) * 40).map { word($0) }
            let result = try await value.observe(observation(words, accepted: Double(window + 1) * 20,
                asr: Double(window + 1) * 20, retained: retained))
            for word in result.safeBatch.segments { check(identities.insert(word.id).inserted) }
            total += result.safeBatch.segments.count
            maximumTail = max(maximumTail, result.diagnostics.retainedAttributionWords)
            retained = result.retainActivityFromSample
            check(result.diagnostics.pendingProtectedWords == 0)
            check(result.safeBatch.speakers.count == 1)
        }
        let final = try await value.finish(observation(accepted: 1_000, asr: 1_000, final: true, retained: retained))
        check(total == 2_000 && identities.count == 2_000)
        check(maximumTail < 100, "A long meeting accumulated its entire protected transcript")
        check(final.diagnostics.retainedAttributionWords == 0)
    }

    static func guardsAndLimits() async throws {
        let missing = try state()
        var untimed = word(0); untimed.nativeTiming = nil
        await expect(.unsupportedNativeTiming) { _ = try await missing.observe(observation([untimed], accepted: 1, asr: 1)) }
        await expect(.failed) { _ = try await missing.observe(observation(accepted: 1, asr: 1)) }
        let noASR = try state()
        await expect(.invalidObservation) { _ = try await noASR.observe(observation([word(0)], accepted: 1)) }
        let regression = try state()
        _ = try await regression.observe(observation(accepted: 10, asr: 10))
        await expect(.regressedCursor) { _ = try await regression.observe(observation(accepted: 11, asr: 9)) }
        let stale = try state()
        var source = observation([word(0)], accepted: 1, asr: 1)
        source.batch.speechObservationIdentity = .init(attemptID: UUID(), epochID: epoch)
        await expect(.staleObservation) { _ = try await stale.observe(source) }
        let duplicate = try state()
        await expect(.invalidObservation) { _ = try await duplicate.observe(observation([word(0), word(0)], accepted: 1, asr: 1)) }
        let words = try state(limits: .init(maximumPendingWords: 1))
        await expect(.pendingWordLimit) { _ = try await words.observe(observation([word(0), word(1)], accepted: 1, asr: 1)) }
        let bytes = try state(limits: .init(maximumPendingTextBytes: 1))
        await expect(.pendingTextLimit) { _ = try await bytes.observe(observation([word(0)], accepted: 1, asr: 1)) }
        let duration = try state(limits: .init(maximumPendingSeconds: 1))
        await expect(.pendingTimeLimit) { _ = try await duration.observe(observation([word(0), word(1, start: 5, end: 5.4)],
            accepted: 6, processed: 0, asr: 6)) }
        let nestedDuration = try state(limits: .init(maximumPendingSeconds: 1))
        await expect(.pendingTimeLimit) { _ = try await nestedDuration.observe(observation([
            word(0, start: 0, end: 10), word(1, start: 0.5, end: 0.6)], accepted: 11, processed: 0, asr: 11)) }
        let unjoined = try state()
        await expect(.invalidObservation) { _ = try await unjoined.finish(observation(accepted: 10, processed: 9, asr: 10, final: true)) }
        let privacy = try state(privacy: .init(redactor: RejectedRedactor()))
        do { _ = try await privacy.observe(observation([word(0)], accepted: 1, asr: 1)); check(false) }
        catch is RejectedRedactor.Failure { check(true) }
        await expect(.failed) { _ = try await privacy.observe(observation(accepted: 1, asr: 1)) }
    }

    static func cancellationAndReentry() async throws {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let redactor = BlockedRedactor(continuation)
        let value = try state(privacy: .init(redactor: redactor))
        let task = Task { try await value.observe(observation([word(0)], accepted: 1, asr: 1)) }
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        await expect(.concurrentOperation) { _ = try await value.observe(observation(accepted: 1)) }
        await value.cancel()
        await redactor.release()
        await expect(.cancelled) { _ = try await task.value }
        check(await value.metadataDiagnostics == nil, "Late privacy completion published after cancellation")
    }
}

import Foundation
import PichiTextPrivacy

private struct StructuredPrivacyRedactor: TranscriptTextRedacting {
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        let output = try PIIRedactor.redact(text, ner: [])
        return .init(text: output.text, spans: output.spans.map { .init(range: $0.range, replacement: $0.replacement) })
    }
}

private actor NativePrivacyRedactor: TranscriptTextRedacting {
    let runtime = PIINERRuntime()
    func prepare(_ directory: URL) async throws { try await runtime.load(directory: directory) }
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        let output = try PIIRedactor.redact(text, ner: await runtime.tag(text))
        return .init(text: output.text, spans: output.spans.map { .init(range: $0.range, replacement: $0.replacement) })
    }
}

private struct InvalidOffsetRedactor: TranscriptTextRedacting {
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        .init(text: "[ИМЯ]", spans: [.init(range: NSRange(location: 1, length: 1), replacement: "[ИМЯ]")])
    }
}

private struct MissingOffsetsRedactor: TranscriptTextRedacting {
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction { .init(text: "[ИМЯ]", spans: []) }
}

private actor CancellablePrivacyRedactor: TranscriptTextRedacting {
    let started: AsyncStream<Void>.Continuation
    init(started: AsyncStream<Void>.Continuation) { self.started = started }
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        started.yield(())
        try await Task.sleep(nanoseconds: 5_000_000_000)
        try Task.checkCancellation()
        return try await StructuredPrivacyRedactor().redactWithSpans(text)
    }
}

@main
struct MeetingPrivacyContextTests {
    enum Failure: Error { case assertion(String) }
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.assertion(message) }
    }
    static func segment(_ text: String, track: UUID, start: Int) -> MeetingTranscriptSegment {
        .init(id: UUID(), start: .init(value: Int64(start), timescale: 1), end: .init(value: Int64(start + 1), timescale: 1),
              sourceTrackID: track, speakerID: nil, text: text, originalText: "Synthetic original", revision: 1,
              status: .final, overlap: .none, completeness: .complete)
    }
    static func main() async throws {
        try await suite(using: StructuredPrivacyRedactor())
        if let path = ProcessInfo.processInfo.environment["PICHI_PII_TEST_MODEL_DIRECTORY"] {
            let native = NativePrivacyRedactor()
            try await native.prepare(URL(fileURLWithPath: path, isDirectory: true))
            try await suite(using: native)
        }
        let track = UUID()
        let invalid = MeetingPCMTranscriptBatch(segments: [segment("🙂 Иван", track: track, start: 0)])
        do {
            _ = try await MeetingTranscriptPrivacyPolicy.redactedBatch(invalid, using: InvalidOffsetRedactor())
            throw Failure.assertion("invalid surrogate offsets must not publish")
        } catch is MeetingPrivacyPublicationError { }
        do {
            _ = try await MeetingTranscriptPrivacyPolicy.redactedBatch(invalid, using: MissingOffsetsRedactor())
            throw Failure.assertion("redacted text without offsets must not publish raw segments")
        } catch is MeetingPrivacyPublicationError { }
        let context = MeetingTranscriptPrivacyContext(redactor: StructuredPrivacyRedactor())
        let oversized = MeetingPCMTranscriptBatch(segments: [segment(String(repeating: "x", count: 16_385), track: track, start: 0)])
        do {
            _ = try await context.redact(oversized)
            throw Failure.assertion("pending tail must stay bounded")
        } catch is MeetingPrivacyPublicationError { }
        let started = AsyncStream<Void>.makeStream()
        let cancelled = MeetingTranscriptPrivacyContext(redactor: CancellablePrivacyRedactor(started: started.continuation))
        let task = Task { try await cancelled.redact(.init(segments: [segment("телефон 8 999", track: track, start: 0)])) }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        do { _ = try await task.value; throw Failure.assertion("cancelled privacy work must join and throw") }
        catch is CancellationError { }
        let cancelledTail = try await cancelled.finish()
        try check(cancelledTail == nil, "cancelled transform committed a raw pending tail")
        print("Meeting privacy context tests passed: actual segments/evidence, structured rules, opt-in native NER, delayed tail and final flush")
    }

    static func suite(using redactor: any TranscriptTextRedacting) async throws {
        let track = UUID()
        for (texts, masked) in [
            (["телефон", "273 55 11", "метформин 500 мг"], "273 55 11"),
            (["дата рождения", "12 мая 1980", "инсулин 10 единиц"], "12 мая 1980"),
            (["домашний адрес", "улица Примерная дом 12", "метотрексат 15 мг"], "улица Примерная дом 12"),
            (["врач иван", "петрович сидоров", "обсудил лизиноприл 10 мг"], "петрович сидоров"),
        ] {
            let input = MeetingPCMTranscriptBatch(segments: texts.enumerated().map { segment($0.element, track: track, start: $0.offset) })
            let output = try await MeetingTranscriptPrivacyPolicy.redactedBatch(input, using: redactor)
            try check(!output.segments.map(\.text).joined(separator: " ").contains(masked), "cross-segment PII escaped")
            try check(output.segments.last?.text == texts.last, "unrelated drug/dose text changed")
            try check(output.segments.map(\.id) == input.segments.map(\.id), "IDs changed")
            try check(output.segments.map(\.start) == input.segments.map(\.start), "timestamps changed")
            try check(output.segments.allSatisfy { $0.originalText == nil }, "originalText retained")
        }

        // A word/utterance canonical sidecar uses the same validated projection.
        let epoch = MeetingAnalysisEpochID(trackID: track, ordinal: 0)
        let units = ["дата рождения", "12 мая 1980", "метформин 500 мг"].enumerated().map { index, text in
            MeetingFinalTextUnit(id: "unit-\(index)", trackID: track, analysisEpochID: epoch, precision: .utterance,
                text: text, analysisStart: Double(index), analysisEnd: Double(index + 1), speaker: .unassigned, analysisSpanIDs: ["span"])
        }
        let evidence = MeetingFinalTranscriptEvidence(backendID: .parakeetNemotron, attemptID: UUID(), units: units)
        let safeEvidence = try await MeetingTranscriptPrivacyPolicy.redactedEvidence(evidence, using: redactor)
        try check(!safeEvidence.units[1].text.contains("1980"), "canonical DOB leaked")
        try check(safeEvidence.units[2].text == units[2].text, "canonical unrelated text changed")

        let large = MeetingPCMTranscriptBatch(segments: [
            segment(String(repeating: "word ", count: 7_998), track: track, start: 0),
            segment("дата рождения", track: track, start: 1),
            segment("12 мая 1980", track: track, start: 2),
            segment(String(repeating: "note ", count: 7_998), track: track, start: 3),
        ])
        let largeOutput = try await MeetingTranscriptPrivacyPolicy.redactedBatch(large, using: redactor)
        try check(largeOutput.segments[2].text == "[ДАТА_РОЖДЕНИЯ]", "overlap duplicated a replacement or leaked DOB")
        try check(largeOutput.segments[0].text == large.segments[0].text && largeOutput.segments[3].text == large.segments[3].text, "window projection changed unrelated large text")

        // Strict successive windows hold the possible first half until context
        // arrives. No checkpoint from either call may contain the phone fragments.
        let context = MeetingTranscriptPrivacyContext(redactor: redactor)
        let first = MeetingPCMTranscriptBatch(segments: [segment("телефон 8 999", track: track, start: 0)])
        let second = MeetingPCMTranscriptBatch(segments: [segment("123 45 67", track: track, start: 8)])
        let firstOutput = try await context.redact(first)
        try check(firstOutput.segments.isEmpty, "possible raw entity tail published early")
        let secondOutput = try await context.redact(second)
        try check(secondOutput.segments.count == 1 && !secondOutput.segments[0].text.contains("8 999"), "first-half phone leaked after join")
        let finalOutput = try await context.finish()
        try check(finalOutput?.segments.count == 1 && finalOutput?.segments[0].text.contains("123 45 67") == false, "final phone tail leaked")
        let repeatFinish = try await context.finish()
        try check(repeatFinish == nil, "finish duplicated a checkpoint")

        for (cue, value, privateValue) in [
            ("дата рождения", "12 мая 1980", "1980"),
            ("домашний адрес", "улица Примерная дом 12", "Примерная"),
        ] {
            let contextual = MeetingTranscriptPrivacyContext(redactor: redactor)
            let a = try await contextual.redact(.init(segments: [segment(cue, track: track, start: 0)]))
            let b = try await contextual.redact(.init(segments: [segment(value, track: track, start: 8)]))
            let c = try await contextual.finish()
            let text = (a.segments + b.segments + (c?.segments ?? [])).map(\.text).joined(separator: " ")
            try check(!text.contains(privateValue), "context-only identifier escaped across strict windows")
        }
        let fresh = MeetingTranscriptPrivacyContext(redactor: redactor)
        _ = try await fresh.redact(MeetingPCMTranscriptBatch(segments: [segment("12 мая 1980", track: track, start: 0)]))
        let freshOutput = try await fresh.finish()
        try check(freshOutput?.segments[0].text == "12 мая 1980", "context leaked across attempts")
    }
}

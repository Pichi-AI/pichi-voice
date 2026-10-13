import Foundation

nonisolated enum MeetingPrivacyPublicationError: LocalizedError {
    case redactorUnavailable
    case unsupportedLegacyPublication
    var errorDescription: String? {
        switch self {
        case .redactorUnavailable: return PichiLocalization.text("Prepare the local privacy model before enabling sensitive data redaction.")
        case .unsupportedLegacyPublication: return PichiLocalization.text("Sensitive data redaction requires a compatible meeting backend.")
        }
    }
}

/// Privacy transforms affect publication values, never source fingerprints or timestamps.
/// Exporting a legacy session returns a separate copy and never rewrites stored history.
nonisolated enum MeetingTranscriptPrivacyPolicy {
    static func redactedCopy(session: MeetingSession, using redactor: any TranscriptTextRedacting, preservingPublicationArtifacts: Bool = false) async throws -> MeetingSession {
        var copy = session
        copy.title = try await redactor.redact(copy.title)
        if let title = copy.defaultTitleBase { copy.defaultTitleBase = try await redactor.redact(title) }
        copy.selectedMicrophone.displayName = try await redactor.redact(copy.selectedMicrophone.displayName)
        if let application = copy.capturedApplication {
            copy.capturedApplication?.displayName = try await redactor.redact(application.displayName)
        }
        for i in copy.audioTracks.indices { copy.audioTracks[i].sourceDisplayName = try await redactor.redact(copy.audioTracks[i].sourceDisplayName) }
        for i in copy.speakers.indices {
            copy.speakers[i].displayName = try await redactor.redact(copy.speakers[i].displayName)
            for j in copy.speakers[i].identityCandidates.indices {
                copy.speakers[i].identityCandidates[j].displayName = try await redactor.redact(copy.speakers[i].identityCandidates[j].displayName)
                copy.speakers[i].identityCandidates[j].source = try await redactor.redact(copy.speakers[i].identityCandidates[j].source)
            }
        }
        copy.transcriptSegments = try await self.redactedSegments(copy.transcriptSegments, using: redactor)
        for i in copy.events.indices {
            if let detail = copy.events[i].detail { copy.events[i].detail = try await redactor.redact(detail) }
        }
        for i in copy.failures.indices { copy.failures[i].message = try await redactor.redact(copy.failures[i].message) }
        // A copy must never export an unfiltered historical sidecar or generated summary.
        if !preservingPublicationArtifacts {
            copy.resultSidecarReference = nil
            copy.postProcessing = nil
        }
        return copy
    }

    static func redactedBatch(_ batch: MeetingPCMTranscriptBatch, using redactor: any TranscriptTextRedacting,
                              contextPrefixes: [MeetingAudioTrackID: String] = [:]) async throws -> MeetingPCMTranscriptBatch {
        var copy = batch
        if let source = copy.sourceTrack { copy.sourceTrack?.sourceDisplayName = try await redactor.redact(source.sourceDisplayName) }
        copy.segments = try await self.redactedSegments(copy.segments, using: redactor, contextPrefixes: contextPrefixes)
        for i in copy.speakers.indices {
            copy.speakers[i].displayName = try await redactor.redact(copy.speakers[i].displayName)
            copy.speakers[i].diarizationEmbedding = nil
            copy.speakers[i].diarizationEmbeddingObservationCount = nil
            copy.speakers[i].diarizationQuality = nil
            copy.speakers[i].identityCandidates = []
        }
        return copy
    }

    /// Live text uses the same bounded span projection as durable publication. A finalized
    /// phrase supplies context to the next partial without changing row identity or timing.
    static func redactedLiveSnapshot(_ snapshot: MeetingLiveTranscriptSnapshot,
                                     using redactor: any TranscriptTextRedacting) async throws -> MeetingLiveTranscriptSnapshot {
        var copy = snapshot
        copy.utterances = Array(snapshot.utterances.suffix(100))
        for source: MeetingLiveSpeaker in [.you, .them] {
            let indices = copy.utterances.indices.filter { copy.utterances[$0].speaker == source }
                .sorted { copy.utterances[$0].start < copy.utterances[$1].start }
            var fragments = indices.map { TextFragment(key: $0, text: copy.utterances[$0].text) }
            let partialKey = copy.utterances.count
            if let partial = copy.partials[source] { fragments.append(.init(key: partialKey, text: partial.text)) }
            let safe = try await self.projectedTexts(fragments, prefix: "", using: redactor)
            for index in indices { copy.utterances[index].text = safe[index] ?? copy.utterances[index].text }
            if var partial = copy.partials[source] {
                partial.text = safe[partialKey] ?? partial.text
                copy.partials[source] = partial
            }
        }
        return copy
    }

    /// Preserve bounded linguistic context across adjacent utterances, then
    /// project replacements back to each original segment. Context is inference
    /// input only; it cannot add text, change timing, or enter a checkpoint.
    private static func redactedSegments(_ segments: [MeetingTranscriptSegment], using redactor: any TranscriptTextRedacting,
                                         contextPrefixes: [MeetingAudioTrackID: String] = [:]) async throws -> [MeetingTranscriptSegment] {
        var copy = segments
        let groups = Dictionary(grouping: segments.indices) { segments[$0].sourceTrackID }
        for (trackID, indices) in groups {
            let ordered = indices.sorted { a, b in
                segments[a].start == segments[b].start ? a < b : segments[a].start < segments[b].start
            }
            let fragments = ordered.map { TextFragment(key: $0, text: segments[$0].text) }
            let projected = try await self.projectedTexts(fragments, prefix: contextPrefixes[trackID] ?? "", separator: "\n", using: redactor)
            for index in ordered {
                copy[index].text = projected[index] ?? segments[index].text
                copy[index].originalText = nil
            }
        }
        return copy
    }

    private struct TextFragment {
        let key: Int
        let text: String
    }

    private static func projectedTexts(_ fragments: [TextFragment], prefix: String, separator: String = " ",
                                       using redactor: any TranscriptTextRedacting) async throws -> [Int: String] {
        guard prefix.utf16.count <= MeetingTranscriptPrivacyContext.maximumContextUTF16 else {
            throw MeetingPrivacyPublicationError.unsupportedLegacyPublication
        }
        var rangesByFragment: [Int: [TranscriptRedactedSpan]] = [:]
        var cursor = 0
        while cursor < fragments.count {
            try Task.checkCancellation()
            var text = cursor == 0 ? prefix : ""
            var ranges: [(Int, NSRange)] = []
            var end = cursor
            while end < fragments.count {
                let fragment = fragments[end]
                let joiner = text.isEmpty ? "" : separator
                guard text.utf16.count + joiner.utf16.count + fragment.text.utf16.count <= 60_000 else { break }
                text += joiner
                let range = NSRange(location: text.utf16.count, length: fragment.text.utf16.count)
                text += fragment.text
                ranges.append((fragment.key, range)); end += 1
            }
            guard end > cursor else { throw MeetingPrivacyPublicationError.unsupportedLegacyPublication }
            let output = try await redactor.redactWithSpans(text)
            try Task.checkCancellation()
            try self.validate(output, for: text)
            for (key, range) in ranges {
                for span in output.spans {
                    let intersection = NSIntersectionRange(span.range, range)
                    guard intersection.length > 0 else { continue }
                    rangesByFragment[key, default: []].append(.init(
                        range: NSRange(location: intersection.location - range.location, length: intersection.length),
                        replacement: span.replacement))
                }
            }
            if end == fragments.count { break }
            // The overlap is bounded by the next inference window's character
            // admission and keeps context for entities crossing window edges.
            cursor = max(cursor + 1, end - 32)
        }
        var result: [Int: String] = [:]
        for fragment in fragments {
            if let spans = rangesByFragment[fragment.key], !spans.isEmpty {
                result[fragment.key] = try self.replacing(fragment.text, spans: spans)
            }
        }
        return result
    }

    private static func validate(_ output: TranscriptTextRedaction, for input: String) throws {
        let units = Array(input.utf16)
        for span in output.spans {
            guard span.range.location >= 0, span.range.length > 0,
                  span.range.location <= units.count, span.range.length <= units.count - span.range.location,
                  !span.replacement.isEmpty,
                  span.range.location == 0 || !(0xDC00...0xDFFF).contains(units[span.range.location]),
                  NSMaxRange(span.range) == units.count || !(0xDC00...0xDFFF).contains(units[NSMaxRange(span.range)]) else {
                throw MeetingPrivacyPublicationError.unsupportedLegacyPublication
            }
        }
        // A generic transformer must not claim redacted text while supplying
        // incomplete offsets that would publish raw canonical word/segment text.
        guard try self.replacing(input, spans: output.spans) == output.text else {
            throw MeetingPrivacyPublicationError.unsupportedLegacyPublication
        }
    }

    private static func replacing(_ input: String, spans: [TranscriptRedactedSpan]) throws -> String {
        let ordered = spans.sorted { $0.range.location < $1.range.location }
        var merged: [TranscriptRedactedSpan] = []
        for span in ordered {
            guard span.range.location >= 0, span.range.length > 0,
                  span.range.location <= input.utf16.count, span.range.length <= input.utf16.count - span.range.location,
                  !span.replacement.isEmpty else { throw MeetingPrivacyPublicationError.unsupportedLegacyPublication }
            if let previous = merged.last, NSIntersectionRange(previous.range, span.range).length > 0 {
                merged[merged.count - 1] = .init(range: NSUnionRange(previous.range, span.range), replacement: previous.replacement)
            } else { merged.append(span) }
        }
        let output = NSMutableString(string: input)
        for span in merged.reversed() { output.replaceCharacters(in: span.range, with: span.replacement) }
        return output as String
    }

    static func redactedEvidence(_ evidence: MeetingFinalTranscriptEvidence, using redactor: any TranscriptTextRedacting) async throws -> MeetingFinalTranscriptEvidence {
        var replacements: [String: String] = [:]
        let groups = Dictionary(grouping: evidence.units) { $0.analysisEpochID }
        for group in groups.values {
            let ordered = group.sorted { $0.analysisStart < $1.analysisStart }
            let fragments = ordered.indices.map { TextFragment(key: $0, text: ordered[$0].text) }
            let projected = try await self.projectedTexts(fragments, prefix: "", using: redactor)
            for (index, text) in projected { replacements[ordered[index].id] = text }
        }
        let units = evidence.units.map { unit in
            MeetingFinalTextUnit(id: unit.id, trackID: unit.trackID, analysisEpochID: unit.analysisEpochID,
                                 precision: unit.precision, text: replacements[unit.id] ?? unit.text,
                                 analysisStart: unit.analysisStart, analysisEnd: unit.analysisEnd,
                                 speaker: unit.speaker, analysisSpanIDs: unit.analysisSpanIDs, confidence: unit.confidence)
        }
        return MeetingFinalTranscriptEvidence(backendID: evidence.backendID, attemptID: evidence.attemptID,
                                               units: units, speakerActivity: evidence.speakerActivity,
                                               voiceProfiles: evidence.voiceProfiles,
                                               speakerSlotsContinueAcrossEpochs: evidence.speakerSlotsContinueAcrossEpochs)
    }
}

/// One bounded context owner per frozen strict-memory attempt. The last segment
/// waits for the next window's context instead of first publishing a possible
/// entity fragment. Finish flushes it before the consumer's joined drain returns.
/// This is fallible text detection, not a promise about every incomplete entity.
actor MeetingTranscriptPrivacyContext {
    nonisolated static let maximumContextUTF16 = 1_024
    nonisolated static let maximumPendingUTF16 = 16_384
    private let redactor: any TranscriptTextRedacting
    private var trackID: MeetingAudioTrackID?
    private var lastEnd: MeetingMediaTime?
    private var prefix = ""
    private var pending: MeetingTranscriptSegment?
    private var pendingIsComplete = true
    private var isProcessing = false
    init(redactor: any TranscriptTextRedacting) { self.redactor = redactor }

    func redact(_ batch: MeetingPCMTranscriptBatch) async throws -> MeetingPCMTranscriptBatch {
        try Task.checkCancellation()
        guard !isProcessing else { throw MeetingPrivacyPublicationError.unsupportedLegacyPublication }
        isProcessing = true
        defer { isProcessing = false }
        let tracks = Set(batch.segments.map(\.sourceTrackID))
        guard tracks.count <= 1 else { throw MeetingPrivacyPublicationError.unsupportedLegacyPublication }
        let ordered = batch.segments.sorted { $0.start < $1.start }
        let currentTrack = ordered.first?.sourceTrackID ?? batch.sourceTrack?.id
        let sameTrack = currentTrack != nil && currentTrack == trackID
        let forward = ordered.first.map { first in lastEnd.map { first.start.seconds + 0.001 >= $0.seconds } ?? true } ?? true
        let continues = sameTrack && forward
        if pending != nil, !ordered.isEmpty, !continues { throw MeetingPrivacyPublicationError.unsupportedLegacyPublication }
        let context = continues ? prefix : ""
        guard let tail = ordered.last else {
            return try await MeetingTranscriptPrivacyPolicy.redactedBatch(batch, using: redactor)
        }
        guard tail.text.utf16.count <= Self.maximumPendingUTF16 else { throw MeetingPrivacyPublicationError.unsupportedLegacyPublication }
        var combined = batch
        combined.segments = pending.map { [$0] + batch.segments } ?? batch.segments
        combined.isComplete = combined.isComplete && pendingIsComplete
        var safe = try await MeetingTranscriptPrivacyPolicy.redactedBatch(combined, using: redactor,
            contextPrefixes: currentTrack.map { [$0: context] } ?? [:])
        try Task.checkCancellation()
        // A checkpoint receives all earlier complete segments, never this raw
        // tail. Reusing its original ID later preserves normal store operations.
        safe.segments.removeAll { $0.id == tail.id }
        let published = combined.segments.filter { $0.id != tail.id }.sorted { $0.start < $1.start }
        prefix = Self.suffix(([context] + published.map(\.text)).filter { !$0.isEmpty }.joined(separator: "\n"))
        pending = tail; pending?.originalText = nil
        pendingIsComplete = batch.isComplete
        trackID = currentTrack; lastEnd = tail.end
        return safe
    }

    func finish() async throws -> MeetingPCMTranscriptBatch? {
        try Task.checkCancellation()
        guard !isProcessing else { throw MeetingPrivacyPublicationError.unsupportedLegacyPublication }
        guard let pending else { return nil }
        isProcessing = true
        defer { isProcessing = false }
        let batch = MeetingPCMTranscriptBatch(segments: [pending], isComplete: pendingIsComplete)
        let safe = try await MeetingTranscriptPrivacyPolicy.redactedBatch(batch, using: redactor,
            contextPrefixes: [pending.sourceTrackID: prefix])
        try Task.checkCancellation()
        self.pending = nil; prefix = ""; trackID = nil; lastEnd = nil
        return safe
    }

    private nonisolated static func suffix(_ text: String) -> String {
        // Character iteration prevents a UTF-16 budget cut from bisecting an
        // emoji/name; drop a truncated leading word rather than inventing one.
        var suffix = ""
        var count = 0
        for character in text.reversed() {
            let width = String(character).utf16.count
            guard count + width <= Self.maximumContextUTF16 else { break }
            suffix.insert(character, at: suffix.startIndex); count += width
        }
        if count < text.utf16.count, let separator = suffix.firstIndex(where: { $0.isWhitespace }) {
            suffix = String(suffix[suffix.index(after: separator)...])
        }
        return suffix
    }
}

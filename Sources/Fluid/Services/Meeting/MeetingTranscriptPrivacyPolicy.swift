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
        copy.transcriptSegments = try await self.redactedSegments(copy.transcriptSegments, using: redactor).segments
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
                              contextPrefixes: [MeetingAudioTrackID: String] = [:],
                              provisionalPreviewID: UUID? = nil,
                              provisionalSegmentIDs: Set<UUID> = []) async throws -> MeetingPCMTranscriptBatch {
        var copy = batch
        if let source = copy.sourceTrack { copy.sourceTrack?.sourceDisplayName = try await redactor.redact(source.sourceDisplayName) }
        let projection = try await self.redactedSegments(copy.segments, using: redactor, contextPrefixes: contextPrefixes,
                                                        provisionalSegmentIDs: provisionalSegmentIDs)
        copy.segments = projection.segments
        copy.livePreview = nil
        if let id = provisionalPreviewID, let text = projection.provisionalText, !text.isEmpty,
           let first = batch.segments.filter({ provisionalSegmentIDs.contains($0.id) }).min(by: { $0.start < $1.start }) {
            copy.livePreview = .init(id: id, text: text, start: first.start.seconds, end: projection.provisionalEnd)
        }
        for i in copy.speakers.indices {
            copy.speakers[i].displayName = try await redactor.redact(copy.speakers[i].displayName)
            copy.speakers[i].diarizationEmbedding = nil
            copy.speakers[i].diarizationEmbeddingObservationCount = nil
            copy.speakers[i].diarizationQuality = nil
            copy.speakers[i].identityCandidates = []
        }
        return copy
    }

    /// NER sees finalized turns and explicitly stable whole words only. An open turn's
    /// lexical edge remains behind capture progress until the same detector admits it.
    static func redactedLiveSnapshot(_ snapshot: MeetingLiveTranscriptSnapshot,
                                     using redactor: any TranscriptTextRedacting) async throws -> MeetingLiveTranscriptSnapshot {
        var copy = self.boundedLiveInput(snapshot)
        for source: MeetingLiveSpeaker in [.you, .them] {
            let indices = copy.utterances.indices.filter { copy.utterances[$0].speaker == source }
                .sorted { a, b in copy.utterances[a].start == copy.utterances[b].start ? a < b : copy.utterances[a].start < copy.utterances[b].start }
            var fragments = indices.map { TextFragment(key: $0, text: copy.utterances[$0].text) }
            let partialKey = copy.utterances.count
            let partial = copy.partials[source]
            if let partial, let text = try self.stablePrefix(of: partial), !text.isEmpty {
                fragments.append(.init(key: partialKey, text: text))
            }
            let projection = try await self.projectedTexts(fragments, prefix: "", using: redactor)
            // A decoder's EOU can be an arbitrary audio-window boundary, not the
            // conversation's end. Keep lexical admission consistent across turns;
            // the final processing pipeline performs the full canonical flush.
            for index in indices {
                copy.utterances[index].text = projection.provisional?[index] ?? ""
                copy.utterances[index].hasIncompleteTextCoverage = !projection.provisionalCompleteKeys.contains(index)
            }
            if var safePartial = partial, let text = projection.provisional?[partialKey], !text.isEmpty {
                let wholeInputAdmitted = projection.provisionalCompleteKeys.contains(partialKey)
                    && safePartial.stableUTF16Count == safePartial.text.utf16.count
                safePartial.text = text
                if !wholeInputAdmitted { safePartial.end = nil }
                // Stable offsets refer to raw text and do not describe replacements.
                safePartial.stableUTF16Count = nil
                copy.partials[source] = safePartial
            } else { copy.partials.removeValue(forKey: source) }
        }
        copy.utterances.removeAll { $0.text.isEmpty }
        return copy
    }

    private static func stablePrefix(of partial: MeetingLivePartial) throws -> String? {
        guard let count = partial.stableUTF16Count else { return nil }
        return try self.stablePrefix(in: partial.text, utf16Count: count).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate static func stablePrefix(in text: String, utf16Count count: Int) throws -> String {
        let units = Array(text.utf16)
        guard count >= 0, count <= units.count,
              count == units.count || !(0xDC00...0xDFFF).contains(units[count]),
              let boundary = String.Index(utf16Offset: count, in: text).samePosition(in: text) else {
            throw MeetingPrivacyPublicationError.unsupportedLegacyPublication
        }
        // A stability claim cannot bisect a lexical word. Punctuation is itself a boundary.
        if boundary != text.startIndex, boundary != text.endIndex {
            let before = text[text.index(before: boundary)]
            let after = text[boundary]
            if (before.isLetter || before.isNumber), (after.isLetter || after.isNumber) {
                throw MeetingPrivacyPublicationError.unsupportedLegacyPublication
            }
        }
        return String(text[..<boundary])
    }

    /// The UI projects at most 100 completed rows. Apply the same bound before
    /// queuing inference so replaced snapshots cannot retain an entire meeting.
    static func boundedLiveInput(_ snapshot: MeetingLiveTranscriptSnapshot) -> MeetingLiveTranscriptSnapshot {
        var copy = snapshot
        copy.utterances = Array(snapshot.utterances.suffix(100))
        return copy
    }

    /// Preserve bounded linguistic context across adjacent utterances, then
    /// project replacements back to each original segment. Context is inference
    /// input only; it cannot add text, change timing, or enter a checkpoint.
    private struct SegmentProjection {
        let segments: [MeetingTranscriptSegment]
        let provisionalText: String?
        let provisionalEnd: TimeInterval?
    }

    private static func redactedSegments(_ segments: [MeetingTranscriptSegment], using redactor: any TranscriptTextRedacting,
                                         contextPrefixes: [MeetingAudioTrackID: String] = [:],
                                         provisionalSegmentIDs: Set<UUID> = []) async throws -> SegmentProjection {
        var copy = segments
        let groups = Dictionary(grouping: segments.indices) { segments[$0].sourceTrackID }
        var provisionalText: String?
        var provisionalEnd: TimeInterval?
        for (trackID, indices) in groups {
            let ordered = indices.sorted { a, b in
                segments[a].start == segments[b].start ? a < b : segments[a].start < segments[b].start
            }
            let fragments = ordered.map { TextFragment(key: $0, text: segments[$0].text) }
            let projected = try await self.projectedTexts(fragments, prefix: contextPrefixes[trackID] ?? "", using: redactor)
            for index in ordered {
                copy[index].text = projected.canonical[index] ?? segments[index].text
                copy[index].originalText = nil
            }
            // A display prefix belongs to one source. Never join unrelated source contexts.
            if groups.count == 1, !provisionalSegmentIDs.isEmpty, let preview = projected.provisional {
                provisionalText = ordered.filter { provisionalSegmentIDs.contains(segments[$0].id) }
                    .map { preview[$0] ?? "" }.filter { !$0.isEmpty }.joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // A partially admitted segment has no known word-level endpoint. Retire
                // captured progress only through complete, privacy-approved fragments.
                provisionalEnd = ordered.filter {
                    provisionalSegmentIDs.contains(segments[$0].id)
                        && projected.provisionalCompleteKeys.contains($0)
                        && !(preview[$0] ?? "").isEmpty
                }.map { segments[$0].end.seconds }.max()
            }
        }
        return .init(segments: copy, provisionalText: provisionalText, provisionalEnd: provisionalEnd)
    }

    private struct TextFragment {
        let key: Int
        let text: String
    }

    private struct TextProjection {
        let canonical: [Int: String]
        let provisional: [Int: String]?
        let provisionalCompleteKeys: Set<Int>
    }

    private static func projectedTexts(_ fragments: [TextFragment], prefix: String, separator: String = " ",
                                       using redactor: any TranscriptTextRedacting) async throws -> TextProjection {
        guard prefix.utf16.count <= MeetingTranscriptPrivacyContext.maximumContextUTF16 else {
            throw MeetingPrivacyPublicationError.unsupportedLegacyPublication
        }
        var rangesByFragment: [Int: [TranscriptRedactedSpan]] = [:]
        var provisional: [Int: String]?
        var provisionalCompleteKeys: Set<Int> = []
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
            // Strict held text fits one admission window. A multi-window transformation has
            // no single adapter-approved prefix, so canonical projection remains available
            // but provisional display fails closed rather than splicing separate approvals.
            if cursor == 0, end == fragments.count, let limit = output.provisionalSafeUTF16 {
                var approved: [Int: String] = [:]
                let source = text as NSString
                for (key, range) in ranges where range.location < limit {
                    let admitted = NSRange(location: range.location, length: min(NSMaxRange(range), limit) - range.location)
                    let spans = output.spans.compactMap { span -> TranscriptRedactedSpan? in
                        let intersection = NSIntersectionRange(span.range, admitted)
                        guard intersection.length > 0 else { return nil }
                        return .init(range: NSRange(location: intersection.location - admitted.location, length: intersection.length),
                                     replacement: span.replacement)
                    }
                    approved[key] = try self.replacing(source.substring(with: admitted), spans: spans)
                    if NSMaxRange(range) <= limit { provisionalCompleteKeys.insert(key) }
                }
                provisional = approved
            }
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
        return .init(canonical: result, provisional: provisional, provisionalCompleteKeys: provisionalCompleteKeys)
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
        if let limit = output.provisionalSafeUTF16 {
            guard limit >= 0, limit <= units.count,
                  limit == units.count || !(0xDC00...0xDFFF).contains(units[limit]),
                  !output.spans.contains(where: { $0.range.location < limit && NSMaxRange($0.range) > limit }) else {
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
            let projected = try await self.projectedTexts(fragments, prefix: "", using: redactor).canonical
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

/// Delivery ownership for the existing live privacy transform. Cancelling every
/// partial can starve slow inference and leave unjoined work behind; one worker
/// instead finishes its revision and then consumes the latest bounded raw input.
/// Raw snapshots are never replaced by previously filtered display strings.
@MainActor
final class MeetingLivePrivacyPublication {
    private struct Pending {
        let snapshot: MeetingLiveTranscriptSnapshot
        let generation: UUID
        let redactor: any TranscriptTextRedacting
        let publish: @MainActor (MeetingLiveTranscriptSnapshot, UUID) -> Void
        let failed: @MainActor (UUID) -> Void
    }
    private var pending: Pending?
    private var worker: Task<Void, Never>?
    private var workerID: UUID?
    private var generation: UUID?
    private var submittedRevision: UInt64 = 0

    func submit(_ snapshot: MeetingLiveTranscriptSnapshot, generation: UUID,
                using redactor: any TranscriptTextRedacting,
                publish: @escaping @MainActor (MeetingLiveTranscriptSnapshot, UUID) -> Void,
                failed: @escaping @MainActor (UUID) -> Void) {
        // A caller must join stop before changing the recording generation.
        guard (self.generation == nil && worker == nil) || self.generation == generation else { return }
        guard snapshot.revision > submittedRevision else { return }
        self.generation = generation
        submittedRevision = snapshot.revision
        self.pending = Pending(snapshot: MeetingTranscriptPrivacyPolicy.boundedLiveInput(snapshot),
                               generation: generation, redactor: redactor, publish: publish, failed: failed)
        guard worker == nil else { return }
        let id = UUID()
        workerID = id
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.workerID == id { self.worker = nil; self.workerID = nil }
            }
            while self.workerID == id, let item = self.pending {
                self.pending = nil
                do {
                    try Task.checkCancellation()
                    let safe = try await MeetingTranscriptPrivacyPolicy.redactedLiveSnapshot(item.snapshot, using: item.redactor)
                    try Task.checkCancellation()
                    guard self.workerID == id, self.generation == item.generation else { return }
                    item.publish(safe, item.generation)
                } catch is CancellationError { return }
                catch {
                    guard self.workerID == id, self.generation == item.generation, !Task.isCancelled else { return }
                    self.pending = nil
                    item.failed(item.generation)
                    return
                }
            }
        }
    }

    /// Keep the task slot until it finishes, so concurrent teardown callers join
    /// the same native operation and a new generation cannot inherit old work.
    func stop() async {
        pending = nil
        generation = nil
        submittedRevision = 0
        let task = worker
        let id = workerID
        task?.cancel()
        await task?.value
        if workerID == id { worker = nil; workerID = nil }
    }
}

/// One bounded context owner per frozen strict-memory attempt. A lexical tail
/// waits for the next window's context instead of first publishing a possible
/// entity fragment. Segment granularity can be a word or an utterance. Finish
/// flushes the whole held array before the consumer's joined drain returns.
/// This is fallible text detection, not a promise about every incomplete entity.
actor MeetingTranscriptPrivacyContext {
    nonisolated static let maximumContextUTF16 = 1_024
    nonisolated static let maximumPendingUTF16 = 16_384
    nonisolated static let minimumPendingTokens = 32
    nonisolated static let maximumPendingSegments = 128
    private let redactor: any TranscriptTextRedacting
    private var trackID: MeetingAudioTrackID?
    private var lastEnd: MeetingMediaTime?
    private var prefix = ""
    private var pending: [MeetingTranscriptSegment] = []
    private var pendingIsComplete = true
    private var isProcessing = false
    private let provisionalPreviewID = UUID()
    private var lastSafePreview: MeetingLivePartial?
    private struct SpeechObservation {
        let trackID: MeetingAudioTrackID
        let firstSegmentID: UUID
        let identity: MeetingPCMTranscriptBatch.SpeechObservationIdentity?
        let text: String

        func belongsToSameWindow(as batch: MeetingPCMTranscriptBatch, trackID: MeetingAudioTrackID?, firstSegmentID: UUID?) -> Bool {
            guard self.trackID == trackID else { return false }
            if let identity = batch.speechObservationIdentity { return self.identity == identity }
            // Legacy callers have no physical-window provenance. Their original
            // segment ID guard remains intact and never matches a typed window.
            return self.identity == nil && self.firstSegmentID == firstSegmentID
        }
    }
    /// One bounded raw hypothesis belongs to one growing PCM window. It never
    /// enters NER until words agree with the next observation or the window seals.
    private var previousSpeechObservation: SpeechObservation?
    /// Aggregate support fields only, read after the owned observation completes.
    private(set) var speechAdmissionDiagnosticFields = ""
    init(redactor: any TranscriptTextRedacting) { self.redactor = redactor }

    /// Speech can be displayed before expensive attribution, but cannot enter the durable
    /// tail or checkpoint until that window completes. Use the same frozen redactor/guards.
    func previewSpeech(_ batch: MeetingPCMTranscriptBatch) async throws -> MeetingLivePartial? {
        guard !isProcessing else { throw MeetingPrivacyPublicationError.unsupportedLegacyPublication }
        isProcessing = true
        var completed = false
        var diagnosticRawUTF16 = 0
        var diagnosticStableUTF16 = 0
        var diagnosticPreviewUTF16 = 0
        defer {
            if !completed { lastSafePreview = nil; previousSpeechObservation = nil }
            isProcessing = false
            // Scalar publication evidence only. Raw hypotheses, detected values,
            // names and model outputs never enter the support logger.
            speechAdmissionDiagnosticFields = "rawUTF16=\(diagnosticRawUTF16) stableUTF16=\(diagnosticStableUTF16) previewUTF16=\(diagnosticPreviewUTF16) pendingSegments=\(pending.count) sealed=\(batch.speechObservationIsFinal) completed=\(completed)"
        }
        try Task.checkCancellation()
        let tracks = Set(batch.segments.map(\.sourceTrackID))
        guard tracks.count <= 1 else { throw MeetingPrivacyPublicationError.unsupportedLegacyPublication }
        let ordered = batch.segments.sorted { $0.start < $1.start }
        let currentTrack = ordered.first?.sourceTrackID ?? batch.sourceTrack?.id
        if let identity = batch.speechObservationIdentity {
            guard identity.epochID.trackID == currentTrack,
                  identity.epochID.ordinal >= 0, identity.epochID.generation >= 0 else {
                throw MeetingPrivacyPublicationError.unsupportedLegacyPublication
            }
        }
        let forward = ordered.first.map { first in lastEnd.map { first.start.seconds + 0.001 >= $0.seconds } ?? true } ?? true
        let continues = currentTrack != nil && currentTrack == trackID && forward
        if !pending.isEmpty, let first = ordered.first {
            guard currentTrack == trackID, lastEnd.map({ first.start.seconds + 0.001 >= $0.seconds }) ?? true else {
                throw MeetingPrivacyPublicationError.unsupportedLegacyPublication
            }
        }
        if ordered.isEmpty {
            completed = true
            let preview = currentTrack == nil || continues ? lastSafePreview : nil
            diagnosticPreviewUTF16 = preview?.text.utf16.count ?? 0
            return preview
        }
        var combined = batch
        combined.segments = pending + batch.segments
        var remaining = Self.maximumPendingUTF16
        guard combined.segments.count <= Self.maximumPendingSegments else {
            throw MeetingPrivacyPublicationError.unsupportedLegacyPublication
        }
        for (index, segment) in combined.segments.enumerated() {
            let count = segment.text.utf16.count + (index == 0 ? 0 : 1)
            guard count <= remaining else { throw MeetingPrivacyPublicationError.unsupportedLegacyPublication }
            remaining -= count
        }
        let rawText = ordered.map(\.text).joined(separator: " ")
        diagnosticRawUTF16 = rawText.utf16.count
        let stableCount: Int
        if batch.speechObservationIsFinal {
            stableCount = rawText.utf16.count
        } else if let previous = previousSpeechObservation,
                  previous.belongsToSameWindow(as: batch, trackID: currentTrack, firstSegmentID: ordered.first?.id) {
            stableCount = MeetingSpeechHypothesisStability.stableUTF16Count(previous: previous.text, current: rawText)
        } else { stableCount = 0 }
        diagnosticStableUTF16 = stableCount
        if let currentTrack, let first = ordered.first {
            previousSpeechObservation = SpeechObservation(trackID: currentTrack, firstSegmentID: first.id,
                identity: batch.speechObservationIdentity, text: rawText)
        }
        guard stableCount > 0 else {
            completed = true
            let preview = continues ? lastSafePreview : nil
            diagnosticPreviewUTF16 = preview?.text.utf16.count ?? 0
            return preview
        }
        _ = try MeetingTranscriptPrivacyPolicy.stablePrefix(in: rawText, utf16Count: stableCount)
        var admitted: [MeetingTranscriptSegment] = []
        var position = 0
        var clippedAudioCoverage = false
        var completeSourceEnd = pending.filter { !$0.text.isEmpty }.map { $0.end.seconds }.max()
        for segment in ordered {
            let count = segment.text.utf16.count
            if position < stableCount {
                var copy = segment
                let admittedCount = min(count, stableCount - position)
                copy.text = try MeetingTranscriptPrivacyPolicy.stablePrefix(in: copy.text, utf16Count: admittedCount)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                copy.originalText = nil
                if !copy.text.isEmpty {
                    admitted.append(copy)
                    if admittedCount == count { completeSourceEnd = max(completeSourceEnd ?? 0, segment.end.seconds) }
                }
                if admittedCount < count { clippedAudioCoverage = true }
            }
            position += count + 1
        }
        combined.segments = pending + admitted
        let safe = try await MeetingTranscriptPrivacyPolicy.redactedBatch(combined, using: redactor,
            contextPrefixes: currentTrack.map { [$0: continues ? prefix : ""] } ?? [:],
            provisionalPreviewID: provisionalPreviewID, provisionalSegmentIDs: Set(combined.segments.map(\.id)))
        try Task.checkCancellation()
        var preview = safe.livePreview
        // The clipped utterance has no word-level endpoint. Earlier fully admitted
        // source fragments still have real endpoints; preserve only their approved
        // coverage instead of discarding it or claiming the clipped source's end.
        if clippedAudioCoverage {
            let approvedEnd = preview?.end
            preview?.end = approvedEnd.flatMap { approvedEnd in
                completeSourceEnd.map { min(approvedEnd, $0) }
            }
        }
        diagnosticPreviewUTF16 = preview?.text.utf16.count ?? 0
        lastSafePreview = preview
        completed = true
        return preview
    }

    func redact(_ batch: MeetingPCMTranscriptBatch) async throws -> MeetingPCMTranscriptBatch {
        guard !isProcessing else { throw MeetingPrivacyPublicationError.unsupportedLegacyPublication }
        isProcessing = true
        var completed = false
        defer { if !completed { lastSafePreview = nil }; isProcessing = false }
        try Task.checkCancellation()
        let tracks = Set(batch.segments.map(\.sourceTrackID))
        guard tracks.count <= 1 else { throw MeetingPrivacyPublicationError.unsupportedLegacyPublication }
        let ordered = batch.segments.sorted { $0.start < $1.start }
        let currentTrack = ordered.first?.sourceTrackID ?? batch.sourceTrack?.id
        let sameTrack = currentTrack != nil && currentTrack == trackID
        let forward = ordered.first.map { first in lastEnd.map { first.start.seconds + 0.001 >= $0.seconds } ?? true } ?? true
        let continues = sameTrack && forward
        if !pending.isEmpty, !ordered.isEmpty, !continues { throw MeetingPrivacyPublicationError.unsupportedLegacyPublication }
        let context = continues ? prefix : ""
        guard let last = ordered.last else {
            var safe = try await MeetingTranscriptPrivacyPolicy.redactedBatch(batch, using: redactor)
            try Task.checkCancellation()
            // An empty forward window has no new hypothesis to invalidate the
            // already approved display. No-source silence belongs to this owned
            // attempt; an explicitly different source never inherits its preview.
            if !pending.isEmpty, currentTrack == nil || continues { safe.livePreview = lastSafePreview }
            lastSafePreview = safe.livePreview
            completed = true
            return safe
        }
        var combined = batch
        combined.segments = pending + batch.segments
        combined.isComplete = combined.isComplete && pendingIsComplete
        let combinedOrdered = combined.segments.sorted { $0.start < $1.start }
        var heldCount = 0
        var tokens = 0
        var heldUTF16 = 0
        for segment in combinedOrdered.reversed() {
            heldCount += 1
            tokens += segment.text.split(whereSeparator: { $0.isWhitespace }).count
            heldUTF16 += segment.text.utf16.count + (heldCount > 1 ? 1 : 0)
            guard heldCount <= Self.maximumPendingSegments, heldUTF16 <= Self.maximumPendingUTF16 else {
                throw MeetingPrivacyPublicationError.unsupportedLegacyPublication
            }
            if tokens >= Self.minimumPendingTokens { break }
        }
        let tail = Array(combinedOrdered.suffix(heldCount))
        let heldIDs = Set(tail.map(\.id))
        var safe = try await MeetingTranscriptPrivacyPolicy.redactedBatch(combined, using: redactor,
            contextPrefixes: currentTrack.map { [$0: context] } ?? [:],
            provisionalPreviewID: self.provisionalPreviewID, provisionalSegmentIDs: heldIDs)
        try Task.checkCancellation()
        // A checkpoint receives earlier complete segments, never any word from
        // this raw lexical tail. Its stable IDs later use normal store operations.
        safe.segments.removeAll { heldIDs.contains($0.id) }
        let published = combinedOrdered.filter { !heldIDs.contains($0.id) }
        prefix = Self.suffix(([context] + published.map(\.text)).filter { !$0.isEmpty }.joined(separator: " "))
        pending = tail.map { segment in var copy = segment; copy.originalText = nil; return copy }
        pendingIsComplete = combined.isComplete
        trackID = currentTrack; lastEnd = last.end
        lastSafePreview = safe.livePreview
        completed = true
        return safe
    }

    func finish() async throws -> MeetingPCMTranscriptBatch? {
        guard !isProcessing else { throw MeetingPrivacyPublicationError.unsupportedLegacyPublication }
        lastSafePreview = nil
        previousSpeechObservation = nil
        try Task.checkCancellation()
        guard !pending.isEmpty else { return nil }
        isProcessing = true
        defer { isProcessing = false }
        let batch = MeetingPCMTranscriptBatch(segments: pending, isComplete: pendingIsComplete)
        let safe = try await MeetingTranscriptPrivacyPolicy.redactedBatch(batch, using: redactor,
            contextPrefixes: trackID.map { [$0: prefix] } ?? [:])
        try Task.checkCancellation()
        self.pending = []; prefix = ""; trackID = nil; lastEnd = nil
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

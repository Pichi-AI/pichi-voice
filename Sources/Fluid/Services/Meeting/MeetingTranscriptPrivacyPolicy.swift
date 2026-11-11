import Foundation
import CryptoKit

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

/// Privacy transforms protect recognized speech and external identity evidence. User-entered
/// display metadata, source fingerprints and timestamps remain intact.
/// Exporting a legacy session returns a separate copy and never rewrites stored history.
nonisolated enum MeetingTranscriptPrivacyPolicy {
    static func redactedCopy(session: MeetingSession, using redactor: any TranscriptTextRedacting, preservingPublicationArtifacts: Bool = false) async throws -> MeetingSession {
        var copy = session
        for i in copy.speakers.indices {
            // Participant labels are explicit user metadata, not recognized speech. Keep
            // aliases intact through corrections, repeated publication and export. External
            // identity suggestions remain filtered independently below.
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
                              provisionalSegmentIDs: Set<UUID> = [],
                              atSpeechBoundary: Bool = false) async throws -> MeetingPCMTranscriptBatch {
        var copy = batch
        let projection = try await self.redactedSegments(copy.segments, using: redactor, contextPrefixes: contextPrefixes,
                                                        provisionalSegmentIDs: provisionalSegmentIDs,
                                                        atSpeechBoundary: atSpeechBoundary)
        copy.segments = projection.segments
        copy.livePreview = nil
        if let id = provisionalPreviewID, let text = projection.provisionalText, !text.isEmpty,
           let first = batch.segments.filter({ provisionalSegmentIDs.contains($0.id) }).min(by: { $0.start < $1.start }) {
            copy.livePreview = .init(id: id, text: text,
                start: first.nativeTiming?.start ?? first.start.seconds, end: projection.provisionalEnd)
            copy.livePreview?.containsPrivacyReplacement = projection.segments.contains {
                provisionalSegmentIDs.contains($0.id) && $0.containsPrivacyReplacement == true
            }
        }
        for i in copy.speakers.indices {
            // A resumed batch can carry existing aliases. Never run transcript redaction
            // over participant labels; mergingSpeakers also preserves the saved alias.
            copy.speakers[i].diarizationEmbedding = nil
            copy.speakers[i].diarizationEmbeddingObservationCount = nil
            copy.speakers[i].diarizationQuality = nil
            copy.speakers[i].identityCandidates = []
        }
        return copy
    }

    /// NER sees finalized turns and explicitly stable whole words only. An open turn's
    /// lexical edge remains behind capture progress until the same detector admits it.
    struct LiveProjection: Sendable {
        let snapshot: MeetingLiveTranscriptSnapshot
        let redactions: [UUID: [TranscriptRedactedSpan]]
        let admittedUTF16: [UUID: Int]
    }

    static func redactedLiveSnapshot(_ snapshot: MeetingLiveTranscriptSnapshot,
                                     using redactor: any TranscriptTextRedacting) async throws -> MeetingLiveTranscriptSnapshot {
        try await self.redactedLiveProjection(snapshot, using: redactor).snapshot
    }

    /// Redaction evidence survives a change of bounded context. A source owner may
    /// supply earlier spans only while the exact original text remains unchanged.
    static func redactedLiveProjection(_ snapshot: MeetingLiveTranscriptSnapshot,
                                      using redactor: any TranscriptTextRedacting,
                                      preserving redactions: [UUID: [TranscriptRedactedSpan]] = [:]) async throws -> LiveProjection {
        var copy = self.boundedLiveInput(snapshot)
        var retained: [UUID: [TranscriptRedactedSpan]] = [:]
        var admitted: [UUID: Int] = [:]
        for source: MeetingLiveSpeaker in [.you, .them] {
            let indices = copy.utterances.indices.filter { copy.utterances[$0].speaker == source }
                .sorted { a, b in copy.utterances[a].start == copy.utterances[b].start ? a < b : copy.utterances[a].start < copy.utterances[b].start }
            var fragments = indices.map { TextFragment(key: $0, text: copy.utterances[$0].text) }
            let partialKey = copy.utterances.count
            let partial = copy.partials[source]
            let partialMasks = try partial.map { try self.atomicMasks(in: $0.text, spans: redactions[$0.id] ?? []) } ?? []
            if let partial, var text = try self.stablePrefix(of: partial),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // A shorter stability claim cannot expose the beginning of an old mask.
                var limit = text.utf16.count
                for span in partialMasks where span.range.location < limit && NSMaxRange(span.range) > limit {
                    limit = span.range.location
                }
                if limit < text.utf16.count { text = (text as NSString).substring(to: limit) }
                if !text.isEmpty { fragments.append(.init(key: partialKey, text: text)) }
            }
            var prior: [Int: [TranscriptRedactedSpan]] = [:]
            for index in indices {
                prior[index] = try self.atomicMasks(in: copy.utterances[index].text, spans: redactions[copy.utterances[index].id] ?? [])
            }
            if let fragment = fragments.first(where: { $0.key == partialKey }) {
                prior[partialKey] = partialMasks.filter { NSMaxRange($0.range) <= fragment.text.utf16.count }
            }
            let projection = try await self.projectedTexts(fragments, prefix: "", preserving: prior,
                                                           atomicProtection: true, using: redactor)
            for index in indices {
                retained[copy.utterances[index].id] = projection.redactions[index]
                admitted[copy.utterances[index].id] = projection.provisionalUTF16[index]
            }
            if let partial {
                retained[partial.id] = self.mergedSpans(partialMasks + (projection.redactions[partialKey] ?? []))
                admitted[partial.id] = projection.provisionalUTF16[partialKey]
            }
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
                safePartial.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !wholeInputAdmitted { safePartial.end = nil }
                // Stable offsets refer to raw text and do not describe replacements.
                safePartial.stableUTF16Count = nil
                safePartial.containsPrivacyReplacement = projection.redactions[partialKey]?.isEmpty == false
                copy.partials[source] = safePartial
            } else { copy.partials.removeValue(forKey: source) }
        }
        copy.utterances.removeAll { $0.text.isEmpty }
        return .init(snapshot: copy, redactions: retained, admittedUTF16: admitted)
    }

    private static func stablePrefix(of partial: MeetingLivePartial) throws -> String? {
        guard let count = partial.stableUTF16Count else { return nil }
        return try self.stablePrefix(in: partial.text, utf16Count: count)
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

    /// Each privacy inference page contains at most 100 completed rows. Bound
    /// queued raw input while the publisher assembles the full protected history.
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
                                         provisionalSegmentIDs: Set<UUID> = [],
                                         atSpeechBoundary: Bool = false) async throws -> SegmentProjection {
        var copy = segments
        let groups = Dictionary(grouping: segments.indices) { segments[$0].sourceTrackID }
        var provisionalText: String?
        var provisionalEnd: TimeInterval?
        for (trackID, indices) in groups {
            let ordered = indices.sorted { a, b in
                segments[a].start == segments[b].start ? a < b : segments[a].start < segments[b].start
            }
            let fragments = ordered.map { TextFragment(key: $0, text: segments[$0].text) }
            let projected = try await self.projectedTexts(fragments, prefix: contextPrefixes[trackID] ?? "",
                atSpeechBoundary: atSpeechBoundary, using: redactor)
            for index in ordered {
                copy[index].text = projected.canonical[index] ?? segments[index].text
                copy[index].originalText = nil
                if projected.redactions[index]?.isEmpty == false {
                    copy[index].containsPrivacyReplacement = true
                }
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
                }.map { segments[$0].nativeTiming?.end ?? segments[$0].end.seconds }.max()
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
        let redactions: [Int: [TranscriptRedactedSpan]]
        let provisionalUTF16: [Int: Int]
    }

    private static func projectedTexts(_ fragments: [TextFragment], prefix: String, separator: String = " ",
                                       preserving prior: [Int: [TranscriptRedactedSpan]] = [:],
                                       atomicProtection: Bool = false,
                                       atSpeechBoundary: Bool = false,
                                       using redactor: any TranscriptTextRedacting) async throws -> TextProjection {
        guard prefix.utf16.count <= MeetingTranscriptPrivacyContext.maximumContextUTF16 else {
            throw MeetingPrivacyPublicationError.unsupportedLegacyPublication
        }
        var rangesByFragment = prior
        var provisional: [Int: String]?
        var provisionalCompleteKeys: Set<Int> = []
        var provisionalUTF16: [Int: Int] = [:]
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
            let output = try await atSpeechBoundary
                ? redactor.redactSpeechBoundaryWithSpans(text) : redactor.redactWithSpans(text)
            try Task.checkCancellation()
            try self.validate(output, for: text)
            let evaluatedSpans = atomicProtection ? try self.atomicMasks(in: text, spans: output.spans) : output.spans
            // Strict held text fits one admission window. A multi-window transformation has
            // no single adapter-approved prefix, so canonical projection remains available
            // but provisional display fails closed rather than splicing separate approvals.
            if cursor == 0, end == fragments.count, let limit = output.provisionalSafeUTF16 {
                var approved: [Int: String] = [:]
                let source = text as NSString
                for (key, range) in ranges where range.location < limit {
                    let evaluated = evaluatedSpans.compactMap { span -> TranscriptRedactedSpan? in
                        let intersection = NSIntersectionRange(span.range, range)
                        guard intersection.length > 0 else { return nil }
                        return .init(range: NSRange(location: intersection.location - range.location, length: intersection.length),
                                     replacement: span.replacement)
                    }
                    let masks = self.mergedSpans((prior[key] ?? []) + evaluated)
                    var length = min(NSMaxRange(range), limit) - range.location
                    for span in masks where span.range.location < length && NSMaxRange(span.range) > length {
                        length = span.range.location
                    }
                    guard length > 0 else { continue }
                    let admitted = NSRange(location: range.location, length: length)
                    approved[key] = try self.replacing(source.substring(with: admitted),
                        spans: masks.filter { NSMaxRange($0.range) <= length })
                    provisionalUTF16[key] = length
                    if length == range.length { provisionalCompleteKeys.insert(key) }
                }
                provisional = approved
            }
            for (key, range) in ranges {
                for span in evaluatedSpans {
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
        rangesByFragment = rangesByFragment.mapValues(self.mergedSpans)
        var result: [Int: String] = [:]
        for fragment in fragments {
            if let spans = rangesByFragment[fragment.key], !spans.isEmpty {
                result[fragment.key] = try self.replacing(fragment.text, spans: spans)
            }
        }
        return .init(canonical: result, provisional: provisional, provisionalCompleteKeys: provisionalCompleteKeys,
                     redactions: rangesByFragment, provisionalUTF16: provisionalUTF16)
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

    /// Retained protection follows an atomic whitespace-delimited token, including
    /// punctuation and Unicode suffixes. A revised hypothesis cannot reveal a new
    /// suffix merely because an earlier evaluation ended the same field sooner.
    fileprivate static func atomicMasks(in text: String, spans: [TranscriptRedactedSpan]) throws -> [TranscriptRedactedSpan] {
        let source = text as NSString
        let expanded = try spans.map { span -> TranscriptRedactedSpan in
            guard span.range.location >= 0, span.range.length > 0, NSMaxRange(span.range) <= source.length else {
                throw MeetingPrivacyPublicationError.unsupportedLegacyPublication
            }
            var end = NSMaxRange(span.range)
            guard end == source.length || !(0xDC00...0xDFFF).contains(source.character(at: end)) else {
                throw MeetingPrivacyPublicationError.unsupportedLegacyPublication
            }
            // UTF16 whitespace lies in the BMP. Surrogate pairs stay inside the
            // protected token; no suffix String or full remaining-text copy is needed.
            while end < source.length {
                if let scalar = UnicodeScalar(source.character(at: end)), scalar.properties.isWhitespace { break }
                end += 1
            }
            return .init(range: NSRange(location: span.range.location,
                length: end - span.range.location), replacement: span.replacement)
        }
        return self.mergedSpans(expanded)
    }

    fileprivate static func mergedSpans(_ spans: [TranscriptRedactedSpan]) -> [TranscriptRedactedSpan] {
        let ordered = spans.sorted { $0.range.location < $1.range.location }
        var merged: [TranscriptRedactedSpan] = []
        for span in ordered {
            if let previous = merged.last, NSIntersectionRange(previous.range, span.range).length > 0 {
                merged[merged.count - 1] = .init(range: NSUnionRange(previous.range, span.range), replacement: previous.replacement)
            } else { merged.append(span) }
        }
        return merged
    }

    fileprivate static func replacing(_ input: String, spans: [TranscriptRedactedSpan]) throws -> String {
        let merged = self.mergedSpans(spans)
        for span in merged {
            guard span.range.location >= 0, span.range.length > 0,
                  span.range.location <= input.utf16.count, span.range.length <= input.utf16.count - span.range.location,
                  !span.replacement.isEmpty else { throw MeetingPrivacyPublicationError.unsupportedLegacyPublication }
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
                                 speaker: unit.speaker, analysisSpanIDs: unit.analysisSpanIDs, confidence: unit.confidence,
                                 wordTimingProvenance: unit.wordTimingProvenance)
        }
        return MeetingFinalTranscriptEvidence(backendID: evidence.backendID, attemptID: evidence.attemptID,
                                               units: units, speakerActivity: evidence.speakerActivity,
                                               voiceProfiles: evidence.voiceProfiles,
                                               speakerSlotsContinueAcrossEpochs: evidence.speakerSlotsContinueAcrossEpochs)
    }
}

/// One joined privacy owner. Raw input stays in its existing recognition owner;
/// only one bounded page is retained across native inference. Previously approved
/// history and content digests let delayed/coalesced updates backfill every row.
@MainActor
final class MeetingLivePrivacyPublication {
    private static let pageRows = 100
    private static let contextRows = 32
    private struct Pending {
        let snapshot: MeetingLiveTranscriptSnapshot
        let latestSnapshot: (@MainActor () -> MeetingLiveTranscriptSnapshot?)?
        let generation: UUID
        let redactor: any TranscriptTextRedacting
        let publish: @MainActor (MeetingLiveTranscriptSnapshot, UUID) -> Void
        let failed: @MainActor (UUID) -> Void
    }
    private nonisolated struct SourceVersion: Equatable, Sendable {
        let digest: Data
        let start: Double
        let end: Double
        let speaker: MeetingLiveSpeaker
        let incomplete: Bool
        let participant: MeetingSpeakerPresentation?
        init(_ row: MeetingLiveUtterance) {
            digest = Data(SHA256.hash(data: Data(row.text.utf8)))
            start = row.start; end = row.end; speaker = row.speaker
            incomplete = row.hasIncompleteTextCoverage; participant = row.participant
        }
    }
    private nonisolated struct MaskProof: Sendable {
        let utf16Count: Int
        let digest: Data
        init?(text: String, spans: [TranscriptRedactedSpan]) {
            let source = text as NSString
            guard let end = spans.map({ NSMaxRange($0.range) }).max(), end > 0, end <= source.length,
                  end == source.length || !(0xDC00...0xDFFF).contains(source.character(at: end)) else { return nil }
            utf16Count = end; digest = Data(SHA256.hash(data: Data(source.substring(to: end).utf8)))
        }
        func matches(_ text: String) -> Bool {
            let source = text as NSString
            guard utf16Count <= source.length,
                  utf16Count == source.length || !(0xDC00...0xDFFF).contains(source.character(at: utf16Count)) else { return false }
            return Data(SHA256.hash(data: Data(source.substring(to: utf16Count).utf8))) == digest
        }
    }
    private nonisolated struct Source: Sendable {
        let order: [UUID]
        let versions: [UUID: SourceVersion]
        let revision: UInt64
        let verifiedMasks: Set<UUID>
        let verifiedProposedMasks: Set<UUID>
    }
    private nonisolated struct Page: Sendable {
        let snapshot: MeetingLiveTranscriptSnapshot
        let source: Source
        let isTail: Bool
        let contextOnlyIDs: Set<UUID>
    }
    private var pending: Pending?
    private var worker: Task<Void, Never>?
    private var workerID: UUID?
    private var generation: UUID?
    private var submittedRevision: UInt64 = 0
    private var publishedRevision: UInt64 = 0
    private var lastTailRevision: UInt64 = 0
    private var prepared = false
    private var privacyIdentity: String?
    private var versions: [UUID: SourceVersion] = [:]
    private var sourceOrder: [UUID] = []
    private var visited: Set<UUID> = []
    private var contextPending: Set<UUID> = []
    private var approved: [UUID: MeetingLiveUtterance] = [:]
    private var retainedMasks: [UUID: [TranscriptRedactedSpan]] = [:]
    private var admittedUTF16: [UUID: Int] = [:]
    private var maskProofs: [UUID: MaskProof] = [:]
    // When a known sensitive unit is rewritten before its protected prefix can be
    // verified, its field position is ambiguous. Preserve other units and withhold
    // or redact this one rather than treating the disappeared cue as permission.
    private var conservativeRewrites: [UUID: String] = [:]

    func submit(_ snapshot: MeetingLiveTranscriptSnapshot, generation: UUID,
                using redactor: any TranscriptTextRedacting,
                latestSnapshot: (@MainActor () -> MeetingLiveTranscriptSnapshot?)? = nil,
                publish: @escaping @MainActor (MeetingLiveTranscriptSnapshot, UUID) -> Void,
                failed: @escaping @MainActor (UUID) -> Void) {
        guard (self.generation == nil && worker == nil) || self.generation == generation,
              snapshot.revision > submittedRevision else { return }
        self.generation = generation
        submittedRevision = snapshot.revision
        // Compatibility callers without a source owner retain the existing bounded
        // one-snapshot behavior. Production supplies the locked source getter above.
        self.pending = Pending(snapshot: MeetingTranscriptPrivacyPolicy.boundedLiveInput(snapshot),
            latestSnapshot: latestSnapshot, generation: generation, redactor: redactor, publish: publish, failed: failed)
        guard worker == nil else { return }
        let id = UUID()
        workerID = id
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.workerID == id { self.worker = nil; self.workerID = nil } }
            var current: Pending?
            while self.workerID == id {
                if let next = self.pending { current = next; self.pending = nil }
                guard let item = current else { return }
                do {
                    try Task.checkCancellation()
                    guard self.generation == item.generation else { throw CancellationError() }
                    let selected: Page?
                    do {
                        guard let input = item.latestSnapshot?() ?? (item.latestSnapshot == nil ? item.snapshot : nil) else { return }
                        selected = try await self.page(from: input, using: item.redactor)
                    }
                    guard let page = selected else { current = nil; continue }
                    let hasStablePartial = try page.snapshot.partials.values.contains { partial in
                        guard let count = partial.stableUTF16Count else { return false }
                        return !(try MeetingTranscriptPrivacyPolicy.stablePrefix(in: partial.text, utf16Count: count))
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                    let hasRecognizedText = hasStablePartial || page.snapshot.utterances.contains {
                        !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                    let safe: MeetingLiveTranscriptSnapshot
                    let masks: [UUID: [TranscriptRedactedSpan]]
                    let admitted: [UUID: Int]
                    if hasRecognizedText {
                        // Empty availability updates can arrive before capture.start.
                        // Native privacy readiness is owned by the first real text page.
                        if !self.prepared {
                            let identity = item.redactor.checkpointIdentity
                            try await item.redactor.prepareForMeeting()
                            try Task.checkCancellation()
                            guard identity == item.redactor.checkpointIdentity else {
                                throw MeetingPrivacyPublicationError.unsupportedLegacyPublication
                            }
                            self.privacyIdentity = identity; self.prepared = true
                        }
                        guard self.privacyIdentity == item.redactor.checkpointIdentity else {
                            throw MeetingPrivacyPublicationError.unsupportedLegacyPublication
                        }
                        // `page` owns at most 100 raw rows. No full source crosses NER.
                        var prior: [UUID: [TranscriptRedactedSpan]] = [:]
                        for row in page.snapshot.utterances {
                            if let replacement = self.conservativeRewrites[row.id], !row.text.isEmpty {
                                prior[row.id] = [.init(range: NSRange(location: 0, length: row.text.utf16.count), replacement: replacement)]
                            } else { prior[row.id] = self.retainedMasks[row.id] }
                        }
                        for partial in page.snapshot.partials.values {
                            if let replacement = self.conservativeRewrites[partial.id], !partial.text.isEmpty {
                                prior[partial.id] = [.init(range: NSRange(location: 0, length: partial.text.utf16.count), replacement: replacement)]
                            } else { prior[partial.id] = self.retainedMasks[partial.id] }
                        }
                        let projection = try await MeetingTranscriptPrivacyPolicy.redactedLiveProjection(page.snapshot,
                            using: item.redactor, preserving: prior)
                        safe = projection.snapshot; masks = projection.redactions; admitted = projection.admittedUTF16
                    } else {
                        var availability = page.snapshot
                        availability.utterances = []; availability.partials = [:]
                        safe = availability; masks = [:]; admitted = [:]
                    }
                    try Task.checkCancellation()
                    guard self.workerID == id, self.generation == item.generation else { return }
                    guard !self.prepared || self.privacyIdentity == item.redactor.checkpointIdentity else {
                        throw MeetingPrivacyPublicationError.unsupportedLegacyPublication
                    }
                    var rawTexts = Dictionary(page.snapshot.utterances.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
                    for partial in page.snapshot.partials.values where rawTexts[partial.id] == nil { rawTexts[partial.id] = partial.text }
                    var proposedMasks: [UUID: [TranscriptRedactedSpan]] = [:]
                    var proposedProofs: [UUID: MaskProof] = [:]
                    for (unitID, spans) in masks {
                        guard let text = rawTexts[unitID] else { continue }
                        let union = try MeetingTranscriptPrivacyPolicy.atomicMasks(in: text,
                            spans: MeetingTranscriptPrivacyPolicy.mergedSpans((self.retainedMasks[unitID] ?? []) + spans))
                        if !union.isEmpty {
                            guard let proof = MaskProof(text: text, spans: union) else {
                                throw MeetingPrivacyPublicationError.unsupportedLegacyPublication
                            }
                            proposedMasks[unitID] = union; proposedProofs[unitID] = proof
                        }
                    }
                    let latest: Source
                    if let getter = item.latestSnapshot {
                        guard let snapshot = getter() else { return }
                        latest = try await Self.source(from: snapshot, maskProofs: self.maskProofs,
                                                       proposedProofs: proposedProofs)
                    } else {
                        latest = try await Self.source(from: page.snapshot, maskProofs: self.maskProofs,
                                                       proposedProofs: proposedProofs)
                    }
                    try Task.checkCancellation()
                    guard self.workerID == id, self.generation == item.generation else { return }
                    self.reconcile(latest)
                    // Learned redaction evidence is useful even if the visible page is
                    // stale. Retain it only when its original masked prefix still matches
                    // the current source; do this before rejecting stale publication.
                    for (id, spans) in proposedMasks where latest.versions[id] != nil {
                        if latest.verifiedProposedMasks.contains(id) {
                            self.retainedMasks[id] = spans; self.maskProofs[id] = proposedProofs[id]
                        } else if let replacement = spans.first?.replacement {
                            self.conservativeRewrites[id] = replacement
                        }
                    }
                    // A changed or withdrawn raw page cannot publish an older version.
                    guard page.snapshot.utterances.allSatisfy({ latest.versions[$0.id] == page.source.versions[$0.id] }) else { continue }
                    let pageIDs = Set(page.snapshot.utterances.map(\.id))
                    for id in pageIDs where !page.contextOnlyIDs.contains(id) {
                        self.approved[id] = nil; self.admittedUTF16[id] = nil
                    }
                    for row in safe.utterances {
                        if !page.contextOnlyIDs.contains(row.id) {
                            self.approved[row.id] = row
                            self.admittedUTF16[row.id] = admitted[row.id]
                        }
                    }
                    for raw in page.snapshot.utterances where page.contextOnlyIDs.contains(raw.id) {
                        guard var previous = self.approved[raw.id], var limit = self.admittedUTF16[raw.id] else { continue }
                        // Left-only context may strengthen old masks, never approve more
                        // raw characters than its prior independently admitted prefix.
                        let union = self.retainedMasks[raw.id] ?? []
                        for span in union where span.range.location < limit && NSMaxRange(span.range) > limit {
                            limit = span.range.location
                        }
                        guard limit > 0 else {
                            self.approved[raw.id] = nil; self.admittedUTF16[raw.id] = nil; continue
                        }
                        previous.text = try MeetingTranscriptPrivacyPolicy.replacing((raw.text as NSString).substring(to: limit),
                            spans: union.filter { NSMaxRange($0.range) <= limit })
                        previous.hasIncompleteTextCoverage = limit < raw.text.utf16.count
                        self.approved[raw.id] = previous; self.admittedUTF16[raw.id] = limit
                    }
                    self.visited.formUnion(pageIDs)
                    if page.isTail {
                        self.contextPending.removeAll()
                        self.lastTailRevision = page.source.revision
                    } else {
                        // The page's lexical edge can be withheld even for a previously
                        // visited row. Force its raw context into the following page.
                        self.contextPending = Set(page.snapshot.utterances.suffix(Self.contextRows).map(\.id))
                        self.visited.subtract(self.contextPending)
                    }
                    var publication = safe
                    publication.utterances = latest.order.compactMap { self.approved[$0] }
                    publication.partials = publication.partials.filter {
                        latest.versions[$0.value.id]?.digest == page.source.versions[$0.value.id]?.digest
                    }
                    // Internal page progress is independent of raw recognition revisions.
                    self.publishedRevision = max(self.publishedRevision + 1, page.source.revision)
                    publication.revision = self.publishedRevision
                    item.publish(publication, item.generation)
                    if item.latestSnapshot == nil { current = nil }
                } catch is CancellationError { return }
                catch {
                    guard self.workerID == id, self.generation == item.generation, !Task.isCancelled else { return }
                    self.pending = nil; item.failed(item.generation); return
                }
            }
        }
    }

    private static func source(from snapshot: MeetingLiveTranscriptSnapshot,
                               maskProofs: [UUID: MaskProof], proposedProofs: [UUID: MaskProof] = [:]) async throws -> Source {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard snapshot.utterances.allSatisfy({ $0.start.isFinite && $0.end.isFinite
                && $0.start >= 0 && $0.end >= $0.start }) else {
                throw MeetingPrivacyPublicationError.unsupportedLegacyPublication
            }
            var values = snapshot.utterances.map { ($0.id, SourceVersion($0)) }
            let order = values.map(\.0)
            guard Set(order).count == values.count else {
                throw MeetingPrivacyPublicationError.unsupportedLegacyPublication
            }
            let closedIDs = Set(order)
            for (speaker, partial) in snapshot.partials where !closedIDs.contains(partial.id) {
                values.append((partial.id, SourceVersion(.init(id: partial.id, speaker: speaker,
                    text: partial.text, start: partial.start, end: partial.end ?? partial.start))))
            }
            guard Set(values.map(\.0)).count == values.count else {
                throw MeetingPrivacyPublicationError.unsupportedLegacyPublication
            }
            var verifiedMasks: Set<UUID> = [], verifiedProposed: Set<UUID> = []
            for row in snapshot.utterances {
                if maskProofs[row.id]?.matches(row.text) == true { verifiedMasks.insert(row.id) }
                if proposedProofs[row.id]?.matches(row.text) == true { verifiedProposed.insert(row.id) }
            }
            for partial in snapshot.partials.values {
                if maskProofs[partial.id]?.matches(partial.text) == true { verifiedMasks.insert(partial.id) }
                if proposedProofs[partial.id]?.matches(partial.text) == true { verifiedProposed.insert(partial.id) }
            }
            let result = Source(order: order, versions: Dictionary(uniqueKeysWithValues: values),
                revision: snapshot.revision, verifiedMasks: verifiedMasks, verifiedProposedMasks: verifiedProposed)
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler {
            let value = try await task.value; try Task.checkCancellation(); return value
        } onCancel: { task.cancel() }
    }

    private func reconcile(_ source: Source) {
        let changed = Set(self.versions.keys).filter { self.versions[$0] != source.versions[$0] }
        var invalidated = Set(changed)
        if !changed.isEmpty {
            // A source edit can change an entity spanning neighboring fragments.
            // Hide and revisit that bounded context before another page publishes.
            for order in [self.sourceOrder, source.order] {
                let positions = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
                for id in changed {
                    guard let index = positions[id] else { continue }
                    let lower = max(0, index - Self.contextRows)
                    let upper = min(order.count, index + Self.contextRows + 1)
                    invalidated.formUnion(order[lower..<upper])
                }
            }
        }
        self.visited.subtract(invalidated)
        self.contextPending.subtract(invalidated)
        for id in invalidated { self.approved[id] = nil; self.admittedUTF16[id] = nil }
        for id in changed where self.versions[id]?.digest != source.versions[id]?.digest && !source.verifiedMasks.contains(id) {
            if source.versions[id] == nil {
                self.conservativeRewrites[id] = nil
            } else if let replacement = self.retainedMasks[id]?.first?.replacement {
                self.conservativeRewrites[id] = replacement
            }
            self.retainedMasks[id] = nil; self.maskProofs[id] = nil
        }
        self.versions = source.versions
        self.sourceOrder = source.order
    }

    private func page(from input: MeetingLiveTranscriptSnapshot, using redactor: any TranscriptTextRedacting) async throws -> Page? {
        let source = try await Self.source(from: input, maskProofs: self.maskProofs)
        self.reconcile(source)
        let first = source.order.firstIndex { !self.visited.contains($0) }
        guard first != nil || source.revision > self.lastTailRevision else { return nil }
        // The carried right edge also needs its own left context. Always reserve
        // that context inside the same 100-row budget instead of approving its first
        // rows with a newly truncated preceding cue.
        var start = first.map { max(0, $0 - Self.contextRows) }
            ?? max(0, input.utterances.count - Self.pageRows)
        var end = min(input.utterances.count, start + Self.pageRows)
        if try redactor.durablePublicationLimit(in: "") != nil {
            func sealed(_ row: MeetingLiveUtterance) throws -> Bool {
                let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return try redactor.durablePublicationLimit(in: text) == text.utf16.count
            }
            // A new page cannot interpret a same-speaker suffix without the
            // beginning of its required unit. Backtrack inside the existing cap.
            var changed = true
            while changed {
                changed = false
                for speaker: MeetingLiveSpeaker in [.you, .them] {
                    if let previous = input.utterances[..<start].lastIndex(where: { $0.speaker == speaker }),
                       try !sealed(input.utterances[previous]) {
                        start = previous; changed = true
                    }
                }
                guard (first ?? start) - start < Self.pageRows else {
                    throw MeetingPrivacyPublicationError.unsupportedLegacyPublication
                }
            }
            end = min(input.utterances.count, start + Self.pageRows)
            if end < input.utterances.count {
                // A truncated page ends only after complete units for both
                // speakers. Otherwise a later cue could change a published prefix.
                while end > start {
                    var safe = true
                    for speaker: MeetingLiveSpeaker in [.you, .them] {
                        if let last = input.utterances[start..<end].lastIndex(where: { $0.speaker == speaker }),
                           try !sealed(input.utterances[last]) {
                            end = last; safe = false; break
                        }
                    }
                    if safe { break }
                }
                let firstFresh = source.order.firstIndex {
                    !self.visited.contains($0) && !self.contextPending.contains($0)
                } ?? (first ?? start)
                guard end > firstFresh else { throw MeetingPrivacyPublicationError.unsupportedLegacyPublication }
            }
        }
        let contextOnlyIDs = Set(source.order[start..<(first ?? start)])
        var snapshot = input
        snapshot.utterances = Array(input.utterances[start..<end])
        let isTail = end == input.utterances.count
        if !isTail { snapshot.partials = [:] }
        return Page(snapshot: snapshot, source: source, isTail: isTail, contextOnlyIDs: contextOnlyIDs)
    }

    /// Join the current owner without cancelling its already queued source revision.
    /// Recognition may withhold a lexical tail, so work completion is independent
    /// of whether a particular last word has become publishable.
    func waitForCurrentWork() async { await self.worker?.value }

    /// Keep ownership until even a noncooperative native preparation/inference
    /// returns. A new generation cannot inherit its history, model or publication.
    func stop() async {
        pending = nil; generation = nil; submittedRevision = 0
        let task = worker; let id = workerID
        task?.cancel(); await task?.value
        if workerID == id { worker = nil; workerID = nil }
        publishedRevision = 0; lastTailRevision = 0; prepared = false; privacyIdentity = nil
        versions.removeAll(); sourceOrder.removeAll(); visited.removeAll(); contextPending.removeAll(); approved.removeAll()
        retainedMasks.removeAll(); admittedUTF16.removeAll(); maskProofs.removeAll(); conservativeRewrites.removeAll()
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
    private var speakerNameFormat: String?
    private var isProcessing = false
    private let provisionalPreviewID = UUID()
    private var lastSafePreview: MeetingLivePartial?
    /// The sealed lexical tail has its own approved display. A new, empty ASR
    /// window may replace hypothesis stability, but cannot erase this owned tail.
    private(set) var pendingPreview: MeetingLivePartial?
    private var lastSafePreviewIdentity: MeetingPCMTranscriptBatch.SpeechObservationIdentity?
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

    /// Metadata only. Streaming attribution must retain acoustic evidence for this lexical
    /// tail and must not advance its safe cursor past words still awaiting privacy context.
    var earliestHeldWordStart: TimeInterval? {
        self.pending.map { $0.nativeTiming?.start ?? $0.start.seconds }.min()
    }

    /// Speech can be displayed before expensive attribution, but cannot enter the durable
    /// tail or checkpoint until that window completes. Use the same frozen redactor/guards.
    func previewSpeech(_ batch: MeetingPCMTranscriptBatch,
                       preservingPendingPreview: Bool = false) async throws -> MeetingLivePartial? {
        guard !isProcessing else { throw MeetingPrivacyPublicationError.unsupportedLegacyPublication }
        isProcessing = true
        var completed = false
        var diagnosticRawUTF16 = 0
        var diagnosticStableUTF16 = 0
        var diagnosticPreviewUTF16 = 0
        defer {
            if !completed { lastSafePreview = nil; lastSafePreviewIdentity = nil; previousSpeechObservation = nil }
            isProcessing = false
            // Scalar publication evidence only. Raw hypotheses, detected values,
            // names and model outputs never enter the support logger.
            speechAdmissionDiagnosticFields = "rawUTF16=\(diagnosticRawUTF16) stableUTF16=\(diagnosticStableUTF16) previewUTF16=\(diagnosticPreviewUTF16) pendingSegments=\(pending.count) sealed=\(batch.speechObservationIsFinal) completed=\(completed)"
        }
        try Task.checkCancellation()
        if self.speakerNameFormat == nil { self.speakerNameFormat = batch.speakerNameFormat }
        let tracks = Set(batch.segments.map(\.sourceTrackID))
        guard tracks.count <= 1 else { throw MeetingPrivacyPublicationError.unsupportedLegacyPublication }
        let ordered = batch.segments.sorted { $0.start < $1.start }
        let segmentTrack = ordered.first?.sourceTrackID
        let declaredTrack = batch.sourceTrack?.id
        guard segmentTrack == nil || declaredTrack == nil || segmentTrack == declaredTrack else {
            throw MeetingPrivacyPublicationError.unsupportedLegacyPublication
        }
        // An empty native observation has no segment or fabricated track record.
        // Its typed physical-window provenance still identifies the source clock.
        let currentTrack = segmentTrack ?? declaredTrack ?? batch.speechObservationIdentity?.epochID.trackID
        let preservedPreview = preservingPendingPreview && (currentTrack == nil || currentTrack == trackID)
            ? pendingPreview : nil
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
            let preview: MeetingLivePartial?
            if let identity = batch.speechObservationIdentity {
                if previousSpeechObservation?.identity != identity { previousSpeechObservation = nil }
                preview = lastSafePreviewIdentity == identity ? lastSafePreview : nil
            } else { preview = currentTrack == nil || continues ? lastSafePreview : nil }
            let visible = preview ?? preservedPreview
            diagnosticPreviewUTF16 = visible?.text.utf16.count ?? 0
            return visible
        }
        var combined = batch
        combined.speakerNameFormat = self.speakerNameFormat
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
            let visible = preview ?? preservedPreview
            diagnosticPreviewUTF16 = visible?.text.utf16.count ?? 0
            return visible
        }
        _ = try MeetingTranscriptPrivacyPolicy.stablePrefix(in: rawText, utf16Count: stableCount)
        var admitted: [MeetingTranscriptSegment] = []
        var position = 0
        var clippedAudioCoverage = false
        var completeSourceEnd = pending.filter { !$0.text.isEmpty }.map { $0.nativeTiming?.end ?? $0.end.seconds }.max()
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
                    if admittedCount == count {
                        completeSourceEnd = max(completeSourceEnd ?? 0, segment.nativeTiming?.end ?? segment.end.seconds)
                    }
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
        // A complete admitted text fragment can still be a coarse window-wide
        // placeholder. Until that physical window seals, its sampled end is not
        // evidence that the displayed words cover newly captured audio.
        if !batch.permitsSpeechPreviewCoverage { preview?.end = nil }
        let visible = preview ?? preservedPreview
        diagnosticPreviewUTF16 = visible?.text.utf16.count ?? 0
        lastSafePreview = preview
        lastSafePreviewIdentity = preview == nil ? nil : batch.speechObservationIdentity
        completed = true
        return visible
    }

    func redact(_ batch: MeetingPCMTranscriptBatch) async throws -> MeetingPCMTranscriptBatch {
        guard !isProcessing else { throw MeetingPrivacyPublicationError.unsupportedLegacyPublication }
        isProcessing = true
        var completed = false
        defer { if !completed { lastSafePreview = nil; lastSafePreviewIdentity = nil }; isProcessing = false }
        try Task.checkCancellation()
        if self.speakerNameFormat == nil { self.speakerNameFormat = batch.speakerNameFormat }
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
            safe.speakerNameFormat = self.speakerNameFormat
            try Task.checkCancellation()
            // An empty forward window has no new hypothesis to invalidate the
            // already approved display. No-source silence belongs to this owned
            // attempt; an explicitly different source never inherits its preview.
            if !pending.isEmpty, currentTrack == nil || continues { safe.livePreview = lastSafePreview }
            if safe.livePreview != lastSafePreview { lastSafePreviewIdentity = nil }
            lastSafePreview = safe.livePreview
            completed = true
            return safe
        }
        var combined = batch
        combined.speakerNameFormat = self.speakerNameFormat
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
        // A contextual detector may need a complete unit, even when its beginning
        // is older than the ordinary lexical tail. Snap durable publication back
        // to its approved boundary, retaining original segment identities.
        let firstHeld = combinedOrdered.count - heldCount
        let candidatePrefix = combinedOrdered.prefix(firstHeld).map(\.text).joined(separator: " ")
        if let limit = try redactor.durablePublicationLimit(in: candidatePrefix) {
            guard limit >= 0, limit <= candidatePrefix.utf16.count,
                  Range(NSRange(location: 0, length: limit), in: candidatePrefix) != nil else {
                throw MeetingPrivacyPublicationError.unsupportedLegacyPublication
            }
            var offset = 0
            var publicationCount = 0
            for segment in combinedOrdered.prefix(firstHeld) {
                let end = offset + segment.text.utf16.count
                if end <= limit { publicationCount += 1 }
                offset = end + 1
            }
            heldCount = combinedOrdered.count - publicationCount
            let held = combinedOrdered.suffix(heldCount)
            guard heldCount <= Self.maximumPendingSegments,
                  held.reduce(0, { $0 + $1.text.utf16.count + 1 }) <= Self.maximumPendingUTF16 else {
                throw MeetingPrivacyPublicationError.unsupportedLegacyPublication
            }
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
        if safe.livePreview != lastSafePreview { lastSafePreviewIdentity = nil }
        lastSafePreview = safe.livePreview
        pendingPreview = safe.livePreview
        completed = true
        return safe
    }

    /// A complete sealed empty ASR window can close already recognized speech without
    /// ending the meeting. The adapter applies canonical entity redaction to that text.
    /// Preserve bounded raw context so a number/name continued later is still evaluated.
    func admitSpeechBoundary() async throws -> MeetingPCMTranscriptBatch? {
        guard redactor.supportsSpeechBoundaryAdmission else { return nil }
        guard !isProcessing else { throw MeetingPrivacyPublicationError.unsupportedLegacyPublication }
        try Task.checkCancellation()
        guard !pending.isEmpty else { return nil }
        isProcessing = true
        defer { isProcessing = false }
        let source = pending
        var batch = MeetingPCMTranscriptBatch(segments: source, isComplete: pendingIsComplete)
        batch.speakerNameFormat = self.speakerNameFormat
        let safe = try await MeetingTranscriptPrivacyPolicy.redactedBatch(batch, using: redactor,
            contextPrefixes: trackID.map { [$0: prefix] } ?? [:], atSpeechBoundary: true)
        try Task.checkCancellation()
        prefix = Self.suffix(([prefix] + source.map(\.text)).filter { !$0.isEmpty }.joined(separator: " "))
        pending.removeAll(keepingCapacity: false)
        pendingPreview = nil; lastSafePreview = nil; lastSafePreviewIdentity = nil
        previousSpeechObservation = nil
        return safe
    }

    func finish() async throws -> MeetingPCMTranscriptBatch? {
        guard !isProcessing else { throw MeetingPrivacyPublicationError.unsupportedLegacyPublication }
        lastSafePreview = nil
        pendingPreview = nil
        lastSafePreviewIdentity = nil
        previousSpeechObservation = nil
        try Task.checkCancellation()
        guard !pending.isEmpty else { return nil }
        isProcessing = true
        defer { isProcessing = false }
        var batch = MeetingPCMTranscriptBatch(segments: pending, isComplete: pendingIsComplete)
        batch.speakerNameFormat = self.speakerNameFormat
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

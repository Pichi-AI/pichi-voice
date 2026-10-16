import CryptoKit
import Foundation

nonisolated enum MeetingSpeakerActivityCoverage {
    static func isOutside(
        _ unit: MeetingFinalTextUnit,
        activityByEpoch: [MeetingAnalysisEpochID: [MeetingBackendSpeakerActivity]],
        tolerance: TimeInterval = MeetingAnalysisManifestSchema.mappingToleranceSeconds
    ) -> Bool {
        guard let activity = activityByEpoch[unit.analysisEpochID], !activity.isEmpty else {
            return false
        }
        return !activity.contains {
            min($0.end, unit.analysisEnd) - max($0.start, unit.analysisStart) > tolerance
        }
    }
}

// Stage C2b1 of `MEETING_TRANSCRIPTION_IMPLEMENTATION_PLAN.md` (§4) and
// `MEETING_TRANSCRIPTION_BACKEND_ARCHITECTURE_PLAN.md` §4.6: the pure assembler every backend
// shares. It reads a frozen plan, a validated analysis manifest, final evidence, per-span
// coverage receipts and per-unit echo verdicts, and produces product speakers, transcript
// segments, the durable result sidecar, skipped chunks and product coverage gaps.
//
// It does no I/O, runs no aligner or diarizer, and applies only confirmed owner identity tokens. Every input text unit
// leaves with exactly one disposition, in the plan's precedence order: timing/provenance
// quarantine, inadmissible capture era, echo suppression, outside speaker activity,
// timing/overlap ambiguity, emitted. Every admissible manifest span must be tiled exactly once by
// receipts — a missing, duplicate, unknown or out-of-bounds receipt is a hard typed error, and
// text never implies coverage.

/// Real, per-unit cross-track echo evidence, supplied by the pipeline's existing signal/text
/// analysis. A verdict is a measured fact about one microphone unit, never a guess: in an online
/// call a microphone unit without one fails assembly.
nonisolated enum MeetingUnitEchoVerdict: Equatable {
    /// Evidence found this microphone unit is not a copy of remote (application-track) audio.
    case notEcho
    /// Evidence found this unit duplicates an application-track unit. The application copy is
    /// retained; the microphone copy is ledger-only.
    case echoSuppressed(duplicateOfUnitID: String?)
}

/// Why a presentation-time interval has no transcript coverage.
nonisolated enum MeetingAssemblyCoverageGapReason: String, Codable, CaseIterable {
    case inadmissibleCaptureEra
    case missingOrUnreadableAudio
    case processingFailed
    case skipped
    case providerTruncated
    /// An indivisible unit touched an excluded interval, so its whole text was excluded; this
    /// gap marks the unit's admissible portion as incomplete coverage (plan §4).
    case excludedUnitIncompleteCoverage
}

/// A product-visible coverage gap, in seconds elapsed since the meeting presentation origin (the
/// same meeting-relative domain used by `MeetingTranscriptSegment.start/end`).
nonisolated struct MeetingAssemblyCoverageGap: Equatable {
    let trackID: MeetingAudioTrackID
    let start: TimeInterval
    let end: TimeInterval
    let reason: MeetingAssemblyCoverageGapReason
}

/// Everything the assembler needs, already validated or frozen upstream. `plan` is the frozen
/// backend plan; the assembler re-validates the manifest against it and the evidence against both.
nonisolated struct MeetingAssemblyInput {
    let plan: MeetingBackendPlan
    let manifest: MeetingAnalysisManifest
    let evidence: MeetingFinalTranscriptEvidence
    let coverageReceipts: [MeetingSpanCoverageReceipt]
    /// Echo verdicts keyed by unit ID. Required for every online-call microphone unit that
    /// survives quarantine and admission; never consulted for in-room or application audio.
    let echoVerdicts: [String: MeetingUnitEchoVerdict]
    let confirmedLocalUserTokens: Set<MeetingBackendSpeakerToken>

    init(
        plan: MeetingBackendPlan,
        manifest: MeetingAnalysisManifest,
        evidence: MeetingFinalTranscriptEvidence,
        coverageReceipts: [MeetingSpanCoverageReceipt],
        echoVerdicts: [String: MeetingUnitEchoVerdict] = [:],
        confirmedLocalUserTokens: Set<MeetingBackendSpeakerToken> = []
    ) {
        self.plan = plan
        self.manifest = manifest
        self.evidence = evidence
        self.coverageReceipts = coverageReceipts
        self.echoVerdicts = echoVerdicts
        self.confirmedLocalUserTokens = confirmedLocalUserTokens
    }
}

nonisolated struct MeetingAssemblyResult: Equatable {
    /// Deterministic product speakers, minted only here, scoped by attempt + track + epoch +
    /// token label. Cross-epoch identity requires explicit voice matching; tracks never merge.
    let speakers: [MeetingSessionSpeaker]
    /// Emitted and ambiguous-admitted units, once each, in presentation order. Ambiguous text is
    /// one segment with a nil speaker and `.ambiguous` overlap; excluded units never appear.
    let segments: [MeetingTranscriptSegment]
    /// The complete disposition and coverage ledger, already passing `validated()`.
    let sidecar: MeetingResultSidecar
    /// Planned chunks at least one of whose spans the backend reported as skipped.
    let skippedChunks: [MeetingAnalysisChunkIdentity]
    let coverageGaps: [MeetingAssemblyCoverageGap]
    /// False when any gap exists, so truncation or missing work can never look like a complete
    /// transcript.
    let isComplete: Bool
}

nonisolated enum MeetingAssemblyError: LocalizedError, Equatable {
    case missingCoverageReceipt(spanID: String)
    case duplicateCoverageReceiptID(String)
    case overlappingCoverageReceipts(spanID: String)
    case unknownCoverageReceiptSpan(spanID: String)
    case coverageReceiptOutOfBounds(receiptID: String)
    case invalidCoverageReceiptInterval(receiptID: String)
    case missingEchoVerdict(unitID: String)
    case echoVerdictForUnknownUnit(unitID: String)
    case echoDuplicateTargetUnknown(unitID: String, duplicateID: String)
    case echoDuplicateTargetNotApplicationAudio(unitID: String, duplicateID: String)
    case echoDuplicateTargetNotVisible(unitID: String, duplicateID: String)
    case textContradictsCoverage(
        unitID: String,
        receiptID: String,
        status: MeetingSpanCoverageStatus
    )

    var errorDescription: String? {
        switch self {
        case let .missingCoverageReceipt(spanID):
            return "Admissible analysis span \"\(spanID)\" has no complete coverage receipt."
        case let .duplicateCoverageReceiptID(id):
            return "Coverage receipt identifier \"\(id)\" appears more than once."
        case let .overlappingCoverageReceipts(spanID):
            return "Analysis span \"\(spanID)\" has overlapping coverage receipts."
        case let .unknownCoverageReceiptSpan(spanID):
            return "A coverage receipt references unknown analysis span \"\(spanID)\"."
        case let .coverageReceiptOutOfBounds(receiptID):
            return "Coverage receipt \"\(receiptID)\" lies outside its analysis span's bounds."
        case let .invalidCoverageReceiptInterval(receiptID):
            return "Coverage receipt \"\(receiptID)\" has non-finite or non-positive bounds."
        case let .missingEchoVerdict(unitID):
            return "Online microphone text unit \"\(unitID)\" has no cross-track echo verdict."
        case let .echoVerdictForUnknownUnit(unitID):
            return "An echo verdict references unknown text unit \"\(unitID)\"."
        case let .echoDuplicateTargetUnknown(unitID, duplicateID):
            return "Echo verdict for \"\(unitID)\" names unknown duplicate target \"\(duplicateID)\"."
        case let .echoDuplicateTargetNotApplicationAudio(unitID, duplicateID):
            return "Echo verdict for \"\(unitID)\" names \"\(duplicateID)\", which is not application audio."
        case let .echoDuplicateTargetNotVisible(unitID, duplicateID):
            return "Echo verdict for \"\(unitID)\" names application unit \"\(duplicateID)\", which is not publishable."
        case let .textContradictsCoverage(unitID, receiptID, status):
            return "Text unit \"\(unitID)\" overlaps receipt \"\(receiptID)\" marked \(status.rawValue)."
        }
    }
}

nonisolated struct MeetingTranscriptAssembler {
    private let tolerance = MeetingAnalysisManifestSchema.mappingToleranceSeconds
    private let speakerNameFormat: String

    /// The product resolves this trusted UI template before assembly; assembly remains pure.
    init(speakerNameFormat: String = "Speaker %lld") {
        self.speakerNameFormat = speakerNameFormat
    }

    func assemble(_ input: MeetingAssemblyInput) throws -> MeetingAssemblyResult {
        try Task.checkCancellation()
        let manifest = try input.manifest.validated(against: input.plan)
        let evidence = try input.evidence.validatedForAssembly(against: input.plan, manifest: manifest)
        let unitIDs = Set(evidence.units.map(\.id))
        let unitsByID = Dictionary(
            evidence.units.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for unitID in input.echoVerdicts.keys where !unitIDs.contains(unitID) {
            throw MeetingAssemblyError.echoVerdictForUnknownUnit(unitID: unitID)
        }

        let receipts = try self.reconcileCoverage(manifest: manifest, receipts: input.coverageReceipts)
        let spansByID = Dictionary(
            manifest.allSpans.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let receiptsBySpanID = Dictionary(grouping: receipts, by: \.spanID)
        let activityByEpoch = Dictionary(grouping: evidence.speakerActivity) { $0.token.analysisEpochID }
        let inadmissibleGapsByTrack = Dictionary(grouping: manifest.allGaps.filter {
            $0.reason == .inadmissibleCaptureEra && $0.recordedInterval != nil
        }) { $0.trackID }

        var dispositions: [MeetingTextUnitDispositionRecord] = []
        var emitted: [(unit: MeetingFinalTextUnit, presentation: MeetingAnalysisInterval)] = []
        var remainderGaps: [MeetingAssemblyCoverageGap] = []

        let canonicalUnits = evidence.units.sorted { $0.id < $1.id }
        for unit in canonicalUnits {
            try Task.checkCancellation()
            if let quarantine = unit.quarantineReason(in: manifest) {
                // No interval arithmetic on quarantined bounds (plan §4).
                dispositions.append(MeetingTextUnitDispositionRecord(
                    unitID: unit.id,
                    disposition: .rejectedInvalidTiming,
                    reasonCode: quarantine.rawValue
                ))
                continue
            }
            let spans = unit.analysisSpanIDs.compactMap { spansByID[$0] }
            let presentation = MeetingAnalysisInterval(
                start: spans[0].presentationMapping.presentationTime(forAnalysisTime: unit.analysisStart),
                end: spans[spans.count - 1].presentationMapping
                    .presentationTime(forAnalysisTime: unit.analysisEnd)
            )
            let recorded = MeetingAnalysisInterval(
                start: spans[0].recordedInterval.start
                    + (unit.analysisStart - spans[0].analysisInterval.start),
                end: spans[spans.count - 1].recordedInterval.start
                    + (unit.analysisEnd - spans[spans.count - 1].analysisInterval.start)
            )
            try self.validateCoverageStatus(
                for: unit,
                spans: spans,
                receiptsBySpanID: receiptsBySpanID
            )

            if self.intersectsInadmissibleGap(
                recorded, gaps: inadmissibleGapsByTrack[unit.trackID] ?? []
            ) {
                dispositions.append(MeetingTextUnitDispositionRecord(
                    unitID: unit.id,
                    disposition: .inadmissible,
                    reasonCode: MeetingUnitDispositionReason.inadmissibleCaptureEra.rawValue
                ))
                remainderGaps.append(contentsOf: self.admissibleRemainderGaps(
                    of: recorded,
                    excluding: inadmissibleGapsByTrack[unit.trackID] ?? [],
                    trackID: unit.trackID
                ))
                continue
            }

            if manifest.captureMode == .onlineCall,
               manifest.track(unit.trackID)?.kind == .microphone
            {
                guard let verdict = input.echoVerdicts[unit.id] else {
                    throw MeetingAssemblyError.missingEchoVerdict(unitID: unit.id)
                }
                if case let .echoSuppressed(duplicateOfUnitID) = verdict {
                    if let duplicateOfUnitID {
                        guard let duplicate = unitsByID[duplicateOfUnitID] else {
                            throw MeetingAssemblyError.echoDuplicateTargetUnknown(
                                unitID: unit.id,
                                duplicateID: duplicateOfUnitID
                            )
                        }
                        guard manifest.track(duplicate.trackID)?.kind == .applicationAudio else {
                            throw MeetingAssemblyError.echoDuplicateTargetNotApplicationAudio(
                                unitID: unit.id,
                                duplicateID: duplicateOfUnitID
                            )
                        }
                        guard duplicate.quarantineReason(in: manifest) == nil,
                              !MeetingSpeakerActivityCoverage.isOutside(
                                  duplicate,
                                  activityByEpoch: activityByEpoch
                              )
                        else {
                            throw MeetingAssemblyError.echoDuplicateTargetNotVisible(
                                unitID: unit.id,
                                duplicateID: duplicateOfUnitID
                            )
                        }
                    }
                    dispositions.append(MeetingTextUnitDispositionRecord(
                        unitID: unit.id,
                        disposition: .echoSuppressed,
                        reasonCode: MeetingUnitDispositionReason.crossTrackEcho.rawValue
                    ))
                    continue
                }
            }

            if MeetingSpeakerActivityCoverage.isOutside(unit, activityByEpoch: activityByEpoch) {
                dispositions.append(MeetingTextUnitDispositionRecord(
                    unitID: unit.id,
                    disposition: .outsideActivity,
                    reasonCode: MeetingUnitDispositionReason.outsideSpeakerActivity.rawValue
                ))
                continue
            }

            if case .ambiguous = unit.speaker {
                dispositions.append(MeetingTextUnitDispositionRecord(
                    unitID: unit.id,
                    disposition: .ambiguousUnassigned,
                    reasonCode: MeetingUnitDispositionReason.ambiguousSpeaker.rawValue
                ))
                emitted.append((unit, presentation))
            } else if spans.contains(where: { $0.timing.certainty == .timingUncertain }) {
                dispositions.append(MeetingTextUnitDispositionRecord(
                    unitID: unit.id,
                    disposition: .ambiguousUnassigned,
                    reasonCode: MeetingUnitDispositionReason.timingUncertain.rawValue
                ))
                emitted.append((unit, presentation))
            } else {
                dispositions.append(MeetingTextUnitDispositionRecord(
                    unitID: unit.id,
                    disposition: .emitted
                ))
                emitted.append((unit, presentation))
            }
        }

        let dispositionByUnitID = Dictionary(
            dispositions.map { ($0.unitID, $0.disposition) },
            uniquingKeysWith: { first, _ in first }
        )
        let dispositionReasonByUnitID = Dictionary(
            dispositions.map { ($0.unitID, $0.reasonCode) },
            uniquingKeysWith: { first, _ in first }
        )
        // Raw ambiguous units mint no speaker. The later product continuity policy can borrow
        // an existing neighboring identity while leaving these evidence dispositions intact.
        let visibleUnits = emitted.filter { dispositionByUnitID[$0.unit.id] == .emitted }
        let visibleTokens = Set(visibleUnits.compactMap { item -> MeetingBackendSpeakerToken? in
            guard case let .assigned(token) = item.unit.speaker else { return nil }
            return token
        })
        let identityLinks = evidence.speakerSlotsContinueAcrossEpochs
            ? MeetingSpeakerVoiceMatcher.continuityLinks(allowedTokens: visibleTokens)
            : MeetingSpeakerVoiceMatcher.links(profiles: evidence.voiceProfiles, allowedTokens: visibleTokens)
        let speakers = self.makeSpeakers(
            attemptID: manifest.attemptID,
            trackKinds: Dictionary(uniqueKeysWithValues: manifest.tracks.map { ($0.id, $0.kind) }),
            emitted: visibleUnits,
            identityLinks: identityLinks,
            confirmedLocalUserTokens: input.confirmedLocalUserTokens
        )
        let speakerIDsByToken = Dictionary(
            speakers.map { ($0.token, $0.speaker.id) },
            uniquingKeysWith: { first, _ in first }
        )
        // Word timestamps may tie. Preserve the backend's original word order, not the
        // lexical unit ID order used for sidecars or the attempt-dependent segment UUID.
        let sourceOffsets = Dictionary(uniqueKeysWithValues: evidence.units.enumerated().map { ($0.element.id, $0.offset) })
        let segments = emitted
            .map { unit, presentation -> (offset: Int, segment: MeetingTranscriptSegment) in
                let disposition = dispositionByUnitID[unit.id]
                let reasonCode = dispositionReasonByUnitID[unit.id] ?? nil
                let isSpeakerAmbiguous = disposition == .ambiguousUnassigned
                    && reasonCode == MeetingUnitDispositionReason.ambiguousSpeaker.rawValue
                let isTimingUncertain = disposition == .ambiguousUnassigned
                    && reasonCode == MeetingUnitDispositionReason.timingUncertain.rawValue
                let speakerID: SessionSpeakerID? = {
                    guard disposition == .emitted,
                          case let .assigned(token) = unit.speaker
                    else { return nil }
                    return speakerIDsByToken[token]
                }()
                let attributionState: MeetingTranscriptAttributionState = {
                    if isSpeakerAmbiguous { return .overlappingSpeakers }
                    if isTimingUncertain { return .timingUncertain }
                    return speakerID != nil ? .assigned : .unassigned
                }()
                let segment = MeetingTranscriptSegment(
                    id: Self.stableUUID("segment:\(manifest.attemptID.uuidString):\(unit.id)"),
                    start: Self.mediaTime(presentation.start),
                    end: Self.mediaTime(max(presentation.start, presentation.end)),
                    sourceTrackID: unit.trackID,
                    speakerID: speakerID,
                    text: unit.text,
                    revision: 0,
                    status: .final,
                    overlap: isSpeakerAmbiguous ? .ambiguous : .none,
                    completeness: .complete,
                    isLikelyEcho: nil,
                    attributionState: attributionState
                )
                return (sourceOffsets[unit.id] ?? 0, segment)
            }
            .sorted {
                ($0.segment.start, $0.segment.end, $0.segment.sourceTrackID.uuidString, $0.offset)
                    < ($1.segment.start, $1.segment.end, $1.segment.sourceTrackID.uuidString, $1.offset)
            }
            .map(\.segment)

        let receiptGaps = self.receiptCoverageGaps(
            manifest: manifest, spansByID: spansByID, receipts: receipts
        )
        let manifestGaps = self.manifestCoverageGaps(manifest: manifest)
        let coverageGaps = (receiptGaps + manifestGaps + remainderGaps).sorted {
            ($0.trackID.uuidString, $0.start, $0.end, $0.reason.rawValue)
                < ($1.trackID.uuidString, $1.start, $1.end, $1.reason.rawValue)
        }
        let skippedChunks = self.skippedChunks(spansByID: spansByID, receipts: receipts)

        // Omitted evidence is a continuity boundary, not a new product coverage claim.
        // An unmappable quarantined unit disables inference only in its own epoch.
        var continuityBarriers = coverageGaps
        var blockedEpochs = Set<MeetingAnalysisEpochID>()
        for record in dispositions where record.disposition != .emitted && record.disposition != .ambiguousUnassigned {
            try Task.checkCancellation()
            guard let unit = unitsByID[record.unitID] else { continue }
            guard unit.quarantineReason(in: manifest) == nil,
                  let firstSpan = unit.analysisSpanIDs.first.flatMap({ spansByID[$0] }),
                  let lastSpan = unit.analysisSpanIDs.last.flatMap({ spansByID[$0] }) else {
                blockedEpochs.insert(unit.analysisEpochID)
                continue
            }
            continuityBarriers.append(.init(trackID: unit.trackID,
                start: firstSpan.presentationMapping.presentationTime(forAnalysisTime: unit.analysisStart),
                end: lastSpan.presentationMapping.presentationTime(forAnalysisTime: unit.analysisEnd),
                reason: .excludedUnitIncompleteCoverage))
        }

        let sidecar = try MeetingResultSidecar(
            backendID: evidence.backendID,
            backendVersion: input.plan.backendVersion,
            attemptID: evidence.attemptID,
            analysisManifest: manifest,
            units: canonicalUnits,
            dispositions: dispositions,
            coverageReceipts: receipts,
            speakerIdentityLinks: identityLinks
        ).validated()

        let hasQuarantinedUnit = dispositions.contains {
            $0.disposition == .rejectedInvalidTiming
        }
        var seenSpeakerIDs = Set<SessionSpeakerID>()
        return MeetingAssemblyResult(
            speakers: speakers.map(\.speaker).filter { seenSpeakerIDs.insert($0.id).inserted },
            segments: try MeetingTranscriptSpeakerContinuity.resolve(segments,
                epochs: Dictionary(uniqueKeysWithValues: emitted.filter {
                    !blockedEpochs.contains($0.unit.analysisEpochID)
                }.map { item in
                    (Self.stableUUID("segment:\(manifest.attemptID.uuidString):\(item.unit.id)"), item.unit.analysisEpochID)
                }), barriers: continuityBarriers),
            sidecar: sidecar,
            skippedChunks: skippedChunks,
            coverageGaps: coverageGaps,
            isComplete: coverageGaps.isEmpty
                && manifest.allGaps.isEmpty
                && !hasQuarantinedUnit
        )
    }

    // MARK: - Coverage reconciliation

    private func validateCoverageStatus(
        for unit: MeetingFinalTextUnit,
        spans: [MeetingAnalysisSpan],
        receiptsBySpanID: [String: [MeetingSpanCoverageReceipt]]
    ) throws {
        for span in spans {
            let coveredStart = max(unit.analysisStart, span.analysisInterval.start)
            let coveredEnd = min(unit.analysisEnd, span.analysisInterval.end)
            guard coveredEnd - coveredStart > self.tolerance else { continue }
            let overlappingReceipts = (receiptsBySpanID[span.id] ?? []).filter {
                min($0.analysisEnd, coveredEnd) - max($0.analysisStart, coveredStart)
                    > self.tolerance
            }
            if let contradiction = overlappingReceipts.first(where: { $0.status != .processed }) {
                throw MeetingAssemblyError.textContradictsCoverage(
                    unitID: unit.id,
                    receiptID: contradiction.id,
                    status: contradiction.status
                )
            }
        }
    }

    /// Receipts must tile every admissible span's analysis interval exactly once. The manifest's
    /// own gaps need no receipt — the backend never saw that audio — and a span full of recognized
    /// text but no receipt fails here: text never implies coverage.
    private func reconcileCoverage(
        manifest: MeetingAnalysisManifest,
        receipts: [MeetingSpanCoverageReceipt]
    ) throws -> [MeetingSpanCoverageReceipt] {
        var seenIDs = Set<String>()
        for receipt in receipts {
            try Task.checkCancellation()
            guard seenIDs.insert(receipt.id).inserted else {
                throw MeetingAssemblyError.duplicateCoverageReceiptID(receipt.id)
            }
        }
        let spansByID = Dictionary(
            manifest.allSpans.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var receiptsBySpan: [String: [MeetingSpanCoverageReceipt]] = [:]
        for receipt in receipts {
            guard MeetingEvidenceInterval.isValid(start: receipt.analysisStart, end: receipt.analysisEnd) else {
                throw MeetingAssemblyError.invalidCoverageReceiptInterval(receiptID: receipt.id)
            }
            guard let span = spansByID[receipt.spanID] else {
                throw MeetingAssemblyError.unknownCoverageReceiptSpan(spanID: receipt.spanID)
            }
            guard span.analysisInterval.start - self.tolerance <= receipt.analysisStart,
                  receipt.analysisEnd <= span.analysisInterval.end + self.tolerance
            else {
                throw MeetingAssemblyError.coverageReceiptOutOfBounds(receiptID: receipt.id)
            }
            receiptsBySpan[receipt.spanID, default: []].append(receipt)
        }
        for span in manifest.allSpans {
            try Task.checkCancellation()
            guard let spanReceipts = receiptsBySpan[span.id] else {
                throw MeetingAssemblyError.missingCoverageReceipt(spanID: span.id)
            }
            var cursor = span.analysisInterval.start
            for receipt in spanReceipts.sorted(by: { $0.analysisStart < $1.analysisStart }) {
                if receipt.analysisStart < cursor - self.tolerance {
                    throw MeetingAssemblyError.overlappingCoverageReceipts(spanID: span.id)
                }
                guard receipt.analysisStart <= cursor + self.tolerance else {
                    throw MeetingAssemblyError.missingCoverageReceipt(spanID: span.id)
                }
                cursor = max(cursor, receipt.analysisEnd)
            }
            guard cursor >= span.analysisInterval.end - self.tolerance else {
                throw MeetingAssemblyError.missingCoverageReceipt(spanID: span.id)
            }
        }
        return receipts.sorted {
            ($0.spanID, $0.analysisStart, $0.analysisEnd, $0.status.rawValue, $0.id)
                < ($1.spanID, $1.analysisStart, $1.analysisEnd, $1.status.rawValue, $1.id)
        }
    }

    // MARK: - Admission

    private func intersectsInadmissibleGap(
        _ presentation: MeetingAnalysisInterval,
        gaps: [MeetingAnalysisGap]
    ) -> Bool {
        gaps.contains { gap in
            guard let recorded = gap.recordedInterval else { return false }
            return min(recorded.end, presentation.end) - max(recorded.start, presentation.start)
                > self.tolerance
        }
    }

    /// The admissible portion of a whole-unit exclusion, recorded as incomplete coverage.
    private func admissibleRemainderGaps(
        of presentation: MeetingAnalysisInterval,
        excluding gaps: [MeetingAnalysisGap],
        trackID: MeetingAudioTrackID
    ) -> [MeetingAssemblyCoverageGap] {
        let excluded = gaps.compactMap(\.recordedInterval)
            .filter {
                min($0.end, presentation.end) - max($0.start, presentation.start) > self.tolerance
            }
            .sorted { $0.start < $1.start }
        var pieces: [MeetingAnalysisInterval] = [presentation]
        for interval in excluded {
            pieces = pieces.flatMap { piece -> [MeetingAnalysisInterval] in
                let overlapStart = max(piece.start, interval.start)
                let overlapEnd = min(piece.end, interval.end)
                guard overlapEnd - overlapStart > self.tolerance else { return [piece] }
                var remainder: [MeetingAnalysisInterval] = []
                if overlapStart - piece.start > self.tolerance {
                    remainder.append(MeetingAnalysisInterval(start: piece.start, end: overlapStart))
                }
                if piece.end - overlapEnd > self.tolerance {
                    remainder.append(MeetingAnalysisInterval(start: overlapEnd, end: piece.end))
                }
                return remainder
            }
        }
        return pieces.map {
            MeetingAssemblyCoverageGap(
                trackID: trackID,
                start: $0.start,
                end: $0.end,
                reason: .excludedUnitIncompleteCoverage
            )
        }
    }

    // MARK: - Gaps and skipped chunks

    private func receiptCoverageGaps(
        manifest: MeetingAnalysisManifest,
        spansByID: [String: MeetingAnalysisSpan],
        receipts: [MeetingSpanCoverageReceipt]
    ) -> [MeetingAssemblyCoverageGap] {
        receipts.compactMap { receipt in
            let reason: MeetingAssemblyCoverageGapReason
            switch receipt.status {
            case .processed: return nil
            case .failed: reason = .processingFailed
            case .skipped: reason = .skipped
            case .providerTruncated: reason = .providerTruncated
            }
            guard let span = spansByID[receipt.spanID] else { return nil }
            let transform = span.presentationMapping
            return MeetingAssemblyCoverageGap(
                trackID: span.trackID,
                start: transform.presentationTime(forAnalysisTime: receipt.analysisStart),
                end: transform.presentationTime(forAnalysisTime: receipt.analysisEnd),
                reason: reason
            )
        }
    }

    /// Manifest gaps are facts the builder established; presentation uses the recorded interval
    /// directly because an unreadable or inadmissible piece has no de-drift correction to apply.
    private func manifestCoverageGaps(
        manifest: MeetingAnalysisManifest
    ) -> [MeetingAssemblyCoverageGap] {
        manifest.allGaps.compactMap { gap in
            guard let recorded = gap.recordedInterval else { return nil }
            return MeetingAssemblyCoverageGap(
                trackID: gap.trackID,
                start: recorded.start,
                end: recorded.end,
                reason: gap.reason == .inadmissibleCaptureEra
                    ? .inadmissibleCaptureEra
                    : .missingOrUnreadableAudio
            )
        }
    }

    private func skippedChunks(
        spansByID: [String: MeetingAnalysisSpan],
        receipts: [MeetingSpanCoverageReceipt]
    ) -> [MeetingAnalysisChunkIdentity] {
        var seen = Set<MeetingAnalysisChunkIdentity>()
        var skipped: [MeetingAnalysisChunkIdentity] = []
        for receipt in receipts where receipt.status == .skipped {
            guard let span = spansByID[receipt.spanID], seen.insert(span.chunk).inserted else { continue }
            skipped.append(span.chunk)
        }
        return skipped.sorted {
            ($0.trackID.uuidString, $0.sequence, $0.chunkID.uuidString)
                < ($1.trackID.uuidString, $1.sequence, $1.chunkID.uuidString)
        }
    }

    // MARK: - Product speakers and segments

    /// Beside a substantial speaker on its track, a speaker needs this much evidence, across all
    /// its linked epochs, to get a name.
    static let minimumSpeakerWords = 10
    static let minimumSpeakerSeconds: TimeInterval = 5

    /// Only the assembler mints product speaker IDs. The key is attempt + track + epoch + token
    /// label. Cross-epoch identity requires explicit links: voice evidence, or a diarizer that kept
    /// one state per track. Recomputed attempts never inherit an old identity. You is never
    /// inferred here; only externally verified owner tokens can receive that label.
    private func makeSpeakers(
        attemptID: UUID,
        trackKinds: [MeetingAudioTrackID: MeetingAudioTrackKind],
        emitted: [(unit: MeetingFinalTextUnit, presentation: MeetingAnalysisInterval)],
        identityLinks: [MeetingSpeakerIdentityLink],
        priorSpeakers: [MeetingSessionSpeaker] = [],
        confirmedLocalUserTokens: Set<MeetingBackendSpeakerToken> = []
    ) -> [(token: MeetingBackendSpeakerToken, speaker: MeetingSessionSpeaker)] {
        var tokens: [MeetingBackendSpeakerToken] = []
        var seen = Set<MeetingBackendSpeakerToken>()
        for (unit, _) in emitted {
            guard case let .assigned(token) = unit.speaker, seen.insert(token).inserted else { continue }
            tokens.append(token)
        }
        tokens.sort {
            ($0.analysisEpochID.trackID.uuidString, $0.analysisEpochID.ordinal, $0.label)
                < ($1.analysisEpochID.trackID.uuidString, $1.analysisEpochID.ordinal, $1.label)
        }
        let canonicalByToken = Dictionary(uniqueKeysWithValues: identityLinks.map { ($0.token, $0.canonicalToken) })
        // A slot heard for a word or two (a cough, crosstalk) next to real speakers on the same
        // track is not a person. Its lines stay in the transcript without a speaker instead of
        // minting "Speaker N". A track where every slot is brief keeps them all.
        var wordsByIdentity: [MeetingBackendSpeakerToken: Int] = [:]
        var secondsByIdentity: [MeetingBackendSpeakerToken: TimeInterval] = [:]
        for (unit, presentation) in emitted {
            guard case let .assigned(token) = unit.speaker else { continue }
            let identity = canonicalByToken[token] ?? token
            wordsByIdentity[identity, default: 0] += unit.text.split(whereSeparator: \.isWhitespace).count
            secondsByIdentity[identity, default: 0] += max(0, presentation.end - presentation.start)
        }
        let isSubstantial = { (identity: MeetingBackendSpeakerToken) in
            wordsByIdentity[identity, default: 0] >= Self.minimumSpeakerWords
                || secondsByIdentity[identity, default: 0] >= Self.minimumSpeakerSeconds
        }
        let tracksWithSubstantialSpeaker = Set(wordsByIdentity.keys.filter(isSubstantial).map(\.analysisEpochID.trackID))
        let speakingTokens = tokens.filter { token in
            let identity = canonicalByToken[token] ?? token
            return isSubstantial(identity) || !tracksWithSubstantialSpeaker.contains(identity.analysisEpochID.trackID)
        }
        let localIdentities = Set(confirmedLocalUserTokens.map { canonicalByToken[$0] ?? $0 })
        let priorIDs = Set(priorSpeakers.map(\.id))
        let ordinals = Dictionary(uniqueKeysWithValues: speakingTokens.filter {
            canonicalByToken[$0] == nil && !priorIDs.contains(Self.speakerID(attemptID: attemptID, token: $0))
        }.enumerated().map { ($0.element, $0.offset + priorSpeakers.count + 1) })
        return speakingTokens.map { token in
            let canonical = canonicalByToken[token] ?? token
            let scopedClusterID = Self.scopedClusterID(for: canonical)
            let speakerID = Self.speakerID(attemptID: attemptID, token: canonical)
            let isLocalUser = localIdentities.contains(canonical)
            if var prior = priorSpeakers.first(where: { $0.id == speakerID }) {
                prior.isLocalUser = isLocalUser
                return (token, prior)
            }
            return (
                token,
                MeetingSessionSpeaker(
                    id: speakerID,
                    displayName: String(format: self.speakerNameFormat, Int64(ordinals[canonical] ?? 1)),
                    diarizationClusterID: scopedClusterID,
                    trackKind: trackKinds[token.analysisEpochID.trackID] ?? .microphone,
                    isLocalUser: isLocalUser,
                    identityCandidates: []
                )
            )
        }
    }

    /// PCM-only input has one contiguous, admitted physical window and no audio-file
    /// spans to materialize. Reuse the same product identity/attribution rules after the
    /// runtime validates its bounded window; never fabricate an audio chunk manifest.
    func assemblePCMWindow(
        attemptID: UUID,
        epoch: MeetingAnalysisEpochID,
        offset: TimeInterval,
        duration: TimeInterval,
        units: [MeetingFinalTextUnit],
        identityLinks: [MeetingSpeakerIdentityLink] = [],
        priorSpeakers: [MeetingSessionSpeaker] = [],
        confirmedLocalUserTokens: Set<MeetingBackendSpeakerToken> = [],
        applySpeakerContinuity: Bool = true
    ) throws -> MeetingPCMTranscriptBatch {
        guard offset.isFinite, offset >= 0, duration.isFinite, duration > 0,
              units.allSatisfy({ $0.trackID == epoch.trackID && $0.analysisEpochID == epoch
                  && $0.analysisStart.isFinite && $0.analysisEnd.isFinite
                  && $0.analysisStart >= 0 && $0.analysisEnd > $0.analysisStart
                  && $0.analysisEnd <= duration + 1e-6 && $0.analysisSpanIDs.isEmpty }) else {
            throw MeetingAssemblyError.invalidCoverageReceiptInterval(receiptID: "pcm-window")
        }
        let emitted = units.map { ($0, MeetingAnalysisInterval(start: offset + $0.analysisStart, end: offset + $0.analysisEnd)) }
        let visible = emitted.filter { if case .ambiguous = $0.0.speaker { return false }; return true }
        let canonicalByToken = Dictionary(identityLinks.map { ($0.token, $0.canonicalToken) }, uniquingKeysWith: { first, _ in first })
        let localSpeakerIDs = Set(confirmedLocalUserTokens.map {
            Self.speakerID(attemptID: attemptID, token: canonicalByToken[$0] ?? $0)
        })
        // Owner verification covers the complete retained evidence for this attempt. A later
        // ambiguous voice must revoke an earlier owner label even when that speaker is absent
        // from this window. Keep canonical IDs and user-edited metadata unchanged.
        let reconciledPriorSpeakers = priorSpeakers.map { prior in
            var speaker = prior
            speaker.isLocalUser = localSpeakerIDs.contains(speaker.id)
            return speaker
        }
        let speakers = self.makeSpeakers(attemptID: attemptID, trackKinds: [epoch.trackID: .microphone],
                                         emitted: visible, identityLinks: identityLinks, priorSpeakers: reconciledPriorSpeakers,
                                         confirmedLocalUserTokens: confirmedLocalUserTokens)
        let speakerIDs = Dictionary(speakers.map { ($0.token, $0.speaker.id) }, uniquingKeysWith: { first, _ in first })
        let segments = emitted.map { unit, interval in
            let speakerID: SessionSpeakerID?
            let overlap: MeetingTranscriptOverlap
            switch unit.speaker {
            case let .assigned(token): speakerID = speakerIDs[token]; overlap = .none
            case .ambiguous: speakerID = nil; overlap = .ambiguous
            case .unassigned: speakerID = nil; overlap = .none
            }
            return MeetingTranscriptSegment(
                id: Self.stableUUID("segment:\(attemptID.uuidString):\(unit.id)"),
                start: Self.mediaTime(interval.start), end: Self.mediaTime(interval.end),
                sourceTrackID: epoch.trackID, speakerID: speakerID, text: unit.text,
                revision: 0, status: .final, overlap: overlap, completeness: .complete,
                attributionState: overlap == .ambiguous ? .overlappingSpeakers : (speakerID == nil ? .unassigned : .assigned)
            )
        }
        let resolved = applySpeakerContinuity ? try MeetingTranscriptSpeakerContinuity.resolve(segments,
            epochs: Dictionary(uniqueKeysWithValues: segments.map { ($0.id, epoch) })) : segments
        var batch = MeetingPCMTranscriptBatch(segments: resolved,
            speakers: speakers.map(\.speaker))
        batch.speakers = batch.mergingSpeakers(into: reconciledPriorSpeakers)
        return batch
    }

    private static func scopedClusterID(for token: MeetingBackendSpeakerToken) -> String {
        "\(token.analysisEpochID):\(token.label.precomposedStringWithCanonicalMapping)"
    }

    private static func speakerID(attemptID: UUID, token: MeetingBackendSpeakerToken) -> SessionSpeakerID {
        Self.stableUUID("speaker:\(attemptID.uuidString):\(Self.scopedClusterID(for: token))")
    }

    private static func mediaTime(_ seconds: TimeInterval) -> MeetingMediaTime {
        MeetingMediaTime(value: Int64((max(0, seconds) * 1000).rounded()), timescale: 1000)
    }

    private nonisolated static func stableUUID(_ key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

/// Resolves short product-level unknown runs using the user's neighboring-turn policy.
/// Raw backend evidence and sidecar dispositions remain unchanged. No audio or models are read.
nonisolated enum MeetingTranscriptSpeakerContinuity {
    static let maximumWords = 5
    static let maximumRunSeconds: TimeInterval = 3
    static let maximumAdjacentGapSeconds: TimeInterval = 0.8
    static let maximumTimingOverlapSeconds: TimeInterval = 0.08

    static func resolve(_ segments: [MeetingTranscriptSegment],
                        epochs: [MeetingTranscriptSegmentID: MeetingAnalysisEpochID],
                        barriers: [MeetingAssemblyCoverageGap] = []) throws -> [MeetingTranscriptSegment] {
        try Task.checkCancellation()
        var result = segments
        // Original anchors only: a guess made in this pass cannot support another guess.
        var groups: [MeetingAnalysisEpochID: [Int]] = [:]
        for index in segments.indices {
            guard let epoch = epochs[segments[index].id], epoch.trackID == segments[index].sourceTrackID else { continue }
            groups[epoch, default: []].append(index)
        }
        let barriersByTrack = Dictionary(grouping: barriers, by: \.trackID)
        for (epoch, indices) in groups {
            try Task.checkCancellation()
            let ordered = indices.sorted {
                (segments[$0].start, segments[$0].end, $0) < (segments[$1].start, segments[$1].end, $1)
            }
            let blocked = (barriersByTrack[epoch.trackID] ?? []).sorted { $0.start < $1.start }
            var barrierCursor = 0
            var cursor = 0
            while cursor < ordered.count {
                try Task.checkCancellation()
                guard segments[ordered[cursor]].speakerID == nil else { cursor += 1; continue }
                let first = cursor
                while cursor < ordered.count, segments[ordered[cursor]].speakerID == nil { cursor += 1 }
                guard first > 0, cursor < ordered.count else { continue }
                let left = segments[ordered[first - 1]], right = segments[ordered[cursor]]
                guard let leftSpeaker = left.speakerID, let target = right.speakerID,
                      left.speakerAttributionInference == nil, right.speakerAttributionInference == nil else { continue }
                let run = ordered[first..<cursor]
                let chain = ordered[(first - 1)...cursor]
                guard run.count <= Self.maximumWords, chain.allSatisfy({ index in
                    let segment = segments[index]
                    return segment.sourceTrackID == epoch.trackID && segment.status == .final
                        && segment.completeness == .complete && !segment.isEcho
                        && segment.attributionState != .timingUncertain
                        && segment.start.seconds.isFinite && segment.end.seconds.isFinite
                        && segment.start.seconds >= 0 && segment.end > segment.start
                }), run.allSatisfy({
                    let state = segments[$0].attributionState
                    return state == nil || state == .unassigned || state == .overlappingSpeakers
                }) else { continue }
                let wordCount = run.reduce(0) { $0 + segments[$1].text.split(whereSeparator: \.isWhitespace).count }
                guard (1...Self.maximumWords).contains(wordCount),
                      segments[ordered[cursor - 1]].end.seconds - segments[ordered[first]].start.seconds
                        <= Self.maximumRunSeconds else { continue }
                var continuous = true
                for position in (first - 1)..<cursor {
                    let gap = segments[ordered[position + 1]].start.seconds - segments[ordered[position]].end.seconds
                    if gap > Self.maximumAdjacentGapSeconds || gap < -Self.maximumTimingOverlapSeconds {
                        continuous = false
                        break
                    }
                }
                while barrierCursor < blocked.count, blocked[barrierCursor].end <= left.start.seconds { barrierCursor += 1 }
                guard continuous,
                      barrierCursor == blocked.count || blocked[barrierCursor].start >= right.end.seconds else { continue }
                let rule: MeetingSpeakerAttributionInference.Rule = leftSpeaker == target
                    ? .surroundingSpeaker : .incomingSpeaker
                for index in run {
                    result[index].speakerAttributionInference = .init(rule: rule,
                        originalState: segments[index].attributionState, originalOverlap: segments[index].overlap,
                        precedingSegmentID: left.id, followingSegmentID: right.id)
                    result[index].speakerID = target
                    result[index].attributionState = .assigned
                    result[index].overlap = .none
                }
            }
        }
        return result
    }
}

/// Speaker-only reconciliation after whole-recording analysis. Reuses canonical speaker
/// identity and coverage rules while retaining accepted text, redaction and segment provenance.
nonisolated enum MeetingPCMRecordingAttribution {
    static func assemble(
        transcript: MeetingPCMTranscriptBatch, activity: [MeetingBackendSpeakerActivity],
        epoch: MeetingAnalysisEpochID, attemptID: UUID, duration: TimeInterval,
        speakerNameFormat: String, confirmedLocalUserTokens: Set<MeetingBackendSpeakerToken> = []
    ) throws -> MeetingPCMTranscriptBatch {
        guard duration.isFinite, duration > 0,
              transcript.segments.allSatisfy({ $0.sourceTrackID == epoch.trackID
                  && $0.start.seconds.isFinite && $0.end.seconds.isFinite
                  && $0.start.seconds >= 0 && $0.end.seconds > $0.start.seconds
                  && $0.end.seconds <= duration + 0.001 }),
              activity.allSatisfy({ $0.token.analysisEpochID == epoch && $0.start.isFinite && $0.end.isFinite
                  && $0.start >= 0 && $0.end > $0.start && $0.end <= duration + 1e-6 }) else {
            throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow
        }
        let orderedActivity = activity.sorted { $0.start < $1.start }
        var cursor = 0
        var active: [MeetingBackendSpeakerActivity] = []
        var assignments: [Int: MeetingBackendSpeakerAssignment] = [:]
        // Long meetings must not compare every word with the entire recording timeline.
        // Keep only intervals that can overlap the current accepted text unit.
        for index in transcript.segments.indices.sorted(by: {
            transcript.segments[$0].start < transcript.segments[$1].start
        }) {
            try Task.checkCancellation()
            let segment = transcript.segments[index]
            let start = segment.start.seconds, end = segment.end.seconds
            active.removeAll { $0.end <= start }
            while cursor < orderedActivity.count, orderedActivity[cursor].start < end {
                if orderedActivity[cursor].end > start { active.append(orderedActivity[cursor]) }
                cursor += 1
            }
            // Persisted native segment timings do not imply word precision. Preserve real
            // overlap conservatively rather than inferring a dominant voice in a coarse turn.
            assignments[index] = MeetingParakeetNemotronBackend.assignment(
                start: start, end: end, activity: active, allowDominance: false)
        }
        let units = transcript.segments.enumerated().map { index, segment in
            MeetingFinalTextUnit(id: "post-stop:\(segment.id)", trackID: epoch.trackID,
                analysisEpochID: epoch, precision: .utterance, text: segment.text,
                analysisStart: segment.start.seconds, analysisEnd: segment.end.seconds,
                speaker: assignments[index] ?? .unassigned, analysisSpanIDs: [], confidence: nil)
        }
        // Canonical media times round to milliseconds. The last accepted boundary can
        // exceed the physical frame duration by at most that rounding quantum.
        let assemblyDuration = max(duration, transcript.segments.map { $0.end.seconds }.max() ?? duration)
        let attributed = try MeetingTranscriptAssembler(speakerNameFormat: speakerNameFormat)
            .assemblePCMWindow(attemptID: attemptID, epoch: epoch, offset: 0, duration: assemblyDuration,
                units: units, priorSpeakers: transcript.speakers, confirmedLocalUserTokens: confirmedLocalUserTokens,
                applySpeakerContinuity: false)
        guard attributed.segments.count == transcript.segments.count else {
            throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow
        }
        var result = transcript
        result.speakers = attributed.speakers
        for index in result.segments.indices {
            result.segments[index].speakerID = attributed.segments[index].speakerID
            result.segments[index].overlap = attributed.segments[index].overlap
            result.segments[index].attributionState = attributed.segments[index].attributionState
            result.segments[index].speakerAttributionInference = nil
        }
        // Infer only after restoring original IDs, completeness, echo and publication state.
        result.segments = try MeetingTranscriptSpeakerContinuity.resolve(result.segments,
            epochs: Dictionary(uniqueKeysWithValues: result.segments.map { ($0.id, epoch) }))
        return result
    }
}

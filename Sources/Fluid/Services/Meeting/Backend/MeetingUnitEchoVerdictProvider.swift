import Foundation

// Stage C2b2 of `MEETING_TRANSCRIPTION_IMPLEMENTATION_PLAN.md` (§4): the product-owned source of
// per-unit cross-track echo verdicts for canonical assembly. A verdict is a measured fact about
// one microphone text unit, never a guess — in an online call a microphone unit without one fails
// assembly, so this provider is the fail-closed gate between backend evidence and admission.
//
// The pipeline owns when verdicts are requested; the provider owns how they are measured. The
// composite backend's real signal/text scoring lands with Stage E; until then the default
// provider deliberately supplies no verdicts, which makes online microphone text unassemblable
// rather than silently admitted.

nonisolated protocol MeetingUnitEchoVerdictProviding: Sendable {
    /// Verdicts keyed by unit ID. Only online-call microphone units that survive quarantine and
    /// admission require one; application-track and in-room units are never consulted.
    func echoVerdicts(
        for evidence: MeetingFinalTranscriptEvidence,
        manifest: MeetingAnalysisManifest,
        plan: MeetingBackendPlan
    ) async throws -> [String: MeetingUnitEchoVerdict]
}

/// Returns no verdicts. The assembler then refuses every admissible online-call microphone unit
/// with `missingEchoVerdict`, so canonical online output can never be published on absent echo
/// evidence.
nonisolated struct MeetingFailClosedEchoVerdictProvider: MeetingUnitEchoVerdictProviding {
    func echoVerdicts(
        for _: MeetingFinalTranscriptEvidence,
        manifest _: MeetingAnalysisManifest,
        plan: MeetingBackendPlan
    ) async throws -> [String: MeetingUnitEchoVerdict] {
        [:]
    }
}

/// Stage E deterministic text/time echo evidence. For each online-call microphone unit it
/// compares the unit's text only against *temporally overlapping* application-track units with
/// the existing `MeetingEchoDetector`: a positive detector verdict suppresses the microphone copy
/// (the application copy is retained); anything else is measured `notEcho`. In-room sessions and
/// application units need no verdict and get none.
///
/// This provider creates no text, no timing and no speaker identity: it reads the backend's units
/// and the manifest's mapping only. Quarantined units are never read for interval arithmetic —
/// the assembler never consults their verdicts either.
nonisolated struct MeetingTextOverlapEchoVerdictProvider: MeetingUnitEchoVerdictProviding {
    init() {}

    func echoVerdicts(
        for evidence: MeetingFinalTranscriptEvidence,
        manifest: MeetingAnalysisManifest,
        plan: MeetingBackendPlan
    ) async throws -> [String: MeetingUnitEchoVerdict] {
        guard manifest.captureMode == .onlineCall else { return [:] }

        var microphoneUnits: [MeetingPositionedEchoUnit] = []
        var applicationUnits: [MeetingPositionedEchoUnit] = []
        let activityByEpoch = Dictionary(grouping: evidence.speakerActivity) { $0.token.analysisEpochID }
        let boundaryAssignments = MeetingWordBoundaryRecovery.assignments(
            units: evidence.units.filter { $0.quarantineReason(in: manifest) == nil },
            activityByEpoch: activityByEpoch
        )

        for unit in evidence.units {
            try Task.checkCancellation()
            guard let track = manifest.track(unit.trackID),
                  unit.quarantineReason(in: manifest) == nil,
                  let firstSpanID = unit.analysisSpanIDs.first,
                  let lastSpanID = unit.analysisSpanIDs.last,
                  let firstSpan = track.spans.first(where: { $0.id == firstSpanID }),
                  let lastSpan = track.spans.first(where: { $0.id == lastSpanID })
            else { continue }
            let presentation = MeetingAnalysisInterval(
                start: firstSpan.presentationMapping.presentationTime(forAnalysisTime: unit.analysisStart),
                end: lastSpan.presentationMapping.presentationTime(forAnalysisTime: unit.analysisEnd)
            )
            guard presentation.isValid else { continue }
            let positioned = MeetingPositionedEchoUnit(id: unit.id, trackID: unit.trackID,
                text: unit.text, presentation: presentation)
            switch track.kind {
            case .applicationAudio:
                // An application unit outside its own speaker activity can never become a visible
                // duplicate target, so it is not echo evidence either (the assembler proves this).
                guard !MeetingSpeakerActivityCoverage.isOutside(
                    unit,
                    activityByEpoch: activityByEpoch,
                    boundaryAssignments: boundaryAssignments,
                    preservesTokenEmissions: plan.request.configuration.speakerAttributionPolicy?.enableTokenEmissionContext == true
                ) else { continue }
                applicationUnits.append(positioned)
            case .microphone:
                microphoneUnits.append(positioned)
            }
        }

        return try MeetingPositionedEchoScoring.verdicts(microphoneUnits: microphoneUnits,
            applicationUnits: applicationUnits)
    }
}

/// Positioned raw text is shared by the recorded-manifest and live-PCM admissions. Source
/// clocks are projected by their owning input adapter before invoking the same echo policy.
nonisolated struct MeetingPositionedEchoUnit: Sendable {
    let id: String
    let trackID: MeetingAudioTrackID
    let text: String
    let presentation: MeetingAnalysisInterval
}

/// The deterministic text/time policy does not own inference, privacy, source clocks or IO.
/// Keeping one implementation preserves the canonical causal and short-phrase rules online.
nonisolated enum MeetingPositionedEchoScoring {
    static let wordContextSeconds: TimeInterval = 2
    private static let tolerance = MeetingAnalysisManifestSchema.mappingToleranceSeconds

    static func verdicts(microphoneUnits: [MeetingPositionedEchoUnit],
                         applicationUnits: [MeetingPositionedEchoUnit]) throws -> [String: MeetingUnitEchoVerdict] {
        let applicationUnits = applicationUnits.sorted {
            ($0.presentation.start, $0.presentation.end, $0.id)
                < ($1.presentation.start, $1.presentation.end, $1.id)
        }

        var verdicts: [String: MeetingUnitEchoVerdict] = [:]
        for mic in microphoneUnits {
            try Task.checkCancellation()
            // Canonical evidence normally contains one unit per ASR word. The existing detector
            // deliberately refuses fewer than four words, so classify a short temporal phrase and
            // then apply that verdict only to target words that actually occur in the remote phrase.
            let context = MeetingAnalysisInterval(
                start: max(0, mic.presentation.start - Self.wordContextSeconds),
                end: mic.presentation.end + Self.wordContextSeconds
            )
            let micContext = microphoneUnits.filter {
                $0.trackID == mic.trackID
                    && min($0.presentation.end, context.end)
                    - max($0.presentation.start, context.start) > Self.tolerance
            }.sorted {
                ($0.presentation.start, $0.presentation.end, $0.id)
                    < ($1.presentation.start, $1.presentation.end, $1.id)
            }
            let applicationContext = applicationUnits.filter {
                min($0.presentation.end, context.end)
                    - max($0.presentation.start, context.start) > Self.tolerance
            }
            let causalMatches = applicationContext.filter {
                $0.presentation.start <= mic.presentation.end + Self.tolerance
            }
            let micText = micContext.map(\.text).joined(separator: " ")
            let remoteText = applicationContext.map(\.text).joined(separator: " ")
            let targetWords = Set(MeetingEchoDetector.normalizedWords(mic.text))
            let causalRemoteWords = Set(causalMatches.flatMap {
                MeetingEchoDetector.normalizedWords($0.text)
            })
            guard MeetingEchoDetector.isLikelyEcho(micText: micText, remoteText: remoteText),
                  !targetWords.isDisjoint(with: causalRemoteWords)
            else {
                verdicts[mic.id] = .notEcho
                continue
            }
            let duplicate = causalMatches.first {
                !targetWords.isDisjoint(with: Set(MeetingEchoDetector.normalizedWords($0.text)))
            } ?? causalMatches.first
            verdicts[mic.id] = .echoSuppressed(duplicateOfUnitID: duplicate?.id)
        }
        return verdicts
    }
}

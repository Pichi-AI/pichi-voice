import Foundation

nonisolated enum MeetingPrivacyPublicationError: LocalizedError {
    case redactorUnavailable
    case unsupportedLegacyPublication
    var errorDescription: String? {
        switch self {
        case .redactorUnavailable: return "Prepare the local privacy model before enabling sensitive data redaction."
        case .unsupportedLegacyPublication: return "Sensitive data redaction requires a compatible meeting backend."
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
        for i in copy.transcriptSegments.indices {
            copy.transcriptSegments[i].text = try await redactor.redact(copy.transcriptSegments[i].text)
            copy.transcriptSegments[i].originalText = nil
        }
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

    static func redactedBatch(_ batch: MeetingPCMTranscriptBatch, using redactor: any TranscriptTextRedacting) async throws -> MeetingPCMTranscriptBatch {
        var copy = batch
        if let source = copy.sourceTrack { copy.sourceTrack?.sourceDisplayName = try await redactor.redact(source.sourceDisplayName) }
        for i in copy.segments.indices {
            copy.segments[i].text = try await redactor.redact(copy.segments[i].text)
            copy.segments[i].originalText = nil
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

    static func redactedEvidence(_ evidence: MeetingFinalTranscriptEvidence, using redactor: any TranscriptTextRedacting) async throws -> MeetingFinalTranscriptEvidence {
        var replacements: [String: String] = [:]
        var rangesByUnit: [String: [TranscriptRedactedSpan]] = [:]
        let groups = Dictionary(grouping: evidence.units) { $0.analysisEpochID }
        for group in groups.values {
            let ordered = group.sorted { $0.analysisStart < $1.analysisStart }
            var cursor = 0
            while cursor < ordered.count {
                var text = ""
                var ranges: [(MeetingFinalTextUnit, NSRange)] = []
                var end = cursor
                while end < ordered.count {
                    let unit = ordered[end]
                    let separator = text.isEmpty ? "" : " "
                    guard text.utf16.count + separator.utf16.count + unit.text.utf16.count <= 60_000 else { break }
                    text += separator
                    let range = NSRange(location: text.utf16.count, length: unit.text.utf16.count)
                    text += unit.text
                    ranges.append((unit, range)); end += 1
                }
                guard end > cursor else { throw MeetingPrivacyPublicationError.unsupportedLegacyPublication }
                let output = try await redactor.redactWithSpans(text)
                for (unit, range) in ranges {
                    for span in output.spans {
                        let intersection = NSIntersectionRange(span.range, range)
                        guard intersection.length > 0 else { continue }
                        let local = NSRange(location: intersection.location - range.location, length: intersection.length)
                        let value = TranscriptRedactedSpan(range: local, replacement: span.replacement)
                        if !(rangesByUnit[unit.id] ?? []).contains(value) { rangesByUnit[unit.id, default: []].append(value) }
                    }
                }
                if end == ordered.count { break }
                // Preserve context around boundaries without allowing unbounded input.
                cursor = max(cursor + 1, end - 32)
            }
        }
        for unit in evidence.units {
            let ranges = (rangesByUnit[unit.id] ?? []).sorted { $0.range.location > $1.range.location }
            guard !ranges.isEmpty else { continue }
            let text = NSMutableString(string: unit.text)
            var lastLocation = unit.text.utf16.count
            for span in ranges where NSMaxRange(span.range) <= lastLocation {
                text.replaceCharacters(in: span.range, with: span.replacement)
                lastLocation = span.range.location
            }
            replacements[unit.id] = text as String
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

import Foundation

// Persistence validation belongs to the application. The read-only meeting command
// decodes the same models without linking the settings and speech-engine UI catalog.
nonisolated extension MeetingSession {
    func validateForPersistence() throws {
        guard self.schemaVersion > 0,
              self.schemaVersion <= Self.currentSchemaVersion
        else {
            throw MeetingModelValidationError.unsupportedSchema(self.schemaVersion)
        }
        guard MeetingLanguageCode.isValid(self.languageCode) else {
            throw MeetingModelValidationError.unsupportedLanguage
        }
        guard !self.selectedMicrophone.captureDeviceID.isEmpty else {
            throw MeetingModelValidationError.missingMicrophone
        }
        if let endedAt = self.endedAt, endedAt < self.startedAt {
            throw MeetingModelValidationError.invalidTimeRange
        }
        guard self.timebase.machTimebaseDenominator > 0 else {
            throw MeetingModelValidationError.invalidTimebase
        }
        try MeetingCaptureConfiguration.validateAudioSource(
            mode: self.mode, scope: self.effectiveApplicationAudioScope, application: self.capturedApplication
        )

        let trackIDs = Set(self.audioTracks.map(\.id))
        guard trackIDs.count == self.audioTracks.count else {
            throw MeetingModelValidationError.duplicateTrackID
        }
        let trackKinds = self.audioTracks.map(\.kind)
        guard Set(trackKinds).count == trackKinds.count else {
            throw MeetingModelValidationError.duplicateTrackKind
        }
        if [.recording, .recordingDegraded, .stopping, .processing, .completed, .interrupted]
            .contains(self.state)
        {
            let expectedKinds: Set<MeetingAudioTrackKind> = self.mode.capturesComputerAudio
                ? [.applicationAudio, .microphone]
                : [.microphone]
            guard Set(trackKinds) == expectedKinds else {
                throw MeetingModelValidationError.invalidTrackSet
            }
        }

        var chunkIDs = Set<MeetingAudioChunkID>()
        for track in self.audioTracks {
            let sequences = track.chunks.map(\.sequence)
            guard sequences == Array(0..<sequences.count) else {
                throw MeetingModelValidationError.invalidChunkSequence
            }
            if let format = track.format,
               format.sampleRate <= 0 || format.channelCount <= 0
            {
                throw MeetingModelValidationError.invalidAudioFormat
            }
            if let firstPresentationTime = track.timebase.firstPresentationTime {
                try Self.validateMediaTime(firstPresentationTime)
            }
            if let lastPresentationTime = track.health.lastPresentationTime {
                try Self.validateMediaTime(lastPresentationTime)
            }
            for chunk in track.chunks {
                guard chunkIDs.insert(chunk.id).inserted else {
                    throw MeetingModelValidationError.duplicateChunkID
                }
                try Self.validateMediaTime(chunk.presentationStart)
                try Self.validateMediaTime(chunk.presentationEnd)
                guard chunk.presentationEnd >= chunk.presentationStart else {
                    throw MeetingModelValidationError.invalidTimeRange
                }
                let pathComponents = URL(fileURLWithPath: chunk.relativeFilePath).pathComponents
                guard !chunk.relativeFilePath.hasPrefix("/"), !pathComponents.contains("..") else {
                    throw MeetingModelValidationError.invalidRelativePath
                }
                for discontinuity in chunk.discontinuities {
                    if let presentationTime = discontinuity.presentationTime {
                        try Self.validateMediaTime(presentationTime)
                    }
                }
                if chunk.finalizationState == .finalized {
                    guard !chunk.sha256.isEmpty, chunk.byteCount > 0 else {
                        throw MeetingModelValidationError.incompleteFinalizedChunk
                    }
                }
            }
        }
        if let firstPresentationTime = self.timebase.firstPresentationTime {
            try Self.validateMediaTime(firstPresentationTime)
        }

        if let origin = self.transcriptPresentationOrigin {
            try Self.validateMediaTime(origin)
            guard self.transcriptTimeDomain == .meetingRelative, origin.seconds >= 0 else { throw MeetingModelValidationError.invalidTimebase }
        }
        try self.validateTranscriptStructure()
        // Historical attempts keep their original request language. Backend capabilities are
        // checked when processing starts; persistence must also read older installed providers.
        for attempt in self.processingAttempts {
            for code in [attempt.languageCode, attempt.retainedTranscriptLanguageCode].compactMap({ $0 }) {
                guard MeetingLanguageCode.isValid(code) else {
                    throw MeetingModelValidationError.unsupportedLanguage
                }
            }
        }
        let completedLanguage = self.processingAttempts.last(where: {
            $0.stage == .completed && $0.completedAt != nil && $0.errorCode == nil && $0.languageCode != nil
        })?.languageCode
        let retainedLanguage = self.processingAttempts.reversed().compactMap(\.retainedTranscriptLanguageCode).first
        if let transcriptLanguage = completedLanguage ?? retainedLanguage, transcriptLanguage != self.languageCode {
            // Older snapshots labeled retained text with the pending request. Let recovery
            // repair that state once instead of making the stored transcript unreadable.
            let latest = self.processingAttempts.last(where: { $0.languageCode != nil })
            let legacyPending = [.processing, .interrupted].contains(self.state)
                && latest?.completedAt == nil && latest?.errorCode == nil
                && latest?.languageCode == self.languageCode && latest?.retainedTranscriptLanguageCode == nil
            guard legacyPending else { throw MeetingModelValidationError.unsupportedLanguage }
        }
    }

    private static func validateMediaTime(_ time: MeetingMediaTime) throws {
        guard time.timescale > 0 else {
            throw MeetingModelValidationError.invalidMediaTimescale
        }
    }
}

nonisolated extension MeetingCaptureConfiguration {
    func validate() throws {
        guard MeetingLanguageCode.isValid(self.languageCode) else {
            throw MeetingModelValidationError.unsupportedLanguage
        }
        guard !self.microphone.captureDeviceID.isEmpty else {
            throw MeetingModelValidationError.missingMicrophone
        }
        try Self.validateAudioSource(
            mode: self.mode, scope: self.effectiveApplicationAudioScope, application: self.application
        )
    }

    static func validateAudioSource(
        mode: MeetingCaptureMode,
        scope: MeetingApplicationAudioScope,
        application: MeetingApplicationIdentity?
    ) throws {
        if mode == .inRoom {
            guard application == nil, scope != .systemAudio else {
                throw MeetingModelValidationError.unexpectedInRoomApplication
            }
        } else if scope == .systemAudio {
            guard application == nil else { throw MeetingModelValidationError.unexpectedSystemAudioApplication }
        } else if application == nil {
            throw MeetingModelValidationError.missingOnlineApplication
        }
    }
}

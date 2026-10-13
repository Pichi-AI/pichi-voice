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
        guard VoiceEngineLanguageCatalog.parakeetV3LanguageIDs.contains(self.languageCode) else {
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
        switch (self.mode, self.capturedApplication) {
        case (.onlineCall, .none):
            throw MeetingModelValidationError.missingOnlineApplication
        case (.inRoom, .some):
            throw MeetingModelValidationError.unexpectedInRoomApplication
        case (.onlineCall, .some), (.inRoom, .none):
            break
        }

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
            let expectedKinds: Set<MeetingAudioTrackKind> = self.mode == .onlineCall
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

        try self.validateTranscriptStructure()
        for attempt in self.processingAttempts {
            if let languageCode = attempt.languageCode,
               languageCode != self.languageCode
            {
                throw MeetingModelValidationError.unsupportedLanguage
            }
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
        guard VoiceEngineLanguageCatalog.parakeetV3LanguageIDs.contains(self.languageCode) else {
            throw MeetingModelValidationError.unsupportedLanguage
        }
        guard !self.microphone.captureDeviceID.isEmpty else {
            throw MeetingModelValidationError.missingMicrophone
        }
        switch (self.mode, self.application) {
        case (.onlineCall, .none):
            throw MeetingModelValidationError.missingOnlineApplication
        case (.inRoom, .some):
            throw MeetingModelValidationError.unexpectedInRoomApplication
        case (.onlineCall, .some), (.inRoom, .none):
            break
        }
    }
}

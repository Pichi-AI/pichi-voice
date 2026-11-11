@preconcurrency import AVFoundation
import Foundation

/// One portable AAC/M4A file. Platforms own destination selection and presentation.
nonisolated enum MeetingAudioExporter {
    private static let publicationLock = NSLock()

    @discardableResult
    static func exportAudioFiles(
        of session: MeetingSession, from sourceDirectory: URL, into destinationFolder: URL,
        copyItem: @escaping @Sendable (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) },
        validatePublication: @escaping @Sendable () throws -> Void = {}
    ) async throws -> URL {
        try await export(of: session, from: sourceDirectory, into: destinationFolder,
                         copyItem: copyItem, validatePublication: validatePublication)
    }

    static func export(
        of session: MeetingSession, from sourceDirectory: URL, into destinationFolder: URL,
        copyItem: @escaping @Sendable (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) },
        validatePublication: @escaping @Sendable () throws -> Void = {}
    ) async throws -> URL {
        try Task.checkCancellation()
        guard !session.isLocalContentConcealed, session.retention.audioDeletedAt == nil, session.hasFinalizedAudio else {
            throw CocoaError(.fileNoSuchFile)
        }
        // Immutable source snapshot; synchronous disk work and encoding stay off the UI actor.
        let worker = Task.detached(priority: .utility) {
            let accessing = destinationFolder.startAccessingSecurityScopedResource()
            defer { if accessing { destinationFolder.stopAccessingSecurityScopedResource() } }
            return try await stageExport(of: session, from: sourceDirectory, into: destinationFolder,
                                         copyItem: copyItem, validatePublication: validatePublication)
        }
        // A synchronous copy may not be interruptible. Always join worker retirement and cleanup.
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    private static func stageExport(
        of session: MeetingSession, from sourceDirectory: URL, into destinationFolder: URL,
        copyItem: (URL, URL) throws -> Void,
        validatePublication: () throws -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        let manager = FileManager.default
        let staging = destinationFolder.appendingPathComponent(".\(UUID().uuidString).export-tmp", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        let composition = AVMutableComposition()
        let origin = MeetingAnalysisManifest.presentationOrigin(of: session)
        guard origin.isFinite else { throw CocoaError(.fileReadCorruptFile) }
        var inserted = false
        var mixParameters: [AVAudioMixInputParameters] = []
        let audibleTracks = session.audioTracks.filter { $0.chunks.contains { $0.finalizationState == .finalized && $0.byteCount > 0 } }
        for track in audibleTracks {
            guard let output = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw CocoaError(.fileReadCorruptFile) }
            var previousEnd = CMTime.zero
            for chunk in track.chunks.sorted(by: { $0.presentationStart < $1.presentationStart })
                where chunk.finalizationState == .finalized && chunk.byteCount > 0 {
                try Task.checkCancellation()
                let hostClock = session.timebase.recordingTimePolicy == .hostMonotonicV1
                let path = hostClock ? chunk.captureAnalysisAsset?.relativeFilePath : MeetingAudioPresentation.relativePlaybackPath(for: chunk)
                guard let path, chunk.presentationStart.timescale > 0, chunk.presentationEnd.timescale > 0,
                      chunk.presentationEnd > chunk.presentationStart else { throw CocoaError(.fileReadCorruptFile) }
                let source = try MeetingChunkPathConfinement.containedURL(sessionDirectory: sourceDirectory, relativePath: path)
                let local = staging.appendingPathComponent(UUID().uuidString).appendingPathExtension(source.pathExtension)
                // Retain a private snapshot so deletion cannot produce a successful partial export.
                try copyItem(source, local)
                try Task.checkCancellation()
                let asset = AVURLAsset(url: local)
                let tracks = try await withTaskCancellationHandler {
                    try await asset.loadTracks(withMediaType: .audio)
                } onCancel: { asset.cancelLoading() }
                guard let input = tracks.first else { throw CocoaError(.fileReadCorruptFile) }
                let available = try await input.load(.timeRange)
                guard available.isValid, available.duration.isNumeric, available.duration > .zero else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                if hostClock {
                    let mapping = try MeetingHostClockMapping.validated(chunk: chunk)
                    let decoded = try AVAudioFile(forReading: local)
                    guard let metadata = chunk.captureAnalysisAsset, let sampleRate = metadata.sampleRate,
                          decoded.length == mapping.frameCount, decoded.processingFormat.sampleRate == sampleRate,
                          Int(decoded.processingFormat.channelCount) == metadata.channelCount else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    for span in mapping.spans {
                        let range = CMTimeRange(start: time(span.frameStart / sampleRate),
                                                duration: time((span.frameEnd - span.frameStart) / sampleRate))
                        try insert(range, of: input, into: output, start: span.hostStart.seconds - origin,
                                   duration: span.hostEnd.seconds - span.hostStart.seconds, previousEnd: &previousEnd)
                    }
                } else {
                    // Legacy sample-clock chunks have no persisted frame mapping. AVFoundation
                    // supplies the actual playable range, including the container's codec trim.
                    try insert(available, of: input, into: output, start: chunk.presentationStart.seconds - origin,
                               duration: chunk.presentationEnd.seconds - chunk.presentationStart.seconds, previousEnd: &previousEnd)
                }
                inserted = true
            }
            let parameters = AVMutableAudioMixInputParameters(track: output)
            // Leave headroom when microphone and system audio speak together.
            parameters.setVolume(1 / Float(audibleTracks.count), at: .zero)
            mixParameters.append(parameters)
        }
        guard inserted, composition.duration > .zero else { throw CocoaError(.fileNoSuchFile) }
        let encoded = staging.appendingPathComponent("audio.m4a")
        guard let encoder = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let mix = AVMutableAudioMix(); mix.inputParameters = mixParameters
        encoder.audioMix = mix
        encoder.shouldOptimizeForNetworkUse = true
        try Task.checkCancellation()
        // The native async API cancels its encoder and waits for the terminal callback.
        try await encoder.export(to: encoded, as: .m4a)
        try Task.checkCancellation()
        try validatePublication()
        try Task.checkCancellation()
        // Only final publication is serialized. Concurrent encoders use distinct private staging.
        return try publicationLock.withLock {
            try validatePublication()
            try Task.checkCancellation()
            let baseName = sanitizedExportName(session.displayTitle)
            while true {
                let name = uniqueExportName(baseName, in: destinationFolder, fileManager: manager)
                let destination = destinationFolder.appendingPathComponent(name)
                do {
                    // Successful move is the commit point. Late cancellation preserves output.
                    try manager.moveItem(at: encoded, to: destination)
                    return destination
                } catch CocoaError.fileWriteFileExists { try Task.checkCancellation() }
            }
        }
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
    }

    private static func insert(_ source: CMTimeRange, of input: AVAssetTrack, into output: AVMutableCompositionTrack,
                               start: Double, duration: Double, previousEnd: inout CMTime) throws {
        guard start.isFinite, duration.isFinite, start >= -0.001, duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let position = time(max(0, start))
        // Inserting an overlapping chunk on the same track would shift the remaining timeline.
        // Permit timestamp quantization only; different tracks are mixed independently.
        guard CMTimeGetSeconds(CMTimeSubtract(previousEnd, position)) <= 0.001 else { throw CocoaError(.fileReadCorruptFile) }
        let target = CMTimeMaximum(position, previousEnd)
        try output.insertTimeRange(source, of: input, at: target)
        output.scaleTimeRange(CMTimeRange(start: target, duration: source.duration), toDuration: time(duration))
        previousEnd = CMTimeAdd(target, time(duration))
    }

    static func sanitizedExportName(_ title: String) -> String {
        // Keep readable names in every supported language, while leaving room for
        // extensions, collision suffixes and the audio export staging suffix.
        let allowed = CharacterSet.letters.union(.decimalDigits).union(.nonBaseCharacters)
            .union(CharacterSet(charactersIn: " _.-"))
        var sanitized = ""
        var byteCount = 0
        for character in title.precomposedStringWithCanonicalMapping {
            let safe = character.unicodeScalars.allSatisfy { allowed.contains($0) } ? String(character) : "-"
            guard sanitized.count < 80, byteCount + safe.utf8.count <= 160 else { break }
            sanitized += safe
            byteCount += safe.utf8.count
        }
        // A path component must never become '.', '..' or a hidden file. The
        // allowlist above replaces slash, backslash, controls and bidi controls.
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return sanitized.isEmpty ? PichiLocalization.text("Meeting") : sanitized
    }

    private static func uniqueExportName(_ baseName: String, in folder: URL, fileManager: FileManager) -> String {
        var candidate = baseName + ".m4a"
        var suffix = 2
        while fileManager.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            candidate = "\(baseName) \(suffix).m4a"
            suffix += 1
        }
        return candidate
    }

}

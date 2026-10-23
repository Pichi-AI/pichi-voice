import Foundation

/// Shared existing audio export operation; platforms choose the destination and presentation.
nonisolated enum MeetingAudioExporter {
    private static let audioExportLock = NSLock()

    static func exportAudioFiles(
        of session: MeetingSession,
        from sourceDirectory: URL,
        into destinationFolder: URL,
        copyItem: @escaping @Sendable (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
    ) async throws {
        _ = try await self.export(of: session, from: sourceDirectory, into: destinationFolder, copyItem: copyItem)
    }

    static func export(
        of session: MeetingSession, from sourceDirectory: URL, into destinationFolder: URL,
        copyItem: @escaping @Sendable (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
    ) async throws -> URL {
        try Task.checkCancellation()
        guard session.retention.audioDeletedAt == nil, session.hasFinalizedAudio else {
            throw CocoaError(.fileNoSuchFile)
        }
        // The session and URLs are immutable snapshots; no view state crosses to the worker.
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let accessing = destinationFolder.startAccessingSecurityScopedResource()
            defer { if accessing { destinationFolder.stopAccessingSecurityScopedResource() } }
            // Preserve the old serial export semantics when users request another export
            // while copying. The lock and all filesystem work stay off the main actor.
            return try Self.audioExportLock.withLock {
                try Self.stageExport(of: session, from: sourceDirectory, into: destinationFolder, copyItem: copyItem)
            }
        }
        // copyItem is synchronous and may not be interruptible. Cancellation reaches
        // the concrete worker, but the caller still joins its retirement and cleanup.
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func stageExport(
        of session: MeetingSession,
        from sourceDirectory: URL,
        into destinationFolder: URL,
        copyItem: (URL, URL) throws -> Void
    ) throws -> URL {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        let baseName = Self.sanitizedExportName(session.displayTitle)
        let name = Self.uniqueExportName(baseName, in: destinationFolder, fileManager: fileManager)
        let stagingDirectory = destinationFolder.appendingPathComponent(".\(name).\(UUID().uuidString).export-tmp", isDirectory: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        do {
            for track in session.audioTracks {
                for chunk in track.chunks where chunk.finalizationState == .finalized && chunk.byteCount > 0 {
                    try Task.checkCancellation()
                    let sourceURL = chunk.fileURL(relativeTo: sourceDirectory).standardizedFileURL
                    let root = sourceDirectory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
                    guard sourceURL.resolvingSymlinksInPath().path.hasPrefix(root) else {
                        throw CocoaError(.fileReadInvalidFileName)
                    }
                    let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
                    let fileName = "\(track.kind.rawValue)-\(String(format: "%03d", chunk.sequence)).\(ext)"
                    try copyItem(sourceURL, stagingDirectory.appendingPathComponent(fileName, isDirectory: false))
                    try Task.checkCancellation()
                }
            }
            try Task.checkCancellation()
            var destinationName = name
            // Publication commits when moveItem successfully returns. Cancellation
            // checks cannot be atomic with a filesystem move: a request racing that
            // move may still commit. Keep committed output and return its URL; never
            // delete a user's published export because cancellation arrived late.
            do {
                try fileManager.moveItem(at: stagingDirectory, to: destinationFolder.appendingPathComponent(destinationName, isDirectory: true))
            } catch CocoaError.fileWriteFileExists {
                // Destination appeared between the uniqueness check and the move; retry once with a fresh name.
                try Task.checkCancellation()
                destinationName = Self.uniqueExportName(baseName, in: destinationFolder, fileManager: fileManager)
                try Task.checkCancellation()
                try fileManager.moveItem(at: stagingDirectory, to: destinationFolder.appendingPathComponent(destinationName, isDirectory: true))
            }
            return destinationFolder.appendingPathComponent(destinationName, isDirectory: true)
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        }
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
        var candidate = baseName
        var suffix = 2
        while fileManager.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            candidate = "\(baseName) \(suffix)"
            suffix += 1
        }
        return candidate
    }

}

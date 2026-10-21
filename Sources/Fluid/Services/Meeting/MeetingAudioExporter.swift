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
        guard session.retention.audioDeletedAt == nil, session.hasFinalizedAudio else {
            throw CocoaError(.fileNoSuchFile)
        }
        // The session and URLs are immutable snapshots; no view state crosses to the worker.
        return try await Task.detached(priority: .utility) {
            let accessing = destinationFolder.startAccessingSecurityScopedResource()
            defer { if accessing { destinationFolder.stopAccessingSecurityScopedResource() } }
            // Preserve the old serial export semantics when users request another export
            // while copying. The lock and all filesystem work stay off the main actor.
            return try Self.audioExportLock.withLock {
                try Self.stageExport(of: session, from: sourceDirectory, into: destinationFolder, copyItem: copyItem)
            }
        }.value
    }

    private static func stageExport(
        of session: MeetingSession,
        from sourceDirectory: URL,
        into destinationFolder: URL,
        copyItem: (URL, URL) throws -> Void
    ) throws -> URL {
        let fileManager = FileManager.default
        let baseName = Self.sanitizedExportName(session.displayTitle)
        let name = Self.uniqueExportName(baseName, in: destinationFolder, fileManager: fileManager)
        let stagingDirectory = destinationFolder.appendingPathComponent(".\(name).\(UUID().uuidString).export-tmp", isDirectory: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        do {
            for track in session.audioTracks {
                for chunk in track.chunks where chunk.finalizationState == .finalized && chunk.byteCount > 0 {
                    let sourceURL = chunk.fileURL(relativeTo: sourceDirectory).standardizedFileURL
                    let root = sourceDirectory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
                    guard sourceURL.resolvingSymlinksInPath().path.hasPrefix(root) else {
                        throw CocoaError(.fileReadInvalidFileName)
                    }
                    let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
                    let fileName = "\(track.kind.rawValue)-\(String(format: "%03d", chunk.sequence)).\(ext)"
                    try copyItem(sourceURL, stagingDirectory.appendingPathComponent(fileName, isDirectory: false))
                }
            }
            var destinationName = name
            do {
                try fileManager.moveItem(at: stagingDirectory, to: destinationFolder.appendingPathComponent(destinationName, isDirectory: true))
            } catch CocoaError.fileWriteFileExists {
                // Destination appeared between the uniqueness check and the move; retry once with a fresh name.
                destinationName = Self.uniqueExportName(baseName, in: destinationFolder, fileManager: fileManager)
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

import Foundation
import UniformTypeIdentifiers

/// One transient, read-only document lease. QuickLook reads the original URL;
/// it is never copied into meeting storage, bookmarked, renamed or deleted.
final class MobilePresentationDocument {
    let url: URL
    private let releaseAccess: (() -> Void)?

    init(url: URL,
         startAccess: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stopAccess: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() },
         isReadablePDF: (URL) throws -> Bool = { url in
             let values = try url.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey, .isReadableKey])
             return values.isRegularFile == true && values.isReadable == true
                 && values.contentType?.conforms(to: .pdf) == true
         }) throws {
        let scoped = startAccess(url)
        do {
            guard url.isFileURL, try isReadablePDF(url) else { throw CocoaError(.fileReadCorruptFile) }
        } catch {
            if scoped { stopAccess(url) }
            throw error
        }
        self.url = url
        self.releaseAccess = scoped ? { stopAccess(url) } : nil
    }

    deinit { releaseAccess?() }
}

import Foundation
import PDFKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One transient, read-only document lease. PDFKit reads the original URL;
/// it is never copied into meeting storage, bookmarked, renamed or deleted.
final class MobilePresentationDocument: Identifiable {
    let id = UUID()
    let url: URL
    let pdf: PDFDocument
    private let releaseAccess: (() -> Void)?

    init(url: URL,
         startAccess: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stopAccess: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() },
         isReadablePDF: (URL) throws -> Bool = { url in
             let values = try url.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey, .isReadableKey])
             return values.isRegularFile == true && values.isReadable == true
                 && values.contentType?.conforms(to: .pdf) == true
         },
         loadPDF: (URL) -> PDFDocument? = { PDFDocument(url: $0) }) throws {
        let scoped = startAccess(url)
        do {
            guard url.isFileURL, try isReadablePDF(url),
                  let pdf = loadPDF(url), !pdf.isLocked, pdf.pageCount > 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            self.pdf = pdf
        } catch {
            if scoped { stopAccess(url) }
            throw error
        }
        self.url = url
        self.releaseAccess = scoped ? { stopAccess(url) } : nil
    }

    deinit { releaseAccess?() }
}

/// Multiple presentation windows share the process idle timer. Only the last
/// recording presentation restores its previous value; closing another window
/// cannot turn the timer back on underneath a recording presentation.
@MainActor
final class MobilePresentationAwakeRegistry {
    static let shared = MobilePresentationAwakeRegistry(
        getDisabled: { UIApplication.shared.isIdleTimerDisabled },
        setDisabled: { UIApplication.shared.isIdleTimerDisabled = $0 })

    private let getDisabled: () -> Bool
    private let setDisabled: (Bool) -> Void
    private var owners = Set<UUID>()
    private var previousValue: Bool?

    init(getDisabled: @escaping () -> Bool, setDisabled: @escaping (Bool) -> Void) {
        self.getDisabled = getDisabled
        self.setDisabled = setDisabled
    }

    func acquire() -> UUID {
        if owners.isEmpty {
            previousValue = getDisabled()
            setDisabled(true)
        }
        let token = UUID()
        owners.insert(token)
        return token
    }

    func release(_ token: UUID) {
        guard owners.remove(token) != nil, owners.isEmpty else { return }
        if let previousValue { setDisabled(previousValue) }
        previousValue = nil
    }
}

/// The native view owns the file and screen leases until dismantle, including
/// dismissal animation. Streaming view updates never reload the PDF document.
struct MobilePresentationPDFView: UIViewRepresentable {
    let document: MobilePresentationDocument
    let isRecording: Bool

    @MainActor
    final class Coordinator {
        private(set) var document: MobilePresentationDocument?
        private let awake: MobilePresentationAwakeRegistry
        private var awakeToken: UUID?

        init(document: MobilePresentationDocument, awake: MobilePresentationAwakeRegistry? = nil) {
            self.document = document
            self.awake = awake ?? .shared
        }

        func update(isRecording: Bool) {
            if isRecording && document != nil && awakeToken == nil { awakeToken = awake.acquire() }
            else if !isRecording, let token = awakeToken {
                awakeToken = nil
                awake.release(token)
            }
        }

        func finish() {
            update(isRecording: false)
            document = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(document: document) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document.pdf
        context.coordinator.update(isRecording: isRecording)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.update(isRecording: isRecording)
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        view.document = nil
        coordinator.finish()
    }
}

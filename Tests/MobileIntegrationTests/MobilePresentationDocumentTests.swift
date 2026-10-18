import Foundation
import PDFKit
import UIKit
import XCTest
@testable import PichiVoiceMobile

@MainActor
final class MobilePresentationDocumentTests: XCTestCase {
    private func stubPDF() -> PDFDocument {
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        return document
    }

    func testAccessRemainsOwnedUntilThePreviewLeaseIsReleased() throws {
        let url = URL(fileURLWithPath: "/synthetic.pdf")
        var acquired: [URL] = [], released: [URL] = []
        var preview: MobilePresentationDocument? = try MobilePresentationDocument(url: url,
            startAccess: { acquired.append($0); return true },
            stopAccess: { released.append($0) }, isReadablePDF: { _ in true }, loadPDF: { _ in self.stubPDF() })
        XCTAssertEqual(acquired, [url])
        XCTAssertEqual(preview?.url, url)
        XCTAssertTrue(released.isEmpty)
        preview = nil
        XCTAssertEqual(released, [url])
    }

    func testInvalidAndUnreadableDocumentsReleaseAcquiredAccess() {
        let url = URL(fileURLWithPath: "/synthetic.txt")
        var releases = 0
        XCTAssertThrowsError(try MobilePresentationDocument(url: url,
            startAccess: { _ in true }, stopAccess: { _ in releases += 1 },
            isReadablePDF: { _ in false }))
        XCTAssertEqual(releases, 1)
        XCTAssertThrowsError(try MobilePresentationDocument(url: url,
            startAccess: { _ in true }, stopAccess: { _ in releases += 1 },
            isReadablePDF: { _ in throw CocoaError(.fileReadNoPermission) }))
        XCTAssertEqual(releases, 2)
    }

    func testReadableLocalDocumentDoesNotRequireASecurityScope() throws {
        var releases = 0
        var preview: MobilePresentationDocument? = try MobilePresentationDocument(
            url: URL(fileURLWithPath: "/synthetic.pdf"), startAccess: { _ in false },
            stopAccess: { _ in releases += 1 }, isReadablePDF: { _ in true }, loadPDF: { _ in self.stubPDF() })
        XCTAssertNotNil(preview)
        preview = nil
        XCTAssertEqual(releases, 0)
    }

    func testPreviewNeverChangesTheSelectedSourceFile() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-\(UUID()).pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400))
        let bytes = renderer.pdfData { context in
            context.beginPage()
            ("Synthetic page 1" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: nil)
            context.beginPage()
            ("Synthetic page 2" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: nil)
        }
        try bytes.write(to: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }
        var preview: MobilePresentationDocument? = try MobilePresentationDocument(url: fixture)
        XCTAssertEqual(preview?.url, fixture)
        XCTAssertEqual(preview?.pdf.pageCount, 2)
        preview = nil
        XCTAssertEqual(try Data(contentsOf: fixture), bytes)
    }

    func testMalformedAndEmptyPDFReleaseTheScope() {
        let url = URL(fileURLWithPath: "/synthetic.pdf")
        var releases = 0
        for loader: (URL) -> PDFDocument? in [{ _ in nil }, { _ in PDFDocument() }] {
            XCTAssertThrowsError(try MobilePresentationDocument(url: url,
                startAccess: { _ in true }, stopAccess: { _ in releases += 1 },
                isReadablePDF: { _ in true }, loadPDF: loader))
        }
        XCTAssertEqual(releases, 2)
    }

    func testNativeViewerRetainsOneLoadedDocumentUntilDismantle() throws {
        var loads = 0, releases = 0, disabled = false
        let awake = MobilePresentationAwakeRegistry(getDisabled: { disabled }, setDisabled: { disabled = $0 })
        var document: MobilePresentationDocument? = try MobilePresentationDocument(
            url: URL(fileURLWithPath: "/synthetic.pdf"), startAccess: { _ in true },
            stopAccess: { _ in releases += 1 }, isReadablePDF: { _ in true },
            loadPDF: { _ in loads += 1; return self.stubPDF() })
        let coordinator = MobilePresentationPDFView.Coordinator(document: try XCTUnwrap(document), awake: awake)
        let view = PDFView()
        view.document = document?.pdf
        document = nil
        for _ in 0..<100 { coordinator.update(isRecording: true) }
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(releases, 0)
        XCTAssertTrue(disabled)
        MobilePresentationPDFView.dismantleUIView(view, coordinator: coordinator)
        XCTAssertNil(view.document)
        XCTAssertNil(coordinator.document)
        XCTAssertEqual(releases, 1)
        XCTAssertFalse(disabled)
        coordinator.finish()
        coordinator.update(isRecording: true)
        XCTAssertFalse(disabled)
        XCTAssertEqual(releases, 1)
    }

    func testMultipleRecordingWindowsRestoreOnlyAfterLastRelease() {
        var disabled = false, writes: [Bool] = []
        let awake = MobilePresentationAwakeRegistry(getDisabled: { disabled }, setDisabled: {
            disabled = $0; writes.append($0)
        })
        let first = awake.acquire(), second = awake.acquire()
        XCTAssertEqual(writes, [true])
        awake.release(first)
        awake.release(first)
        XCTAssertTrue(disabled)
        awake.release(second)
        XCTAssertFalse(disabled)
        XCTAssertEqual(writes, [true, false])
    }

    func testInitiallyDisabledIdleTimerIsPreservedAcrossStopAndCancel() throws {
        var disabled = true, writes: [Bool] = []
        let awake = MobilePresentationAwakeRegistry(getDisabled: { disabled }, setDisabled: {
            disabled = $0; writes.append($0)
        })
        let document = try MobilePresentationDocument(url: URL(fileURLWithPath: "/synthetic.pdf"),
            startAccess: { _ in false }, isReadablePDF: { _ in true }, loadPDF: { _ in self.stubPDF() })
        let coordinator = MobilePresentationPDFView.Coordinator(document: document, awake: awake)
        coordinator.update(isRecording: false)
        XCTAssertTrue(writes.isEmpty)
        coordinator.update(isRecording: true)
        coordinator.update(isRecording: false)
        XCTAssertTrue(disabled)
        coordinator.update(isRecording: true)
        coordinator.finish()
        XCTAssertTrue(disabled)
        XCTAssertEqual(writes, [true, true, true, true])
    }
}

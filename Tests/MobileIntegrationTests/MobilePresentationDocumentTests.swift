import Foundation
import XCTest
@testable import PichiVoiceMobile

final class MobilePresentationDocumentTests: XCTestCase {
    func testAccessRemainsOwnedUntilThePreviewLeaseIsReleased() throws {
        let url = URL(fileURLWithPath: "/synthetic.pdf")
        var acquired: [URL] = [], released: [URL] = []
        var preview: MobilePresentationDocument? = try MobilePresentationDocument(url: url,
            startAccess: { acquired.append($0); return true },
            stopAccess: { released.append($0) }, isReadablePDF: { _ in true })
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
            stopAccess: { _ in releases += 1 }, isReadablePDF: { _ in true })
        XCTAssertNotNil(preview)
        preview = nil
        XCTAssertEqual(releases, 0)
    }

    func testPreviewNeverChangesTheSelectedSourceFile() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-\(UUID()).pdf")
        let bytes = Data("%PDF-1.4\n% synthetic read-only ownership fixture\n%%EOF\n".utf8)
        try bytes.write(to: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }
        var preview: MobilePresentationDocument? = try MobilePresentationDocument(url: fixture)
        XCTAssertEqual(preview?.url, fixture)
        preview = nil
        XCTAssertEqual(try Data(contentsOf: fixture), bytes)
    }
}

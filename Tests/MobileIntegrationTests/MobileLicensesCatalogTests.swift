import Foundation
@testable import PichiVoiceMobile
import XCTest

final class MobileLicensesCatalogTests: XCTestCase {
    func testPackagedCatalogLoadsEveryReferencedNoticeOffline() throws {
        let catalog = try MobileLicensesCatalog.load()
        let documents = catalog.groups.flatMap(\.components).flatMap(\.documents)
        XCTAssertFalse(documents.isEmpty)
        for document in documents {
            XCTAssertFalse(try MobileLicensesCatalog.text(for: document).isEmpty, document.file)
        }
    }

    func testValidCatalogKeepsDisplayMetadataAndSharedDocumentText() throws {
        let text = "Copyright Ёлка\n\nSynthetic license.\n"
        let document = self.document("Shared.txt")
        let catalog = try self.catalog(groups: [self.group(components: [
            self.component(id: "first", documents: [document]),
            self.component(id: "second", documents: [document])
        ])])
        try self.withBundle(catalog: catalog, notices: ["Shared.txt": Data(text.utf8)]) { bundle in
            let loaded = try MobileLicensesCatalog.load(bundle: bundle)
            XCTAssertEqual(loaded.groups.map(\.id), ["synthetic"])
            XCTAssertEqual(loaded.groups.first?.footerKey, "Synthetic footer")
            let components = try XCTUnwrap(loaded.groups.first?.components)
            XCTAssertEqual(components.map(\.id), ["first", "second"])
            XCTAssertEqual(components.first?.name, "Synthetic component")
            XCTAssertEqual(components.first?.license, "MIT")
            for item in components {
                let shared = try XCTUnwrap(item.documents.first)
                XCTAssertEqual(shared.id, "Shared.txt")
                XCTAssertEqual(try MobileLicensesCatalog.text(for: shared, bundle: bundle), text)
            }
        }
    }

    func testMalformedJSONAndUnsupportedCatalogVersionAreRejected() throws {
        try self.withBundle(catalog: Data("{ broken".utf8)) { bundle in
            XCTAssertThrowsError(try MobileLicensesCatalog.load(bundle: bundle)) { error in
                XCTAssertTrue(error is DecodingError)
            }
        }
        for version in [0, 2] {
            try self.withBundle(catalog: try self.catalog(version: version)) { bundle in
                self.assertReadError(.invalidCatalog) { try MobileLicensesCatalog.load(bundle: bundle) }
            }
        }
    }

    func testDuplicateGroupComponentAndDocumentIdentitiesAreRejected() throws {
        let component = self.component()
        let group = self.group(components: [component])
        let cases = [
            try self.catalog(groups: [group, group]),
            try self.catalog(groups: [group, self.group(id: "another", components: [component])]),
            try self.catalog(groups: [self.group(components: [self.component(documents: [self.document(), self.document()])])])
        ]
        for catalog in cases {
            try self.withBundle(catalog: catalog) { bundle in
                self.assertReadError(.invalidCatalog) { try MobileLicensesCatalog.load(bundle: bundle) }
            }
        }
    }

    func testEmptyCollectionsAndRequiredDisplayFieldsAreRejected() throws {
        let cases = [
            try self.catalog(groups: []),
            try self.catalog(groups: [self.group(components: [])]),
            try self.catalog(groups: [self.group(id: "")]),
            try self.catalog(groups: [self.group(title: "")]),
            try self.catalog(groups: [self.group(components: [self.component(id: "")])]),
            try self.catalog(groups: [self.group(components: [self.component(name: "")])]),
            try self.catalog(groups: [self.group(components: [self.component(license: "")])]),
            try self.catalog(groups: [self.group(components: [self.component(documents: [])])]),
            try self.catalog(groups: [self.group(components: [self.component(documents: [self.document(title: "")])])])
        ]
        for catalog in cases {
            try self.withBundle(catalog: catalog) { bundle in
                self.assertReadError(.invalidCatalog) { try MobileLicensesCatalog.load(bundle: bundle) }
            }
        }
    }

    func testCatalogCollectionBoundsRejectOversizedStructures() throws {
        let cases = [
            try self.catalog(groups: (0..<17).map { self.group(id: "group-\($0)", components: [self.component(id: "component-\($0)")]) }),
            try self.catalog(groups: [self.group(components: (0..<129).map { self.component(id: "component-\($0)") })]),
            try self.catalog(groups: [self.group(components: [self.component(documents: (0..<17).map { self.document("Notice-\($0).txt") })])])
        ]
        for catalog in cases {
            try self.withBundle(catalog: catalog) { bundle in
                self.assertReadError(.invalidCatalog) { try MobileLicensesCatalog.load(bundle: bundle) }
            }
        }
    }

    func testCatalogRejectsTraversalControlCharactersAndOverlongFilenames() throws {
        let filenames = ["", ".", "..", "../Outside.txt", "Notices/License.txt", "folder\\License.txt",
                         "line\nLicense.txt", String(repeating: "я", count: 81)]
        for filename in filenames {
            let catalog = try self.catalog(groups: [self.group(components: [self.component(documents: [self.document(filename)])])])
            try self.withBundle(catalog: catalog) { bundle in
                self.assertReadError(.invalidCatalog) { try MobileLicensesCatalog.load(bundle: bundle) }
            }
        }
    }

    func testCatalogByteLimitAcceptsExactBoundaryAndRejectsOneExtraByte() throws {
        var catalog = try self.catalog()
        catalog.append(Data(repeating: 0x20, count: 65_536 - catalog.count))
        try self.withBundle(catalog: catalog) { bundle in
            XCTAssertEqual(try MobileLicensesCatalog.load(bundle: bundle).formatVersion, 1)
        }
        catalog.append(0x20)
        try self.withBundle(catalog: catalog) { bundle in
            self.assertReadError(.invalidText) { try MobileLicensesCatalog.load(bundle: bundle) }
        }
    }

    func testMissingCatalogMissingDocumentAndTraversalReadAreRejected() throws {
        try self.withBundle(catalog: nil) { bundle in
            self.assertReadError(.missingDocument) { try MobileLicensesCatalog.load(bundle: bundle) }
            self.assertReadError(.missingDocument) {
                try MobileLicensesCatalog.text(for: .init(titleKey: "License", file: "Absent.txt"), bundle: bundle)
            }
            try Data("Must not escape Notices".utf8).write(to: bundle.bundleURL.appendingPathComponent("Outside.txt"))
            self.assertReadError(.missingDocument) {
                try MobileLicensesCatalog.text(for: .init(titleKey: "License", file: "../Outside.txt"), bundle: bundle)
            }
        }
    }

    func testDocumentByteLimitAcceptsExactBoundaryAndRejectsOneExtraByte() throws {
        let document = MobileLicensesCatalog.Document(titleKey: "License", file: "Limit.txt")
        for count in [262_144, 262_145] {
            try self.withBundle(catalog: try self.catalog(), notices: [document.file: Data(repeating: 0x61, count: count)]) { bundle in
                if count == 262_144 {
                    XCTAssertEqual(try MobileLicensesCatalog.text(for: document, bundle: bundle), String(repeating: "a", count: count))
                } else {
                    self.assertReadError(.invalidText) { try MobileLicensesCatalog.text(for: document, bundle: bundle) }
                }
            }
        }
    }

    func testEmptyAndInvalidUTF8DocumentsAreRejected() throws {
        let document = MobileLicensesCatalog.Document(titleKey: "License", file: "Invalid.txt")
        for bytes in [Data(), Data([0xC3, 0x28])] {
            try self.withBundle(catalog: try self.catalog(), notices: [document.file: bytes]) { bundle in
                self.assertReadError(.invalidText) { try MobileLicensesCatalog.text(for: document, bundle: bundle) }
            }
        }
    }

    // All resource fixtures are synthetic and live only for this test invocation.
    private func withBundle(catalog: Data?, notices: [String: Data] = [:], body: (Bundle) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MobileLicenses-\(UUID().uuidString).bundle")
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Notices", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "ai.example.synthetic.licenses.\(UUID().uuidString)",
                    "CFBundlePackageType": "BNDL", "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Info.plist"))
        if let catalog { try catalog.write(to: resources.appendingPathComponent("MobileLicenses.json")) }
        for (filename, bytes) in notices { try bytes.write(to: resources.appendingPathComponent(filename)) }
        try body(XCTUnwrap(Bundle(url: root)))
    }

    private func catalog(version: Int = 1, groups: [[String: Any]]? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["formatVersion": version, "groups": groups ?? [self.group()]])
    }

    private func group(id: String = "synthetic", title: String = "Synthetic group",
                       components: [[String: Any]]? = nil) -> [String: Any] {
        ["id": id, "titleKey": title, "footerKey": "Synthetic footer", "components": components ?? [self.component()]]
    }

    private func component(id: String = "component", name: String = "Synthetic component", license: String = "MIT",
                           documents: [[String: String]]? = nil) -> [String: Any] {
        ["id": id, "name": name, "license": license, "documents": documents ?? [self.document()]]
    }

    private func document(_ filename: String = "License.txt", title: String = "License") -> [String: String] {
        ["titleKey": title, "file": filename]
    }

    private func assertReadError<T>(_ expected: MobileLicensesCatalog.ReadError, file: StaticString = #filePath,
                                    line: UInt = #line, operation: () throws -> T) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            switch (error as? MobileLicensesCatalog.ReadError, expected) {
            case (.invalidCatalog?, .invalidCatalog), (.missingDocument?, .missingDocument), (.invalidText?, .invalidText): break
            default: XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
        }
    }
}

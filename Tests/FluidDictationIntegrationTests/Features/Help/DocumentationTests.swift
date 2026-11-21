import XCTest
@testable import FluidVoice_Debug

@MainActor
final class DocumentationTests: XCTestCase {
    func testDocumentationFallsBackFromRegionalToBaseThenDefaultThenBrandWebsite() {
        var package = BrandPackage(profile: .neutral, links: BrandLinks(documentation: [
            "default": "https://example.org/guide", "fr": "https://example.org/fr/guide",
            "fr-CA": "https://example.org/ca/guide",
        ]))
        XCTAssertEqual(package.documentationURL(for: Locale(identifier: "fr-CA"))?.path, "/ca/guide")
        XCTAssertEqual(package.documentationURL(for: Locale(identifier: "fr-FR"))?.path, "/fr/guide")
        XCTAssertEqual(package.documentationURL(for: Locale(identifier: "ru"))?.path, "/guide")
        package.links = nil
        XCTAssertEqual(package.documentationURL(for: Locale(identifier: "en"))?.absoluteString, package.profile.website)
    }

    func testImportedDocumentationURLsUseTheSameHTTPSValidationAsPublicBrandLinks() {
        for url in ["http://example.org/docs", "https://user@example.org/docs"] {
            let package = BrandPackage(profile: .neutral, links: BrandLinks(documentation: ["en": url]))
            XCTAssertThrowsError(try package.validate())
        }
    }

    func testMenuActionOpensTheShippedGuideForTheCurrentInterfaceLanguage() {
        var opened: [URL] = []
        for language in [PichiInterfaceLanguage.english, .russian] {
            MenuBarManager.openHelpDocumentation(package: AppBrand.packagedPackage, language: language) {
                opened.append($0)
                return true
            }
        }
        XCTAssertEqual(opened.map(\.absoluteString), [
            "https://pichi.ai/voice/docs/", "https://pichi.ai/ru/voice/docs/",
        ])
    }
}

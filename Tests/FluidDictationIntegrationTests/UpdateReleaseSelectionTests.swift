@testable import FluidVoice_Debug
import Foundation
import XCTest

final nonisolated class UpdateReleaseSelectionTests: XCTestCase {
    func testPublicTagPinsMarketingVersionNumericBuildAndExactDMG() throws {
        let release = try decode()
        let selection = try XCTUnwrap(UpdateReleaseSelection.pichi(release, owner: "Pichi-AI", repo: "pichi-voice"))
        XCTAssertEqual(selection.tag, "v0.1.0+71-public.1")
        XCTAssertEqual(selection.version, "0.1.0")
        XCTAssertEqual(selection.build, "71")
        XCTAssertEqual(selection.displayVersion, "0.1.0 (71)")
        XCTAssertEqual(selection.assetName, "Pichi-Voice-0.1.0-71-macos-arm64.dmg")
    }

    func testDraftRuntimeWrongNameWrongRepositoryWrongTagAndDuplicateAssetAreRejected() throws {
        for overrides: [String: Any] in [
            ["draft": true], ["tag_name": "runtime-v0.1.0"],
            ["assetName": "Pichi-Voice-0.1.0-71-macos-arm64.zip"],
            ["downloadURL": "https://github.com/attacker/pichi-voice/releases/download/v0.1.0+71-public.1/Pichi-Voice-0.1.0-71-macos-arm64.dmg"],
            ["downloadURL": "https://github.com/Pichi-AI/pichi-voice/releases/download/v0.1.0+72-public.1/Pichi-Voice-0.1.0-71-macos-arm64.dmg"],
            ["duplicate": true], ["size": UpdateDownload.maximumBytes + 1],
        ] {
            XCTAssertNil(UpdateReleaseSelection.pichi(try decode(overrides), owner: "Pichi-AI", repo: "pichi-voice"), "\(overrides)")
        }
    }

    func testEncodedTagURLPreservesExactSelectionAndRejectsQueries() throws {
        let url = "https://github.com/Pichi-AI/pichi-voice/releases/download/v0.1.0%2B71-public.1/Pichi-Voice-0.1.0-71-macos-arm64.dmg"
        XCTAssertNotNil(UpdateReleaseSelection.pichi(try decode(["downloadURL": url]), owner: "Pichi-AI", repo: "pichi-voice"))
        XCTAssertNil(UpdateReleaseSelection.pichi(try decode(["downloadURL": url + "?other=artifact"]), owner: "Pichi-AI", repo: "pichi-voice"))
    }

    func testBuildOrderingPreservesSameMarketingVersionRollbacks() {
        XCTAssertTrue(UpdateReleaseSelection.isOlder(version: "0.1.0", build: "69", than: "0.1.0", build: "71"))
        XCTAssertTrue(UpdateReleaseSelection.isOlder(version: "0.1.0", build: "9", than: "0.1.0", build: "10"))
        XCTAssertFalse(UpdateReleaseSelection.isOlder(version: "0.1.0", build: "71", than: "0.1.0", build: "71"))
        XCTAssertFalse(UpdateReleaseSelection.isOlder(version: "0.2.0", build: "1", than: "0.1.0", build: "71"))
        XCTAssertNil(UpdateReleaseSelection.pichiVersion("v0.1.0+runtime-public.1"))
    }

    private func decode(_ overrides: [String: Any] = [:]) throws -> GHRelease {
        var asset: [String: Any] = [
            "name": overrides["assetName"] ?? "Pichi-Voice-0.1.0-71-macos-arm64.dmg",
            "content_type": "application/x-apple-diskimage",
            "browser_download_url": overrides["downloadURL"] ?? "https://github.com/Pichi-AI/pichi-voice/releases/download/v0.1.0+71-public.1/Pichi-Voice-0.1.0-71-macos-arm64.dmg",
        ]
        if let size = overrides["size"] { asset["size"] = size }
        let release: [String: Any] = [
            "tag_name": overrides["tag_name"] ?? "v0.1.0+71-public.1", "prerelease": false,
            "draft": overrides["draft"] ?? false,
            "assets": overrides["duplicate"] as? Bool == true ? [asset, asset] : [asset],
        ]
        return try JSONDecoder().decode(GHRelease.self, from: JSONSerialization.data(withJSONObject: release))
    }
}

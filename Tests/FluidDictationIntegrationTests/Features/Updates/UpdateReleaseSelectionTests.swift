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
        XCTAssertEqual(selection.displayVersion, "0.1.0")
        XCTAssertEqual(selection.assetName, "Pichi-Voice.dmg")
    }

    func testNormalVersionTagsAndPrereleasesUseTheCanonicalProductAsset() throws {
        for tag in ["v0.2.0", "v0.2.1", "v0.3.0-beta.2", "v1.0.0-rc.1"] {
            let selection = try XCTUnwrap(UpdateReleaseSelection.pichi(try decode(["tag_name": tag]), owner: "Pichi-AI", repo: "pichi-voice"))
            XCTAssertNil(selection.build)
            XCTAssertEqual(selection.expectedBundleReleaseTag, tag)
            XCTAssertEqual(selection.displayVersion, String(tag.dropFirst()))
            XCTAssertEqual(selection.version, String(tag.dropFirst().split(separator: "-")[0]))
            let oldName = "Pichi-Voice-0.2.0-73-macos-arm64.dmg"
            XCTAssertNil(UpdateReleaseSelection.pichi(try decode(["tag_name": tag, "assetName": oldName,
                "downloadURL": "https://github.com/Pichi-AI/pichi-voice/releases/download/\(tag)/\(oldName)"]), owner: "Pichi-AI", repo: "pichi-voice"))
        }
        for tag in ["v00.2.0", "v0.02.0", "v0.2", "v0.2.0-beta.01", "v0.2.0+unbound", "v0.2.0/other"] {
            XCTAssertNil(UpdateReleaseSelection.pichiVersion(tag), tag)
        }
    }

    func testFriendlyLabelsKeepDifferentApprovedBuildSelectionsDistinct() throws {
        let first = try XCTUnwrap(UpdateReleaseSelection.pichi(try decode(["tag_name": "v0.2.0+73-public.1"]), owner: "Pichi-AI", repo: "pichi-voice"))
        let changed = try XCTUnwrap(UpdateReleaseSelection.pichi(try decode(["tag_name": "v0.2.0+74-public.1"]), owner: "Pichi-AI", repo: "pichi-voice"))
        XCTAssertEqual(first.displayVersion, "0.2.0")
        XCTAssertEqual(first.displayVersion, changed.displayVersion)
        XCTAssertNotEqual(first, changed)
        XCTAssertNotEqual(first.build, changed.build)
        XCTAssertNil(first.expectedBundleReleaseTag, "Historical bundles have no signed release-tag field")
        XCTAssertEqual(UpdateReleaseSelection.displayVersion(version: "0.3.0", tag: "v0.3.0-beta.2"), "0.3.0-beta.2")
        XCTAssertEqual(UpdateReleaseSelection.displayVersion(version: "0.2.0", tag: "v0.3.0-beta.2"), "0.2.0")
    }

    func testDraftRuntimeWrongNameWrongRepositoryWrongTagAndDuplicateAssetAreRejected() throws {
        for overrides: [String: Any] in [
            ["draft": true], ["tag_name": "runtime-v0.1.0"],
            ["assetName": "Pichi-Voice.zip"],
            ["downloadURL": "https://github.com/attacker/pichi-voice/releases/download/v0.1.0+71-public.1/Pichi-Voice.dmg"],
            ["downloadURL": "https://github.com/Pichi-AI/pichi-voice/releases/download/v0.1.0+72-public.1/Pichi-Voice.dmg"],
            ["duplicate": true], ["size": UpdateDownload.maximumBytes + 1],
        ] {
            XCTAssertNil(UpdateReleaseSelection.pichi(try decode(overrides), owner: "Pichi-AI", repo: "pichi-voice"), "\(overrides)")
        }
    }

    func testEncodedTagURLPreservesExactSelectionAndRejectsQueries() throws {
        let url = "https://github.com/Pichi-AI/pichi-voice/releases/download/v0.1.0%2B71-public.1/Pichi-Voice.dmg"
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

    func testHistoricalVersionedDMGRemainsSelectableWithoutRenamingPublishedAssets() throws {
        let name = "Pichi-Voice-0.1.0-71-macos-arm64.dmg"
        let release = try decode(["assetName": name,
            "downloadURL": "https://github.com/Pichi-AI/pichi-voice/releases/download/v0.1.0+71-public.1/" + name])
        XCTAssertEqual(UpdateReleaseSelection.pichi(release, owner: "Pichi-AI", repo: "pichi-voice")?.assetName, name)
    }

    func testInvalidCanonicalAssetCannotSilentlyFallBackToALegacyAsset() throws {
        let invalid = try decode(["downloadURL": "https://github.com/attacker/pichi-voice/releases/download/v0.1.0+71-public.1/Pichi-Voice.dmg"])
        let legacyName = "Pichi-Voice-0.1.0-71-macos-arm64.dmg"
        let legacy = try decode(["assetName": legacyName,
            "downloadURL": "https://github.com/Pichi-AI/pichi-voice/releases/download/v0.1.0+71-public.1/" + legacyName])
        let body: [String: Any] = ["tag_name": invalid.tag_name, "prerelease": false,
            "assets": (invalid.assets + legacy.assets).map {
                ["name": $0.name, "browser_download_url": $0.browser_download_url.absoluteString, "content_type": $0.content_type]
            }]
        let release = try JSONDecoder().decode(GHRelease.self, from: JSONSerialization.data(withJSONObject: body))
        XCTAssertNil(UpdateReleaseSelection.pichi(release, owner: "Pichi-AI", repo: "pichi-voice"))
    }

    private func decode(_ overrides: [String: Any] = [:]) throws -> GHRelease {
        let tag = overrides["tag_name"] as? String ?? "v0.1.0+71-public.1"
        var asset: [String: Any] = [
            "name": overrides["assetName"] ?? "Pichi-Voice.dmg",
            "content_type": "application/x-apple-diskimage",
            "browser_download_url": overrides["downloadURL"] ?? "https://github.com/Pichi-AI/pichi-voice/releases/download/\(tag)/Pichi-Voice.dmg",
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

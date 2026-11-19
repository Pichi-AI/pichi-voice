import Foundation
import XCTest
@testable import FluidVoice_Debug

final class MacUpdateDistributionTests: XCTestCase {
    func testPackagedMacPolicySelectsPublicRepositoryAndSigningTeam() throws {
        let bundle = Bundle.main
        let policy = BrandDistribution.load(bundle: bundle)
        try policy.validate()
        XCTAssertTrue(policy.updatesEnabled)
        XCTAssertEqual(policy.repositoryOwner, "Pichi-AI")
        XCTAssertEqual(policy.repositoryName, "pichi-voice")
        XCTAssertEqual(policy.expectedSigningTeam, "LU46F7HGJM")
    }

    func testAnEnabledFeedRequiresExplicitSigningTrust() {
        XCTAssertThrowsError(try BrandDistribution(
            formatVersion: 1, repository: "https://github.com/Pichi-AI/pichi-voice",
            updatesEnabled: true
        ).validate())
        XCTAssertThrowsError(try BrandDistribution(
            formatVersion: 1, updatesEnabled: true, expectedSigningTeam: "LU46F7HGJM"
        ).validate())
    }

    func testUntrustedAndUnsignedDistributionsRemainDisabled() throws {
        let policy = BrandDistribution(
            formatVersion: 1, repository: "https://github.com/Pichi-AI/pichi-voice",
            updatesEnabled: true, expectedSigningTeam: "0000000000"
        )
        try policy.validate()
        XCTAssertFalse(policy.updatesAllowedForCurrentSignature)
        XCTAssertFalse(BrandDistribution.unconfigured.updatesAllowedForCurrentSignature)
    }
}

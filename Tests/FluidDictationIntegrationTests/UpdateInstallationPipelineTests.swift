import CryptoKit
import Darwin
@testable import FluidVoice_Debug
import Foundation
import Security
import XCTest

final nonisolated class UpdateInstallationPipelineTests: XCTestCase {
    func testSigningFixturePrerequisiteUsesExactCertificateOUAndApprovedTeams() {
        for team in Fixture.approvedTeams {
            let values = self.certificateProperties(team: team)
            XCTAssertEqual(Fixture.certificateTeamIdentifier(from: values), team)
            XCTAssertTrue(Fixture.acceptsCertificateTeam(values))
        }
        XCTAssertFalse(Fixture.acceptsCertificateTeam(self.certificateProperties(team: "ZZZZZZZZZZ")))
    }

    func testSigningFixturePrerequisiteDoesNotTrustDisplayLabelsOrTeamSubstrings() throws {
        var values = self.certificateProperties(team: "ZZZZZZZZZZ")
        let approved = try XCTUnwrap(Fixture.approvedTeams.sorted().first)
        values[kSecOIDCommonName as String] = [kSecPropertyKeyType as String: kSecPropertyTypeString,
                                            kSecPropertyKeyValue as String: "Apple Development: Fixture (" + approved + ")"]
        XCTAssertFalse(Fixture.acceptsCertificateTeam(values))
        XCTAssertFalse(Fixture.acceptsCertificateTeam(self.certificateProperties(team: approved + "-OTHER")))
        XCTAssertFalse(Fixture.acceptsCertificateTeam(self.certificateProperties(team: " " + approved)))
        XCTAssertFalse(Fixture.acceptsCertificateTeam(self.certificateProperties(team: approved.lowercased())))
    }

    func testSigningFixturePrerequisiteRejectsMissingAndMalformedCertificateOU() {
        XCTAssertNil(Fixture.certificateTeamIdentifier(from: [:]))
        for value: Any in [42, Data([0x01]), ["V4J43B279J"], ""] {
            let values = self.certificateProperties(team: value)
            XCTAssertFalse(Fixture.acceptsCertificateTeam(values))
        }
        let wrongType = self.certificateProperties(team: "LU46F7HGJM", type: kSecPropertyTypeNumber as String)
        XCTAssertNil(Fixture.certificateTeamIdentifier(from: wrongType))
    }

    func testSigningFixtureRejectsDuplicateSubjectOrganizationalUnits() {
        var values = self.certificateProperties(team: "LU46F7HGJM")
        var subject = values[kSecOIDX509V1SubjectName as String] as? [String: Any] ?? [:]
        let entry = (subject[kSecPropertyKeyValue as String] as? [[String: Any]])?.first ?? [:]
        subject[kSecPropertyKeyValue as String] = [entry, entry]
        values[kSecOIDX509V1SubjectName as String] = subject
        XCTAssertNil(Fixture.certificateTeamIdentifier(from: values))
    }

    private func certificateProperties(team: Any, type: String = kSecPropertyTypeString as String) -> [String: Any] {
        [kSecOIDX509V1SubjectName as String: [
            kSecPropertyKeyType as String: kSecPropertyTypeSection,
            kSecPropertyKeyValue as String: [[kSecPropertyKeyLabel as String: kSecOIDOrganizationalUnitName,
                                            kSecPropertyKeyType as String: type, kSecPropertyKeyValue as String: team]],
        ]]
    }

    func testConfiguredProductionTrustRejectsUnsignedBundlesWithoutTouchingThem() throws {
        XCTAssertEqual(AppBrand.distribution.expectedSigningTeam, "LU46F7HGJM")
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("UpdateDisabledTrustTests-" + UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let installed = root.appendingPathComponent("Applications/Fixture.app")
        let incoming = root.appendingPathComponent("Downloads/Incoming.app")
        let backup = root.appendingPathComponent("Backups/Previous.app")
        let payload = Data("synthetic preserved marker".utf8)
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": Fixture.identifier, "CFBundleShortVersionString": Fixture.installedVersion,
            "CFBundleVersion": Fixture.installedBuild, "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL",
        ], format: .xml, options: 0)
        for bundle in [installed, incoming] {
            try manager.createDirectory(at: bundle.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            try plist.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
            try payload.write(to: bundle.appendingPathComponent("Contents/Resources/payload.txt"))
        }
        XCTAssertThrowsError(try SimpleUpdater.prepareValidatedInstallation(installedAppURL: installed, downloadedAppURL: incoming,
            installedExpectation: .init(bundleIdentifier: Fixture.identifier, version: Fixture.installedVersion, build: Fixture.installedBuild),
            expectedVersion: Fixture.incomingVersion, backupURL: backup, isRollback: false)) { error in
            let underlying = (error as? UpdateAppReplacement.Failure)?.underlyingError ?? error
            guard case .invalidSignature? = underlying as? UpdateBundleValidator.ValidationError else {
                return XCTFail("Configured trust must still reject the unsigned fixture: \(underlying)")
            }
        }
        for bundle in [installed, incoming] {
            XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")), plist)
            XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent("Contents/Resources/payload.txt")), payload)
            XCTAssertEqual(try manager.contentsOfDirectory(atPath: bundle.appendingPathComponent("Contents").path).sorted(), ["Info.plist", "Resources"])
        }
        XCTAssertFalse(manager.fileExists(atPath: backup.path))
        let parentEntries = try manager.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path)
        XCTAssertFalse(parentEntries.contains { $0.hasSuffix(".staging") })
        XCTAssertFalse(manager.fileExists(atPath: backup.deletingLastPathComponent().path))
    }

    func testReleaseInstallationHasVerifiedBackupAndCanRecoverWithoutConsumingSource() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let installation = try fixture.prepare()
        XCTAssertEqual(installation.backupURL, fixture.backup)
        XCTAssertEqual(try fixture.validated(fixture.installed).version, Fixture.incomingVersion)
        XCTAssertEqual(try fixture.validated(fixture.backup).version, Fixture.installedVersion)
        XCTAssertEqual(try fixture.validated(fixture.backup).build, Fixture.installedBuild)
        XCTAssertEqual(try fixture.payload(fixture.backup), "installed")
        XCTAssertEqual(try fixture.payload(installation.replacement.recoveryAppURL), "installed")
        XCTAssertEqual(try fixture.payload(fixture.incoming), "incoming")
        try installation.replacement.recover()
        XCTAssertEqual(try fixture.validated(fixture.installed).version, Fixture.installedVersion)
        XCTAssertEqual(try fixture.payload(fixture.installed), "installed")
        XCTAssertEqual(try fixture.validated(fixture.incoming).version, Fixture.incomingVersion)
        XCTAssertEqual(try fixture.validated(fixture.backup).version, Fixture.installedVersion)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installation.replacement.stagingDirectoryURL.path))
    }

    func testTamperedCandidateCannotReplaceOriginalOrCreateBackup() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let originalPlist = try Data(contentsOf: fixture.installed.appendingPathComponent("Contents/Info.plist"))
        try Data("tampered incoming".utf8).write(to: fixture.incoming.appendingPathComponent("Contents/Resources/payload.txt"))
        XCTAssertThrowsError(try fixture.prepare())
        XCTAssertEqual(try Data(contentsOf: fixture.installed.appendingPathComponent("Contents/Info.plist")), originalPlist)
        try fixture.assertOriginalUnchanged()
        XCTAssertEqual(try fixture.payload(fixture.incoming), "tampered incoming")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
        try fixture.assertNoStage()
    }

    func testSameMarketingVersionInstallsOnlyTheApprovedBuildAndKeepsPreviousBuild() throws {
        let fixture = try Fixture(candidateVersion: Fixture.installedVersion)
        defer { fixture.cleanup() }
        let installation = try fixture.prepare(expectedVersion: Fixture.installedVersion)
        XCTAssertEqual(try fixture.validated(fixture.installed).build, "27")
        XCTAssertEqual(try fixture.validated(fixture.backup).build, Fixture.installedBuild)
        try installation.replacement.recover()
        try fixture.assertOriginalUnchanged()
    }

    func testUnapprovedBuildCannotReplaceOriginalOrCreateBackup() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        XCTAssertThrowsError(try fixture.prepare(expectedBuild: "28")) {
            XCTAssertEqual($0 as? UpdateBundleValidator.ValidationError, .buildMismatch)
        }
        try fixture.assertOriginalUnchanged()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
        try fixture.assertNoStage()
    }

    func testInstalledVersionChangedSinceApprovalRejectsPreparation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        XCTAssertThrowsError(try fixture.prepare(installedVersion: "1.6.10-beta.6")) { error in
            self.assertInstalledChanged(error)
        }
        try fixture.assertOriginalUnchanged()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
        try fixture.assertNoStage()
    }

    func testInstalledBuildChangedSinceApprovalRejectsPreparation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        XCTAssertThrowsError(try fixture.prepare(installedBuild: "25")) { error in
            self.assertInstalledChanged(error)
        }
        try fixture.assertOriginalUnchanged()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
        try fixture.assertNoStage()
    }

    func testPreexistingBackupDestinationIsPreservedAndOriginalIsUntouched() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.incoming, to: fixture.backup)
        let before = try Data(contentsOf: fixture.backup.appendingPathComponent("Contents/Info.plist"))
        XCTAssertThrowsError(try fixture.prepare()) { error in
            guard case .backupFailed? = error as? SimpleUpdateError else { return XCTFail("Expected backup failure: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: fixture.backup.appendingPathComponent("Contents/Info.plist")), before)
        XCTAssertEqual(try fixture.validated(fixture.backup).version, Fixture.incomingVersion)
        XCTAssertEqual(try fixture.payload(fixture.backup), "incoming")
        try fixture.assertOriginalUnchanged()
        try fixture.assertNoStage()
    }

    func testRegularFileAtBackupParentAbortsWithoutReplacingOriginal() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let parent = fixture.backup.deletingLastPathComponent()
        let marker = Data("unrelated existing file".utf8)
        try marker.write(to: parent)
        XCTAssertThrowsError(try fixture.prepare()) { error in
            guard case .backupFailed? = error as? SimpleUpdateError else { return XCTFail("Expected backup failure: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: parent), marker)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
        try fixture.assertOriginalUnchanged()
        try fixture.assertNoStage()
    }

    func testDevelopmentCandidateIsRejectedAsReleaseButAcceptedAsRollbackAndRetained() throws {
        let fixture = try Fixture(incomingDeveloperID: false, candidateVersion: "1.6.10-beta.6")
        defer { fixture.cleanup() }
        XCTAssertThrowsError(try fixture.prepare(expectedVersion: fixture.candidateVersion)) { error in
            guard case .invalidSignature? = error as? UpdateBundleValidator.ValidationError else {
                return XCTFail("Expected the release policy to reject a development certificate: \(error)")
            }
        }
        try fixture.assertOriginalUnchanged()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
        try fixture.assertNoStage()

        let installation = try fixture.prepare(expectedVersion: nil, isRollback: true)
        XCTAssertEqual(try fixture.validated(fixture.installed).version, fixture.candidateVersion)
        XCTAssertEqual(try fixture.validated(fixture.incoming).version, fixture.candidateVersion)
        XCTAssertEqual(try fixture.validated(fixture.backup).version, Fixture.installedVersion)
        try installation.replacement.finalize()
        XCTAssertEqual(try fixture.validated(fixture.incoming).version, fixture.candidateVersion)
        XCTAssertEqual(try fixture.validated(fixture.backup).version, Fixture.installedVersion)
        try fixture.assertNoStage()
    }

    func testReleaseWithoutApprovedVersionIsRejectedBeforeAnyStagingOrBackup() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        XCTAssertThrowsError(try fixture.prepare(expectedVersion: nil)) { error in
            XCTAssertEqual(error as? UpdateBundleValidator.ValidationError, .invalidExpectation)
        }
        try fixture.assertOriginalUnchanged()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
        try fixture.assertNoStage()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.lockURL.path))
    }

    func testCancelledTaskBeforePreparationDoesNotTouchOriginalStageOrBackup() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let gate = StartGate()
        let operation = Task.detached {
            await gate.wait()
            return try fixture.prepare()
        }
        operation.cancel()
        await gate.open()
        do {
            let installation = try await operation.value
            try installation.replacement.recover()
            XCTFail("Cancellation must reject preparation before exchange.")
        } catch is CancellationError {
            // This is the real production Task.checkCancellation exit.
        }
        try fixture.assertOriginalUnchanged()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
        try fixture.assertNoStage()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.lockURL.path))
    }

    private func assertInstalledChanged(_ error: Error) {
        guard let failure = error as? UpdateAppReplacement.Failure else { return XCTFail("Expected preparation wrapper: \(error)") }
        XCTAssertEqual(failure.operation, .preparation)
        guard case .installedAppChanged? = failure.underlyingError as? SimpleUpdateError else {
            return XCTFail("Expected installed app changed rejection: \(failure.underlyingError)")
        }
    }

    private actor StartGate {
        private var opened = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            guard !self.opened else { return }
            await withCheckedContinuation { self.continuation = $0 }
        }

        func open() {
            self.opened = true
            self.continuation?.resume()
            self.continuation = nil
        }
    }

    private struct Fixture: Sendable {
        static let identifier = "com.fluidvoice.update-pipeline.fixture"
        static let installedVersion = "1.6.10-beta.7"
        static let installedBuild = "26"
        static let incomingVersion = "1.6.10-beta.8"
        static let approvedTeams = Set([AppBrand.distribution.expectedSigningTeam].compactMap { $0 })

        let root: URL
        let installed: URL
        let incoming: URL
        let backup: URL
        let candidateVersion: String
        let simulateReleaseAssessment: Bool
        var lockURL: URL { self.installed.deletingLastPathComponent().appendingPathComponent(".fluidvoice-update-\(self.installed.lastPathComponent).lock") }

        init(incomingDeveloperID: Bool = true, candidateVersion: String = Self.incomingVersion) throws {
            guard AppBrand.distribution.updatesEnabled, !Self.approvedTeams.isEmpty else {
                throw XCTSkip("Signed pipeline fixtures require configured distribution trust.")
            }
            // Admit every required identity before creating or signing a bundle.
            // A trusted certificate from another team is not a pipeline fixture prerequisite.
            let installedIdentity = try Self.signingIdentity(developerID: false)
            // Only the external release/notary authority is substituted. Real local
            // development signatures still seal all fixture metadata and resources.
            let incomingIdentity = installedIdentity
            self.root = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateInstallationPipelineTests-" + UUID().uuidString, isDirectory: true)
            self.installed = self.root.appendingPathComponent("Applications/Fixture.app")
            self.incoming = self.root.appendingPathComponent("Downloads/Incoming.app")
            self.backup = self.root.appendingPathComponent("Backups/Previous.app")
            self.candidateVersion = candidateVersion
            self.simulateReleaseAssessment = incomingDeveloperID
            do {
                try self.makeBundle(at: self.installed, version: Self.installedVersion, build: Self.installedBuild, payload: "installed", identity: installedIdentity)
                try self.makeBundle(at: self.incoming, version: candidateVersion, build: "27", payload: "incoming", identity: incomingIdentity)
            } catch {
                self.cleanup()
                throw error
            }
        }

        func cleanup() { try? FileManager.default.removeItem(at: self.root) }

        func prepare(
            installedVersion: String = Self.installedVersion,
            installedBuild: String = Self.installedBuild,
            expectedVersion: String? = Self.incomingVersion,
            expectedBuild: String? = "27",
            isRollback: Bool = false
        ) throws -> SimpleUpdater.PreparedInstallation {
            let assessments = PipelineValidationLog()
            let result = try SimpleUpdater.prepareValidatedInstallation(
                installedAppURL: self.installed,
                downloadedAppURL: self.incoming,
                installedExpectation: .init(bundleIdentifier: Self.identifier, version: installedVersion, build: installedBuild),
                expectedVersion: expectedVersion,
                expectedBuild: expectedBuild,
                backupURL: self.backup,
                isRollback: isRollback,
                validateBundle: { url, expectation, policy in
                    if case let .developerID(teams) = policy {
                        assessments.recordReleaseAssessment()
                        if self.simulateReleaseAssessment {
                            return try UpdateBundleValidator.validate(at: url, expectation: expectation,
                                policy: .appleDevelopment(allowedTeamIDs: teams))
                        }
                    }
                    return try UpdateBundleValidator.validate(at: url, expectation: expectation, policy: policy)
                }
            )
            XCTAssertEqual(assessments.releaseAssessments, isRollback ? 0 : 1,
                "The production pipeline must request Developer ID authority for an incoming release")
            return result
        }

        func validated(_ bundle: URL) throws -> UpdateBundleValidator.ValidatedBundle {
            try UpdateBundleValidator.validate(
                at: bundle,
                expectation: .init(bundleIdentifier: Self.identifier, version: nil),
                policy: .installedApp(allowedTeamIDs: Self.approvedTeams)
            )
        }

        func payload(_ bundle: URL) throws -> String {
            try String(contentsOf: bundle.appendingPathComponent("Contents/Resources/payload.txt"), encoding: .utf8)
        }

        func assertOriginalUnchanged() throws {
            let original = try self.validated(self.installed)
            XCTAssertEqual(original.version, Self.installedVersion)
            XCTAssertEqual(original.build, Self.installedBuild)
            XCTAssertEqual(try self.payload(self.installed), "installed")
        }

        func assertNoStage() throws {
            let contents = try FileManager.default.contentsOfDirectory(atPath: self.installed.deletingLastPathComponent().path)
            XCTAssertFalse(contents.contains { $0.hasSuffix(".staging") })
        }

        private func makeBundle(at bundle: URL, version: String, build: String, payload: String, identity: String) throws {
            let executableDirectory = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
            let resources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executableDirectory.appendingPathComponent("Fixture"))
            try Data(payload.utf8).write(to: resources.appendingPathComponent("payload.txt"))
            let plist = [
                "CFBundleIdentifier": Self.identifier,
                "CFBundleShortVersionString": version,
                "CFBundleVersion": build,
                "CFBundleExecutable": "Fixture",
                "CFBundlePackageType": "APPL",
            ]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
            try self.sign(bundle, identity: identity)
            _ = try self.validated(bundle)
        }

        private static func signingIdentity(developerID: Bool) throws -> String {
            let prefix = developerID ? "Developer ID Application:" : "Apple Development:"
            var result: CFTypeRef?
            let query: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let identities = result as? [SecIdentity] else {
                throw XCTSkip("A \(prefix) signing identity from an approved team is required for signed pipeline fixtures.")
            }
            for identity in identities {
                var certificate: SecCertificate?
                guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
                      let summary = SecCertificateCopySubjectSummary(certificate) as String?, summary.hasPrefix(prefix),
                      let values = SecCertificateCopyValues(certificate, [kSecOIDX509V1SubjectName] as CFArray, nil) as? [String: Any],
                      Self.acceptsCertificateTeam(values)
                else { continue }
                var trust: SecTrust?
                guard let policy = SecPolicyCreateWithProperties(kSecPolicyAppleCodeSigning, nil),
                      SecTrustCreateWithCertificates(certificate, policy, &trust) == errSecSuccess, let trust,
                      SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
                      SecTrustEvaluateWithError(trust, nil)
                else { continue }
                return Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
            }
            throw XCTSkip("A valid \(prefix) signing identity from an approved team is required for signed pipeline fixtures.")
        }

        static func certificateTeamIdentifier(from values: [String: Any]) -> String? {
            guard let subject = values[kSecOIDX509V1SubjectName as String] as? [String: Any],
                  subject[kSecPropertyKeyType as String] as? String == kSecPropertyTypeSection as String,
                  let entries = subject[kSecPropertyKeyValue as String] as? [[String: Any]] else { return nil }
            let organizationalUnits = entries.filter { $0[kSecPropertyKeyLabel as String] as? String == kSecOIDOrganizationalUnitName as String }
            guard organizationalUnits.count == 1, let property = organizationalUnits.first,
                  property[kSecPropertyKeyType as String] as? String == kSecPropertyTypeString as String,
                  let team = property[kSecPropertyKeyValue as String] as? String, !team.isEmpty else { return nil }
            return team
        }

        static func acceptsCertificateTeam(_ values: [String: Any]) -> Bool {
            self.certificateTeamIdentifier(from: values).map(self.approvedTeams.contains) ?? false
        }

        private func sign(_ bundle: URL, identity: String) throws {
            let log = bundle.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".codesign.log")
            XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
            let output = try FileHandle(forWritingTo: log)
            defer { try? output.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = ["--force", "--sign", identity, "--timestamp=none", bundle.path]
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let deadline = Date().addingTimeInterval(15)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                process.terminate()
                let terminationDeadline = Date().addingTimeInterval(1)
                while process.isRunning, Date() < terminationDeadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                XCTFail("Temporary fixture signing exceeded its bounded timeout.")
                throw NSError(domain: "UpdateInstallationPipelineTests", code: 1)
            }
            guard process.terminationStatus == 0 else {
                let diagnostic = (try? String(contentsOf: log, encoding: .utf8)) ?? "No signing diagnostic"
                XCTFail("Temporary fixture signing failed: \(diagnostic)")
                throw NSError(domain: "UpdateInstallationPipelineTests", code: Int(process.terminationStatus))
            }
        }
    }
}

private final nonisolated class PipelineValidationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var releaseAssessments: Int { self.lock.withLock { self.count } }
    func recordReleaseAssessment() { self.lock.withLock { self.count += 1 } }
}

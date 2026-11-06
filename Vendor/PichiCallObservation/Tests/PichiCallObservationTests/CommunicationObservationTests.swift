import XCTest
@testable import PichiCallObservation

final class CommunicationObservationTests: XCTestCase {
    func testRealPrejoinShapeDoesNotAdmitMicrophoneBeforeConnectedControls() throws {
        // Recorded Teams web prejoin controls, 2026-11-06. Room/process identities anonymized.
        let module = try SemanticCommunicationModule(descriptor: .init(id: "observed.teams", displayName: "Observed Teams surface",
            browserBundleIdentifiers: ["com.google.Chrome"], urlRules: [.init(host: "teams.live.com")],
            callRules: .init(connected: [.init(identifier: "hangup-button", labels: ["Leave"])],
                prejoin: [.init(identifier: "prejoin-join-button", labels: ["Join now"])]),
            microphoneRules: .init(muted: [.init(labels: ["Unmute mic"])], unmuted: [.init(labels: ["Mute mic"])])))
        let prejoin = CommunicationObservationSnapshot(bundleIdentifier: "com.google.Chrome", processID: 42, windowID: 77,
            documentURL: "https://teams.live.com/v2/", controls: [
                .init(role: "AXButton", identifier: "prejoin-join-button", labels: ["Join now"]),
                .init(role: "AXSwitch", labels: ["Unmute mic (⇧ ⌘ M)"], value: "0")])
        XCTAssertEqual(module.evaluate(prejoin).callState, .prejoin)
        XCTAssertEqual(module.evaluate(prejoin).microphoneState, .indeterminate)
        let conflicting = CommunicationObservationSnapshot(bundleIdentifier: prejoin.bundleIdentifier, processID: 42, windowID: 77,
            documentURL: prejoin.documentURL, controls: prejoin.controls + [.init(role: "AXButton", identifier: "hangup-button", labels: ["Leave"])])
        XCTAssertEqual(module.evaluate(conflicting).callState, .indeterminate)
    }

    func testPrejoinDescriptorRoundTripAndLegacyDefault() throws {
        let data = Data(#"{"schemaVersion":1,"id":"observed.zoom","displayName":"Zoom","nativeBundleIdentifiers":["us.zoom.xos"],"callRules":{"prejoin":[{"labels":["Start"]}]}}"#.utf8)
        let descriptor = try CommunicationModuleDescriptor.decode(data)
        XCTAssertEqual(descriptor.callRules.prejoin.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(CommunicationModuleDescriptor.self, from: JSONEncoder().encode(descriptor)), descriptor)
        XCTAssertTrue(CommunicationCallRules().prejoin.isEmpty)
    }
    private func module(id: String = "test.call", host: String = "meet.example.com", validation: CommunicationModuleValidation = .contractTested) throws -> SemanticCommunicationModule {
        try SemanticCommunicationModule(descriptor: .init(id: id, displayName: "Synthetic call", browserBundleIdentifiers: ["browser.synthetic"],
            urlRules: [.init(host: host, pathPrefixes: ["/room"], excludedPathPrefixes: ["/room/settings"])], validation: validation,
            callRules: .init(connected: [.init(labels: ["Leave call"])], ended: [.init(labels: ["Rejoin"])],
                ringing: [.init(labels: ["Answer call"])], held: [.init(labels: ["Resume call"])]),
            microphoneRules: .init(muted: [.init(labels: ["Turn on microphone"], allowsShortcutSuffix: true)],
                unmuted: [.init(labels: ["Turn off microphone"], allowsShortcutSuffix: true)])))
    }
    private func snapshot(_ labels: [String], url: String = "https://meet.example.com/room/test") -> CommunicationObservationSnapshot {
        .init(bundleIdentifier: "browser.synthetic", processID: 42, windowID: 10, documentURL: url,
              controls: labels.map { .init(role: "AXButton", labels: [$0]) })
    }
    func testCallContextAndExplicitMuteTransitions() throws {
        let module = try self.module()
        XCTAssertEqual(module.evaluate(self.snapshot(["Turn on microphone"])).microphoneState, .indeterminate)
        XCTAssertEqual(module.evaluate(self.snapshot(["Leave call", "Turn on microphone"])).microphoneState, .muted)
        XCTAssertEqual(module.evaluate(self.snapshot(["Leave call", "Turn off microphone (⌘⇧M)"])).microphoneState, .unmuted)
        XCTAssertEqual(module.evaluate(self.snapshot(["Leave call", "Turn off camera"])).microphoneState, .indeterminate)
        XCTAssertEqual(module.evaluate(self.snapshot(["Leave call", "Turn on microphone for another participant"])).microphoneState, .indeterminate)
        XCTAssertEqual(module.evaluate(self.snapshot(["Leave call", "Turn off microphone (for another participant)"])).microphoneState, .indeterminate)
    }
    func testConflictingControlsAndMissingEvidenceNeverProveUnmute() throws {
        let module = try self.module()
        XCTAssertEqual(module.evaluate(self.snapshot(["Leave call", "Turn on microphone", "Turn off microphone"])).microphoneState, .indeterminate)
        XCTAssertEqual(module.evaluate(self.snapshot(["Leave call", "Rejoin", "Turn off microphone"])).callState, .indeterminate)
        XCTAssertEqual(module.evaluate(self.snapshot([])).callState, .indeterminate)
        let content = CommunicationObservationSnapshot(bundleIdentifier: "browser.synthetic", processID: 42, windowID: 10,
            documentURL: "https://meet.example.com/room/test", controls: [.init(role: "AXButton", labels: ["Leave call"]), .init(role: "AXStaticText", labels: ["Turn off microphone"])])
        XCTAssertEqual(module.evaluate(content).microphoneState, .indeterminate)
    }
    func testRingingHoldEndAreIndependentFromConnectedMicrophone() throws {
        let module = try self.module()
        XCTAssertEqual(module.evaluate(self.snapshot(["Leave call", "Answer call", "Turn off microphone"])).callState, .ringing)
        XCTAssertEqual(module.evaluate(self.snapshot(["Leave call", "Resume call", "Turn off microphone"])).callState, .onHold)
        XCTAssertEqual(module.evaluate(self.snapshot(["Resume call", "Turn off microphone"])).microphoneState, .indeterminate)
        XCTAssertEqual(module.evaluate(self.snapshot(["Rejoin"])).callState, .ended)
    }
    func testHostAndPathOwnershipRejectDeceptiveURLs() throws {
        let module = try self.module()
        for url in ["https://meet.example.com.evil.test/room/a", "http://meet.example.com/room/a", "https://user@meet.example.com/room/a", "https://meet.example.com/room/settings", "https://meet.example.com/roomy/a"] {
            XCTAssertFalse(module.matches(bundleIdentifier: "browser.synthetic", documentURL: url), url)
        }
        XCTAssertTrue(module.matches(bundleIdentifier: "browser.synthetic", documentURL: "https://meet.example.com/room/a?authuser=2"))
        XCTAssertFalse(module.matches(bundleIdentifier: "another.browser", documentURL: "https://meet.example.com/room/a"))
    }
    func testSubdomainMatchingHasDNSBoundary() {
        let rule = CommunicationURLRule(host: "example.com", allowsSubdomains: true)
        XCTAssertTrue(rule.matches("https://a.example.com/"))
        XCTAssertFalse(rule.matches("https://notexample.com/"))
        XCTAssertFalse(rule.matches("https://example.com.evil.test/"))
    }
    func testRegistryDoesNotChooseBetweenMatchingModules() throws {
        let first = try self.module(), second = try self.module(id: "other.call")
        let registry = try CommunicationModuleRegistry(modules: [first, second])
        XCTAssertNil(registry.resolve(snapshot: self.snapshot(["Leave call", "Turn off microphone"])))
        var duplicate = try CommunicationModuleRegistry(modules: [first])
        XCTAssertThrowsError(try duplicate.register(first))
        let planned = try self.module(id: "research.call", validation: .researchOnly)
        XCTAssertTrue(try CommunicationModuleRegistry(modules: [planned]).candidates(bundleIdentifier: "browser.synthetic").isEmpty)
    }
    func testSchemaAndResourceBoundsAreValidated() throws {
        XCTAssertThrowsError(try SemanticCommunicationModule(descriptor: .init(schemaVersion: 2, id: "test.call", displayName: "Call", nativeBundleIdentifiers: ["test.app"])))
        XCTAssertThrowsError(try SemanticCommunicationModule(descriptor: .init(id: "test.call", displayName: "Call", nativeBundleIdentifiers: ["test.app"], microphoneRules: .init(unmuted: [.init(role: "AXStaticText", labels: ["Mic on"])]))))
        let module = try self.module()
        let oversized = CommunicationObservationSnapshot(bundleIdentifier: "browser.synthetic", processID: 42, windowID: 10,
            documentURL: "https://meet.example.com/room/test", controls: Array(repeating: .init(role: "AXButton", labels: ["Leave call"]), count: 513))
        XCTAssertEqual(module.evaluate(oversized).callState, .indeterminate)
        let encoded = try JSONEncoder().encode(module.descriptor)
        XCTAssertEqual(try CommunicationModuleDescriptor.decode(encoded), module.descriptor)
        XCTAssertThrowsError(try CommunicationModuleDescriptor.decode(Data(repeating: 32, count: 65_537)))
    }
    func testToggleValueRequiresExactControlIdentity() {
        let selector = CommunicationControlSelector(role: "AXCheckBox", identifier: "self.microphone", expectedValue: "1")
        XCTAssertTrue(selector.matches(.init(role: "AXCheckBox", identifier: "self.microphone", value: "1")))
        XCTAssertFalse(selector.matches(.init(role: "AXCheckBox", identifier: "peer.microphone", value: "1")))
        XCTAssertFalse(selector.matches(.init(role: "AXCheckBox", identifier: "self.microphone", value: "0")))
    }
}

extension CommunicationObservationTests {
    func testPWAOwnerMatchesOnlyDeclaredBrowserAndStillRequiresKnownURL() throws {
        let module = try self.module()
        XCTAssertTrue(module.matches(bundleIdentifier: "browser.synthetic.app.owned", documentURL: "https://meet.example.com/room/a"))
        XCTAssertFalse(module.matches(bundleIdentifier: "browser.synthetic.apps.evil", documentURL: "https://meet.example.com/room/a"))
        XCTAssertFalse(module.matches(bundleIdentifier: "browser.synthetic.app.owned", documentURL: "https://evil.test/room/a"))
        let registry = try CommunicationModuleRegistry(modules: [module])
        XCTAssertEqual(registry.candidates(bundleIdentifier: "browser.synthetic.app.owned").count, 1)
    }

    func testExplicitAncestorPreventsPeerControlWithSameLabel() {
        let selector = CommunicationControlSelector(labels: ["Turn off microphone"], ancestorIdentifier: "local.call.toolbar")
        XCTAssertTrue(selector.matches(.init(role: "AXButton", labels: ["Turn off microphone"], ancestorIdentifiers: ["local.call.toolbar"])))
        XCTAssertFalse(selector.matches(.init(role: "AXButton", labels: ["Turn off microphone"], ancestorIdentifiers: ["remote.participant.actions"])))
    }
}

extension CommunicationObservationTests {
    func testCompactJSONHasSafeDefaultsAndMandatorySchema() throws {
        let data = Data(#"{"schemaVersion":1,"id":"example.call","displayName":"Example","browserBundleIdentifiers":["browser.synthetic"],"urlRules":[{"host":"call.example.com"}],"callRules":{"connected":[{"labels":["Leave call"]}]},"microphoneRules":{"unmuted":[{"labels":["Turn off microphone"]}]}}"#.utf8)
        let descriptor = try CommunicationModuleDescriptor.decode(data)
        XCTAssertEqual(descriptor.version, "1.0.0")
        XCTAssertTrue(descriptor.urlRules[0].requiresHTTPS)
        XCTAssertFalse(descriptor.urlRules[0].allowsSubdomains)
        XCTAssertTrue(descriptor.pushToTalkChords.isEmpty)
        XCTAssertThrowsError(try CommunicationModuleDescriptor.decode(Data(#"{"id":"example.call","displayName":"Example"}"#.utf8)))
    }
}

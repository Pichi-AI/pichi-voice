import XCTest
import UIKit
@preconcurrency import AVFoundation

private nonisolated enum PhysicalSpeakerLabelsPreflight {
    struct Unverified: Error {}

    static func validate(_ environment: [String: String], revision: String) throws {
        guard revision.count == 40 && revision.allSatisfy({ "0123456789abcdef".contains($0) }),
              environment["PICHI_PHYSICAL_SPEAKER_LABELS_PREFLIGHT"] == "1",
              environment["PICHI_PHYSICAL_SPEAKER_PREFLIGHT_REVISION"] == revision,
              environment["PICHI_PHYSICAL_SPEAKER_SESSION_MODE"] == "streaming",
              let sessionID = environment["PICHI_PHYSICAL_SPEAKER_SESSION_ID"],
              UUID(uuidString: sessionID) != nil else { throw Unverified() }
    }
}

private nonisolated enum PhysicalCaptionGeometry {
    struct Sample: Equatable {
        let identifier: String
        let paragraph: CGRect
        let viewport: CGRect

        var tailIsVisible: Bool {
            guard !identifier.isEmpty, Self.valid(paragraph), Self.valid(viewport) else { return false }
            // An intersecting tall row can still have its tail below the viewport.
            return paragraph.maxY > viewport.minY && paragraph.maxY <= viewport.maxY
                && paragraph.intersection(viewport).width > 0
        }

        private static func valid(_ rect: CGRect) -> Bool {
            [rect.minX, rect.minY, rect.width, rect.height, rect.maxX, rect.maxY].allSatisfy(\.isFinite)
                && rect.size.width > 0 && rect.size.height > 0 && !rect.isNull && !rect.isInfinite
        }
    }

    struct ParagraphFrame {
        let identifier: String
        let frame: CGRect
    }

    struct HistoryExtent {
        let validParagraphCount: Int
        let invalidParagraphCount: Int
        let duplicateIdentifiers: Bool
        let span: CGFloat
        let viewportHeight: CGFloat

        var isReady: Bool {
            !duplicateIdentifiers && validParagraphCount >= 2 && span.isFinite
                && viewportHeight.isFinite && viewportHeight > 0 && span / viewportHeight >= 1.75
        }
    }

    static func committedHistory(_ paragraphs: [ParagraphFrame], viewport: CGRect) -> HistoryExtent {
        func valid(_ frame: CGRect) -> Bool {
            !frame.isNull && !frame.isInfinite && frame.width > 0 && frame.height > 0
                && [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite)
        }
        let identifiers = paragraphs.map(\.identifier).filter { !$0.isEmpty }
        let duplicates = Set(identifiers).count != identifiers.count
        guard valid(viewport) else {
            return HistoryExtent(validParagraphCount: 0, invalidParagraphCount: paragraphs.count,
                                 duplicateIdentifiers: duplicates, span: 0, viewportHeight: 0)
        }
        // The current tail may include an inline pending wave. Only earlier rows
        // establish committed scroll extent that survives replacement of that wave.
        let closed = paragraphs.dropLast()
        let frames = closed.filter {
            !$0.identifier.isEmpty && valid($0.frame)
                && min($0.frame.maxX, viewport.maxX) > max($0.frame.minX, viewport.minX)
        }.map(\.frame)
        let span = (frames.map(\.maxY).max() ?? 0) - (frames.map(\.minY).min() ?? 0)
        return HistoryExtent(validParagraphCount: frames.count, invalidParagraphCount: closed.count - frames.count,
                             duplicateIdentifiers: duplicates, span: span, viewportHeight: viewport.height)
    }

    struct Settling {
        private var previous: Sample?

        mutating func observe(_ sample: Sample) -> Bool {
            defer { previous = sample.tailIsVisible ? sample : nil }
            return sample.tailIsVisible && previous == sample
        }
    }
}

private nonisolated enum PhysicalCaptionLatestControl {
    static let canonicalID = "meeting.liveTranscript.latest"
    static let viewportID = "meeting.liveTranscript"
    static let labels = ["Jump to latest captions", "Перейти к последним субтитрам"]
    struct Candidate {
        let identifier: String
        let label: String
        let frame: CGRect
        let enabled: Bool
        let hittable: Bool
    }

    static func select(_ buttons: [Candidate], viewport: CGRect) -> Int? {
        let canonical = buttons.indices.filter { buttons[$0].identifier == canonicalID }
        let matches = canonical.isEmpty ? buttons.indices.filter {
            buttons[$0].identifier == viewportID && labels.contains(buttons[$0].label)
        } : canonical
        guard matches.count == 1, let index = matches.first else { return nil }
        let button = buttons[index]
        let frames = [viewport, button.frame]
        guard button.enabled, button.hittable, labels.contains(button.label),
              frames.allSatisfy({ !$0.isNull && !$0.isInfinite && $0.width > 0 && $0.height > 0
                  && [$0.minX, $0.minY, $0.maxX, $0.maxY].allSatisfy(\.isFinite) }),
              viewport.contains(button.frame) else { return nil }
        return index
    }
}

private nonisolated struct PhysicalPostSoakAuthorization: Codable, Equatable {
    struct Unverified: Error {}
    let revision: String
    let runID: UUID
    let sessionID: UUID
    let title: String

    static func select(_ environment: [String: String], revision: String) throws -> Self {
        guard revision.count == 40 && revision.allSatisfy({ "0123456789abcdef".contains($0) }),
              environment["PICHI_PHYSICAL_POST_SOAK_CONTINUATION"] == "1",
              environment["PICHI_PHYSICAL_POST_SOAK_AUT_REVISION"] == revision,
              environment["PICHI_PHYSICAL_POST_SOAK_OWNED_IDLE_PREFLIGHT"] == "1",
              environment["PICHI_PHYSICAL_READ_ONLY_IDLE_PREFLIGHT"] == "1",
              let run = environment["PICHI_PHYSICAL_POST_SOAK_RUN_ID"], let runID = UUID(uuidString: run),
              let session = environment["PICHI_PHYSICAL_POST_SOAK_SESSION_ID"], let sessionID = UUID(uuidString: session),
              let title = environment["PICHI_PHYSICAL_POST_SOAK_SESSION_TITLE"],
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 1024 else {
            throw Unverified()
        }
        return Self(revision: revision, runID: runID, sessionID: sessionID, title: title)
    }
}

private nonisolated struct PhysicalPostSoakReceipt: Codable {
    var version: Int
    var authorization: PhysicalPostSoakAuthorization
    var state: String
    var audioStorageMode: String
    var piiRedactionEnabled: Bool
    var exclusiveIdleAttested: Bool

    func validate(_ expected: PhysicalPostSoakAuthorization) throws {
        guard version == 1, authorization == expected, state == "completed", audioStorageMode == "memoryOnly",
              piiRedactionEnabled, exclusiveIdleAttested else { throw PhysicalPostSoakAuthorization.Unverified() }
    }
}

// This test-only authorization pins the ordinary App Review 34 AUT, not the runner revision.
private nonisolated struct PhysicalOwnedPlaybackAuthorization: Codable, Equatable {
    struct Unverified: Error {}
    static let frozenRevision = "1a245d0447b08e3fc681d439ea4ef3b392e034c2"
    let revision: String
    let runID: UUID
    let sessionID: UUID
    let title: String

    static func select(_ environment: [String: String], revision: String) throws -> Self {
        guard revision == frozenRevision,
              environment["PICHI_PHYSICAL_OWNED_PLAYBACK_DELETE"] == "1",
              environment["PICHI_PHYSICAL_OWNED_PLAYBACK_AUT_REVISION"] == revision,
              environment["PICHI_PHYSICAL_READ_ONLY_IDLE_PREFLIGHT"] == "1",
              let run = environment["PICHI_PHYSICAL_OWNED_PLAYBACK_RUN_ID"], let runID = UUID(uuidString: run),
              let session = environment["PICHI_PHYSICAL_OWNED_PLAYBACK_SESSION_ID"], let sessionID = UUID(uuidString: session),
              let title = environment["PICHI_PHYSICAL_OWNED_PLAYBACK_SESSION_TITLE"],
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 1024,
              runID != sessionID else { throw Unverified() }
        return Self(revision: revision, runID: runID, sessionID: sessionID, title: title)
    }
}

private nonisolated struct PhysicalOwnedPlaybackReceipt: Codable {
    let version: Int
    let authorization: PhysicalOwnedPlaybackAuthorization
    let issuedAt: Date
    let state: String
    let audioStorageMode: String
    let syntheticOwned: Bool
    let backedUp: Bool
    let exclusiveIdleAttested: Bool

    func validate(_ expected: PhysicalOwnedPlaybackAuthorization, now: Date, consumed: Bool) throws {
        let age = now.timeIntervalSince(issuedAt)
        guard version == 1, authorization == expected, state == "completed", audioStorageMode == "retainedFiles",
              syntheticOwned, backedUp, exclusiveIdleAttested, !consumed,
              age.isFinite, age >= 0, age <= 900 else { throw PhysicalOwnedPlaybackAuthorization.Unverified() }
    }
}

private nonisolated struct PhysicalFirstUseAuthorization: Codable, Equatable {
    struct Unverified: Error {}
    let revision: String
    let runID: UUID
    let deviceID: String

    static func select(_ environment: [String: String], revision: String) throws -> Self {
        guard revision == PhysicalOwnedPlaybackAuthorization.frozenRevision,
              environment["PICHI_PHYSICAL_FIRST_USE_WELCOME_TO_TINY"] == "1",
              environment["PICHI_PHYSICAL_FIRST_USE_AUT_REVISION"] == revision,
              environment["PICHI_PHYSICAL_READ_ONLY_IDLE_PREFLIGHT"] == "1",
              let run = environment["PICHI_PHYSICAL_FIRST_USE_RUN_ID"], let runID = UUID(uuidString: run),
              let deviceID = environment["PICHI_PHYSICAL_FIRST_USE_DEVICE_ID"], deviceID.count == 40,
              deviceID.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw Unverified() }
        return Self(revision: revision, runID: runID, deviceID: deviceID)
    }
}

private nonisolated struct PhysicalFirstUseReceipt: Codable {
    let version: Int
    let authorization: PhysicalFirstUseAuthorization
    let issuedAt: Date
    let build: String
    let bundleID: String
    let legacyBundleID: String
    let newNamespaceEmpty: Bool
    let legacyNamespacePreserved: Bool
    let destinationVerified: Bool
    let foregroundWelcomeAttested: Bool

    func validate(_ expected: PhysicalFirstUseAuthorization, now: Date, consumed: Bool) throws {
        let age = now.timeIntervalSince(issuedAt)
        guard version == 1, authorization == expected, build == "34", bundleID == "ai.pichi.voice",
              legacyBundleID == "ai.pichi.voice.mobile", newNamespaceEmpty, legacyNamespacePreserved,
              destinationVerified, foregroundWelcomeAttested, !consumed,
              age.isFinite, age >= 0, age <= 900 else { throw PhysicalFirstUseAuthorization.Unverified() }
    }
}

private nonisolated struct PhysicalSetupContinuationAuthorization: Codable, Equatable {
    struct Unverified: Error {}
    let revision: String
    let runID: UUID
    let deviceID: String
    let operation: String
    let fromStage: String

    static func select(_ environment: [String: String], revision: String) throws -> Self {
        guard revision == PhysicalOwnedPlaybackAuthorization.frozenRevision,
              environment["PICHI_PHYSICAL_SETUP_CONTINUATION"] == "1",
              environment["PICHI_PHYSICAL_FIRST_USE_WELCOME_TO_TINY"] != "1",
              environment["PICHI_PHYSICAL_SETUP_AUT_REVISION"] == revision,
              environment["PICHI_PHYSICAL_READ_ONLY_IDLE_PREFLIGHT"] == "1",
              environment["PICHI_PHYSICAL_SETUP_OPERATION"] == "tiny-selected-to-final-account",
              environment["PICHI_PHYSICAL_SETUP_FROM_STAGE"] == "tiny-selected",
              let run = environment["PICHI_PHYSICAL_SETUP_RUN_ID"], let runID = UUID(uuidString: run),
              let deviceID = environment["PICHI_PHYSICAL_SETUP_DEVICE_ID"], deviceID.count == 40,
              deviceID.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw Unverified() }
        return Self(revision: revision, runID: runID, deviceID: deviceID,
                    operation: "tiny-selected-to-final-account", fromStage: "tiny-selected")
    }
}

private extension PhysicalSetupContinuationAuthorization {
    static func selectGuest(_ environment: [String: String], revision: String) throws -> Self {
        guard revision == PhysicalOwnedPlaybackAuthorization.frozenRevision,
              environment["PICHI_PHYSICAL_SETUP_GUEST_COMPLETION"] == "1",
              environment["PICHI_PHYSICAL_SETUP_CONTINUATION"] != "1",
              environment["PICHI_PHYSICAL_FIRST_USE_WELCOME_TO_TINY"] != "1",
              environment["PICHI_PHYSICAL_SETUP_AUT_REVISION"] == revision,
              environment["PICHI_PHYSICAL_READ_ONLY_IDLE_PREFLIGHT"] == "1",
              environment["PICHI_PHYSICAL_SETUP_OPERATION"] == "final-account-to-guest-recordings",
              environment["PICHI_PHYSICAL_SETUP_FROM_STAGE"] == "final-account",
              let run = environment["PICHI_PHYSICAL_SETUP_RUN_ID"], let runID = UUID(uuidString: run),
              let deviceID = environment["PICHI_PHYSICAL_SETUP_DEVICE_ID"], deviceID.count == 40,
              deviceID.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw Unverified() }
        return Self(revision: revision, runID: runID, deviceID: deviceID,
                    operation: "final-account-to-guest-recordings", fromStage: "final-account")
    }
}

private nonisolated struct PhysicalGuestCompletionReceipt: Codable {
    let version: Int
    let authorization: PhysicalSetupContinuationAuthorization
    let issuedAt: Date
    let build: String
    let bundleID: String
    let legacyBundleID: String
    let newNamespaceEmpty: Bool
    let legacyNamespacePreserved: Bool
    let destinationVerified: Bool
    let foregroundFinalAccountAttested: Bool
    let localPreparationReady: Bool
    let signedOutAttested: Bool
    let credentialsEmptyAttested: Bool

    func validate(_ expected: PhysicalSetupContinuationAuthorization, now: Date, consumed: Bool) throws {
        let age = now.timeIntervalSince(issuedAt)
        guard version == 1, authorization == expected, build == "34", bundleID == "ai.pichi.voice",
              legacyBundleID == "ai.pichi.voice.mobile", newNamespaceEmpty, legacyNamespacePreserved,
              destinationVerified, foregroundFinalAccountAttested, localPreparationReady, signedOutAttested,
              credentialsEmptyAttested, !consumed, age.isFinite, age >= 0, age <= 900 else {
            throw PhysicalSetupContinuationAuthorization.Unverified()
        }
    }
}

private nonisolated enum PhysicalGuestCredentialFields {
    static func isEmpty(value: String?) -> Bool { value == nil || value == "" }
}

private nonisolated enum PhysicalMicrophonePrompt {
    struct Unverified: Error {}
    static let titles = ["“Pichi Voice” Would Like to Access the Microphone", "\"Pichi Voice\" Would Like to Access the Microphone",
                         "«Pichi Voice» запрашивает доступ к микрофону", "«Pichi Voice» запрашивает доступ к микрофону.",
                         "Приложение «Pichi Voice» запрашивает доступ к микрофону."]
    static let usage = ["Record audio and transcribe speech on this device.", "Записывать звук и распознавать речь на этом устройстве."]
    static let grantLabels = ["OK", "ОК", "Allow", "Разрешить"]
    static let denyLabels = ["Don't Allow", "Don’t Allow", "Не разрешать"]

    static func enabled(_ environment: [String: String], revision: String, isPad: Bool) throws -> Bool {
        guard environment["PICHI_PHYSICAL_ALLOW_MICROPHONE_PROMPT"] == "1" else { return false }
        guard isPad, revision == PhysicalOwnedPlaybackAuthorization.frozenRevision,
              environment["PICHI_PHYSICAL_MICROPHONE_AUT_REVISION"] == revision else { throw Unverified() }
        return true
    }

    static func grantIndex(texts: [String], buttons: [String]) -> Int? {
        guard texts.contains(where: { titles.contains($0) }), texts.contains(where: { usage.contains($0) }), buttons.count == 2,
              buttons.filter({ denyLabels.contains($0) }).count == 1 else { return nil }
        let matches = buttons.indices.filter { grantLabels.contains(buttons[$0]) }
        return matches.count == 1 ? matches.first : nil
    }
}

private nonisolated struct PhysicalSetupContinuationReceipt: Codable {
    let version: Int
    let authorization: PhysicalSetupContinuationAuthorization
    let issuedAt: Date
    let build: String
    let bundleID: String
    let legacyBundleID: String
    let newNamespaceEmpty: Bool
    let legacyNamespacePreserved: Bool
    let destinationVerified: Bool
    let foregroundTinySelectedAttested: Bool
    let tinyPreparationNotStarted: Bool
    let signedOutAttested: Bool
    let piiOffAttested: Bool

    func validate(_ expected: PhysicalSetupContinuationAuthorization, now: Date, consumed: Bool) throws {
        let age = now.timeIntervalSince(issuedAt)
        guard version == 1, authorization == expected, build == "34", bundleID == "ai.pichi.voice",
              legacyBundleID == "ai.pichi.voice.mobile", newNamespaceEmpty, legacyNamespacePreserved,
              destinationVerified, foregroundTinySelectedAttested, tinyPreparationNotStarted,
              signedOutAttested, piiOffAttested, !consumed, age.isFinite, age >= 0, age <= 900 else {
            throw PhysicalSetupContinuationAuthorization.Unverified()
        }
    }
}

@MainActor private enum PhysicalSetupPreparation {
    struct Failure: Error {
        let primary: Error
        let cleanup: Error
    }

    static func run(start: () throws -> Void, observe: () async throws -> Void,
                    cancelOwnedUI: @escaping @MainActor () async throws -> Void) async throws {
        // A rejected or cancelled Start never grants ownership of another operation's Cancel.
        try Task.checkCancellation()
        try start()
        do { try await observe() } catch {
            let primary = error
            let cleanup = Task { @MainActor in
                do { try await cancelOwnedUI(); return nil as Error? } catch { return error }
            }
            if let cleanupError = await cleanup.value { throw Failure(primary: primary, cleanup: cleanupError) }
            throw primary
        }
    }
}

private nonisolated enum PhysicalPlaybackPosition {
    static func seconds(_ value: String?) -> Int? {
        guard let value else { return nil }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              let minutes = Int(parts[0]), let seconds = Int(parts[1]), seconds < 60,
              minutes <= (Int.max - seconds) / 60 else { return nil }
        return minutes * 60 + seconds
    }
}

private nonisolated struct PhysicalPlaybackPauseObservation {
    struct StillAdvancing: Error {}
    let initialPosition: Int
    let startedAt: TimeInterval
    private var previousPosition: Int
    private var previousTime: TimeInterval
    private var stablePosition: Int?
    private var stableSince: TimeInterval?

    init(position: Int, now: TimeInterval) {
        initialPosition = position
        previousPosition = position
        startedAt = now
        previousTime = now
    }

    mutating func observe(position: Int, now: TimeInterval) throws -> Bool {
        guard initialPosition >= 0, startedAt.isFinite, now.isFinite, now >= previousTime,
              position >= previousPosition,
              position == initialPosition || (initialPosition < Int.max && position == initialPosition + 1) else {
            throw StillAdvancing()
        }
        previousPosition = position
        previousTime = now
        // Match the saved-playback test's bounded queued-callback allowance. A
        // running player crosses more than one displayed boundary in 3.5 seconds.
        if now - startedAt < 3.5 { return false }
        if stablePosition == nil {
            stablePosition = position
            stableSince = now
        }
        guard position == stablePosition, let stableSince else { throw StillAdvancing() }
        return now - stableSince >= 2
    }
}

private nonisolated struct PhysicalTinySettingsProfile: Codable, Equatable, Sendable {
    var model: String
    var saveAudio: Bool
    var pii: Bool
    static let original = Self(model: "gigaam-v3-eou", saveAudio: true, pii: false)
    static let strict = Self(model: "whisper-tiny", saveAudio: false, pii: true)
}

private nonisolated struct PhysicalTinySettingsReceipt: Codable {
    enum Phase: String, Codable { case changing, prepared, restored, restorationRequired }
    var version: Int
    var revision: String
    var runID: String
    var original: PhysicalTinySettingsProfile
    var phase: Phase

    func validate(revision: String, runID: String) throws {
        guard version == 1, self.revision == revision, self.runID == runID,
              original == .original else {
            throw NSError(domain: "PhysicalTinySettingsReceipt", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Receipt ownership, frozen revision or original profile differs"])
        }
    }

    func save(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@MainActor private enum PhysicalTinySettingsTransaction {
    enum Key: Equatable { case model, saveAudio, pii }
    struct RestorationRequired: Error {}
    typealias Change = @MainActor (Key, PhysicalTinySettingsProfile) async throws -> Void
    typealias Verify = @MainActor (PhysicalTinySettingsProfile) throws -> Void

    static func prepare(change: @escaping Change, verify: @escaping Verify,
                        commit: () throws -> Void) async throws {
        do {
            for key: Key in [.saveAudio, .pii, .model] {
                try Task.checkCancellation()
                try await change(key, .strict)
            }
            try Task.checkCancellation()
            try verify(.strict)
            try commit()
        } catch {
            let preparationError = error
            do { try await restore(change: change, verify: verify) }
            catch { throw RestorationRequired() }
            throw preparationError
        }
    }

    static func restore(change: @escaping Change, verify: @escaping Verify) async throws {
        // Mandatory rollback owns its task and joins even when preparation was cancelled.
        let cleanup = Task { @MainActor in
            for key: Key in [.model, .pii, .saveAudio] { try await change(key, .original) }
            try verify(.original)
        }
        try await cleanup.value
    }
}

@MainActor private final class PhysicalTinySettingsFake {
    enum Failure: Error { case injected }
    var profile = PhysicalTinySettingsProfile.original
    var restoreKeys: [PhysicalTinySettingsTransaction.Key] = []
    let failingPrepareStep: Int?
    let cancelPrepareStep: Int?
    let failRestoration: Bool
    private var prepareSteps = 0

    init(failingPrepareStep: Int? = nil, cancelPrepareStep: Int? = nil, failRestoration: Bool = false) {
        self.failingPrepareStep = failingPrepareStep
        self.cancelPrepareStep = cancelPrepareStep
        self.failRestoration = failRestoration
    }

    func change(_ key: PhysicalTinySettingsTransaction.Key, _ target: PhysicalTinySettingsProfile) async throws {
        if target == .original {
            restoreKeys.append(key)
            if failRestoration { throw Failure.injected }
        }
        switch key {
        case .model: profile.model = target.model
        case .saveAudio: profile.saveAudio = target.saveAudio
        case .pii: profile.pii = target.pii
        }
        if target == .strict {
            prepareSteps += 1
            if cancelPrepareStep == prepareSteps { withUnsafeCurrentTask { $0?.cancel() } }
            if failingPrepareStep == prepareSteps { throw Failure.injected }
        }
    }

    func verify(_ expected: PhysicalTinySettingsProfile) throws {
        if profile != expected { throw Failure.injected }
    }
}

/// Opt-in tests of the installed app through its public UI. Audible fixtures belong
/// to the runner; silent input uses only the app's explicit DEBUG capture adapter.
final class MobilePhysicalReleaseUITests: XCTestCase {
    func testPhysicalCaptionGeometryAcceptsVisibleFullAndTallRowTails() {
        let viewport = CGRect(x: 10, y: 100, width: 300, height: 400)
        for row in [CGRect(x: 10, y: 120, width: 300, height: 80),
                    CGRect(x: 10, y: -700, width: 300, height: 1200)] {
            XCTAssertTrue(PhysicalCaptionGeometry.Sample(identifier: "tail", paragraph: row, viewport: viewport).tailIsVisible)
        }
    }

    func testPhysicalCaptionGeometryRejectsIntersectionWithoutVisibleTailAndInvalidFrames() {
        let viewport = CGRect(x: 10, y: 100, width: 300, height: 400)
        for row in [CGRect(x: 10, y: 120, width: 300, height: 500),
                    CGRect(x: 10, y: -100, width: 300, height: 200),
                    CGRect(x: 400, y: 200, width: 300, height: 40), .zero, .null, .infinite,
                    CGRect(x: CGFloat.nan, y: 200, width: 300, height: 40),
                    CGRect(x: 10, y: 200, width: -30, height: 40)] {
            XCTAssertFalse(PhysicalCaptionGeometry.Sample(identifier: "tail", paragraph: row, viewport: viewport).tailIsVisible)
        }
        for invalidViewport in [CGRect.zero, .null, .infinite] {
            XCTAssertFalse(PhysicalCaptionGeometry.Sample(identifier: "tail", paragraph: viewport,
                                                         viewport: invalidViewport).tailIsVisible)
        }
        XCTAssertFalse(PhysicalCaptionGeometry.Sample(identifier: "", paragraph: viewport, viewport: viewport).tailIsVisible)
    }

    func testPhysicalCaptionGeometryRequiresStableIdentityAndLayoutAfterInvalidObservation() {
        let viewport = CGRect(x: 0, y: 100, width: 300, height: 400)
        let tail = PhysicalCaptionGeometry.Sample(identifier: "tail", paragraph: viewport, viewport: viewport)
        let moved = PhysicalCaptionGeometry.Sample(identifier: "tail", paragraph: viewport.offsetBy(dx: 0, dy: -1), viewport: viewport)
        let replacement = PhysicalCaptionGeometry.Sample(identifier: "replacement", paragraph: moved.paragraph, viewport: viewport)
        var settling = PhysicalCaptionGeometry.Settling()
        XCTAssertFalse(settling.observe(tail))
        XCTAssertFalse(settling.observe(moved))
        XCTAssertFalse(settling.observe(replacement))
        XCTAssertTrue(settling.observe(replacement))
        XCTAssertFalse(settling.observe(.init(identifier: "tail", paragraph: .zero, viewport: viewport)))
        XCTAssertFalse(settling.observe(replacement))
        XCTAssertTrue(settling.observe(replacement))
    }

    func testPhysicalCaptionHistoryExtentAcceptsExactThresholdOfDistinctCommittedRows() {
        let viewport = CGRect(x: 10, y: 100, width: 300, height: 400)
        let paragraphs: [PhysicalCaptionGeometry.ParagraphFrame] = [
            .init(identifier: "first", frame: CGRect(x: 10, y: -300, width: 300, height: 200)),
            .init(identifier: "second", frame: CGRect(x: 10, y: -100, width: 300, height: 500)),
            .init(identifier: "tail", frame: CGRect(x: 10, y: 400, width: 300, height: 100))
        ]
        let extent = PhysicalCaptionGeometry.committedHistory(paragraphs, viewport: viewport)
        XCTAssertEqual(extent.validParagraphCount, 2)
        XCTAssertEqual(extent.span, 700)
        XCTAssertTrue(extent.isReady)
    }

    func testPhysicalCaptionHistoryExtentRejectsInsufficientHistoryAndPendingTailInflation() {
        let viewport = CGRect(x: 10, y: 100, width: 300, height: 400)
        let short: [PhysicalCaptionGeometry.ParagraphFrame] = [
            .init(identifier: "first", frame: CGRect(x: 10, y: 0, width: 300, height: 300)),
            .init(identifier: "second", frame: CGRect(x: 10, y: 300, width: 300, height: 399)),
            .init(identifier: "tail", frame: CGRect(x: 10, y: 699, width: 300, height: 5000))
        ]
        let extent = PhysicalCaptionGeometry.committedHistory(short, viewport: viewport)
        XCTAssertEqual(extent.span, 699)
        XCTAssertFalse(extent.isReady)
        XCTAssertFalse(PhysicalCaptionGeometry.committedHistory(Array(short.suffix(2)), viewport: viewport).isReady)
        XCTAssertFalse(PhysicalCaptionGeometry.committedHistory([], viewport: viewport).isReady)
    }

    func testPhysicalCaptionHistoryExtentRejectsMalformedForeignAndDuplicateGeometry() {
        let viewport = CGRect(x: 10, y: 100, width: 300, height: 400)
        let good = PhysicalCaptionGeometry.ParagraphFrame(identifier: "first", frame: CGRect(x: 10, y: -300, width: 300, height: 700))
        let tail = PhysicalCaptionGeometry.ParagraphFrame(identifier: "tail", frame: CGRect(x: 10, y: 400, width: 300, height: 100))
        for frame in [CGRect.zero, .null, .infinite, CGRect(x: CGFloat.nan, y: 0, width: 300, height: 800),
                      CGRect(x: 500, y: -5000, width: 300, height: 5000)] {
            let malformed = PhysicalCaptionGeometry.ParagraphFrame(identifier: "bad", frame: frame)
            let extent = PhysicalCaptionGeometry.committedHistory([good, malformed, tail], viewport: viewport)
            XCTAssertEqual(extent.validParagraphCount, 1)
            XCTAssertEqual(extent.invalidParagraphCount, 1)
            XCTAssertFalse(extent.isReady)
        }
        let duplicate = PhysicalCaptionGeometry.committedHistory([good, good, tail], viewport: viewport)
        XCTAssertTrue(duplicate.duplicateIdentifiers)
        XCTAssertFalse(duplicate.isReady)
        let emptyID = PhysicalCaptionGeometry.ParagraphFrame(identifier: "", frame: good.frame)
        XCTAssertFalse(PhysicalCaptionGeometry.committedHistory([good, emptyID, tail], viewport: viewport).isReady)
        for invalidViewport in [CGRect.zero, .null, .infinite] {
            XCTAssertFalse(PhysicalCaptionGeometry.committedHistory([good, tail], viewport: invalidViewport).isReady)
        }
    }

    func testPhysicalCaptionLatestControlPrefersCanonicalAndAcceptsExactInheritedLabels() {
        let viewport = CGRect(x: 24, y: 186.7, width: 354, height: 513)
        func button(_ identifier: String, _ label: String) -> PhysicalCaptionLatestControl.Candidate {
            .init(identifier: identifier, label: label, frame: CGRect(x: 328, y: 649.7, width: 44, height: 44), enabled: true, hittable: true)
        }
        for label in PhysicalCaptionLatestControl.labels {
            let inherited = button(PhysicalCaptionLatestControl.viewportID, label)
            let canonical = button(PhysicalCaptionLatestControl.canonicalID, label)
            XCTAssertEqual(PhysicalCaptionLatestControl.select([inherited], viewport: viewport), 0)
            XCTAssertEqual(PhysicalCaptionLatestControl.select([inherited, canonical], viewport: viewport), 1)
            XCTAssertEqual(PhysicalCaptionLatestControl.select([canonical], viewport: viewport), 0)
        }
    }

    func testPhysicalCaptionLatestControlRejectsForeignLabelIDOutsideAndInvalidFrames() {
        let viewport = CGRect(x: 10, y: 100, width: 300, height: 400)
        func button(_ identifier: String, _ label: String, _ frame: CGRect) -> PhysicalCaptionLatestControl.Candidate {
            .init(identifier: identifier, label: label, frame: frame, enabled: true, hittable: true)
        }
        let goodFrame = CGRect(x: 250, y: 450, width: 44, height: 44)
        for candidate in [button("other", PhysicalCaptionLatestControl.labels[0], goodFrame),
                          button(PhysicalCaptionLatestControl.viewportID, "Other action", goodFrame),
                          button(PhysicalCaptionLatestControl.canonicalID, "Other action", goodFrame)] {
            XCTAssertNil(PhysicalCaptionLatestControl.select([candidate], viewport: viewport))
        }
        for frame in [CGRect(x: 280, y: 450, width: 44, height: 44),
                      CGRect(x: 250, y: 470, width: 44, height: 44), .zero, .null, .infinite,
                      CGRect(x: CGFloat.nan, y: 450, width: 44, height: 44)] {
            XCTAssertNil(PhysicalCaptionLatestControl.select([button(PhysicalCaptionLatestControl.viewportID,
                PhysicalCaptionLatestControl.labels[0], frame)], viewport: viewport))
        }
    }

    func testPhysicalCaptionLatestControlRejectsDuplicateAndUnreadyControlsWithoutFallback() {
        let viewport = CGRect(x: 0, y: 0, width: 300, height: 400)
        func button(_ identifier: String, enabled: Bool = true, hittable: Bool = true) -> PhysicalCaptionLatestControl.Candidate {
            .init(identifier: identifier, label: PhysicalCaptionLatestControl.labels[0],
                  frame: CGRect(x: 250, y: 350, width: 44, height: 44), enabled: enabled, hittable: hittable)
        }
        let inherited = button(PhysicalCaptionLatestControl.viewportID)
        let canonical = button(PhysicalCaptionLatestControl.canonicalID)
        XCTAssertNil(PhysicalCaptionLatestControl.select([], viewport: viewport))
        XCTAssertNil(PhysicalCaptionLatestControl.select([canonical, canonical], viewport: viewport))
        XCTAssertNil(PhysicalCaptionLatestControl.select([inherited, inherited], viewport: viewport))
        for unready in [button(PhysicalCaptionLatestControl.canonicalID, enabled: false),
                        button(PhysicalCaptionLatestControl.canonicalID, hittable: false)] {
            XCTAssertNil(PhysicalCaptionLatestControl.select([inherited, unready], viewport: viewport))
        }
        for unready in [button(PhysicalCaptionLatestControl.viewportID, enabled: false),
                        button(PhysicalCaptionLatestControl.viewportID, hittable: false)] {
            XCTAssertNil(PhysicalCaptionLatestControl.select([unready], viewport: viewport))
        }
        for invalidViewport in [CGRect.zero, .null, .infinite] {
            XCTAssertNil(PhysicalCaptionLatestControl.select([canonical], viewport: invalidViewport))
        }
    }

    private var postSoakTestEnvironment: [String: String] {
        ["PICHI_PHYSICAL_POST_SOAK_CONTINUATION": "1",
         "PICHI_PHYSICAL_POST_SOAK_AUT_REVISION": String(repeating: "a", count: 40),
         "PICHI_PHYSICAL_POST_SOAK_OWNED_IDLE_PREFLIGHT": "1",
         "PICHI_PHYSICAL_READ_ONLY_IDLE_PREFLIGHT": "1",
         "PICHI_PHYSICAL_POST_SOAK_RUN_ID": "00000000-0000-0000-0000-000000000001",
         "PICHI_PHYSICAL_POST_SOAK_SESSION_ID": "00000000-0000-0000-0000-000000000002",
         "PICHI_PHYSICAL_POST_SOAK_SESSION_TITLE": "Synthetic completed session"]
    }

    func testPhysicalPostSoakAuthorizationSelectsExactCompletedReceipt() throws {
        let selected = try PhysicalPostSoakAuthorization.select(postSoakTestEnvironment, revision: String(repeating: "a", count: 40))
        XCTAssertEqual(selected.sessionID.uuidString, postSoakTestEnvironment["PICHI_PHYSICAL_POST_SOAK_SESSION_ID"])
        let receipt = PhysicalPostSoakReceipt(version: 1, authorization: selected, state: "completed",
                                             audioStorageMode: "memoryOnly", piiRedactionEnabled: true, exclusiveIdleAttested: true)
        try JSONDecoder().decode(PhysicalPostSoakReceipt.self, from: JSONEncoder().encode(receipt)).validate(selected)
    }

    func testPhysicalPostSoakAuthorizationRejectsMissingStaleOrMalformedSelection() {
        let revision = String(repeating: "a", count: 40)
        for (key, invalid) in [("PICHI_PHYSICAL_POST_SOAK_CONTINUATION", "0"),
                               ("PICHI_PHYSICAL_POST_SOAK_AUT_REVISION", String(repeating: "b", count: 40)),
                               ("PICHI_PHYSICAL_POST_SOAK_OWNED_IDLE_PREFLIGHT", "0"),
                               ("PICHI_PHYSICAL_READ_ONLY_IDLE_PREFLIGHT", "0"),
                               ("PICHI_PHYSICAL_POST_SOAK_RUN_ID", "invalid"),
                               ("PICHI_PHYSICAL_POST_SOAK_SESSION_ID", "invalid"),
                               ("PICHI_PHYSICAL_POST_SOAK_SESSION_TITLE", " ")] {
            var changed = postSoakTestEnvironment
            changed[key] = invalid
            XCTAssertThrowsError(try PhysicalPostSoakAuthorization.select(changed, revision: revision))
            changed.removeValue(forKey: key)
            XCTAssertThrowsError(try PhysicalPostSoakAuthorization.select(changed, revision: revision))
        }
        for invalidRevision in ["working-tree", String(repeating: "z", count: 40)] {
            XCTAssertThrowsError(try PhysicalPostSoakAuthorization.select(postSoakTestEnvironment, revision: invalidRevision))
        }
    }

    func testPhysicalPostSoakReceiptRejectsForeignSessionRunRevisionAndUnsafeState() throws {
        let selected = try PhysicalPostSoakAuthorization.select(postSoakTestEnvironment, revision: String(repeating: "a", count: 40))
        let receipt = PhysicalPostSoakReceipt(version: 1, authorization: selected, state: "completed",
                                             audioStorageMode: "memoryOnly", piiRedactionEnabled: true, exclusiveIdleAttested: true)
        for key in ["PICHI_PHYSICAL_POST_SOAK_SESSION_ID", "PICHI_PHYSICAL_POST_SOAK_RUN_ID", "PICHI_PHYSICAL_POST_SOAK_SESSION_TITLE"] {
            var changed = postSoakTestEnvironment
            changed[key] = key.hasSuffix("TITLE") ? "Another session" : "00000000-0000-0000-0000-000000000003"
            let foreign = try PhysicalPostSoakAuthorization.select(changed, revision: selected.revision)
            XCTAssertThrowsError(try receipt.validate(foreign))
        }
        var stale = postSoakTestEnvironment
        stale["PICHI_PHYSICAL_POST_SOAK_AUT_REVISION"] = String(repeating: "b", count: 40)
        XCTAssertThrowsError(try receipt.validate(PhysicalPostSoakAuthorization.select(stale, revision: String(repeating: "b", count: 40))))
        let mutations: [(inout PhysicalPostSoakReceipt) -> Void] = [
            { $0.version = 2 }, { $0.state = "recording" }, { $0.audioStorageMode = "saved" },
            { $0.piiRedactionEnabled = false }, { $0.exclusiveIdleAttested = false }
        ]
        for mutate in mutations {
            var changed = receipt
            mutate(&changed)
            XCTAssertThrowsError(try changed.validate(selected))
        }
    }

    private var ownedPlaybackTestEnvironment: [String: String] {
        ["PICHI_PHYSICAL_OWNED_PLAYBACK_DELETE": "1",
         "PICHI_PHYSICAL_OWNED_PLAYBACK_AUT_REVISION": PhysicalOwnedPlaybackAuthorization.frozenRevision,
         "PICHI_PHYSICAL_READ_ONLY_IDLE_PREFLIGHT": "1",
         "PICHI_PHYSICAL_OWNED_PLAYBACK_RUN_ID": "00000000-0000-0000-0000-000000000001",
         "PICHI_PHYSICAL_OWNED_PLAYBACK_SESSION_ID": "00000000-0000-0000-0000-000000000002",
         "PICHI_PHYSICAL_OWNED_PLAYBACK_SESSION_TITLE": "Owned synthetic playback fixture"]
    }

    private func ownedPlaybackTestReceipt() throws -> PhysicalOwnedPlaybackReceipt {
        PhysicalOwnedPlaybackReceipt(version: 1,
            authorization: try PhysicalOwnedPlaybackAuthorization.select(ownedPlaybackTestEnvironment,
                revision: PhysicalOwnedPlaybackAuthorization.frozenRevision),
            issuedAt: Date(timeIntervalSince1970: 1000), state: "completed", audioStorageMode: "retainedFiles",
            syntheticOwned: true, backedUp: true, exclusiveIdleAttested: true)
    }

    func testPhysicalOwnedPlaybackReceiptAcceptsExactFreshUnusedSelection() throws {
        let receipt = try ownedPlaybackTestReceipt()
        let decoded = try JSONDecoder().decode(PhysicalOwnedPlaybackReceipt.self, from: JSONEncoder().encode(receipt))
        try decoded.validate(receipt.authorization, now: Date(timeIntervalSince1970: 1001), consumed: false)
        XCTAssertEqual(receipt.authorization.sessionID.uuidString, ownedPlaybackTestEnvironment["PICHI_PHYSICAL_OWNED_PLAYBACK_SESSION_ID"])
    }

    func testPhysicalOwnedPlaybackAuthorizationRejectsMissingForeignOrMalformedSelection() throws {
        let revision = PhysicalOwnedPlaybackAuthorization.frozenRevision
        for key in ownedPlaybackTestEnvironment.keys {
            var changed = ownedPlaybackTestEnvironment
            changed.removeValue(forKey: key)
            XCTAssertThrowsError(try PhysicalOwnedPlaybackAuthorization.select(changed, revision: revision), key)
            changed = ownedPlaybackTestEnvironment
            changed[key] = key.hasSuffix("TITLE") ? " " : "invalid"
            XCTAssertThrowsError(try PhysicalOwnedPlaybackAuthorization.select(changed, revision: revision), key)
        }
        XCTAssertThrowsError(try PhysicalOwnedPlaybackAuthorization.select(ownedPlaybackTestEnvironment, revision: String(repeating: "a", count: 40)))
        var sameID = ownedPlaybackTestEnvironment
        sameID["PICHI_PHYSICAL_OWNED_PLAYBACK_RUN_ID"] = sameID["PICHI_PHYSICAL_OWNED_PLAYBACK_SESSION_ID"]
        XCTAssertThrowsError(try PhysicalOwnedPlaybackAuthorization.select(sameID, revision: revision))
    }

    func testPhysicalOwnedPlaybackReceiptRejectsForeignUnsafeStaleFutureAndConsumedState() throws {
        let receipt = try ownedPlaybackTestReceipt()
        for key in ["PICHI_PHYSICAL_OWNED_PLAYBACK_RUN_ID", "PICHI_PHYSICAL_OWNED_PLAYBACK_SESSION_ID",
                    "PICHI_PHYSICAL_OWNED_PLAYBACK_SESSION_TITLE"] {
            var foreign = ownedPlaybackTestEnvironment
            foreign[key] = key.hasSuffix("TITLE") ? "Foreign session" : "00000000-0000-0000-0000-000000000003"
            let selected = try PhysicalOwnedPlaybackAuthorization.select(foreign, revision: receipt.authorization.revision)
            XCTAssertThrowsError(try receipt.validate(selected, now: receipt.issuedAt, consumed: false))
        }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
        for (key, invalid) in [("version", 2 as Any), ("state", "processing"), ("audioStorageMode", "memoryOnly"),
                               ("syntheticOwned", false), ("backedUp", false), ("exclusiveIdleAttested", false)] {
            var changed = json
            changed[key] = invalid
            let invalidReceipt = try JSONDecoder().decode(PhysicalOwnedPlaybackReceipt.self, from: JSONSerialization.data(withJSONObject: changed))
            XCTAssertThrowsError(try invalidReceipt.validate(receipt.authorization, now: receipt.issuedAt, consumed: false), key)
        }
        for time in [999.0, 1901.0] {
            XCTAssertThrowsError(try receipt.validate(receipt.authorization, now: Date(timeIntervalSince1970: time), consumed: false))
        }
        XCTAssertThrowsError(try receipt.validate(receipt.authorization, now: receipt.issuedAt, consumed: true))
    }

    func testPhysicalPlaybackPositionAcceptsNativeTimeAndRejectsMalformedOrOverflowValues() {
        XCTAssertEqual(PhysicalPlaybackPosition.seconds("0:03"), 3)
        XCTAssertEqual(PhysicalPlaybackPosition.seconds("12:59"), 779)
        for value in [nil, "", "0:3", "0:60", "-1:00", "1:00 / 2:00", "x:00", "99999999999999999999999:00"] {
            XCTAssertNil(PhysicalPlaybackPosition.seconds(value))
        }
    }

    func testPhysicalPlaybackPauseAllowsOneQueuedBoundaryThenRequiresTwoStableSeconds() throws {
        var observation = PhysicalPlaybackPauseObservation(position: 10, now: 0)
        XCTAssertFalse(try observation.observe(position: 10, now: 0.1))
        XCTAssertFalse(try observation.observe(position: 11, now: 0.25))
        XCTAssertFalse(try observation.observe(position: 11, now: 3.5))
        XCTAssertFalse(try observation.observe(position: 11, now: 5.49))
        XCTAssertTrue(try observation.observe(position: 11, now: 5.5))
    }

    func testPhysicalPlaybackPauseAcceptsNoQueuedUpdateAndRejectsOvershootOrReversal() throws {
        var stable = PhysicalPlaybackPauseObservation(position: 10, now: 0)
        XCTAssertFalse(try stable.observe(position: 10, now: 3.5))
        XCTAssertTrue(try stable.observe(position: 10, now: 5.5))
        var advancing = PhysicalPlaybackPauseObservation(position: 10, now: 0)
        XCTAssertFalse(try advancing.observe(position: 11, now: 0.25))
        XCTAssertThrowsError(try advancing.observe(position: 12, now: 1.25))
        var reversing = PhysicalPlaybackPauseObservation(position: 10, now: 0)
        XCTAssertFalse(try reversing.observe(position: 11, now: 0.25))
        XCTAssertThrowsError(try reversing.observe(position: 10, now: 0.5))
    }

    func testPhysicalPlaybackPauseRejectsNeverStableWindowAndInvalidClock() throws {
        var neverStable = PhysicalPlaybackPauseObservation(position: 10, now: 0)
        XCTAssertFalse(try neverStable.observe(position: 10, now: 3.5))
        // Even the otherwise allowed one-second boundary fails after settling.
        XCTAssertThrowsError(try neverStable.observe(position: 11, now: 4))
        var regressingClock = PhysicalPlaybackPauseObservation(position: 10, now: 1)
        XCTAssertThrowsError(try regressingClock.observe(position: 10, now: 0.5))
        var invalidClock = PhysicalPlaybackPauseObservation(position: 10, now: 0)
        XCTAssertThrowsError(try invalidClock.observe(position: 10, now: .infinity))
    }

    private var firstUseTestEnvironment: [String: String] {
        ["PICHI_PHYSICAL_FIRST_USE_WELCOME_TO_TINY": "1",
         "PICHI_PHYSICAL_FIRST_USE_AUT_REVISION": PhysicalOwnedPlaybackAuthorization.frozenRevision,
         "PICHI_PHYSICAL_READ_ONLY_IDLE_PREFLIGHT": "1",
         "PICHI_PHYSICAL_FIRST_USE_RUN_ID": "00000000-0000-0000-0000-000000000001",
         "PICHI_PHYSICAL_FIRST_USE_DEVICE_ID": String(repeating: "a", count: 40)]
    }

    private func firstUseTestReceipt() throws -> PhysicalFirstUseReceipt {
        PhysicalFirstUseReceipt(version: 1, authorization: try PhysicalFirstUseAuthorization.select(firstUseTestEnvironment,
            revision: PhysicalOwnedPlaybackAuthorization.frozenRevision), issuedAt: Date(timeIntervalSince1970: 1000),
            build: "34", bundleID: "ai.pichi.voice", legacyBundleID: "ai.pichi.voice.mobile",
            newNamespaceEmpty: true, legacyNamespacePreserved: true, destinationVerified: true, foregroundWelcomeAttested: true)
    }

    func testPhysicalFirstUseReceiptAcceptsExactFreshUnusedAttestation() throws {
        let receipt = try firstUseTestReceipt()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PhysicalFirstUseReceipt.self, from: encoder.encode(receipt))
        try decoded.validate(receipt.authorization, now: Date(timeIntervalSince1970: 1001), consumed: false)
    }

    func testPhysicalFirstUseAuthorizationRejectsMissingDisabledMalformedOrStaleInputs() {
        for key in firstUseTestEnvironment.keys {
            var changed = firstUseTestEnvironment
            changed.removeValue(forKey: key)
            XCTAssertThrowsError(try PhysicalFirstUseAuthorization.select(changed, revision: PhysicalOwnedPlaybackAuthorization.frozenRevision), key)
            changed[key] = "invalid"
            XCTAssertThrowsError(try PhysicalFirstUseAuthorization.select(changed, revision: PhysicalOwnedPlaybackAuthorization.frozenRevision), key)
        }
        XCTAssertThrowsError(try PhysicalFirstUseAuthorization.select(firstUseTestEnvironment, revision: String(repeating: "b", count: 40)))
    }

    func testPhysicalFirstUseReceiptRejectsForeignDestinationNamespaceAndUnpreservedLegacy() throws {
        let receipt = try firstUseTestReceipt()
        for key in ["PICHI_PHYSICAL_FIRST_USE_DEVICE_ID", "PICHI_PHYSICAL_FIRST_USE_RUN_ID"] {
            var changed = firstUseTestEnvironment
            changed[key] = key.hasSuffix("DEVICE_ID") ? String(repeating: "b", count: 40) : "00000000-0000-0000-0000-000000000002"
            let foreign = try PhysicalFirstUseAuthorization.select(changed, revision: receipt.authorization.revision)
            XCTAssertThrowsError(try receipt.validate(foreign, now: receipt.issuedAt, consumed: false))
        }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
        for (key, invalid) in [("version", 2 as Any), ("build", "23"), ("bundleID", "ai.pichi.voice.mobile"),
                               ("legacyBundleID", "other"), ("newNamespaceEmpty", false), ("legacyNamespacePreserved", false),
                               ("destinationVerified", false), ("foregroundWelcomeAttested", false)] {
            var changed = json
            changed[key] = invalid
            let unsafe = try JSONDecoder().decode(PhysicalFirstUseReceipt.self, from: JSONSerialization.data(withJSONObject: changed))
            XCTAssertThrowsError(try unsafe.validate(receipt.authorization, now: receipt.issuedAt, consumed: false), key)
        }
        for time in [999.0, 1901.0] {
            XCTAssertThrowsError(try receipt.validate(receipt.authorization, now: Date(timeIntervalSince1970: time), consumed: false))
        }
        XCTAssertThrowsError(try receipt.validate(receipt.authorization, now: receipt.issuedAt, consumed: true))
    }

    private var setupContinuationTestEnvironment: [String: String] {
        ["PICHI_PHYSICAL_SETUP_CONTINUATION": "1",
         "PICHI_PHYSICAL_SETUP_AUT_REVISION": PhysicalOwnedPlaybackAuthorization.frozenRevision,
         "PICHI_PHYSICAL_READ_ONLY_IDLE_PREFLIGHT": "1",
         "PICHI_PHYSICAL_SETUP_OPERATION": "tiny-selected-to-final-account",
         "PICHI_PHYSICAL_SETUP_FROM_STAGE": "tiny-selected",
         "PICHI_PHYSICAL_SETUP_RUN_ID": "00000000-0000-0000-0000-000000000001",
         "PICHI_PHYSICAL_SETUP_DEVICE_ID": String(repeating: "a", count: 40)]
    }

    private func setupContinuationTestReceipt() throws -> PhysicalSetupContinuationReceipt {
        PhysicalSetupContinuationReceipt(version: 1,
            authorization: try PhysicalSetupContinuationAuthorization.select(setupContinuationTestEnvironment,
                revision: PhysicalOwnedPlaybackAuthorization.frozenRevision), issuedAt: Date(timeIntervalSince1970: 1000),
            build: "34", bundleID: "ai.pichi.voice", legacyBundleID: "ai.pichi.voice.mobile",
            newNamespaceEmpty: true, legacyNamespacePreserved: true, destinationVerified: true,
            foregroundTinySelectedAttested: true, tinyPreparationNotStarted: true, signedOutAttested: true, piiOffAttested: true)
    }

    func testPhysicalSetupContinuationAcceptsFreshExactOperationAndRejectsOldWelcomeReceipt() throws {
        let receipt = try setupContinuationTestReceipt()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PhysicalSetupContinuationReceipt.self, from: encoder.encode(receipt))
        try decoded.validate(receipt.authorization, now: Date(timeIntervalSince1970: 1001), consumed: false)
        XCTAssertThrowsError(try decoder.decode(PhysicalSetupContinuationReceipt.self, from: encoder.encode(firstUseTestReceipt())))
    }

    func testPhysicalSetupContinuationRejectsMissingForeignStageDeviceAndUnsafeAttestations() throws {
        let receipt = try setupContinuationTestReceipt()
        for key in setupContinuationTestEnvironment.keys {
            var changed = setupContinuationTestEnvironment
            changed.removeValue(forKey: key)
            XCTAssertThrowsError(try PhysicalSetupContinuationAuthorization.select(changed, revision: receipt.authorization.revision), key)
            changed[key] = "invalid"
            XCTAssertThrowsError(try PhysicalSetupContinuationAuthorization.select(changed, revision: receipt.authorization.revision), key)
        }
        var conflicting = setupContinuationTestEnvironment
        conflicting["PICHI_PHYSICAL_FIRST_USE_WELCOME_TO_TINY"] = "1"
        XCTAssertThrowsError(try PhysicalSetupContinuationAuthorization.select(conflicting, revision: receipt.authorization.revision))
        for key in ["PICHI_PHYSICAL_SETUP_DEVICE_ID", "PICHI_PHYSICAL_SETUP_RUN_ID"] {
            var changed = setupContinuationTestEnvironment
            changed[key] = key.hasSuffix("DEVICE_ID") ? String(repeating: "b", count: 40) : "00000000-0000-0000-0000-000000000002"
            let foreign = try PhysicalSetupContinuationAuthorization.select(changed, revision: receipt.authorization.revision)
            XCTAssertThrowsError(try receipt.validate(foreign, now: receipt.issuedAt, consumed: false))
        }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
        for (key, invalid) in [("version", 2 as Any), ("build", "23"), ("bundleID", "ai.pichi.voice.mobile"),
                               ("legacyBundleID", "other"), ("newNamespaceEmpty", false), ("legacyNamespacePreserved", false),
                               ("destinationVerified", false), ("foregroundTinySelectedAttested", false),
                               ("tinyPreparationNotStarted", false), ("signedOutAttested", false), ("piiOffAttested", false)] {
            var changed = json
            changed[key] = invalid
            let unsafe = try JSONDecoder().decode(PhysicalSetupContinuationReceipt.self, from: JSONSerialization.data(withJSONObject: changed))
            XCTAssertThrowsError(try unsafe.validate(receipt.authorization, now: receipt.issuedAt, consumed: false), key)
        }
        for time in [999.0, 1901.0] {
            XCTAssertThrowsError(try receipt.validate(receipt.authorization, now: Date(timeIntervalSince1970: time), consumed: false))
        }
        XCTAssertThrowsError(try receipt.validate(receipt.authorization, now: receipt.issuedAt, consumed: true))
    }

    @MainActor
    func testPhysicalSetupPreparationSuccessAndRejectedStartNeverCancel() async throws {
        enum Failure: Error { case start }
        var calls: [String] = []
        try await PhysicalSetupPreparation.run(start: { calls.append("start") }, observe: { calls.append("ready") },
            cancelOwnedUI: { calls.append("cancel") })
        XCTAssertEqual(calls, ["start", "ready"])
        do {
            try await PhysicalSetupPreparation.run(start: { throw Failure.start }, observe: { XCTFail("Start was rejected") },
                cancelOwnedUI: { XCTFail("No operation is owned") })
            XCTFail("Rejected Start must propagate")
        } catch Failure.start { }
    }

    @MainActor
    func testPhysicalSetupPreparationCancelledBeforeStartNeverActs() async throws {
        var calls: [String] = []
        let operation = Task { @MainActor in
            try await PhysicalSetupPreparation.run(start: { calls.append("start") }, observe: { calls.append("observe") },
                cancelOwnedUI: { calls.append("cancel") })
        }
        // The MainActor task cannot start until this actor turn yields below.
        operation.cancel()
        do {
            try await operation.value
            XCTFail("A pre-cancelled preparation must not begin")
        } catch is CancellationError { }
        XCTAssertTrue(calls.isEmpty)
    }

    @MainActor
    func testPhysicalSetupPreparationRetainsPrimaryAndCancelFailure() async throws {
        enum Failure: Error, Equatable { case preparation, cancel }
        do {
            try await PhysicalSetupPreparation.run(start: {}, observe: { throw Failure.preparation },
                cancelOwnedUI: { throw Failure.cancel })
            XCTFail("Both failures must be retained")
        } catch let failure as PhysicalSetupPreparation.Failure {
            XCTAssertEqual(failure.primary as? Failure, .preparation)
            XCTAssertEqual(failure.cleanup as? Failure, .cancel)
        }
    }

    @MainActor
    func testPhysicalSetupPreparationCancellationJoinsIndependentUICleanup() async throws {
        var returned = false
        var releaseObserve: CheckedContinuation<Void, Never>?
        var releaseCleanup: CheckedContinuation<Void, Never>?
        let observing = expectation(description: "Preparation observation entered")
        let entered = expectation(description: "Owned UI cancellation entered")
        let operation = Task { @MainActor in
            do {
                try await PhysicalSetupPreparation.run(start: {}, observe: {
                    await withCheckedContinuation { continuation in releaseObserve = continuation; observing.fulfill() }
                    try Task.checkCancellation()
                }, cancelOwnedUI: {
                    XCTAssertFalse(Task.isCancelled)
                    await withCheckedContinuation { continuation in releaseCleanup = continuation; entered.fulfill() }
                })
                XCTFail("Cancellation must propagate")
            } catch is CancellationError { }
            returned = true
        }
        let observed = await XCTWaiter.fulfillment(of: [observing], timeout: 2)
        XCTAssertEqual(observed, .completed)
        operation.cancel()
        releaseObserve?.resume()
        let cancelling = await XCTWaiter.fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(cancelling, .completed)
        XCTAssertFalse(returned, "Cancellation cannot return before owned UI cleanup joins")
        releaseCleanup?.resume()
        try await operation.value
        XCTAssertTrue(returned)
    }

    private var guestCompletionTestEnvironment: [String: String] {
        ["PICHI_PHYSICAL_SETUP_GUEST_COMPLETION": "1",
         "PICHI_PHYSICAL_SETUP_AUT_REVISION": PhysicalOwnedPlaybackAuthorization.frozenRevision,
         "PICHI_PHYSICAL_READ_ONLY_IDLE_PREFLIGHT": "1",
         "PICHI_PHYSICAL_SETUP_OPERATION": "final-account-to-guest-recordings",
         "PICHI_PHYSICAL_SETUP_FROM_STAGE": "final-account",
         "PICHI_PHYSICAL_SETUP_RUN_ID": "00000000-0000-0000-0000-000000000003",
         "PICHI_PHYSICAL_SETUP_DEVICE_ID": String(repeating: "a", count: 40)]
    }

    private func guestCompletionTestReceipt() throws -> PhysicalGuestCompletionReceipt {
        PhysicalGuestCompletionReceipt(version: 1,
            authorization: try PhysicalSetupContinuationAuthorization.selectGuest(guestCompletionTestEnvironment,
                revision: PhysicalOwnedPlaybackAuthorization.frozenRevision), issuedAt: Date(timeIntervalSince1970: 1000),
            build: "34", bundleID: "ai.pichi.voice", legacyBundleID: "ai.pichi.voice.mobile", newNamespaceEmpty: true,
            legacyNamespacePreserved: true, destinationVerified: true, foregroundFinalAccountAttested: true,
            localPreparationReady: true, signedOutAttested: true, credentialsEmptyAttested: true)
    }

    func testPhysicalGuestCompletionAdmitsOnlyFreshExactPreparedSignedOutFinalPage() throws {
        let receipt = try guestCompletionTestReceipt()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        try decoder.decode(PhysicalGuestCompletionReceipt.self, from: encoder.encode(receipt)).validate(
            receipt.authorization, now: Date(timeIntervalSince1970: 1001), consumed: false)
        for key in guestCompletionTestEnvironment.keys {
            var changed = guestCompletionTestEnvironment
            changed.removeValue(forKey: key)
            XCTAssertThrowsError(try PhysicalSetupContinuationAuthorization.selectGuest(changed, revision: receipt.authorization.revision))
            changed[key] = "invalid"
            XCTAssertThrowsError(try PhysicalSetupContinuationAuthorization.selectGuest(changed, revision: receipt.authorization.revision))
        }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
        for key in ["newNamespaceEmpty", "legacyNamespacePreserved", "destinationVerified", "foregroundFinalAccountAttested",
                    "localPreparationReady", "signedOutAttested", "credentialsEmptyAttested"] {
            var changed = json
            changed[key] = false
            let unsafe = try JSONDecoder().decode(PhysicalGuestCompletionReceipt.self, from: JSONSerialization.data(withJSONObject: changed))
            XCTAssertThrowsError(try unsafe.validate(receipt.authorization, now: receipt.issuedAt, consumed: false))
        }
        for (key, invalid) in [("version", 2 as Any), ("build", "23"), ("bundleID", "other"), ("legacyBundleID", "other")] {
            var changed = json
            changed[key] = invalid
            let unsafe = try JSONDecoder().decode(PhysicalGuestCompletionReceipt.self, from: JSONSerialization.data(withJSONObject: changed))
            XCTAssertThrowsError(try unsafe.validate(receipt.authorization, now: receipt.issuedAt, consumed: false))
        }
        var foreign = guestCompletionTestEnvironment
        foreign["PICHI_PHYSICAL_SETUP_DEVICE_ID"] = String(repeating: "b", count: 40)
        XCTAssertThrowsError(try receipt.validate(PhysicalSetupContinuationAuthorization.selectGuest(foreign, revision: receipt.authorization.revision),
            now: receipt.issuedAt, consumed: false))
        for time in [999.0, 1901.0] {
            XCTAssertThrowsError(try receipt.validate(receipt.authorization, now: Date(timeIntervalSince1970: time), consumed: false))
        }
        XCTAssertThrowsError(try receipt.validate(receipt.authorization, now: receipt.issuedAt, consumed: true))
        XCTAssertThrowsError(try JSONDecoder().decode(PhysicalGuestCompletionReceipt.self, from: JSONEncoder().encode(setupContinuationTestReceipt())))
    }

    func testPhysicalGuestCredentialAdmissionRejectsEnteredOrUnknownValuesWithoutExposingThem() {
        XCTAssertTrue(PhysicalGuestCredentialFields.isEmpty(value: nil))
        XCTAssertTrue(PhysicalGuestCredentialFields.isEmpty(value: ""))
        XCTAssertFalse(PhysicalGuestCredentialFields.isEmpty(value: "Email"))
        for value in ["synthetic@example.test", "••••", "unknown"] {
            XCTAssertFalse(PhysicalGuestCredentialFields.isEmpty(value: value))
        }
    }

    func testPhysicalMicrophonePromptRequiresPadRevisionExactAppPurposeAndUniqueGrant() throws {
        let revision = PhysicalOwnedPlaybackAuthorization.frozenRevision
        let environment = ["PICHI_PHYSICAL_ALLOW_MICROPHONE_PROMPT": "1", "PICHI_PHYSICAL_MICROPHONE_AUT_REVISION": revision]
        XCTAssertTrue(try PhysicalMicrophonePrompt.enabled(environment, revision: revision, isPad: true))
        XCTAssertFalse(try PhysicalMicrophonePrompt.enabled([:], revision: revision, isPad: true))
        XCTAssertThrowsError(try PhysicalMicrophonePrompt.enabled(environment, revision: revision, isPad: false))
        XCTAssertThrowsError(try PhysicalMicrophonePrompt.enabled(environment, revision: String(repeating: "b", count: 40), isPad: true))
        for title in PhysicalMicrophonePrompt.titles {
            for usage in PhysicalMicrophonePrompt.usage {
                for grant in PhysicalMicrophonePrompt.grantLabels {
                    XCTAssertEqual(PhysicalMicrophonePrompt.grantIndex(texts: [title, usage], buttons: ["Don't Allow", grant]), 1)
                }
            }
        }
        let good = [PhysicalMicrophonePrompt.titles[0], PhysicalMicrophonePrompt.usage[0]]
        XCTAssertNil(PhysicalMicrophonePrompt.grantIndex(texts: ["Other app", PhysicalMicrophonePrompt.usage[0]], buttons: ["OK"]))
        XCTAssertNil(PhysicalMicrophonePrompt.grantIndex(texts: [PhysicalMicrophonePrompt.titles[0], "Location or Touch ID"], buttons: ["OK"]))
        XCTAssertNil(PhysicalMicrophonePrompt.grantIndex(texts: good, buttons: ["Don't Allow", "Cancel"]))
        XCTAssertNil(PhysicalMicrophonePrompt.grantIndex(texts: good, buttons: ["OK", "Allow"]))
        XCTAssertNil(PhysicalMicrophonePrompt.grantIndex(texts: good, buttons: ["Touch ID", "OK"]))
        XCTAssertNil(PhysicalMicrophonePrompt.grantIndex(texts: good, buttons: ["Don't Allow", "OK", "Password"]))
    }

    func testPhysicalSpeakerPreflightAcceptsVerifiedCurrentSettingsAndSession() throws {
        let revision = String(repeating: "a", count: 40)
        try PhysicalSpeakerLabelsPreflight.validate([
            "PICHI_PHYSICAL_SPEAKER_LABELS_PREFLIGHT": "1",
            "PICHI_PHYSICAL_SPEAKER_PREFLIGHT_REVISION": revision,
            "PICHI_PHYSICAL_SPEAKER_SESSION_MODE": "streaming",
            "PICHI_PHYSICAL_SPEAKER_SESSION_ID": "00000000-0000-0000-0000-000000000001"
        ], revision: revision)
    }

    func testPhysicalSpeakerPreflightRejectsMissingDisabledOrStaleEvidence() throws {
        let revision = String(repeating: "a", count: 40)
        let verified = [
            "PICHI_PHYSICAL_SPEAKER_LABELS_PREFLIGHT": "1",
            "PICHI_PHYSICAL_SPEAKER_PREFLIGHT_REVISION": revision,
            "PICHI_PHYSICAL_SPEAKER_SESSION_MODE": "streaming",
            "PICHI_PHYSICAL_SPEAKER_SESSION_ID": "00000000-0000-0000-0000-000000000001"
        ]
        for (key, invalid) in [("PICHI_PHYSICAL_SPEAKER_LABELS_PREFLIGHT", "0"),
                               ("PICHI_PHYSICAL_SPEAKER_PREFLIGHT_REVISION", String(repeating: "b", count: 40)),
                               ("PICHI_PHYSICAL_SPEAKER_SESSION_MODE", "afterRecording"),
                               ("PICHI_PHYSICAL_SPEAKER_SESSION_ID", "invalid")] {
            var changed = verified
            changed[key] = invalid
            XCTAssertThrowsError(try PhysicalSpeakerLabelsPreflight.validate(changed, revision: revision))
            changed.removeValue(forKey: key)
            XCTAssertThrowsError(try PhysicalSpeakerLabelsPreflight.validate(changed, revision: revision))
        }
    }

    @MainActor
    func testPhysicalControlRevealFindsTargetsInEitherDirection() throws {
        for startingUpward in [true, false] {
            for target in [-2, 0, 2] {
                var position = 0
                var gestures = 0
                try PhysicalControlReveal.run(startingUpward: startingUpward, ready: { position == target }, scroll: { upward, _ in
                    position += upward ? 1 : -1
                    gestures += 1
                })
                XCTAssertEqual(position, target)
                XCTAssertLessThanOrEqual(gestures, 15)
                if target == 0 { XCTAssertEqual(gestures, 0) }
            }
        }
    }

    @MainActor
    func testPhysicalControlRevealRejectsMissingControlAndPreservesGestureFailure() throws {
        enum Failure: Error { case gesture }
        var gestures = 0
        XCTAssertThrowsError(try PhysicalControlReveal.run(ready: { false }, scroll: { _, _ in
            gestures += 1
        })) { XCTAssertTrue($0 is PhysicalControlReveal.NotVisible) }
        XCTAssertEqual(gestures, 15)
        XCTAssertThrowsError(try PhysicalControlReveal.run(ready: { false }, scroll: { _, _ in
            throw Failure.gesture
        })) { XCTAssertTrue($0 is Failure) }
    }

    @MainActor
    func testPhysicalControlRevealPreservesUnsafeReadinessAndCancellationBeforeAnotherGesture() {
        enum Failure: Error { case ownership }
        var gestures = 0
        XCTAssertThrowsError(try PhysicalControlReveal.run(ready: { throw Failure.ownership }, scroll: { _, _ in
            gestures += 1
        })) { XCTAssertTrue($0 is Failure) }
        XCTAssertEqual(gestures, 0)
        XCTAssertThrowsError(try PhysicalControlReveal.run(ready: { throw CancellationError() }, scroll: { _, _ in
            gestures += 1
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(gestures, 0)
        var cancelled = false
        XCTAssertThrowsError(try PhysicalControlReveal.run(startingUpward: false, ready: {
            if cancelled { throw CancellationError() }
            return false
        }, scroll: { _, _ in
            gestures += 1
            cancelled = true
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(gestures, 1)
        gestures = 0
        cancelled = false
        XCTAssertThrowsError(try PhysicalControlReveal.run(ready: {
            // Model cancellation delivered while the native readiness query runs.
            cancelled = true
            return false
        }, scroll: { _, _ in
            if cancelled { throw CancellationError() }
            gestures += 1
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(gestures, 0, "A late cancellation check must precede the actual UI event")
    }

    @MainActor
    func testPhysicalSettingsNavigationRevealsLandscapeRows() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires the explicitly owned idle physical app")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_PHYSICAL_SETTINGS_NAVIGATION"] == "1" else {
            throw XCTSkip("Explicitly enable read-only physical settings navigation")
        }
        let revision = try XCTUnwrap(environment["PICHI_TEST_REVISION"])
        let app = try attachReadOnlyPhysicalApp(revision: revision)
        XCUIDevice.shared.orientation = .landscapeLeft
        try await PhysicalUITransitionWait.until(timeout: 10, condition: { app.frame.width > app.frame.height })
        let original = try tinySettingsRead(app, revision: revision)
        for page in ["models", "privacy", "recording", "participants", "models"] {
            try openPhysicalSettingsPage("settings.\(page)", app: app, revision: revision)
            let detail = app.descendants(matching: .any)["settings.\(page).detail"].firstMatch
            try require(detail.waitForExistence(timeout: 10), "The selected Settings page must open")
            if page == "participants" {
                try verifyAutomaticParticipantResources(in: app, revision: revision, requireReady: false)
            }
            capture("settings-navigation-\(page)", revision: revision)
            // Switching sections preserves the pushed Settings page; the next call
            // must also exercise the app's explicit Settings reselect-to-root contract.
            try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
        }
        XCTAssertEqual(try tinySettingsRead(app, revision: revision), original)
        try tinySettingsIdle(app, revision: revision)
        #endif
    }

    @MainActor
    func testOwnedRecordingCleanupWaitsForReadyStopAndJoinsBeforeReturning() async throws {
        try await verifyOwnedRecordingCleanupJoin(initiallyProcessing: false)
    }

    @MainActor
    func testOwnedRecordingCleanupJoinsProcessingWithoutAnotherStop() async throws {
        try await verifyOwnedRecordingCleanupJoin(initiallyProcessing: true)
    }

    @MainActor
    func testOwnedRecordingCleanupPropagatesJoinFailure() async throws {
        enum Failure: Error { case join }
        var stopCalls = 0
        do {
            try await PhysicalOwnedRecordingCleanup.run(observe: { .join },
                stop: { stopCalls += 1 }, join: { throw Failure.join })
            XCTFail("Failed completion must remain an unresolved cleanup")
        } catch Failure.join {
            XCTAssertEqual(stopCalls, 0)
        }
    }

    @MainActor
    func testOwnedRecordingCleanupJoinsAfterStopFailure() async throws {
        try await verifyOwnedRecordingCleanupJoin(initiallyProcessing: false, stopFails: true)
    }

    @MainActor
    func testOwnedRecordingCleanupRetainsStopAndJoinFailures() async throws {
        try await verifyOwnedRecordingCleanupJoin(initiallyProcessing: false, stopFails: true, joinFails: true)
    }

    @MainActor private func verifyOwnedRecordingCleanupJoin(initiallyProcessing: Bool,
                                                           stopFails: Bool = false, joinFails: Bool = false) async throws {
        enum Failure: Error, Equatable { case stop, join }
        var time: TimeInterval = 0
        var calls: [String] = []
        var returned = false
        var releaseJoin: CheckedContinuation<Void, Never>?
        var joinReleased = false
        let enteredJoin = expectation(description: "Cleanup entered the real join operation")
        let cleanup = Task { @MainActor in
            try await PhysicalOwnedRecordingCleanup.run(observe: {
                PhysicalUITransitionWait.ownedRecordingAction(stopReady: time >= 2,
                    processing: initiallyProcessing, completed: false)
            }, stop: {
                calls.append("stop")
                if stopFails { throw Failure.stop }
            }, join: {
                calls.append("join")
                await withCheckedContinuation { continuation in
                    if joinReleased { continuation.resume() }
                    else { releaseJoin = continuation }
                    enteredJoin.fulfill()
                }
                if joinFails { throw Failure.join }
            }, now: { time }, pause: { time += 1 })
            returned = true
        }
        let entered = await XCTWaiter.fulfillment(of: [enteredJoin], timeout: 2)
        XCTAssertEqual(entered, .completed)
        XCTAssertFalse(returned, "Returning before join releases would abandon owned capture")
        XCTAssertEqual(calls, initiallyProcessing ? ["join"] : ["stop", "join"])
        XCTAssertEqual(time, initiallyProcessing ? 0 : 2)
        joinReleased = true
        releaseJoin?.resume()
        releaseJoin = nil
        if entered != .completed { cleanup.cancel() }
        do {
            try await cleanup.value
            XCTAssertFalse(stopFails || joinFails, "A failed Stop or join must not become cleanup success")
            XCTAssertTrue(returned)
        } catch {
            XCTAssertFalse(returned)
            if stopFails && joinFails {
                let failures = try XCTUnwrap(error as? PhysicalOwnedRecordingCleanup.StopAndJoinFailure)
                XCTAssertEqual(failures.stopError as? Failure, .stop)
                XCTAssertEqual(failures.joinError as? Failure, .join)
            } else {
                guard stopFails, case Failure.stop = error else { throw error }
            }
        }
    }

    @MainActor
    func testPhysicalTransitionWaitObservesDelayedState() async throws {
        var time: TimeInterval = 0
        var observations = 0
        try await PhysicalUITransitionWait.until(timeout: 3, condition: {
            observations += 1
            return time == 2
        }, now: { time }, pause: { time += 1 })
        XCTAssertEqual(time, 2)
        XCTAssertEqual(observations, 3)
    }

    @MainActor
    func testPhysicalTransitionWaitRejectsMissingStateAtDeadline() async throws {
        var time: TimeInterval = 0
        do {
            try await PhysicalUITransitionWait.until(timeout: 2, condition: { false },
                                                    now: { time }, pause: { time += 1 })
            XCTFail("A missing background or Stop transition must fail")
        } catch is PhysicalUITransitionWait.TimedOut {
            XCTAssertEqual(time, 2)
        }
    }

    @MainActor
    func testPhysicalTransitionWaitPreservesCancellation() async throws {
        let work = Task { @MainActor in
            do {
                try await PhysicalUITransitionWait.until(timeout: 10, condition: { false },
                    pause: { withUnsafeCurrentTask { $0?.cancel() } })
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        let cancelled = await work.value
        XCTAssertTrue(cancelled)
    }

    @MainActor
    func testPhysicalCleanupWaitsForTemporarilyDisabledStop() async throws {
        var time: TimeInterval = 0
        var decision: PhysicalUITransitionWait.OwnedRecordingAction?
        try await PhysicalUITransitionWait.until(timeout: 3, condition: {
            decision = PhysicalUITransitionWait.ownedRecordingAction(
                stopReady: time >= 2, processing: false, completed: false)
            return decision != nil
        }, now: { time }, pause: { time += 1 })
        XCTAssertEqual(time, 2)
        XCTAssertEqual(decision, .requestStop)
    }

    @MainActor
    func testPhysicalCleanupJoinsAlreadyProcessingOrCompleted() async throws {
        for processing in [true, false] {
            var pauses = 0
            var decision: PhysicalUITransitionWait.OwnedRecordingAction?
            try await PhysicalUITransitionWait.until(timeout: 3, condition: {
                decision = PhysicalUITransitionWait.ownedRecordingAction(
                    stopReady: false, processing: processing, completed: !processing)
                return decision != nil
            }, pause: { pauses += 1 })
            XCTAssertEqual(decision, .join)
            XCTAssertEqual(pauses, 0)
        }
    }

    @MainActor
    func testPhysicalPrepareTinyStrictSettings() async throws {
        try await physicalTinySettings(restore: false)
    }

    @MainActor
    func testPhysicalRestoreTinyOriginalSettings() async throws {
        try await physicalTinySettings(restore: true)
    }

    @MainActor private func physicalTinySettings(restore: Bool) async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Settings preparation requires the explicitly owned physical device")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_PHYSICAL_TINY_SETTINGS_OPERATION"] == (restore ? "restore" : "prepare") else {
            throw XCTSkip("Enable exactly the requested physical settings operation")
        }
        let revision = try XCTUnwrap(environment["PICHI_TEST_REVISION"])
        let runID = try XCTUnwrap(environment["PICHI_PHYSICAL_TINY_SETTINGS_RUN_ID"])
        try require(revision.count == 40 && revision.allSatisfy { "0123456789abcdef".contains($0) }
            && UUID(uuidString: runID) != nil
            && environment["PICHI_PHYSICAL_TINY_SETTINGS_IDLE_PREFLIGHT"] == "1",
            "The parent must verify the frozen AUT, current backup, idle state and exclusive ownership")
        if !restore { try PhysicalSpeakerLabelsPreflight.validate(environment, revision: revision) }
        try Task.checkCancellation()
        let app = XCUIApplication(bundleIdentifier: "ai.pichi.voice")
        app.launchArguments = []
        app.launchEnvironment = [:]
        try require(app.state == .runningForeground || app.state == .runningBackground,
                    "Settings preparation never launches or resumes an unknown AUT")
        app.activate()
        try tinySettingsIdle(app, revision: revision)
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("PhysicalReleaseUI/tiny-settings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(runID + ".json")
        let change: PhysicalTinySettingsTransaction.Change = { key, target in
            try self.tinySettingsIdle(app, revision: revision)
            switch key {
            case .model: try self.tinySettingsSelectModel(target.model, app: app, revision: revision)
            case .saveAudio, .pii:
                try self.openPhysicalSettingsPage("settings.privacy", app: app, revision: revision)
                let identifier = key == .saveAudio ? "privacy.saveAudio" : "privacy.pii"
                let value = key == .saveAudio ? target.saveAudio : target.pii
                let control = app.switches[identifier]
                try self.tinySettingsReveal(control, app: app, revision: revision)
                let before = try XCTUnwrap(control.value as? String)
                try self.require(before == "0" || before == "1", "Read an exact native switch value before changing it")
                if before != (value ? "1" : "0") {
                    try self.require(control.isEnabled && control.isHittable && app.alerts.count == 0,
                                     "Change only the observed enabled privacy switch")
                    control.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
                }
                let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value ? "1" : "0"), object: control)
                let changeResult = await XCTWaiter.fulfillment(of: [changed], timeout: 10)
                try self.require(changeResult == .completed, "Verify the requested native switch value")
                if key == .pii {
                    let active = app.descendants(matching: .any)["privacy.pii.active"].firstMatch
                    if value {
                        try self.require(active.waitForExistence(timeout: 180), "Requested PII must actually finish preparation")
                    } else {
                        let progress = app.descendants(matching: .any)["privacy.pii.progress"].firstMatch
                        try self.require(active.waitForNonExistence(timeout: 30)
                            && progress.waitForNonExistence(timeout: 30), "PII restoration must finish cancellation")
                    }
                }
            }
            try self.require(app.alerts.count == 0, "Never approve an operating-system or application prompt")
        }
        let verify: PhysicalTinySettingsTransaction.Verify = { expected in
            try self.require(self.tinySettingsRead(app, revision: revision) == expected,
                             "The public UI must show the complete expected settings profile")
        }
        if restore || FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            try require(values.isRegularFile == true && values.isSymbolicLink != true
                && (values.fileSize ?? Int.max) <= 4096, "Only a bounded regular runner-owned receipt can authorize restoration")
            var receipt = try JSONDecoder().decode(PhysicalTinySettingsReceipt.self, from: Data(contentsOf: url))
            try receipt.validate(revision: revision, runID: runID)
            if !restore {
                try require(receipt.phase == .prepared, "Restore an interrupted preparation before reusing its run ID")
                try verify(.strict)
                return
            }
            if receipt.phase == .restored { try verify(.original); return }
            do {
                try await PhysicalTinySettingsTransaction.restore(change: change, verify: verify)
                receipt.phase = .restored
                try receipt.save(to: url)
                capture("tiny-settings-restored", revision: revision)
            } catch {
                receipt.phase = .restorationRequired
                try? receipt.save(to: url)
                throw error
            }
        } else {
            // The concrete original profile comes from the parent's verified backup.
            // Reject a disagreement before the first mutation, never adopt it as a baseline.
            try verify(.original)
            try openPhysicalSettingsPage("settings.participants", app: app, revision: revision)
            try verifyAutomaticParticipantResources(in: app, revision: revision)
            try openPhysicalSettingsPage("settings.models", app: app, revision: revision)
            try tinySettingsReveal(app.buttons["model.activate.whisper-tiny"], app: app, revision: revision)
            try require(app.buttons["model.activate.whisper-tiny"].isEnabled,
                        "Tiny must already be installed; downloading or deleting a model is outside this driver")
            var receipt = PhysicalTinySettingsReceipt(version: 1, revision: revision, runID: runID,
                                                      original: .original, phase: .changing)
            try receipt.save(to: url)
            do {
                try await PhysicalTinySettingsTransaction.prepare(change: change, verify: verify) {
                    receipt.phase = .prepared
                    try receipt.save(to: url)
                }
                capture("tiny-settings-prepared", revision: revision)
            } catch {
                receipt.phase = error is PhysicalTinySettingsTransaction.RestorationRequired ? .restorationRequired : .restored
                try? receipt.save(to: url)
                throw error
            }
        }
        try tinySettingsIdle(app, revision: revision)
        print("[PHYSICAL_TINY_SETTINGS] operation=\(restore ? "restore" : "prepare") runID=\(runID) verified=true")
        #endif
    }

    @MainActor private func tinySettingsIdle(_ app: XCUIApplication, revision: String) throws {
        try require(app.state == .runningForeground && app.alerts.count == 0, "Preserve any foreground interruption or prompt")
        try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
        try require(!app.buttons["meeting.stop"].exists
            && !app.descendants(matching: .any)["meeting.recording"].firstMatch.exists
            && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists,
            "This driver owns no recording and must never stop or alter an active attempt")
    }

    @MainActor private func openPhysicalSettingsPage(_ identifier: String, app: XCUIApplication, revision: String) throws {
        try require(app.state == .runningForeground && app.alerts.count == 0, "Settings navigation cannot dismiss a prompt")
        try openNavigation(app, "settings", titles: ["Settings", "Настройки"], revision: revision)
        let root = app.descendants(matching: .any)["settings.root"].firstMatch
        if !root.waitForExistence(timeout: 2) || !root.isHittable {
            // A section switch preserves its pushed page; reselecting Settings pops to root.
            try openNavigation(app, "settings", titles: ["Settings", "Настройки"], revision: revision)
        }
        try require(root.waitForExistence(timeout: 5) && root.isHittable && app.alerts.count == 0,
                    "Reveal controls only in the ordinary Settings root")
        let control = app.buttons[identifier]
        try reveal(control, in: app, revision: revision, container: root)
        try tap(control, "Open only the requested public Settings page")
    }

    @MainActor private func tinySettingsReveal(_ element: XCUIElement, app: XCUIApplication, revision: String) throws {
        try reveal(element, in: app, revision: revision)
    }

    @MainActor private func verifyAutomaticParticipantResources(in app: XCUIApplication, revision: String,
                                                               requireReady: Bool = true) throws {
        try require(app.descendants(matching: .any)["settings.participants.detail"].firstMatch.exists,
                    "Inspect automatic participant resources only on their ordinary Settings page")
        let resources = app.descendants(matching: .any)["recording.requiredResources"].firstMatch
        try require(resources.waitForExistence(timeout: 10), "Automatic participant resources must be present")
        try reveal(resources, in: app, revision: revision)
        for identifier in ["recording.diarization", "recording.streamingDiarization"] {
            try require(!app.switches[identifier].exists, "Participant labels are automatic, not legacy UI switches")
        }
        if requireReady {
            let ready = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", [
                "Speech detection and speaker labels are ready", "Определение речи и участников готово"
            ])).firstMatch
            try require(ready.waitForExistence(timeout: 180) && app.alerts.count == 0,
                        "Automatic speech detection and participant resources must be ready")
        }
    }

    @MainActor private func tinySettingsSelectedModel(_ app: XCUIApplication, revision: String) throws -> String {
        let scroll = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        for direction in 0..<2 {
            for _ in 0..<6 {
                let selected = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "model.selected.")).allElementsBoundByIndex
                let identifiers = Set(selected.map(\.identifier))
                if identifiers.count == 1, let identifier = identifiers.first {
                    let model = String(identifier.dropFirst("model.selected.".count))
                    try require(model == "gigaam-v3-eou" || model == "whisper-tiny", "Do not overwrite an unrelated model selection")
                    return model
                }
                try require(identifiers.isEmpty && scroll.exists && app.alerts.count == 0, "Model selection must be unambiguous")
                if direction == 0 { scroll.swipeDown() } else { scroll.swipeUp() }
            }
        }
        throw verificationFailure("The public UI did not expose one installed selected model")
    }

    @MainActor private func tinySettingsSelectModel(_ model: String, app: XCUIApplication, revision: String) throws {
        try openPhysicalSettingsPage("settings.models", app: app, revision: revision)
        if try tinySettingsSelectedModel(app, revision: revision) == model { return }
        let activate = app.buttons["model.activate.\(model)"]
        try tinySettingsReveal(activate, app: app, revision: revision)
        try tap(activate, "Activate only an already installed owned model")
        try require(app.descendants(matching: .any)["model.selected.\(model)"].firstMatch.waitForExistence(timeout: 45),
                    "The model must finish its public activation transaction")
    }

    @MainActor private func tinySettingsRead(_ app: XCUIApplication, revision: String) throws -> PhysicalTinySettingsProfile {
        try tinySettingsIdle(app, revision: revision)
        try openPhysicalSettingsPage("settings.models", app: app, revision: revision)
        let model = try tinySettingsSelectedModel(app, revision: revision)
        try openPhysicalSettingsPage("settings.privacy", app: app, revision: revision)
        func value(_ identifier: String) throws -> Bool {
            let control = app.switches[identifier]
            try tinySettingsReveal(control, app: app, revision: revision)
            let raw = try XCTUnwrap(control.value as? String)
            try require(raw == "0" || raw == "1", "Only exact native switch values authorize mutation")
            return raw == "1"
        }
        let audio = try value("privacy.saveAudio"), pii = try value("privacy.pii")
        if pii {
            try require(app.descendants(matching: .any)["privacy.pii.active"].firstMatch.waitForExistence(timeout: 180),
                        "Requested PII is not yet active")
        }
        return .init(model: model, saveAudio: audio, pii: pii)
    }

    @MainActor
    func testTinySettingsPrepareRollsBackEveryPartiallyAppliedStep() async throws {
        for failingStep in 1...3 {
            let fake = PhysicalTinySettingsFake(failingPrepareStep: failingStep)
            do {
                try await PhysicalTinySettingsTransaction.prepare(change: fake.change, verify: fake.verify, commit: {})
                XCTFail("A failed partial preparation must not succeed")
            } catch PhysicalTinySettingsFake.Failure.injected {}
            XCTAssertEqual(fake.profile, .original)
            XCTAssertEqual(fake.restoreKeys, [.model, .pii, .saveAudio])
        }
    }

    @MainActor
    func testTinySettingsCommitRequiresVerifiedTargetAndCommitFailureRollsBack() async throws {
        let fake = PhysicalTinySettingsFake()
        var committed = false
        try await PhysicalTinySettingsTransaction.prepare(change: fake.change, verify: fake.verify) {
            XCTAssertEqual(fake.profile, .strict)
            committed = true
        }
        XCTAssertTrue(committed)
        try await PhysicalTinySettingsTransaction.restore(change: fake.change, verify: fake.verify)
        XCTAssertEqual(fake.profile, .original)
        do {
            try await PhysicalTinySettingsTransaction.prepare(change: fake.change, verify: fake.verify) {
                throw PhysicalTinySettingsFake.Failure.injected
            }
            XCTFail("A receipt commit failure must restore the original settings")
        } catch PhysicalTinySettingsFake.Failure.injected {
            XCTAssertEqual(fake.profile, .original)
        }
    }

    @MainActor
    func testTinySettingsCancellationJoinsRestorationAndReportsItsFailure() async throws {
        let work = Task { @MainActor in
            let fake = PhysicalTinySettingsFake(cancelPrepareStep: 2)
            do {
                try await PhysicalTinySettingsTransaction.prepare(change: fake.change, verify: fake.verify, commit: {})
                return false
            } catch is CancellationError { return fake.profile == .original }
            catch { return false }
        }
        let restored = await work.value
        XCTAssertTrue(restored)
        let fake = PhysicalTinySettingsFake(failingPrepareStep: 1, failRestoration: true)
        do {
            try await PhysicalTinySettingsTransaction.prepare(change: fake.change, verify: fake.verify, commit: {})
            XCTFail("A failed rollback must remain an explicit recovery requirement")
        } catch is PhysicalTinySettingsTransaction.RestorationRequired {
            XCTAssertNotEqual(fake.profile, .original)
        }
    }

    @MainActor
    func testTinySettingsReceiptRejectsAnotherRevisionRunAndBaseline() throws {
        let revision = String(repeating: "a", count: 40), run = "00000000-0000-0000-0000-000000000001"
        var receipt = PhysicalTinySettingsReceipt(version: 1, revision: revision, runID: run, original: .original, phase: .changing)
        let decoded = try JSONDecoder().decode(PhysicalTinySettingsReceipt.self, from: JSONEncoder().encode(receipt))
        XCTAssertNoThrow(try decoded.validate(revision: revision, runID: run))
        XCTAssertThrowsError(try decoded.validate(revision: String(repeating: "b", count: 40), runID: run))
        XCTAssertThrowsError(try decoded.validate(revision: revision, runID: UUID().uuidString))
        receipt.original.saveAudio = false
        XCTAssertThrowsError(try receipt.validate(revision: revision, runID: run))
        receipt.original = .original
        receipt.version = 2
        XCTAssertThrowsError(try receipt.validate(revision: revision, runID: run))
    }

    /// Opt-in regression against an already installed ordinary app. The parent
    /// preserves its data, owns the phone/audio lease and selects destination artifacts.
    @MainActor
    func testPhysicalGigaAMRecordingSurvivesSystemTransitions() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires the explicitly owned physical iPhone and microphone")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_PHYSICAL_GIGAAM_BACKGROUND_UI"] == "1" else {
            throw XCTSkip("Physical background recording requires explicit opt-in")
        }
        let revision = try XCTUnwrap(environment["PICHI_TEST_REVISION"])
        let priorModel = try XCTUnwrap(environment["PICHI_PHYSICAL_PRIOR_MODEL"])
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: false)
        let fixture = support.appendingPathComponent("BackgroundRecordingUI/speech.wav")
        var ownedPlayer: AVAudioPlayer?
        let audio = AVAudioSession.sharedInstance()
        let category = audio.category, mode = audio.mode, options = audio.categoryOptions
        defer {
            ownedPlayer?.stop()
            try? audio.setActive(false, options: .notifyOthersOnDeactivation)
            try? audio.setCategory(category, mode: mode, options: options)
        }
        let app = XCUIApplication(bundleIdentifier: "ai.pichi.voice")
        var ownsRecording = false
        var observedOwnedRecording = false
        func selectModel(_ model: String) throws {
            try self.openPhysicalSettingsPage("settings.models", app: app, revision: revision)
            let selected = app.descendants(matching: .any)["model.selected.\(model)"].firstMatch
            if !selected.exists {
                let activate = app.buttons["model.activate.\(model)"]
                try self.reveal(activate, in: app, revision: revision)
                try self.tap(activate, "Activate the already installed model")
            }
            try self.require(selected.waitForExistence(timeout: 45), "The requested installed model must become selected")
        }
        do {
            app.activate()
            try await waitForPhysicalAppState(app, .runningForeground, phase: "initial-foreground")
            try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
            try require(!app.buttons["meeting.stop"].exists
                && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists,
                "Preserve every existing recording and processing attempt")
            try selectModel("gigaam-v3-eou")
            capture("background-01-gigaam", revision: revision)
            let runner = XCUIApplication(bundleIdentifier: try XCTUnwrap(Bundle.main.bundleIdentifier))
            runner.activate()
            try await waitForPhysicalAppState(runner, .runningForeground, phase: "fixture-foreground")
            try audio.setCategory(.playback, mode: .default, options: .mixWithOthers)
            try audio.setActive(true)
            // prepareToPlay can activate the session; it follows foreground admission
            // and the explicit playback configuration, just like play itself.
            let player = try AVAudioPlayer(contentsOf: fixture)
            ownedPlayer = player
            player.numberOfLoops = -1
            player.volume = 0.15
            try require(player.prepareToPlay(), "Prepare approved synthetic speech in the phone runner")
            try require(player.play(), "Start the owned phone speaker fixture")
            app.activate()
            try await waitForPhysicalAppState(app, .runningForeground, phase: "recording-foreground")
            try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
            try reveal(app.buttons["meeting.start"], in: app, revision: revision)
            ownsRecording = true
            try tap(app.buttons["meeting.start"], "Start normal microphone recording")
            try await waitForVisibleRecording(in: app, timeout: 90)
            observedOwnedRecording = true
            try await observeVisibleRecording(in: app, player: player, seconds: 6)
            capture("background-02-recording", revision: revision)
            var timer = try visibleTimerSeconds(in: app)

            // Pull down Notification Center from the top edge, then dismiss it.
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
            try await Task.sleep(nanoseconds: 6_000_000_000)
            capture("background-03-notification-center", revision: revision)
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
                .press(forDuration: 0.05, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)))
            app.activate()
            try await waitForPhysicalAppState(app, .runningForeground, phase: "after-notifications")
            try verifyVisibleRecording(in: app)
            try require(visibleTimerSeconds(in: app) > timer, "Recording must survive Notification Center")
            capture("background-04-after-notifications", revision: revision)
            timer = try visibleTimerSeconds(in: app)

            XCUIDevice.shared.press(.home)
            try await waitForPhysicalAppState(app, .runningBackground, phase: "home-background")
            try await Task.sleep(nanoseconds: 8_000_000_000)
            try require(app.state == .runningBackground && player.isPlaying, "Microphone app and fixture must remain alive on Home")
            capture("background-05-home", revision: revision)
            app.activate()
            try await waitForPhysicalAppState(app, .runningForeground, phase: "after-home")
            try verifyVisibleRecording(in: app)
            try require(visibleTimerSeconds(in: app) > timer, "Recording must survive Home")
            timer = try visibleTimerSeconds(in: app)

            let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
            settings.activate()
            try await waitForPhysicalAppState(settings, .runningForeground, phase: "settings-foreground")
            try await waitForPhysicalAppState(app, .runningBackground, phase: "settings-background")
            try await Task.sleep(nanoseconds: 8_000_000_000)
            try require(settings.state == .runningForeground && app.state == .runningBackground && player.isPlaying,
                "Settings must remain in foreground while recording and the fixture stay alive")
            capture("background-06-other-app", revision: revision)
            app.activate()
            try await waitForPhysicalAppState(app, .runningForeground, phase: "after-settings")
            try verifyVisibleRecording(in: app)
            try require(visibleTimerSeconds(in: app) > timer, "Recording must survive another app")
            try require(liveTextCharacterCount(in: app) > 0, "Physical synthetic speech must produce visible captions")
            capture("background-07-returned", revision: revision)
            try await waitForPhysicalCommittedCaptionHistory(in: app, player: player, revision: revision)
            player.stop()
            try await exercisePhysicalCaptionScrollAndJump(in: app, revision: revision, prefix: "background-07-caption")
            try await requestPhysicalOwnedStop(in: app)
            try await waitForCompletedTranscript(in: app, timeout: 180)
            ownsRecording = false
            capture("background-08-completed", revision: revision)
            try selectModel(priorModel)
        } catch {
            let primaryError = error
            let failure = error as NSError
            print("[PHYSICAL_GIGAAM] primary_error domain=\(failure.domain) code=\(failure.code) detail=\(failure.localizedDescription)")
            ownedPlayer?.stop()
            // Cleanup must still join when the original test task was cancelled.
            let cleanup = Task { @MainActor in
                do {
                    if ownsRecording {
                        try await self.finishPhysicalOwnedRecording(in: app, observed: observedOwnedRecording)
                        ownsRecording = false
                    } else {
                        app.activate()
                        try await self.waitForPhysicalAppState(app, .runningForeground, phase: "cleanup-foreground")
                    }
                    self.capture("background-failure", revision: revision)
                    if !app.buttons["meeting.stop"].exists { try selectModel(priorModel) }
                    print("[PHYSICAL_GIGAAM] cleanup_joined=true")
                } catch {
                    let cleanupError = error as NSError
                    print("[PHYSICAL_GIGAAM] cleanup_requires_parent_inspection domain=\(cleanupError.domain) code=\(cleanupError.code) detail=\(cleanupError.localizedDescription)")
                    self.capture("background-cleanup-unresolved", revision: revision)
                }
            }
            await cleanup.value
            throw primaryError
        }
        #endif
    }

    @MainActor private func finishPhysicalOwnedRecording(in app: XCUIApplication, observed: Bool) async throws {
        app.activate()
        try await waitForPhysicalAppState(app, .runningForeground, phase: "cleanup-foreground")
        let stop = app.buttons["meeting.stop"]
        try await PhysicalOwnedRecordingCleanup.run(observe: {
            guard app.state == .runningForeground, app.alerts.count == 0 else { return nil }
            return PhysicalUITransitionWait.ownedRecordingAction(
                stopReady: stop.exists && stop.isEnabled && stop.isHittable,
                processing: app.descendants(matching: .any)["meeting.processing"].firstMatch.exists,
                completed: observed && app.buttons["transcript.more"].exists && !stop.exists)
        }, stop: { try await self.requestPhysicalOwnedStop(in: app) },
           join: { try await self.waitForCompletedTranscript(in: app, timeout: 120) })
    }

    @MainActor private func waitForPhysicalAppState(_ app: XCUIApplication, _ expected: XCUIApplication.State,
                                                   phase: String) async throws {
        print("[PHYSICAL_GIGAAM] phase=\(phase) initial_state=\(app.state.rawValue) expected=\(expected.rawValue)")
        do {
            try await PhysicalUITransitionWait.until(timeout: 10, condition: { app.state == expected })
        } catch {
            print("[PHYSICAL_GIGAAM] phase=\(phase) failed_state=\(app.state.rawValue)")
            throw error
        }
        print("[PHYSICAL_GIGAAM] phase=\(phase) observed_state=\(app.state.rawValue)")
    }

    @MainActor private func requestPhysicalOwnedStop(in app: XCUIApplication) async throws {
        let stop = app.buttons["meeting.stop"]
        try await PhysicalUITransitionWait.until(timeout: 10, condition: {
            app.state == .runningForeground && app.alerts.count == 0
                && stop.exists && stop.isEnabled && stop.isHittable
        })
        try tap(stop, "Stop only this test's recording through the ready public control")
        // Disabled/gone is early UI admission evidence, never proof that capture joined.
        try await PhysicalUITransitionWait.until(timeout: 10, condition: { !stop.exists || !stop.isEnabled })
        print("[PHYSICAL_GIGAAM] stop_control_transition_observed=true capture_join_not_yet_proven=true")
    }

    /// Observes an already running frozen Release after the parent preserves its data.
    /// The parent owns normal launch, reboot, unlock and continuous native capture.
    @MainActor
    func testPhysicalReadOnlyMeetingHistoryAfterColdStart() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Saved physical history observation requires the explicitly selected device")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_PHYSICAL_HISTORY_READ_ONLY"] == "1" else {
            throw XCTSkip("Explicitly enable read-only observation of existing physical History")
        }
        let revision = try XCTUnwrap(environment["PICHI_TEST_REVISION"])
        let phase = try XCTUnwrap(environment["PICHI_PHYSICAL_HISTORY_PHASE"])
        let sourceIDs = try XCTUnwrap(environment["PICHI_PHYSICAL_HISTORY_EXPECTED_IDS"])
        try require(["before-reboot", "after-reboot"].contains(phase) && sourceIDs.count <= 1024,
                    "Supply a known reboot phase and one through ten existing visible session UUIDs")
        let values = sourceIDs.split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let parsed = values.compactMap { UUID(uuidString: $0)?.uuidString }
        let expectedIDs = Set(parsed)
        try require((1...10).contains(values.count) && parsed.count == values.count
                    && expectedIDs.count == values.count,
                    "Expected History IDs must be distinct valid UUIDs from the preserved device data")
        let app = try attachReadOnlyPhysicalApp(revision: revision)
        var historyNavigationCompleted = false
        var loadedWithoutRefresh = false
        defer {
            let observedIDs = historyIDs(in: app).sorted()
            let report: [String: Any] = [
                "phase": phase, "revision": revision,
                "expectedSessionIDs": expectedIDs.sorted(),
                "observedSessionIDs": observedIDs, "observedRowCount": observedIDs.count,
                "expectedRowsLoadedWithoutRefresh": loadedWithoutRefresh,
                "historyNavigationCompleted": historyNavigationCompleted, "manualRefreshActions": 0,
                "scope": "Attach-only observation of existing saved History; no app launch, transcript opening, scrolling, search, settings or recording actions"
            ]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "physical-history-\(phase)-\(revision).json"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            let accessibility = XCTAttachment(string: app.debugDescription)
            accessibility.name = "physical-history-\(phase)-\(revision)-accessibility"
            accessibility.lifetime = .keepAlways
            add(accessibility)
            capture("history-\(phase)-final", revision: revision)
        }
        capture("history-\(phase)-initial", revision: revision)
        try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
        historyNavigationCompleted = true
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        for id in expectedIDs.sorted() {
            let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            let rows = app.buttons.matching(identifier: "history.session.\(id)")
            try require(rows.firstMatch.waitForExistence(timeout: remaining) && rows.count == 1,
                        "Existing saved History must load its expected unique rows without manual refresh")
        }
        try require(app.state == .runningForeground && app.alerts.count == 0
                    && !app.buttons["meeting.stop"].exists
                    && !app.descendants(matching: .any)["meeting.recording"].firstMatch.exists
                    && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists,
                    "History observation must remain idle without starting or interrupting an attempt")
        loadedWithoutRefresh = true
        #endif
    }

    /// Opt in with PICHI_PHYSICAL_PROTECTED_EXPORT_ICLOUD_ROOT=1, the existing
    /// PICHI_PHYSICAL_READ_ONLY_IDLE_PREFLIGHT=1 / SESSION_ID / SESSION_TITLE /
    /// SESSION_STATE=completed contract, plus
    /// PICHI_PHYSICAL_PROTECTED_EXPORT_DESTINATION="iCloud Drive". Supply
    /// PICHI_PHYSICAL_PROTECTED_EXPORT_FILENAME=pichi-protected-<slug>-<32 lowercase hex>.json.
    /// The parent owns fresh preservation, continuous frames and exact Mac readback.
    @MainActor
    func testPhysicalOwnedCompletedProtectedExportToICloudDriveRoot() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires an explicitly authorized completed physical-device meeting")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_PHYSICAL_PROTECTED_EXPORT_ICLOUD_ROOT"] == "1" else {
            throw XCTSkip("Enable protected export of one explicitly verified owned completed meeting")
        }
        let revision = try XCTUnwrap(environment["PICHI_TEST_REVISION"])
        let sessionID = try XCTUnwrap(environment["PICHI_PHYSICAL_READ_ONLY_SESSION_ID"])
        let title = try XCTUnwrap(environment["PICHI_PHYSICAL_READ_ONLY_SESSION_TITLE"])
        let filename = try XCTUnwrap(environment["PICHI_PHYSICAL_PROTECTED_EXPORT_FILENAME"])
        let root = "iCloud Drive"
        try require(UUID(uuidString: sessionID) != nil && !title.isEmpty && title.count <= 1024
                    && environment["PICHI_PHYSICAL_READ_ONLY_SESSION_STATE"] == "completed"
                    && environment["PICHI_PHYSICAL_PROTECTED_EXPORT_DESTINATION"] == root,
                    "Supply the exact owned completed session and explicitly authorize iCloud Drive root")
        try require(filename.range(of: "\\Apichi-protected-[a-z0-9][a-z0-9-]{0,47}-[0-9a-f]{32}\\.json\\z",
                                   options: .regularExpression) != nil,
                    "Use a bounded ASCII JSON basename with a fresh random 32-hex suffix; no paths or overwrite")
        let app = try attachReadOnlyPhysicalApp(revision: revision)
        let starts = app.buttons.matching(identifier: "meeting.start")
        let ready = app.descendants(matching: .any)["history.list"].firstMatch.exists
            && starts.count == 1 && starts.firstMatch.isHittable && starts.firstMatch.isEnabled
        try require(!app.otherElements["ActivityListView"].exists
                    && !app.otherElements["Browse View (Picker)"].exists
                    && (ready || completedReadOnlyTranscriptVisible(in: app, title: title)),
                    "Begin ready or on the exact owned completed transcript, without pre-existing native export UI")
        captureProtectedExportStep("root-export-01-idle-entry", app: app, revision: revision)
        try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
        captureProtectedExportStep("root-export-02-owned-history-list", app: app, revision: revision)
        let rows = app.buttons.matching(identifier: "history.session.\(sessionID)")
        try require(rows.firstMatch.waitForExistence(timeout: 10) && rows.count == 1
                    && rows.firstMatch.staticTexts.matching(NSPredicate(format: "label == %@", title)).count == 1,
                    "Only the unique exact owned history ID with its expected title may be opened")
        try tap(rows.firstMatch, "Open only the exact owned completed history session")
        captureProtectedExportStep("root-export-03-owned-history-transcript", app: app, revision: revision)
        try require(completedReadOnlyTranscriptVisible(in: app, title: title),
                    "The selected owned record must remain completed and exportable")
        try require(app.buttons.matching(identifier: "transcript.more").count == 1,
                    "The owned transcript must expose one actions control")
        try tap(app.buttons["transcript.more"], "Open the owned transcript's ordinary actions")
        captureProtectedExportStep("root-export-04-protected-actions", app: app, revision: revision)
        try require(app.buttons.matching(identifier: "transcript.exportProtected").count == 1,
                    "Only the unique protected transcript export may be selected")
        try tap(app.buttons["transcript.exportProtected"], "Open only protected transcript export")
        let activities = app.otherElements.matching(identifier: "ActivityListView")
        let activity = activities.firstMatch
        let identifiedSaves = app.buttons.matching(identifier: "DOCPicker.actionButton")
        let identifiedNames = app.textFields.matching(identifier: "DOCPicker.filenameTextField")
        let nativePickers = app.otherElements.matching(identifier: "Browse View (Picker)")
        // iPadOS 17 omits both DOCPicker control identifiers. Admit only its
        // observed owned picker, one browsing root, one native navbar Save and
        // one filename TextField in that picker. Never mix partial schemas.
        let browsingRoots = nativePickers.otherElements.matching(NSPredicate(format:
            "identifier BEGINSWITH %@", "DOC.browsingRoot Source: "))
        let nativeBars = browsingRoots.navigationBars.matching(identifier: "FullDocumentManagerViewControllerNavigationBar")
        let nativeSaves = nativeBars.buttons.matching(NSPredicate(format: "label IN %@", ["Save", "Сохранить"]))
        let nativeNames = nativePickers.textFields
        var usesControlIdentifiers: Bool { identifiedSaves.count > 0 || identifiedNames.count > 0 }
        var saves: XCUIElementQuery { usesControlIdentifiers ? identifiedSaves : nativeSaves }
        var names: XCUIElementQuery { usesControlIdentifiers ? identifiedNames : nativeNames }
        func saveControlsAreUnique() -> Bool {
            if usesControlIdentifiers { return identifiedSaves.count == 1 && identifiedNames.count == 1 }
            return nativePickers.count == 1 && browsingRoots.count == 1 && nativeBars.count == 1
                && nativeSaves.count == 1 && nativeNames.count == 1
        }
        var ownsActivity = true
        var ownsPicker = false
        defer {
            // Cancel only native UI opened here. Unknown alerts are never accepted.
            if ownsActivity || ownsPicker {
                captureProtectedExportStep("root-export-failure-observed", app: app, revision: revision)
            }
            if app.state == .runningForeground && app.alerts.count == 0 {
                if ownsPicker && (saves.count == 1 || names.count == 1
                    || app.otherElements["Browse View (Picker)"].exists) {
                    let cancel = app.buttons.matching(NSPredicate(format: "label IN %@",
                        ["Cancel", "Отмена", "Отменить"]))
                    if cancel.count == 1 && cancel.firstMatch.isHittable {
                        cancel.firstMatch.tap()
                        captureProtectedExportStep("root-export-cleanup-picker-cancel", app: app, revision: revision)
                    }
                }
                // iPadOS 17 exposes a label-only Close inside this owned native
                // activity navbar. Never close an unrelated or pre-existing UI.
                let identifiedClose = activities.buttons.matching(identifier: "header.closeButton")
                let contentBars = activities.navigationBars.matching(identifier: "UIActivityContentView")
                let nativeClose = contentBars.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "Закрыть"]))
                let close = identifiedClose.count > 0 ? identifiedClose : nativeClose
                let uniqueClose = identifiedClose.count > 0 ? identifiedClose.count == 1
                    : contentBars.count == 1 && nativeClose.count == 1
                if ownsActivity && activities.count == 1 && app.alerts.count == 0 && uniqueClose
                    && close.firstMatch.isEnabled && close.firstMatch.isHittable {
                    close.firstMatch.tap()
                    captureProtectedExportStep("root-export-cleanup-activity-close", app: app, revision: revision)
                }
            }
        }
        try require(activity.waitForExistence(timeout: 15) && activities.count == 1 && app.alerts.count == 0,
                    "Protected export must present the native activity UI without alerts")
        captureProtectedExportStep("root-export-05-native-activity", app: app, revision: revision)
        let saveFiles = app.cells.matching(NSPredicate(format: "label IN %@",
            ["Save to Files", "Сохранить в Файлы", "Сохранить в «Файлы»"]))
        try require(saveFiles.firstMatch.waitForExistence(timeout: 10) && saveFiles.count == 1,
                    "The owned native activity list must offer one unambiguous Save to Files")
        try tap(saveFiles.firstMatch, "Open the native Save to Files destination picker")
        ownsPicker = true
        let pickerAppeared = identifiedSaves.firstMatch.waitForExistence(timeout: 1)
            || nativePickers.firstMatch.waitForExistence(timeout: 10)
        try require(pickerAppeared && saveControlsAreUnique() && app.alerts.count == 0,
                    "The owned native save picker must expose one complete unambiguous native control schema")
        captureProtectedExportStep("root-export-06-native-picker", app: app, revision: revision)

        let rootBars = app.navigationBars.matching(identifier: root)
        // This provider identity and its separate title are observed native AX,
        // not a similarly named folder found by global text matching.
        let cloudRoots = app.otherElements.matching(NSPredicate(format:
            "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
            "DOC.browsingRoot Source: com.apple.CloudDocs.iCloudDriveFileProvider/", ", Title: iCloud Drive"))
        func rootIsVerified() -> Bool {
            rootBars.count <= 1 && cloudRoots.count <= 1 && (rootBars.count == 1 || (cloudRoots.count == 1
                && cloudRoots.firstMatch.navigationBars.matching(identifier: "FullDocumentManagerViewControllerNavigationBar")
                    .staticTexts.matching(NSPredicate(format: "label == %@", root)).count == 1))
        }
        let locations = app.cells.matching(NSPredicate(format: "identifier == %@ AND label == %@",
            "DOC.sidebar.item.iCloud Drive", root))
        var explicitlySelectedRoot = false
        for step in 0..<5 {
            try require(app.alerts.count == 0 && saveControlsAreUnique(),
                        "Remain inside the owned native save picker without accepting alerts")
            if locations.count == 1 && locations.firstMatch.isHittable {
                try tap(locations.firstMatch, "Choose only the explicit iCloud Drive provider root")
                captureProtectedExportStep("root-export-07-explicit-cloud-root", app: app, revision: revision)
                explicitlySelectedRoot = true
                break
            }
            let browse = app.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "Обзор"]))
            let back = app.buttons.matching(identifier: "BackButton")
            if browse.count == 1 && browse.firstMatch.isHittable {
                try tap(browse.firstMatch, "Reveal native Files locations through Browse")
            } else if back.count == 1 && back.firstMatch.isHittable {
                try tap(back.firstMatch, "Return through the owned native picker's exact Back control")
            } else {
                throw verificationFailure("Cannot verify the explicit iCloud Drive root; no Recents, search or guessed destination is used")
            }
            captureProtectedExportStep("root-export-08-location-navigation-\(step)", app: app, revision: revision)
        }
        let rootAppeared = cloudRoots.firstMatch.waitForExistence(timeout: 5)
            || rootBars.firstMatch.waitForExistence(timeout: 1)
        try require(explicitlySelectedRoot && rootAppeared && rootIsVerified()
                    && saveControlsAreUnique() && app.alerts.count == 0,
                    "After explicit provider selection, native navigation must confirm iCloud Drive root")
        captureProtectedExportStep("root-export-09-root-confirmed", app: app, revision: revision)
        let stem = (filename as NSString).deletingPathExtension
        let existing = app.cells.matching(NSPredicate(format:
            "label == %@ OR label == %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@",
            filename, stem, filename + ",", stem + ","))
        try require(existing.count == 0 && !app.staticTexts[filename].exists && !app.staticTexts[stem].exists,
                    "The fresh unique export basename must not already exist; overwrite is forbidden")
        let name = names.firstMatch
        let previous = try XCTUnwrap(name.value as? String)
        try require(!previous.isEmpty && previous.count <= 256,
                    "The native filename field must contain a bounded editable filename")
        try tap(name, "Edit only the owned export filename")
        captureProtectedExportStep("root-export-10-filename-editing", app: app, revision: revision)
        // Retain Files' observed extension convention to avoid a doubled suffix.
        let enteredName = previous.lowercased().hasSuffix(".json") ? filename : stem
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + enteredName)
        captureProtectedExportStep("root-export-11-unique-name-entered", app: app, revision: revision)
        try require(name.value as? String == enteredName && rootIsVerified() && app.alerts.count == 0
                    && saveControlsAreUnique() && saves.firstMatch.isEnabled && saves.firstMatch.isHittable
                    && existing.count == 0 && !app.staticTexts[filename].exists && !app.staticTexts[stem].exists,
                    "Save requires the exact unique filename in verified iCloud Drive root with no conflict")
        captureProtectedExportStep("root-export-12-save-ready", app: app, revision: revision)
        try tap(saves.firstMatch, "Save the protected JSON only to the explicitly verified iCloud Drive root")
        captureProtectedExportStep("root-export-13-save-requested", app: app, revision: revision)
        try require(saves.firstMatch.waitForNonExistence(timeout: 15) && !names.firstMatch.exists
                    && activity.waitForNonExistence(timeout: 10) && app.alerts.count == 0
                    && completedReadOnlyTranscriptVisible(in: app, title: title),
                    "Native Save must dismiss to the same owned completed transcript without any replacement or confirmation")
        ownsPicker = false
        ownsActivity = false
        captureProtectedExportStep("root-export-14-native-save-dismissed", app: app, revision: revision)
        print("[PHYSICAL_PROTECTED_EXPORT_ICLOUD_ROOT] filename=\(filename) native_save_dismissed=true readback_required=true")
        #endif
    }

    @MainActor private func captureProtectedExportStep(_ step: String, app: XCUIApplication, revision: String) {
        capture(step, revision: revision)
        let accessibility = XCTAttachment(string: app.debugDescription)
        accessibility.name = "\(name)-\(step)-accessibility-\(revision)"
        accessibility.lifetime = .keepAlways
        add(accessibility)
    }

    /// Observation only: the parent verifies the saved session and idle process,
    /// preserves current data and owns continuous native frame capture. This test
    /// never starts, stops, relaunches, retries, edits or deletes a meeting.
    @MainActor
    func testPhysicalOwnedCompletedProtectedShareObservation() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires an explicitly authorized completed physical-device meeting")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_PHYSICAL_PROTECTED_SHARE_OBSERVATION"] == "1" else {
            throw XCTSkip("Enable observation of an explicitly verified owned completed meeting")
        }
        let revision = try XCTUnwrap(environment["PICHI_TEST_REVISION"])
        let sessionID = try XCTUnwrap(environment["PICHI_PHYSICAL_READ_ONLY_SESSION_ID"])
        let title = try XCTUnwrap(environment["PICHI_PHYSICAL_READ_ONLY_SESSION_TITLE"])
        try require(UUID(uuidString: sessionID) != nil && !title.isEmpty && title.count <= 1024
                    && environment["PICHI_PHYSICAL_READ_ONLY_SESSION_STATE"] == "completed",
                    "The parent must supply an exact owned session ID, title and completed state")
        let app = try attachReadOnlyPhysicalApp(revision: revision)
        try require(completedReadOnlyTranscriptVisible(in: app, title: title),
                    "Begin on the exact parent-verified completed transcript, with no active attempt")
        capture("share-observation-01-owned-completed-current", revision: revision)
        try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
        let row = app.buttons["history.session.\(sessionID)"]
        try require(row.waitForExistence(timeout: 10) && row.isEnabled && row.isHittable,
                    "Only the exact owned history session may be selected; no search or other row is opened")
        try require(row.staticTexts.matching(NSPredicate(format: "label == %@", title)).firstMatch.exists,
                    "The exact owned history ID must also expose its expected title")
        try tap(row, "Open only the exact owned completed history session")
        capture("share-observation-02-owned-history-transcript", revision: revision)
        try require(completedReadOnlyTranscriptVisible(in: app, title: title),
                    "The selected owned history record must remain completed and exportable")
        let more = app.buttons["transcript.more"]
        try tap(more, "Open the completed transcript's ordinary actions")
        capture("share-observation-03-protected-export-menu", revision: revision)
        try tap(app.buttons["transcript.exportProtected"], "Open only protected transcript export")
        let activityList = app.otherElements["ActivityListView"]
        let close = app.buttons["header.closeButton"]
        var ownsShare = true
        defer {
            // Only dismiss the exact native activity UI opened by this selector.
            // Never accept an alert, pick a destination or tap a suggested contact.
            if ownsShare && app.state == .runningForeground && activityList.exists
                && app.alerts.count == 0 && close.exists && close.isHittable {
                close.tap()
                capture("share-observation-cleanup-native-close", revision: revision)
            }
        }
        try require(activityList.waitForExistence(timeout: 15) && app.alerts.count == 0,
                    "The ordinary protected export must present the observed native activity UI")
        capture("share-observation-04-native-activity", revision: revision)
        let accessibility = XCTAttachment(string: app.debugDescription)
        accessibility.name = "protected-share-observation-accessibility-\(revision)"
        accessibility.lifetime = .keepAlways
        add(accessibility)
        try tap(close, "Close only the observed native activity header")
        try require(activityList.waitForNonExistence(timeout: 10)
                    && completedReadOnlyTranscriptVisible(in: app, title: title),
                    "Cancelling observation must return to the same owned completed transcript")
        ownsShare = false
        capture("share-observation-05-cancelled-no-delivery", revision: revision)
        print("[PHYSICAL_PROTECTED_SHARE_OBSERVATION] native_ui_observed_and_cancelled delivery_attempted=false")
        #endif
    }

    @MainActor private func attachReadOnlyPhysicalApp(revision: String) throws -> XCUIApplication {
        continueAfterFailure = false
        try require(revision.count == 40 && revision.allSatisfy { "0123456789abcdef".contains($0) }
                    && ProcessInfo.processInfo.environment["PICHI_PHYSICAL_READ_ONLY_IDLE_PREFLIGHT"] == "1",
                    "The parent must freshly preserve all current data and verify an idle frozen Release process")
        let app = XCUIApplication()
        app.launchArguments = []
        app.launchEnvironment = [:]
        switch app.state {
        case .runningForeground: break
        case .runningBackground: app.activate()
        case .notRunning, .runningBackgroundSuspended, .unknown:
            throw verificationFailure("Read-only observation never launches, relaunches or resumes an unknown/suspended AUT")
        @unknown default:
            throw verificationFailure("The existing AUT state is unsupported for read-only observation")
        }
        try require(app.state == .runningForeground && app.alerts.count == 0
                    && !app.buttons["meeting.stop"].exists
                    && !app.descendants(matching: .any)["meeting.recording"].firstMatch.exists
                    && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists,
                    "Read-only observation requires the parent's idle process, never an active attempt")
        return app
    }

    @MainActor private func completedReadOnlyTranscriptVisible(in app: XCUIApplication, title: String) -> Bool {
        app.state == .runningForeground && app.alerts.count == 0
            && app.staticTexts.matching(NSPredicate(format: "label == %@", title)).firstMatch.exists
            && app.buttons["transcript.more"].exists && app.buttons["transcript.more"].isHittable
            && !app.buttons["meeting.stop"].exists && !app.buttons["meeting.retry"].exists
            && !app.buttons["meeting.restartProcessing"].exists
            && !app.descendants(matching: .any)["meeting.recording"].firstMatch.exists
            && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists
            && !app.staticTexts.matching(NSPredicate(format: "label IN %@",
                ["Transcription was interrupted", "Расшифровка записи прервана",
                 "Transcription failed", "Не удалось расшифровать запись"])).firstMatch.exists
    }

    @MainActor
    func testPhysicalOwnerVoiceSampleIsSavedWhenCheckedAndCanBeDeleted() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires an explicitly authorized physical-device audio lease")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_PHYSICAL_OWNER_VOICE_UI"] == "1",
              environment["PICHI_PHYSICAL_RELEASE_UI_AUDIO"] == "1" else {
            throw XCTSkip("Enable physical owner voice checking and audible playback explicitly")
        }
        let revision = try XCTUnwrap(environment["PICHI_TEST_REVISION"])
        try require(!revision.isEmpty && revision != "working-tree", "A concrete AUT revision is required")
        let runnerID = try XCTUnwrap(Bundle.main.bundleIdentifier)
        try require(runnerID.hasSuffix(".xctrunner"), "Playback must be owned by the UI test runner")
        let backgroundModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        try require(backgroundModes.contains("audio"), "The frozen signed UI runner must declare background audio")
        let assets = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: false)
        let fixture = assets.appendingPathComponent("PhysicalReleaseUI/audio/owner-enrollment.wav")
        try require(FileManager.default.fileExists(atPath: fixture.path), "Stage the approved synthetic owner voice WAV in the runner")
        var ownedPlayer: AVAudioPlayer?

        let app = XCUIApplication()
        app.launchArguments = []
        app.launchEnvironment = [:]
        app.activate()
        try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
        try require(!app.buttons["meeting.stop"].exists
                    && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists,
                    "An existing meeting or transcription is not owned by this test")
        try openNavigation(app, "settings", titles: ["Settings", "Настройки"], revision: revision)
        try tap(app.buttons["settings.participants"], "Open the ordinary participant settings")
        let start = app.buttons["ownerVoice.start"]
        try reveal(start, in: app, revision: revision)
        let status = app.descendants(matching: .any)["ownerVoice.status"].firstMatch
        try require(status.waitForExistence(timeout: 5), "The existing owner profile status must be visible")
        // Allow the Settings transaction's asynchronous metadata refresh to settle.
        // A human profile is never deleted, replaced, or used as a synthetic test draft.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        if app.buttons["ownerVoice.delete"].exists
            || ["Your voice is saved", "Ваш голос сохранён"].contains(status.label) {
            throw XCTSkip("A pre-existing owner profile is preserved; this test requires an unset profile")
        }
        try require(["Your voice is not set up", "Ваш голос ещё не настроен"].contains(status.label),
                    "The app must confirm that no owner profile is configured")
        try require(!app.buttons["ownerVoice.save"].exists && !app.buttons["ownerVoice.cancel"].exists,
                    "An existing enrollment transaction is not owned by this test")
        try require(app.alerts.count == 0 && !app.staticTexts["ownerVoice.error"].exists,
                    "Permissions and owner profile readiness must be resolved before the audio lease")
        capture("owner-01-profile-unset", revision: revision)

        let audioSession = AVAudioSession.sharedInstance()
        try require(audioSession.outputVolume > 0.05, "Device output must be audible before playback")
        let originalCategory = audioSession.category
        let originalMode = audioSession.mode
        let originalOptions = audioSession.categoryOptions
        var changedPlaybackCategory = false
        var ownsPlaybackSession = false
        var ownsEnrollment = false
        var savedSyntheticProfile = false
        defer {
            ownedPlayer?.stop()
            if ownsPlaybackSession { try? audioSession.setActive(false, options: .notifyOthersOnDeactivation) }
            if changedPlaybackCategory {
                try? audioSession.setCategory(originalCategory, mode: originalMode, options: originalOptions)
            }
        }
        do {
            let runner = XCUIApplication(bundleIdentifier: runnerID)
            runner.activate()
            try require(runner.state == .runningForeground, "The runner must initiate foreground playback")
            try audioSession.setCategory(.playback, mode: .default, options: .mixWithOthers)
            changedPlaybackCategory = true
            try audioSession.setActive(true)
            ownsPlaybackSession = true
            let player = try AVAudioPlayer(contentsOf: fixture)
            ownedPlayer = player
            try require(player.duration.isFinite && player.duration >= 15, "Owner checking requires a valid single-voice speech fixture")
            player.numberOfLoops = -1
            player.volume = 0.8
            try require(player.prepareToPlay(), "The runner must prepare actual synthetic speech playback")
            try require(player.play(), "The runner must start synthetic owner speech")
            app.activate()
            try tap(start, "Start the ordinary owner voice microphone capture")
            ownsEnrollment = true
            let stop = app.buttons["ownerVoice.stop"]
            try require(stop.waitForExistence(timeout: 30), "Owner voice setup must start actual microphone capture")
            capture("owner-02-microphone-recording", revision: revision)
            let began = ProcessInfo.processInfo.systemUptime
            for second in 1...18 {
                let remaining = began + Double(second) - ProcessInfo.processInfo.systemUptime
                if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                try require(player.isPlaying, "Synthetic owner speech playback must continue during capture")
                if !stop.exists { break } // The production capture may reach its bounded duration itself.
            }
            if stop.exists { try tap(stop, "Finish the bounded owner voice sample") }
            try require(stop.waitForNonExistence(timeout: 10), "Microphone capture must join before checking the sample")
            player.stop()
            capture("owner-03-sample-checking", revision: revision)
            // A checked sample is saved without a separate step; the synthetic profile is then removed.
            let delete = app.buttons["ownerVoice.delete"]
            let deadline = ProcessInfo.processInfo.systemUptime + 120
            while !delete.exists && ProcessInfo.processInfo.systemUptime < deadline {
                try require(!app.staticTexts["ownerVoice.error"].exists, "The actual single-voice microphone sample must pass checking")
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            savedSyntheticProfile = delete.exists
            try require(delete.exists && ["Your voice is saved", "Ваш голос сохранён"].contains(status.label),
                        "A checked sample must be saved without a separate Save action")
            try require(!app.buttons["ownerVoice.save"].exists, "Saving needs no separate action")
            capture("owner-04-checked-sample-saved", revision: revision)
            try reveal(delete, in: app, revision: revision)
            try tap(delete, "Remove the synthetic owner profile")
            let confirm = app.buttons.matching(NSPredicate(format: "label IN %@", ["Delete", "Удалить"])).firstMatch
            try require(confirm.waitForExistence(timeout: 5), "Deleting the voice profile asks first")
            try tap(confirm, "Confirm removing the synthetic owner profile")
            try require(delete.waitForNonExistence(timeout: 15), "Delete must remove the saved profile")
            savedSyntheticProfile = false
            ownsEnrollment = false
            try require(["Your voice is not set up", "Ваш голос ещё не настроен"].contains(status.label),
                        "The owner profile must be unset after deleting the synthetic profile")
            capture("owner-05-profile-deleted", revision: revision)
            try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
            try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
            try require(!app.buttons["meeting.stop"].exists, "Owner checking must release capture without starting a meeting")
            try openNavigation(app, "settings", titles: ["Settings", "Настройки"], revision: revision)
            try tap(app.buttons["settings.participants"], "Reopen participant settings after capture cleanup")
            try reveal(start, in: app, revision: revision)
            try require(start.isEnabled && !app.buttons["ownerVoice.delete"].exists,
                        "Navigation must remain responsive and the deleted profile must not return")
            capture("owner-06-clean-settings-reopened", revision: revision)
        } catch {
            ownedPlayer?.stop()
            // The precondition proved no human profile existed, so a saved one is the synthetic sample.
            if savedSyntheticProfile || (app.buttons["ownerVoice.delete"].exists && ownsEnrollment) {
                app.activate()
                let delete = app.buttons["ownerVoice.delete"]
                if delete.exists && delete.isHittable { delete.tap() }
                let confirm = app.buttons.matching(NSPredicate(format: "label IN %@", ["Delete", "Удалить"])).firstMatch
                if confirm.waitForExistence(timeout: 5) { confirm.tap() }
                if !delete.waitForNonExistence(timeout: 15) {
                    print("[PHYSICAL_OWNER_UI] synthetic_profile_cleanup_requires_parent_inspection revision=\(revision)")
                }
                self.capture("owner-failure-synthetic-profile-cleanup", revision: revision)
                ownsEnrollment = false
            }
            if ownsEnrollment {
                let cleanup = Task { @MainActor in
                    app.activate()
                    let cancel = app.buttons["ownerVoice.cancel"]
                    if cancel.exists && cancel.isEnabled { cancel.tap() }
                    let deadline = ProcessInfo.processInfo.systemUptime + 120
                    while app.buttons["ownerVoice.cancel"].exists && ProcessInfo.processInfo.systemUptime < deadline {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                    self.capture("owner-failure-draft-cleanup", revision: revision)
                    if app.buttons["ownerVoice.cancel"].exists {
                        print("[PHYSICAL_OWNER_UI] cleanup_requires_parent_inspection revision=\(revision)")
                    }
                }
                await cleanup.value
            }
            throw error
        }
        #endif
    }

    @MainActor
    func testPhysicalOwnedPostSoakCompletedJSONShareAndRelaunch() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires the parent's exact owned completed physical-device session")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_PHYSICAL_POST_SOAK_CONTINUATION"] == "1" else {
            throw XCTSkip("Explicitly enable only the after-Stop continuation; this never replays the soak")
        }
        let revision = try XCTUnwrap(environment["PICHI_TEST_REVISION"])
        let selected = try PhysicalPostSoakAuthorization.select(environment, revision: revision)
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: false)
        let receiptURL = support.appendingPathComponent("PhysicalReleaseUI/post-soak/\(selected.runID.uuidString).json")
        let attributes = try FileManager.default.attributesOfItem(atPath: receiptURL.path)
        try require(((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 8192,
                    "The parent must stage a bounded owned-session attestation in this runner only")
        let receiptData = try Data(contentsOf: receiptURL)
        try require(receiptData.count <= 8192, "The runner receipt exceeded its bound")
        try JSONDecoder().decode(PhysicalPostSoakReceipt.self, from: receiptData).validate(selected)
        let app = try attachReadOnlyPhysicalApp(revision: revision)
        let sessionID = selected.sessionID.uuidString
        let activity = app.otherElements["ActivityListView"]
        try require(!activity.exists && !app.otherElements["Browse View (Picker)"].exists,
                    "Never adopt a pre-existing share sheet or document picker")
        capture("post-soak-01-idle-attested", revision: revision)

        func reopenOwnedSession(_ step: String) async throws {
            try require(!app.buttons["meeting.stop"].exists
                        && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists,
                        "Continuation must remain idle; it owns no capture or processing attempt")
            try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
            let rows = app.buttons.matching(identifier: "history.session.\(sessionID)")
            try await PhysicalUITransitionWait.until(timeout: 10, condition: {
                rows.count == 1 && rows.firstMatch.isHittable && rows.firstMatch.isEnabled
            })
            try require(rows.firstMatch.staticTexts.matching(NSPredicate(format: "label == %@", selected.title)).count == 1,
                        "The unique exact session ID must also have the attested title")
            capture("\(step)-exact-history-id", revision: revision)
            try tap(rows.firstMatch, "Reopen only the attested owned completed session")
            try await PhysicalUITransitionWait.until(timeout: 10, condition: {
                completedReadOnlyTranscriptVisible(in: app, title: selected.title)
                    && app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@",
                        "transcript.paragraph.")).count > 0
            })
            try require(app.buttons["transcript.copy"].exists, "The completed transcript must expose its ordinary copy control")
            capture("\(step)-completed-transcript", revision: revision)
        }

        try await reopenOwnedSession("post-soak-02")
        try tap(app.buttons["transcript.more"], "Inspect only the owned completed transcript's actions")
        capture("post-soak-03-actions", revision: revision)
        try require(firstButton(in: app, labels: ["Export Audio", "Экспорт аудио"]) == nil,
                    "The attested memory-only session must never offer audio export")
        let json = try XCTUnwrap(firstButton(in: app, labels: ["Export as JSON", "Экспортировать как JSON"]))
        var ownsShare = true
        func ownedShareClose() -> XCUIElement? {
            let identified = activity.buttons.matching(identifier: "header.closeButton")
            if identified.count == 1 { return identified.firstMatch }
            let labelled = activity.navigationBars.matching(identifier: "UIActivityContentView").buttons.matching(
                NSPredicate(format: "label IN %@", ["Close", "Закрыть"]))
            return labelled.count == 1 ? labelled.firstMatch : nil
        }
        defer {
            if ownsShare {
                capture("post-soak-failure-before-share-cleanup", revision: revision)
                if app.state == .runningForeground, app.alerts.count == 0, activity.exists,
                   let close = ownedShareClose(), close.isHittable {
                    close.tap()
                    let closed = activity.waitForNonExistence(timeout: 5)
                    print("[PHYSICAL_POST_SOAK] owned_share_cleanup_joined=\(closed)")
                }
                if activity.exists { print("[PHYSICAL_POST_SOAK] share_cleanup_requires_parent_inspection=true") }
            }
        }
        try tap(json, "Present only the owned completed session's JSON share sheet")
        try await PhysicalUITransitionWait.until(timeout: 15, condition: { activity.exists && app.alerts.count == 0 })
        try await waitForOwnedShareSaveAction(in: app, revision: revision)
        capture("post-soak-04-native-json-share", revision: revision)
        // The parent may copy the owned temporary JSON for inspection. No destination,
        // recipient, clipboard action or Files save is selected by this runner.
        print("[PHYSICAL_POST_SOAK] export_presented kind=json sessionID=\(sessionID) inspectionSeconds=15 delivery_attempted=false")
        try await Task.sleep(nanoseconds: 15_000_000_000)
        try tap(try XCTUnwrap(ownedShareClose()), "Close only this continuation's native share sheet without delivery")
        try await PhysicalUITransitionWait.until(timeout: 10, condition: {
            !activity.exists && completedReadOnlyTranscriptVisible(in: app, title: selected.title)
        })
        ownsShare = false
        capture("post-soak-05-share-dismissed", revision: revision)
        // Admission above and the completed transcript check prove no active attempt
        // belongs to another owner before this explicitly authorized normal relaunch.
        app.terminate()
        app.launchArguments = []
        app.launchEnvironment = [:]
        app.launch()
        try await waitForPhysicalAppState(app, .runningForeground, phase: "post-soak-normal-relaunch")
        capture("post-soak-06-normal-relaunch", revision: revision)
        try await reopenOwnedSession("post-soak-07")
        print("[PHYSICAL_POST_SOAK] completed sessionID=\(sessionID) afterStopOnly=true fullSoakPass=false delivery_attempted=false")
        #endif
    }

    /// A bounded first-use handoff: select Tiny, then stop before any download or other choice.
    @MainActor
    func testPhysicalNewUnifiedIPadWelcomeToTinySelection() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires the parent's exact newly installed unified physical iPad app")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_PHYSICAL_FIRST_USE_WELCOME_TO_TINY"] == "1" else {
            throw XCTSkip("Explicitly authorize only Welcome to Tiny selection in the new empty namespace")
        }
        let revision = try XCTUnwrap(environment["PICHI_TEST_REVISION"])
        let selected = try PhysicalFirstUseAuthorization.select(environment, revision: revision)
        try require(UIDevice.current.userInterfaceIdiom == .pad, "First-use admission is restricted to the attested iPad")
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: false)
        let directory = support.appendingPathComponent("PhysicalReleaseUI/first-use", isDirectory: true)
        let receiptURL = directory.appendingPathComponent("\(selected.runID.uuidString).json")
        let consumedURL = directory.appendingPathComponent("\(selected.runID.uuidString).consumed")
        let values = try receiptURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        try require(values.isRegularFile == true && values.isSymbolicLink != true && (values.fileSize ?? Int.max) <= 8192,
                    "First use requires a bounded regular parent receipt in this runner")
        let data = try Data(contentsOf: receiptURL)
        try require(data.count <= 8192, "The first-use receipt exceeded its bound")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let receipt = try decoder.decode(PhysicalFirstUseReceipt.self, from: data)
        try receipt.validate(selected, now: Date(), consumed: FileManager.default.fileExists(atPath: consumedURL.path))
        let running = XCUIApplication(bundleIdentifier: "ai.pichi.voice")
        try require(running.state == .runningForeground, "Never launch, activate or adopt a background first-use app")
        let app = try attachReadOnlyPhysicalApp(revision: revision)
        func requirePage(_ step: Int) throws {
            let visibleSteps = (0...6).filter { app.descendants(matching: .any)["onboarding.step.\($0)"].firstMatch.exists }
            try require(app.state == .runningForeground && app.alerts.count == 0 && app.sheets.count == 0
                        && visibleSteps == [step] && !app.descendants(matching: .any)["onboarding.error"].firstMatch.exists
                        && !app.buttons["onboarding.cancel"].exists && !app.buttons["meeting.start"].exists
                        && !app.buttons["ownerVoice.stop"].exists
                        && !app.otherElements["ActivityListView"].exists,
                        "Stop at any unexpected page, operation, prompt or recording state")
        }
        try requirePage(0)
        let next = app.buttons["onboarding.next"]
        try require(next.exists && next.isEnabled && next.isHittable, "Welcome must expose its actual Next control")
        capture("first-use-01-attested-welcome", revision: revision)
        try Data("claimed".utf8).write(to: consumedURL, options: .withoutOverwriting)
        try tap(next, "Advance only the attested fresh Welcome page")
        try await PhysicalUITransitionWait.until(timeout: 10, condition: {
            app.descendants(matching: .any)["onboarding.step.1"].firstMatch.exists
                && !app.descendants(matching: .any)["onboarding.step.0"].firstMatch.exists
        })
        try requirePage(1)
        capture("first-use-02-model-choice", revision: revision)
        let tiny = app.buttons["onboarding.model.whisper-tiny"]
        if !tiny.isHittable {
            try reveal(tiny, in: app, revision: revision, container: app.scrollViews.firstMatch)
        }
        try requirePage(1)
        try tap(tiny, "Select only the requested Tiny model through its real onboarding card")
        try await PhysicalUITransitionWait.until(timeout: 5, condition: { tiny.isSelected })
        try requirePage(1)
        try require(!app.descendants(matching: .any)["model.preparation.progress"].firstMatch.exists,
                    "This bounded driver must stop before model download or activation")
        capture("first-use-03-tiny-selected-before-download", revision: revision)
        print("[PHYSICAL_FIRST_USE] welcome_to_tiny_selection=true download_started=false setup_completed=false account_choice_reached=false")
        #endif
    }

    /// Completes only the known local setup choices, then leaves authentication to the owner.
    @MainActor
    func testPhysicalIPadTinySelectedSetupToFinalAccountWithParentCheckpoints() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires the exact attested empty unified physical iPad at Tiny selection")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_PHYSICAL_SETUP_CONTINUATION"] == "1" else {
            throw XCTSkip("Explicitly authorize the Tiny-selected setup continuation, never authentication")
        }
        let revision = try XCTUnwrap(environment["PICHI_TEST_REVISION"])
        let selected = try PhysicalSetupContinuationAuthorization.select(environment, revision: revision)
        try require(UIDevice.current.userInterfaceIdiom == .pad, "This continuation is restricted to the attested iPad")
        executionTimeAllowance = 2400
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: false)
        let directory = support.appendingPathComponent("PhysicalReleaseUI/setup-continuation", isDirectory: true)
        let receiptURL = directory.appendingPathComponent("\(selected.runID.uuidString).json")
        let consumedURL = directory.appendingPathComponent("\(selected.runID.uuidString).consumed")
        let checkpoints = directory.appendingPathComponent(selected.runID.uuidString, isDirectory: true)
        let values = try receiptURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        try require(values.isRegularFile == true && values.isSymbolicLink != true && (values.fileSize ?? Int.max) <= 8192,
                    "A bounded regular parent continuation receipt must authorize this run")
        let data = try Data(contentsOf: receiptURL)
        try require(data.count <= 8192, "The continuation receipt exceeded its bound")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        try decoder.decode(PhysicalSetupContinuationReceipt.self, from: data).validate(selected, now: Date(),
            consumed: FileManager.default.fileExists(atPath: consumedURL.path))
        try require(!FileManager.default.fileExists(atPath: checkpoints.path), "A fresh run cannot inherit old checkpoints or ACKs")
        let existing = XCUIApplication(bundleIdentifier: "ai.pichi.voice")
        try require(existing.state == .runningForeground, "Never launch or activate a different setup state")
        let app = try attachReadOnlyPhysicalApp(revision: revision)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func stages() -> [Int] {
            (0...6).filter { app.descendants(matching: .any)["onboarding.step.\($0)"].firstMatch.exists }
        }
        func requireState(_ allowed: Set<Int>, allowError: Bool = false) throws {
            let observed = stages()
            try require(app.state == .runningForeground && app.alerts.count == 0 && springboard.alerts.count == 0
                        && app.sheets.count == 0 && app.keyboards.count == 0 && !observed.isEmpty
                        && observed.allSatisfy({ allowed.contains($0) })
                        && !app.buttons["meeting.stop"].exists && !app.buttons["ownerVoice.stop"].exists
                        && !app.buttons["account.signOut"].exists
                        && !app.descendants(matching: .any)["account.signingIn"].firstMatch.exists
                        && app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "history.session.")).count == 0,
                        "Stop on any unowned page, prompt, account state, recording or namespace content")
            if !allowError {
                try require(!app.descendants(matching: .any)["onboarding.error"].firstMatch.exists
                            && !app.descendants(matching: .any)["account.error"].firstMatch.exists,
                            "The actual setup must not expose a preparation or account error")
            }
        }
        func requireIdlePage(_ stage: Int) throws {
            try requireState([stage])
            try require(stages() == [stage] && !app.buttons["onboarding.cancel"].exists,
                        "Only the exact idle expected setup page can accept the next choice")
        }
        func waitForPage(_ target: Int, from: Int, timeout: TimeInterval) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while true {
                try Task.checkCancellation()
                try requireState([from, target])
                if stages() == [target] && !app.buttons["onboarding.cancel"].exists { return }
                try require(ProcessInfo.processInfo.systemUptime < deadline, "Setup did not reach expected stage \(target) within its bound")
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        func checkpoint(_ name: String, stage: Int) async throws {
            try requireIdlePage(stage)
            try await visibleCheckpoint(name, app: app, revision: revision, directory: checkpoints)
            try requireIdlePage(stage)
        }
        func prepare(_ from: Int, to target: Int, checkpointName: String, progressID: String) async throws {
            try requireIdlePage(from)
            try await PhysicalSetupPreparation.run(start: {
                try tap(app.buttons["onboarding.next"], "Start only the current ordinary local setup preparation")
            }, observe: {
                let preparationStarted = ProcessInfo.processInfo.systemUptime
                // The preparation can finish before its first progress snapshot. Preserve
                // that distinction instead of claiming a download animation was observed.
                let deadline = ProcessInfo.processInfo.systemUptime + 15
                while true {
                    try Task.checkCancellation()
                    try requireState([from, target])
                    if stages() == [target] && !app.buttons["onboarding.cancel"].exists { break }
                    if app.buttons["onboarding.cancel"].exists
                        && app.descendants(matching: .any)[progressID].firstMatch.exists { break }
                    try require(ProcessInfo.processInfo.systemUptime < deadline, "Preparation exposed neither expected progress nor completion")
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
                let observedProgress = app.buttons["onboarding.cancel"].exists
                print("[PHYSICAL_SETUP_CONTINUATION] from=\(from) visibleProgressObserved=\(observedProgress)")
                try await visibleCheckpoint(checkpointName, app: app, revision: revision, directory: checkpoints)
                let remaining = max(0, 600 - (ProcessInfo.processInfo.systemUptime - preparationStarted))
                try await waitForPage(target, from: from, timeout: remaining)
            }, cancelOwnedUI: {
                try requireState([from, target], allowError: true)
                let cancel = app.buttons["onboarding.cancel"]
                let requestedCancel = cancel.exists
                if requestedCancel { try self.tap(cancel, "Cancel only the local preparation started by this continuation") }
                try await PhysicalUITransitionWait.until(timeout: 30, condition: {
                    app.state == .runningForeground && app.alerts.count == 0 && springboard.alerts.count == 0
                        && !app.buttons["onboarding.cancel"].exists && app.buttons["onboarding.next"].isEnabled
                })
                // MobileRequiredResources deliberately keeps its app-owned background
                // install alive when its foreground waiter is cancelled. UI join is narrower.
                print("[PHYSICAL_SETUP_CONTINUATION] cancelledFrom=\(from) ownedUICancelRequested=\(requestedCancel) ownedUIOperationJoined=true backgroundResourceShutdownVerified=false")
            })
        }
        try requireIdlePage(1)
        let tiny = app.buttons["onboarding.model.whisper-tiny"]
        try require(tiny.exists && tiny.isSelected && !app.descendants(matching: .any)["model.preparation.progress"].firstMatch.exists,
                    "Admission starts only at the selected Tiny card before its Next action")
        try Data("claimed".utf8).write(to: consumedURL, options: .withoutOverwriting)
        try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: false)
        try await checkpoint("01-tiny-selected-before-download", stage: 1)
        try require(tiny.isSelected, "The parent checkpoint must retain the chosen Tiny model")
        try await prepare(1, to: 2, checkpointName: "02-tiny-preparation-or-ready", progressID: "model.preparation.progress")
        try await checkpoint("03-participants-before-prepare", stage: 2)
        try require(app.descendants(matching: .any)["recording.requiredResources"].firstMatch.exists,
                    "Participants must expose the ordinary resource preparation status")
        try await prepare(2, to: 3, checkpointName: "04-participants-preparation-or-ready", progressID: "recording.requiredResources")
        try requireIdlePage(3)
        try require(app.switches["privacy.pii"].value as? String == "0"
                    && !app.descendants(matching: .any)["privacy.pii.progress"].firstMatch.exists
                    && !app.descendants(matching: .any)["privacy.pii.active"].firstMatch.exists,
                    "Retain ordinary PII OFF; never toggle privacy to force this flow")
        try await checkpoint("05-privacy-pii-off", stage: 3)
        try require(app.switches["privacy.pii"].value as? String == "0", "PII must remain OFF after the parent checkpoint")
        try tap(app.buttons["onboarding.next"], "Continue with unchanged ordinary privacy choices")
        try await waitForPage(4, from: 3, timeout: 10)
        try require(app.buttons["ownerVoice.start"].exists && app.buttons["onboarding.skip"].exists,
                    "The new namespace must offer optional voice enrollment without starting it")
        try await checkpoint("06-owner-voice-skip-offer", stage: 4)
        try tap(app.buttons["onboarding.skip"], "Skip optional owner voice enrollment without microphone capture")
        try await waitForPage(5, from: 4, timeout: 10)
        try require(app.switches["meetingLocation.enabled"].value as? String == "0", "Location must already be OFF")
        try await checkpoint("07-location-off-skip-offer", stage: 5)
        try require(app.switches["meetingLocation.enabled"].value as? String == "0", "Retain default location OFF")
        try tap(app.buttons["onboarding.skip"], "Skip the optional location offer without requesting permission")
        try await waitForPage(6, from: 5, timeout: 10)
        try requireIdlePage(6)
        try require(app.descendants(matching: .any)["onboarding.account"].firstMatch.exists
                    && app.buttons["account.signIn"].exists && app.buttons["account.continueAsGuest"].exists,
                    "Stop at the actual configured optional-account page; do not invent an authentication route")
        let signIn = app.buttons["account.signIn"]
        let finalScrolls = app.scrollViews
        try require(finalScrolls.count == 1, "The actual final setup page must own one scroll viewport")
        try PhysicalControlReveal.run(ready: {
            try Task.checkCancellation()
            try requireIdlePage(6)
            let viewport = finalScrolls.firstMatch.frame.intersection(app.windows.firstMatch.frame)
            // Legacy Sign in is disabled until the human supplies credentials.
            // Visibility does not require making that authentication action enabled.
            return signIn.exists && signIn.frame.width > 0 && signIn.frame.height > 0 && viewport.contains(signIn.frame)
        }, scroll: { upward, _ in
            try requireIdlePage(6)
            try require(finalScrolls.count == 1 && finalScrolls.firstMatch.isHittable,
                        "Only the actual final setup page may reveal its account controls")
            if upward { finalScrolls.firstMatch.swipeUp() } else { finalScrolls.firstMatch.swipeDown() }
        })
        // This is the final capture and ACK. The owner must end capture before
        // entering credentials after this test returns; no auth control is tapped.
        try await checkpoint("08-final-account-no-auth", stage: 6)
        print("[PHYSICAL_SETUP_CONTINUATION] finalAccountPageReached=true setupCompleted=false authAttempted=false credentialsEntered=false")
        #endif
    }

    @MainActor
    func testPhysicalIPadFinalAccountContinueAsGuestToEmptyRecordings() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires the attested empty unified iPad at the signed-out final account page")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_PHYSICAL_SETUP_GUEST_COMPLETION"] == "1" else { throw XCTSkip("Enable only the owned iPad guest completion") }
        try Task.checkCancellation()
        let revision = try XCTUnwrap(environment["PICHI_TEST_REVISION"])
        let selected = try PhysicalSetupContinuationAuthorization.selectGuest(environment, revision: revision)
        try require(UIDevice.current.userInterfaceIdiom == .pad, "Guest completion never admits a phone")
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let directory = support.appendingPathComponent("PhysicalReleaseUI/setup-guest", isDirectory: true)
        let receiptURL = directory.appendingPathComponent("\(selected.runID.uuidString).json")
        let consumedURL = directory.appendingPathComponent("\(selected.runID.uuidString).consumed")
        let values = try receiptURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        try require(values.isRegularFile == true && values.isSymbolicLink != true && (values.fileSize ?? Int.max) <= 8192,
                    "Guest completion requires a bounded regular fresh parent receipt")
        let data = try Data(contentsOf: receiptURL)
        try require(data.count <= 8192, "Guest receipt exceeded its bound")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        try decoder.decode(PhysicalGuestCompletionReceipt.self, from: data).validate(selected, now: Date(),
            consumed: FileManager.default.fileExists(atPath: consumedURL.path))
        let running = XCUIApplication(bundleIdentifier: "ai.pichi.voice")
        try require(running.state == .runningForeground, "Never launch or activate a guest-completion app")
        let app = try attachReadOnlyPhysicalApp(revision: revision)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func idle() -> Bool {
            app.state == .runningForeground && app.alerts.count == 0 && springboard.alerts.count == 0
                && app.sheets.count == 0 && app.keyboards.count == 0 && !app.buttons["meeting.stop"].exists
                && !app.descendants(matching: .any)["meeting.recording"].firstMatch.exists
                && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists
                && !app.buttons["ownerVoice.stop"].exists && !app.buttons["account.signOut"].exists
                && !app.descendants(matching: .any)["account.signingIn"].firstMatch.exists
                && !app.descendants(matching: .any)["onboarding.error"].firstMatch.exists
                && !app.descendants(matching: .any)["account.error"].firstMatch.exists
        }
        func emptyCredential(_ field: XCUIElement) -> Bool {
            guard field.exists, !field.hasFocus, field.value == nil || field.value is String else { return false }
            return PhysicalGuestCredentialFields.isEmpty(value: field.value as? String)
        }
        try require(app.textFields.matching(identifier: "account.legacy.email").count == 1
                    && app.secureTextFields.matching(identifier: "account.legacy.password").count == 1, "Credential controls must be unique")
        try require(idle() && app.descendants(matching: .any)["onboarding.step.6"].firstMatch.exists
                    && app.descendants(matching: .any)["onboarding.account"].firstMatch.exists
                    && !app.buttons["onboarding.cancel"].exists
                    && emptyCredential(app.textFields["account.legacy.email"])
                    && emptyCredential(app.secureTextFields["account.legacy.password"]),
                    "Guest admission requires the exact idle final page with empty, unfocused credential fields")
        let guest = app.buttons["account.continueAsGuest"]
        try Task.checkCancellation()
        try PhysicalControlReveal.run(ready: {
            try Task.checkCancellation()
            return guest.exists && guest.isHittable
        }, scroll: { upward, _ in
            let scroll = app.scrollViews.firstMatch
            try require(idle() && scroll.exists && scroll.isHittable, "Reveal only the idle final account page")
            try Task.checkCancellation()
            if upward { scroll.swipeUp() } else { scroll.swipeDown() }
        })
        try require(idle() && emptyCredential(app.textFields["account.legacy.email"])
                    && emptyCredential(app.secureTextFields["account.legacy.password"]), "Never discard entered credential state")
        try Task.checkCancellation()
        try Data("claimed".utf8).write(to: consumedURL, options: .withoutOverwriting)
        capture("guest-completion-01-empty-account-page", revision: revision)
        try require(emptyCredential(app.textFields["account.legacy.email"]) && emptyCredential(app.secureTextFields["account.legacy.password"]),
                    "Credentials must still be empty immediately before the guest action")
        try require(guest.waitForExistence(timeout: 5) && guest.isHittable && guest.isEnabled,
                    "The ordinary Continue as guest action must be ready")
        try Task.checkCancellation()
        guest.tap()
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        while true {
            try Task.checkCancellation()
            try require(idle(), "Guest completion must remain signed out without prompts, errors or recording")
            if app.buttons["meeting.start"].exists && app.buttons["meeting.start"].isEnabled
                && app.buttons["meeting.start"].isHittable && !app.descendants(matching: .any)["onboarding.step.6"].firstMatch.exists { break }
            try require(ProcessInfo.processInfo.systemUptime < deadline, "Normal guest completion did not reach Recordings within 120 seconds")
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        try require(historyIDs(in: app).isEmpty, "The new guest Recordings namespace must remain empty")
        capture("guest-completion-02-empty-recordings-ready", revision: revision)
        print("[PHYSICAL_GUEST_COMPLETION] guestReady=true recordingStarted=false authAttempted=false")
        #endif
    }

    /// Destructive only for the exact freshly attested, independently backed-up synthetic fixture.
    @MainActor
    func testPhysicalOwnedCompletedSyntheticPlaybackPauseStopAndDelete() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires the parent's owned completed synthetic physical-device fixture")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_PHYSICAL_OWNED_PLAYBACK_DELETE"] == "1" else {
            throw XCTSkip("Explicitly authorize playback and deletion of only the backed-up synthetic fixture")
        }
        let revision = try XCTUnwrap(environment["PICHI_TEST_REVISION"])
        let selected = try PhysicalOwnedPlaybackAuthorization.select(environment, revision: revision)
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: false)
        let directory = support.appendingPathComponent("PhysicalReleaseUI/owned-playback", isDirectory: true)
        let receiptURL = directory.appendingPathComponent("\(selected.runID.uuidString).json")
        let consumedURL = directory.appendingPathComponent("\(selected.runID.uuidString).consumed")
        let values = try receiptURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        try require(values.isRegularFile == true && values.isSymbolicLink != true && (values.fileSize ?? Int.max) <= 8192,
                    "Only a bounded regular parent receipt in this runner can authorize playback and deletion")
        let data = try Data(contentsOf: receiptURL)
        try require(data.count <= 8192, "The owned playback receipt exceeded its bound")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let receipt = try decoder.decode(PhysicalOwnedPlaybackReceipt.self, from: data)
        try receipt.validate(selected, now: Date(), consumed: FileManager.default.fileExists(atPath: consumedURL.path))
        // A separate exclusive claim preserves the immutable parent receipt and prevents replay,
        // including after failure. A retry needs a newly verified receipt and fresh run UUID.
        try Data("claimed".utf8).write(to: consumedURL, options: .withoutOverwriting)
        let app = try attachReadOnlyPhysicalApp(revision: revision)
        try require(!app.otherElements["ActivityListView"].exists && !app.otherElements["Browse View (Picker)"].exists
                    && app.sheets.count == 0
                    && app.sliders.matching(PhysicalPlaybackSliderQuery.predicate).count == 0,
                    "Never adopt a pre-existing share sheet, picker, dialog or audio player")
        try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
        let sessionID = selected.sessionID.uuidString
        let rows = app.buttons.matching(identifier: "history.session.\(sessionID)")
        func requireOwnedRow() throws {
            try require(app.state == .runningForeground && app.alerts.count == 0 && app.sheets.count == 0
                        && rows.count == 1 && rows.firstMatch.isHittable && rows.firstMatch.isEnabled
                        && rows.firstMatch.staticTexts.matching(NSPredicate(format: "label == %@", selected.title)).count == 1,
                        "Only the unique exact owned session ID with its attested title may be opened or deleted")
        }
        try requireOwnedRow()
        capture("owned-playback-01-exact-history", revision: revision)
        try tap(rows.firstMatch, "Open only the attested completed synthetic fixture")
        try await PhysicalUITransitionWait.until(timeout: 10, condition: {
            completedReadOnlyTranscriptVisible(in: app, title: selected.title)
        })
        let transcripts = app.scrollViews.matching(identifier: "meeting.transcript")
        try require(transcripts.count == 1, "The admitted session must expose one actual transcript scroll owner")
        let transcript = transcripts.firstMatch
        let audio = try XCTUnwrap(transcript.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "transcript.audio.")).allElementsBoundByIndex.first { $0.isHittable && $0.isEnabled })
        let ownedAudioID = audio.identifier
        let owners = transcript.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "transcript.paragraph.")).allElementsBoundByIndex.filter { $0.buttons.matching(identifier: ownedAudioID).count == 1 }
        try require(owners.count == 1, "The exact audio button must belong to one owned paragraph before opening its player")
        let ownedParagraphID = try XCTUnwrap(owners.first).identifier
        let paragraphs = transcript.descendants(matching: .any).matching(identifier: ownedParagraphID)
        let paragraph = paragraphs.firstMatch
        let ownedAudio = paragraph.buttons[ownedAudioID]
        let slider = paragraph.sliders.matching(PhysicalPlaybackSliderQuery.predicate)
        let pauseLabels = ["Pause audio chunk", "Приостановить воспроизведение фрагмента"]
        let playLabels = ["Play audio chunk", "Воспроизвести аудиофрагмент"]
        let closeLabels = ["Close audio player", "Закрыть аудиоплеер"]
        func transport(_ labels: [String]) -> XCUIElement? {
            let matches = paragraph.buttons.matching(NSPredicate(format: "label IN %@", labels))
            return matches.count == 1 ? matches.firstMatch : nil
        }
        func ownedTranscriptIsIdle() -> Bool {
            // Header actions naturally leave the viewport while reading a long paragraph.
            // Identity remains the exact session admitted above and its pinned paragraph.
            app.state == .runningForeground && app.alerts.count == 0 && app.sheets.count == 0
                && transcripts.count == 1 && paragraphs.count == 1
                && !app.buttons["meeting.stop"].exists && !app.buttons["meeting.retry"].exists
                && !app.buttons["meeting.restartProcessing"].exists
                && !app.descendants(matching: .any)["meeting.recording"].firstMatch.exists
                && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists
                && !app.otherElements["ActivityListView"].exists && !app.otherElements["Browse View (Picker)"].exists
        }
        func diagnoseOwnedControls(_ step: String) {
            let knownLabels = pauseLabels + playLabels + closeLabels
            let controls = paragraphs.count == 1 ? paragraph.buttons.allElementsBoundByIndex.filter {
                $0.identifier == ownedAudioID || knownLabels.contains($0.label)
            } + slider.allElementsBoundByIndex : []
            let records = controls.prefix(16).map { control in
                ["id": control.identifier, "type": String(control.elementType.rawValue), "frame": String(describing: control.frame),
                 "enabled": String(control.isEnabled), "hittable": String(control.isHittable),
                 "transportLabel": knownLabels.contains(control.label) ? control.label : "<redacted>"]
            }
            let diagnostic: [String: Any] = ["paragraphID": ownedParagraphID, "audioID": ownedAudioID,
                "paragraphCount": paragraphs.count, "viewportFrame": transcripts.count == 1 ? String(describing: transcript.frame) : "missing",
                "sliderCount": slider.count, "controls": records]
            if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                let attachment = XCTAttachment(string: text)
                attachment.name = "owned-playback-scoped-controls-\(step)-\(revision)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        func revealOwnedControls(startingUpward: Bool, cleanup: Bool = false, ready: () -> Bool) throws {
            do {
                try PhysicalControlReveal.run(startingUpward: startingUpward, ready: {
                    if !cleanup { try Task.checkCancellation() }
                    try require(ownedTranscriptIsIdle(), "Never scroll or adopt controls outside the exact owned idle paragraph")
                    return ready()
                }, scroll: { upward, _ in
                    try require(ownedTranscriptIsIdle() && transcript.isHittable,
                                "Only the owned transcript viewport may receive a reveal gesture")
                    if upward { transcript.swipeUp() } else { transcript.swipeDown() }
                })
            } catch {
                diagnoseOwnedControls(cleanup ? "cleanup-reveal-failed" : "reveal-failed")
                capture("owned-playback-scoped-reveal-failure", revision: revision)
                throw error
            }
        }
        func revealOwnedClose(cleanup: Bool = false) throws {
            try revealOwnedControls(startingUpward: false, cleanup: cleanup, ready: {
                ownedAudio.exists && ownedAudio.isEnabled && ownedAudio.isHittable && closeLabels.contains(ownedAudio.label)
            })
        }
        try require(slider.count == 0 && transport(pauseLabels) == nil, "Never adopt an existing playback owner")
        var ownsPlayback = false
        defer {
            if ownsPlayback {
                diagnoseOwnedControls("failure-before-cleanup")
                capture("owned-playback-failure-before-cleanup", revision: revision)
                do {
                    // Cleanup stays bounded and ownership-checked even if the test task was cancelled.
                    try revealOwnedClose(cleanup: true)
                    try tap(ownedAudio, "Close only the exact owned paragraph player after failure")
                    let joined = slider.firstMatch.waitForNonExistence(timeout: 5)
                        && ownedAudio.exists && !closeLabels.contains(ownedAudio.label)
                    print("[PHYSICAL_OWNED_PLAYBACK] owned_playback_cleanup_joined=\(joined)")
                    if !joined { print("[PHYSICAL_OWNED_PLAYBACK] cleanup_requires_parent_inspection=true") }
                } catch {
                    print("[PHYSICAL_OWNED_PLAYBACK] cleanup_requires_parent_inspection=true")
                }
            }
        }
        ownsPlayback = true
        try tap(ownedAudio, "Play audio only from the owned synthetic transcript paragraph")
        diagnoseOwnedControls("opened-before-player-reveal")
        try revealOwnedControls(startingUpward: true, ready: {
            let control = transport(pauseLabels) ?? transport(playLabels)
            return PhysicalPlaybackSliderQuery.isUniqueOwnedMatch(paragraphCount: paragraphs.count, sliderCount: slider.count)
                && slider.firstMatch.isHittable && slider.firstMatch.isEnabled
                && control?.isEnabled == true && control?.isHittable == true
        })
        try await PhysicalUITransitionWait.until(timeout: 10, condition: {
            PhysicalPlaybackSliderQuery.isUniqueOwnedMatch(paragraphCount: paragraphs.count, sliderCount: slider.count)
                && transport(pauseLabels)?.isEnabled == true
        })
        let initial = try XCTUnwrap(PhysicalPlaybackPosition.seconds(slider.firstMatch.value as? String))
        try await PhysicalUITransitionWait.until(timeout: 10, condition: {
            ownedTranscriptIsIdle()
                && transport(pauseLabels)?.isEnabled == true
                && (PhysicalPlaybackPosition.seconds(slider.firstMatch.value as? String) ?? -1) >= initial + 2
        })
        capture("owned-playback-02-progressing", revision: revision)
        try tap(try XCTUnwrap(transport(pauseLabels)), "Pause the owned native audio player")
        try await PhysicalUITransitionWait.until(timeout: 5, condition: {
            transport(playLabels)?.isEnabled == true
        })
        let pauseStart = try XCTUnwrap(PhysicalPlaybackPosition.seconds(slider.firstMatch.value as? String))
        var pauseObservation = PhysicalPlaybackPauseObservation(position: pauseStart, now: ProcessInfo.processInfo.systemUptime)
        let pauseDeadline = ProcessInfo.processInfo.systemUptime + 10
        while true {
            try require(ownedTranscriptIsIdle()
                        && transport(playLabels)?.isEnabled == true,
                        "The native player must remain paused throughout settling and stable observation")
            let position = try XCTUnwrap(PhysicalPlaybackPosition.seconds(slider.firstMatch.value as? String))
            if try pauseObservation.observe(position: position, now: ProcessInfo.processInfo.systemUptime) { break }
            try require(ProcessInfo.processInfo.systemUptime < pauseDeadline, "Paused playback did not settle within its bound")
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        let paused = try XCTUnwrap(PhysicalPlaybackPosition.seconds(slider.firstMatch.value as? String))
        capture("owned-playback-03-paused-stable", revision: revision)
        try tap(try XCTUnwrap(transport(playLabels)), "Resume only the owned native audio player")
        try await PhysicalUITransitionWait.until(timeout: 10, condition: {
            transport(pauseLabels)?.isEnabled == true
                && (PhysicalPlaybackPosition.seconds(slider.firstMatch.value as? String) ?? -1) >= paused + 1
        })
        try revealOwnedClose()
        try require(closeLabels.contains(ownedAudio.label), "The same paragraph must own the expanded player")
        try tap(ownedAudio, "Stop the owned player through its ordinary close audio control")
        try await PhysicalUITransitionWait.until(timeout: 5, condition: {
            slider.count == 0 && transport(pauseLabels) == nil
                && transport(playLabels) == nil
                && ownedAudio.exists && !closeLabels.contains(ownedAudio.label)
                && ownedTranscriptIsIdle()
        })
        ownsPlayback = false
        capture("owned-playback-04-stopped", revision: revision)
        try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
        try requireOwnedRow()
        // A partial native drag reveals the exact action without a destructive full swipe.
        rows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: rows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)))
        let delete = app.buttons.matching(identifier: "history.delete.\(sessionID)")
        try require(delete.count == 1 && app.alerts.count == 0 && app.sheets.count == 0,
                    "The exact owned row must expose its own ordinary Delete action")
        capture("owned-playback-05-exact-delete-action", revision: revision)
        try tap(delete.firstMatch, "Delete only the independently backed-up synthetic session")
        try await PhysicalUITransitionWait.until(timeout: 10, condition: {
            rows.count == 0 || app.alerts.count > 0 || app.sheets.count > 0
        })
        if app.alerts.count > 0 || app.sheets.count > 0 {
            let dialogs = app.alerts.count > 0 ? app.alerts : app.sheets
            let dialog = dialogs.firstMatch
            try require(dialogs.count == 1 && dialog.staticTexts.matching(NSPredicate(format: "label IN %@",
                ["Delete this recording with its transcript and audio?", "Удалить эту запись вместе с расшифровкой и аудио?"])).count == 1,
                "Only the known recording-deletion confirmation from the owned action may be accepted")
            let confirm = dialog.buttons.matching(NSPredicate(format: "label IN %@", ["Delete", "Удалить"]))
            try require(confirm.count == 1, "The owned recording confirmation must have one exact destructive action")
            try tap(confirm.firstMatch, "Confirm only the owned synthetic recording deletion")
        }
        try await PhysicalUITransitionWait.until(timeout: 10, condition: {
            app.state == .runningForeground && app.alerts.count == 0 && app.sheets.count == 0 && rows.count == 0
                && app.descendants(matching: .any)["history.list"].firstMatch.exists
                && !app.buttons["meeting.stop"].exists
                && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists
        })
        capture("owned-playback-06-owned-row-gone", revision: revision)
        print("[PHYSICAL_OWNED_PLAYBACK] sessionID=\(sessionID) playback_progress_pause_resume_stop=true owned_row_deleted=true")
        #endif
    }

    @MainActor
    func testReleaseTinyFiveMinuteBackgroundRecordingAndJSONShare() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires an explicitly authorized physical-device audio lease")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_PHYSICAL_RELEASE_UI_SOAK"] == "1",
              environment["PICHI_PHYSICAL_RELEASE_UI_AUDIO"] == "1" else {
            throw XCTSkip("Enable physical Release UI recording and audible playback explicitly")
        }
        let revision = try XCTUnwrap(environment["PICHI_TEST_REVISION"],
                                    "The frozen AUT source revision must be recorded")
        try require(!revision.isEmpty && revision != "working-tree", "A concrete AUT revision is required")
        try PhysicalSpeakerLabelsPreflight.validate(environment, revision: revision)
        let runnerID = try XCTUnwrap(Bundle.main.bundleIdentifier)
        try require(runnerID.hasSuffix(".xctrunner"), "Playback must be owned by the UI test runner")
        let backgroundModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        try require(backgroundModes.contains("audio"),
                    "The copied UI runner must declare audio before valid signing and freezing")
        let assets = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: false)
        let fixture = assets.appendingPathComponent("PhysicalReleaseUI/audio/ru.wav")
        try require(FileManager.default.fileExists(atPath: fixture.path), "Stage the approved public Russian WAV in the runner")
        var ownedPlayer: AVAudioPlayer?

        let app = XCUIApplication()
        // Preserve the user's actual language, theme, model and privacy choices.
        app.launchArguments = []
        app.launchEnvironment = [:]
        app.activate()
        try await waitForPhysicalAppState(app, .runningForeground, phase: "tiny-initial-foreground")
        try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
        try require(!app.buttons["meeting.stop"].exists
                    && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists,
                    "The app must be idle; an existing recording is not owned by this test")
        capture("01-installed-app", revision: revision)
        try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
        let previousSessionIDs = historyIDs(in: app)
        try openPhysicalSettingsPage("settings.models", app: app, revision: revision)
        capture("02-models-opened", revision: revision)
        let selectedTiny = app.descendants(matching: .any)["model.selected.whisper-tiny"].firstMatch
        try reveal(selectedTiny, in: app, revision: revision)
        try require(selectedTiny.exists, "Whisper Tiny must already be selected; the test never changes the model")
        capture("03-tiny-selected", revision: revision)
        try openPhysicalSettingsPage("settings.privacy", app: app, revision: revision)
        try require(app.switches["privacy.saveAudio"].waitForExistence(timeout: 5), "Audio privacy must be visible")
        try require(app.switches["privacy.saveAudio"].value as? String == "0", "Save audio must already be OFF")
        try require(app.switches["privacy.pii"].value as? String == "1", "PII must already be ON")
        capture("04-strict-privacy", revision: revision)
        try openPhysicalSettingsPage("settings.participants", app: app, revision: revision)
        try verifyAutomaticParticipantResources(in: app, revision: revision)
        capture("05-speaker-settings", revision: revision)
        try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
        if !app.buttons["meeting.start"].exists {
            try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
            capture("06-new-meeting", revision: revision)
        }
        try require(app.buttons["meeting.start"].waitForExistence(timeout: 15), "The real Start action must be ready")
        try require(app.alerts.count == 0, "Permissions and model readiness must be resolved before the audio lease")
        capture("07-ready", revision: revision)

        let audioSession = AVAudioSession.sharedInstance()
        try require(audioSession.outputVolume > 0.05, "Device output must be audible before playback")
        let originalCategory = audioSession.category
        let originalMode = audioSession.mode
        let originalOptions = audioSession.categoryOptions
        var ownsRecording = false
        var observedOwnedRecording = false
        var changedPlaybackCategory = false
        var ownsPlaybackSession = false
        defer {
            ownedPlayer?.stop()
            if ownsPlaybackSession {
                try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            }
            if changedPlaybackCategory {
                try? audioSession.setCategory(originalCategory, mode: originalMode, options: originalOptions)
            }
        }
        do {
            // Initiate actual audio while the runner itself is foreground, then return to
            // the AUT. This uses the public audio background mode, not background assertions.
            let runner = XCUIApplication(bundleIdentifier: runnerID)
            runner.activate()
            try await waitForPhysicalAppState(runner, .runningForeground, phase: "tiny-fixture-foreground")
            try audioSession.setCategory(.playback, mode: .default, options: .mixWithOthers)
            changedPlaybackCategory = true
            try audioSession.setActive(true)
            ownsPlaybackSession = true
            let player = try AVAudioPlayer(contentsOf: fixture)
            ownedPlayer = player
            try require(player.duration.isFinite && player.duration >= 1, "The staged speech fixture must be valid")
            player.numberOfLoops = -1
            player.volume = 0.8
            try require(player.prepareToPlay(), "The runner must prepare real fixture playback")
            try require(player.play(), "The runner must start synthetic speech")
            app.activate()
            try await waitForPhysicalAppState(app, .runningForeground, phase: "tiny-recording-foreground")
            // Own the only Start tap even if its automation response fails after delivery.
            ownsRecording = true
            try tap(app.buttons["meeting.start"], "Start through the ordinary Release UI")
            try require(app.buttons["meeting.stop"].waitForExistence(timeout: 30), "The Release app must start recording")
            try require(app.buttons["meeting.stop"].isEnabled, "Capture must reach the recording state")
            observedOwnedRecording = true
            capture("08-recording-started", revision: revision)
            let start = ProcessInfo.processInfo.systemUptime
            var earlyTextCount = 0
            let preferences = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
            for second in 1...300 {
                let remaining = start + Double(second) - ProcessInfo.processInfo.systemUptime
                if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                try require(player.isPlaying, "Synthetic playback stopped before second \(second)")
                if second == 10 {
                    earlyTextCount = liveTextCharacterCount(in: app)
                    capture("09-live-at-ten-seconds", revision: revision)
                    preferences.activate()
                    try await waitForPhysicalAppState(preferences, .runningForeground, phase: "tiny-settings-foreground")
                    try await waitForPhysicalAppState(app, .runningBackground, phase: "tiny-recording-background")
                    capture("10-actual-background", revision: revision)
                    print("[PHYSICAL_RELEASE_UI] background_started revision=\(revision) earlyCharacters=\(earlyTextCount)")
                } else if second > 10 {
                    try require(app.state == .runningBackground, "The recording app left background or terminated at second \(second)")
                }
                if second.isMultiple(of: 30) {
                    print("[PHYSICAL_RELEASE_UI] elapsed=\(second) playback=true appBackground=\(app.state == .runningBackground)")
                }
            }
            player.stop()
            try require(!player.isPlaying, "The owned player must stop before completion")
            app.activate()
            try await waitForPhysicalAppState(app, .runningForeground, phase: "tiny-after-background")
            try require(app.buttons["meeting.stop"].waitForExistence(timeout: 5) && app.buttons["meeting.stop"].isEnabled,
                        "Capture must still be active after five minutes")
            let finalTextCount = liveTextCharacterCount(in: app)
            try require(finalTextCount > max(earlyTextCount, 20), "Protected committed text must advance during background capture")
            try await verifyLatestCaptionVisible(in: app, revision: revision)
            capture("11-five-minutes-following-latest", revision: revision)

            try await exercisePhysicalCaptionScrollAndJump(in: app, revision: revision, prefix: "12-tiny-caption")

            try await requestPhysicalOwnedStop(in: app)
            capture("14-stop-requested", revision: revision)
            try await waitForCompletedTranscript(in: app, timeout: 120)
            ownsRecording = false
            try require(!app.buttons["meeting.stop"].exists, "The recording controls must disappear after joined completion")
            try require(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript.paragraph.")).count > 0,
                        "The completed transcript must contain readable paragraphs backed by real segments")
            capture("15-completed-transcript", revision: revision)
            try tap(app.buttons["transcript.more"], "Open completed transcript actions")
            capture("16-transcript-actions", revision: revision)
            try require(firstButton(in: app, labels: ["Export Audio", "Экспорт аудио"]) == nil,
                        "Strict memory-only recording must not offer audio export")
            let jsonExport = try XCTUnwrap(firstButton(in: app, labels: ["Export as JSON", "Экспортировать как JSON"]),
                                          "The actual JSON export action must be present")
            try tap(jsonExport, "Export the protected JSON transcript")
            try await waitForOwnedShareSaveAction(in: app, revision: revision)
            capture("17-native-json-share", revision: revision)
            // The parent can copy the AUT's owned temporary share directory here. This
            // verifies generated JSON, not delivery to a guessed/cloud Files destination.
            print("[PHYSICAL_RELEASE_UI] export_presented kind=json inspectionSeconds=15")
            try await Task.sleep(nanoseconds: 15_000_000_000)
            app.swipeDown()
            if !app.buttons["transcript.more"].isHittable {
                try tap(try XCTUnwrap(firstButton(in: app, labels: ["Close", "Закрыть", "Cancel", "Отмена"])),
                        "Dismiss the share sheet without sending to another application")
            }
            try require(app.buttons["transcript.more"].isHittable, "The share sheet must close safely")
            capture("18-share-dismissed", revision: revision)
            try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
            let newIDs = historyIDs(in: app).subtracting(previousSessionIDs)
            try require(newIDs.count == 1, "History must show exactly one new meeting from this attempt")
            let sessionID = try XCTUnwrap(newIDs.first)
            print("[PHYSICAL_RELEASE_UI] completed sessionID=\(sessionID) finalCharacters=\(finalTextCount)")
            capture("19-completed-history-row", revision: revision)
            app.terminate()
            app.launch()
            try await waitForPhysicalAppState(app, .runningForeground, phase: "tiny-relaunch")
            capture("20-normal-relaunch", revision: revision)
            try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
            try tap(app.buttons["history.session.\(sessionID)"], "Reopen the persisted meeting after normal relaunch")
            try require(app.descendants(matching: .any)["meeting.transcript"].firstMatch.waitForExistence(timeout: 10),
                        "The persisted transcript must reopen")
            try require(!app.buttons["meeting.stop"].exists, "Relaunch must not restore active capture")
            capture("21-persisted-transcript-reopened", revision: revision)
        } catch {
            let primaryError = error
            let failure = error as NSError
            print("[PHYSICAL_RELEASE_UI] primary_error domain=\(failure.domain) code=\(failure.code) detail=\(failure.localizedDescription)")
            ownedPlayer?.stop()
            if ownsRecording {
                // Request the same normal stop/join path as the user. Never stop someone
                // else's pre-existing recording or delete checkpoints after a failure.
                // An unstructured cleanup task does not inherit the test task's
                // cancellation. Join it before returning the original failure.
                let cleanup = Task { @MainActor in
                    do {
                        try await self.finishPhysicalOwnedRecording(in: app, observed: observedOwnedRecording)
                        ownsRecording = false
                        print("[PHYSICAL_RELEASE_UI] cleanup_joined=true")
                    } catch {
                        let cleanupError = error as NSError
                        print("[PHYSICAL_RELEASE_UI] cleanup_stop_requires_parent_inspection domain=\(cleanupError.domain) code=\(cleanupError.code) detail=\(cleanupError.localizedDescription)")
                    }
                    self.capture("failure-owned-recording-cleanup", revision: revision)
                }
                await cleanup.value
            }
            throw primaryError
        }
        #endif
    }

    /// Human-observed smoke flow, extended to three minutes for external playback.
    /// Every checkpoint pauses until the parent inspects the native screenshot and ACKs.
    @MainActor
    func testReleaseVisibleOneMinuteRecordingWithParentCheckpoints() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires an explicitly authorized, visually observed physical-device audio lease")
        #else
        let environment = ProcessInfo.processInfo.environment
        let externalAudio = environment["PICHI_PHYSICAL_EXTERNAL_AUDIO"] == "1"
        guard environment["PICHI_PHYSICAL_VISIBLE_UI"] == "1",
              externalAudio || environment["PICHI_PHYSICAL_RELEASE_UI_AUDIO"] == "1" else {
            throw XCTSkip("Enable visible physical recording and audible playback explicitly")
        }
        let revision = try XCTUnwrap(environment["PICHI_TEST_REVISION"])
        try require(!revision.isEmpty && revision != "working-tree", "A concrete frozen AUT revision is required")
        let allowMicrophonePrompt = try PhysicalMicrophonePrompt.enabled(environment, revision: revision,
            isPad: UIDevice.current.userInterfaceIdiom == .pad)
        let expectedExternalLiveText = environment["PICHI_PHYSICAL_EXPECTED_LIVE_TEXT"]
            .map(normalizedVisibleSpeech).flatMap { $0.isEmpty ? nil : $0 }
        let runnerID = try XCTUnwrap(Bundle.main.bundleIdentifier)
        try require(runnerID.hasSuffix(".xctrunner"), "Only the UI runner may own synthetic playback")
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        let player: AVAudioPlayer?
        if externalAudio {
            player = nil
        } else {
            let backgroundModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
            try require(backgroundModes.contains("audio"), "The frozen, validly signed runner must declare background audio")
            let fixture = support.appendingPathComponent("PhysicalReleaseUI/audio/ru.wav")
            try require(FileManager.default.fileExists(atPath: fixture.path), "Stage the approved synthetic Russian WAV in the runner")
            let ownedPlayer = try AVAudioPlayer(contentsOf: fixture)
            try require(ownedPlayer.duration.isFinite && ownedPlayer.duration >= 1, "The speech fixture must be valid")
            ownedPlayer.numberOfLoops = -1
            ownedPlayer.volume = 0.8
            player = ownedPlayer
        }
        let audioSource = externalAudio ? "external_parent_acoustic" : "runner_speaker"
        let checkpoints = support.appendingPathComponent("VisibleRecordingUI", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        print("[VISIBLE_UI_RUN] directory=\(checkpoints.path) revision=\(revision) test=testReleaseVisibleOneMinuteRecordingWithParentCheckpoints source=\(audioSource)")

        let app = XCUIApplication()
        app.launchArguments = []
        app.launchEnvironment = [:]
        // External playback is owned and observed by the parent on another device.
        // Do not create an audio session or switch foreground apps on that route.
        let audioSession = externalAudio ? nil : AVAudioSession.sharedInstance()
        let originalCategory = audioSession?.category
        let originalMode = audioSession?.mode
        let originalOptions = audioSession?.categoryOptions
        var ownsRecording = false
        var changedPlaybackCategory = false
        var ownsPlaybackSession = false
        defer {
            player?.stop()
            if ownsPlaybackSession { try? audioSession?.setActive(false, options: .notifyOthersOnDeactivation) }
            if changedPlaybackCategory, let audioSession, let originalCategory, let originalMode, let originalOptions {
                try? audioSession.setCategory(originalCategory, mode: originalMode, options: originalOptions)
            }
        }
        do {
            app.activate()
            try await visibleCheckpoint("00-foreground", app: app, revision: revision, directory: checkpoints)
            try require(app.state == .runningForeground, "The ordinary Release AUT must be foreground")
            try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
            try await visibleCheckpoint("01-meetings-idle", app: app, revision: revision, directory: checkpoints)
            try require(!app.buttons["meeting.stop"].exists
                        && !app.descendants(matching: .any)["meeting.recording"].firstMatch.exists
                        && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists,
                        "An existing recording or processing attempt is not owned by this test")
            if !app.buttons["meeting.start"].exists {
                try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
                try await visibleCheckpoint("02-new-meeting", app: app, revision: revision, directory: checkpoints)
            }
            try require(app.buttons["meeting.start"].waitForExistence(timeout: 15)
                        && app.buttons["meeting.start"].isEnabled && app.buttons["meeting.start"].isHittable,
                        "The real Start action must be ready")
            try require(app.alerts.count == 0, "Resolve permission or readiness prompts through normal UI before testing")
            if let audioSession {
                try require(audioSession.outputVolume > 0.05, "The device speaker must already be audible")
            }
            try await visibleCheckpoint("03-ready", app: app, revision: revision, directory: checkpoints)

            try tap(app.buttons["meeting.start"], "Tap the actual Release Start action before any speech playback")
            ownsRecording = true
            try await waitForVisibleRecording(in: app, timeout: 90, microphonePromptRevision: allowMicrophonePrompt ? revision : nil)
            let beforeSpeechTimer = try visibleTimerSeconds(in: app)
            try await visibleCheckpoint("04-recording-before-speech", app: app, revision: revision, directory: checkpoints)
            try verifyVisibleRecording(in: app)
            try require(player?.isPlaying != true, "No owned speech may play before visually acknowledged recording")

            if externalAudio {
                print("[VISIBLE_UI_EXTERNAL_AUDIO] action=start_approved_synthetic_playback_before_ack checkpoint=05-external-playback-ready")
                try await visibleCheckpoint("05-external-playback-ready", app: app, revision: revision, directory: checkpoints)
                try verifyVisibleRecording(in: app)
                try require(try visibleTimerSeconds(in: app) >= beforeSpeechTimer, "The same recording must continue while external playback starts")
                try await visibleCheckpoint("06-recording-with-speech", app: app, revision: revision, directory: checkpoints)
                var intervalStartTimer = try visibleTimerSeconds(in: app)
                for interval in 1...3 {
                    try await observeVisibleRecording(in: app, player: nil, seconds: 60)
                    let intervalEndTimer = try visibleTimerSeconds(in: app)
                    try require(intervalEndTimer >= intervalStartTimer + 55, "The visible recording timer must advance through each external speech interval")
                    let liveCharacters = liveTextCharacterCount(in: app)
                    try require(liveCharacters > 0, "External audible input must produce actual visible live text during every interval")
                    try await verifyLatestCaptionVisible(in: app, revision: revision)
                    print("[VISIBLE_UI_RECORDING] source=\(audioSource) playbackEvidence=parent_checkpoint_ack interval=\(interval) observedSeconds=60 timerStart=\(intervalStartTimer) timerEnd=\(intervalEndTimer) liveCharacters=\(liveCharacters)")
                    try await visibleCheckpoint("07-recording-\(interval * 60)-seconds", app: app, revision: revision, directory: checkpoints)
                    intervalStartTimer = try visibleTimerSeconds(in: app)
                }
                if let expectedExternalLiveText {
                    let visibleSpeech = normalizedVisibleSpeech(liveParagraphs(in: app).map(\.label).joined(separator: " "))
                    try require(visibleSpeech.contains(expectedExternalLiveText),
                                "Visible live captions must contain the explicitly expected external fixture phrase before Stop")
                    print("[VISIBLE_UI_EXTERNAL_AUDIO] expectedLivePhraseMatched=true source=\(audioSource)")
                }
                // The ACK attests that the parent stopped its external player after
                // inspecting this still-active recording. The runner owns no player.
                print("[VISIBLE_UI_EXTERNAL_AUDIO] action=stop_external_playback_before_ack checkpoint=08-ready-to-stop")
                try await visibleCheckpoint("08-ready-to-stop", app: app, revision: revision, directory: checkpoints)
                try verifyVisibleRecording(in: app)
            } else {
                let player = try XCTUnwrap(player)
                let audioSession = try XCTUnwrap(audioSession)
                let runner = XCUIApplication(bundleIdentifier: runnerID)
                runner.activate()
                try await visibleCheckpoint("05-playback-runner-foreground", app: runner, revision: revision, directory: checkpoints)
                try require(runner.state == .runningForeground, "Initiate playback while its owning runner is foreground")
                try audioSession.setCategory(.playback, mode: .default, options: .mixWithOthers)
                changedPlaybackCategory = true
                try audioSession.setActive(true)
                ownsPlaybackSession = true
                try require(player.prepareToPlay(), "The foreground runner must prepare synthetic playback")
                try require(player.play(), "The runner must start real synthetic speech playback")
                app.activate()
                try verifyVisibleRecording(in: app)
                try require(try visibleTimerSeconds(in: app) >= beforeSpeechTimer, "The same recording timer must survive the foreground change")
                try await visibleCheckpoint("06-recording-with-speech", app: app, revision: revision, directory: checkpoints)
                let speechStartTimer = try visibleTimerSeconds(in: app)
                try await observeVisibleRecording(in: app, player: player, seconds: 30)
                let thirtySecondTimer = try visibleTimerSeconds(in: app)
                try require(thirtySecondTimer >= speechStartTimer + 25, "The visible timer must advance during the first speech interval")
                try await visibleCheckpoint("07-recording-30-seconds", app: app, revision: revision, directory: checkpoints)
                try await observeVisibleRecording(in: app, player: player, seconds: 30)
                let sixtySecondTimer = try visibleTimerSeconds(in: app)
                try require(sixtySecondTimer >= thirtySecondTimer + 25, "The visible timer must keep advancing during the second speech interval")
                try await visibleCheckpoint("08-recording-60-seconds", app: app, revision: revision, directory: checkpoints)
                print("[VISIBLE_UI_RECORDING] source=\(audioSource) timerBeforeSpeech=\(beforeSpeechTimer) timerAtSpeech=\(speechStartTimer) timerAt30=\(thirtySecondTimer) timerAt60=\(sixtySecondTimer) liveCharacters=\(liveTextCharacterCount(in: app))")
                try require(liveTextCharacterCount(in: app) > 0, "Audible input must produce actual visible live text before Stop")

                player.stop()
                try require(!player.isPlaying, "Stop the owned speech player before stopping capture")
            }
            try tap(app.buttons["meeting.stop"], "Tap the actual Stop and Transcribe action")
            // A very short session may complete before the processing snapshot. Retain
            // the observed state rather than requiring a transient spinner to linger.
            try await waitForVisibleProcessingOrCompletion(in: app, timeout: 30)
            try await visibleCheckpoint("09-processing", app: app, revision: revision, directory: checkpoints)
            try await waitForCompletedTranscript(in: app, timeout: 300)
            ownsRecording = false
            try require(!app.buttons["meeting.stop"].exists, "Joined completion must remove the recording controls")
            let paragraphs = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript.paragraph."))
            try require(paragraphs.count > 0, "Completion must expose actual readable transcript paragraphs")
            let speakers = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript.speaker."))
            if speakers.count > 0 {
                try require(speakers.allElementsBoundByIndex.allSatisfy { !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                            "Every exposed speaker must have a readable label")
            }
            print("[VISIBLE_UI_COMPLETED] paragraphs=\(paragraphs.count) speakers=\(speakers.count) revision=\(revision) source=\(audioSource)")
            try await visibleCheckpoint("10-completed", app: app, revision: revision, directory: checkpoints)
        } catch {
            player?.stop()
            // Ownership begins only after this test taps Start. Never stop an
            // unrelated meeting found in the initial foreground or idle checkpoint.
            if ownsRecording {
                let cleanup = Task { @MainActor in
                    app.activate()
                    try? self.saveVisibleCheckpoint("failure-owned-recording-foreground", app: app,
                                                    revision: revision, directory: checkpoints)
                    // Older iPadOS can propagate the container identifier to an inset
                    // button. Use that observed identifier only to clean up OUR failed
                    // attempt; the success path still requires the correct Stop identity.
                    let identifiedStop = app.buttons["meeting.stop"]
                    let stop = identifiedStop.exists ? identifiedStop : app.buttons["meeting.recording"]
                    if stop.waitForExistence(timeout: 30), stop.isEnabled {
                        stop.tap()
                        try? self.saveVisibleCheckpoint("failure-owned-recording-stop", app: app,
                                                        revision: revision, directory: checkpoints)
                        do { try await self.waitForCompletedTranscript(in: app, timeout: 300) }
                        catch { print("[VISIBLE_UI_CLEANUP] joined_completion_requires_parent_inspection") }
                    } else if !app.buttons["transcript.more"].exists {
                        print("[VISIBLE_UI_CLEANUP] stop_unavailable_requires_parent_inspection")
                    }
                    try? self.saveVisibleCheckpoint("failure-owned-recording-cleanup", app: app,
                                                    revision: revision, directory: checkpoints)
                }
                await cleanup.value
            } else {
                try? saveVisibleCheckpoint("failure-current-state", app: app, revision: revision, directory: checkpoints)
            }
            throw error
        }
        #endif
    }

    /// Runs the real recording UI while the DEBUG app feeds a staged file into capture.
    /// The parent observes USB diagnostics and explicitly requests Stop after EOF.
    @MainActor
    func testDebugSilentLongRecordingWithParentStopSignal() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires an explicitly authorized, visibly observed physical iPad")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_PHYSICAL_SILENT_LONG_UI"] == "1" else {
            throw XCTSkip("Enable the silent physical long-recording test explicitly")
        }
        let revision = try XCTUnwrap(environment["PICHI_TEST_REVISION"])
        try require(!revision.isEmpty && revision != "working-tree", "A concrete frozen DEBUG AUT revision is required")
        let inputFile = try XCTUnwrap(environment["PICHI_DEBUG_AUDIO_FILE"])
        let speedText = environment["PICHI_DEBUG_AUDIO_SPEED"] ?? "1"
        let speed = try XCTUnwrap(Double(speedText))
        try require(!inputFile.isEmpty && speed.isFinite && (0.1...32).contains(speed),
                    "An explicit staged input file and supported feed speed are required")
        executionTimeAllowance = 2 * 60 * 60
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        let checkpoints = support.appendingPathComponent("VisibleRecordingUI", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        print("[VISIBLE_UI_RUN] directory=\(checkpoints.path) revision=\(revision) test=testDebugSilentLongRecordingWithParentStopSignal source=debug_file_input speed=\(speed)")

        let app = XCUIApplication()
        var ownsRecording = false
        do {
            // Activation preserves an existing process. Never relaunch an unrelated
            // recording merely to install the DEBUG input environment.
            app.activate()
            try saveVisibleCheckpoint("00-existing-foreground", app: app, revision: revision, directory: checkpoints)
            try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
            try require(!app.buttons["meeting.stop"].exists
                        && !app.descendants(matching: .any)["meeting.recording"].firstMatch.exists
                        && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists,
                        "An existing recording or processing attempt is not owned by this test")
            try await visibleCheckpoint("01-meetings-idle", app: app, revision: revision, directory: checkpoints)
            try require(!app.buttons["meeting.stop"].exists
                        && !app.descendants(matching: .any)["meeting.recording"].firstMatch.exists
                        && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists,
                        "The app must still be idle after parent inspection before relaunch")
            app.launchArguments = []
            app.launchEnvironment = ["PICHI_DEBUG_AUDIO_INPUT": "1", "PICHI_DEBUG_AUDIO_FILE": inputFile,
                                     "PICHI_DEBUG_AUDIO_SPEED": speedText, "PICHI_TEST_REVISION": revision]
            app.launch()
            try saveVisibleCheckpoint("02-silent-aut-launched", app: app, revision: revision, directory: checkpoints)
            try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
            try require(!app.buttons["meeting.stop"].exists
                        && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists,
                        "The relaunched DEBUG AUT must remain idle before this test starts recording")
            if !app.buttons["meeting.start"].exists {
                try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
                try saveVisibleCheckpoint("02-new-meeting", app: app, revision: revision, directory: checkpoints)
            }
            try require(app.alerts.count == 0, "Resolve ordinary readiness prompts before silent capture")
            try await visibleCheckpoint("03-ready", app: app, revision: revision, directory: checkpoints)
            try tap(app.buttons["meeting.start"], "Start the actual app recording with silent DEBUG file input")
            ownsRecording = true
            try await waitForVisibleRecording(in: app, timeout: 90)
            try await visibleCheckpoint("04-recording", app: app, revision: revision, directory: checkpoints)

            let stopSignal = checkpoints.appendingPathComponent("silent-stop.ack")
            let began = ProcessInfo.processInfo.systemUptime
            let deadline = began + 2 * 60 * 60
            var previousTimer = try visibleTimerSeconds(in: app)
            var tick = 0
            while !FileManager.default.fileExists(atPath: stopSignal.path) {
                try require(ProcessInfo.processInfo.systemUptime < deadline, "Parent must signal Stop within two hours")
                let nextTick = min(ProcessInfo.processInfo.systemUptime + 30, deadline)
                while ProcessInfo.processInfo.systemUptime < nextTick
                    && !FileManager.default.fileExists(atPath: stopSignal.path) {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                try verifyVisibleRecording(in: app)
                if FileManager.default.fileExists(atPath: stopSignal.path) { break }
                let timer = try visibleTimerSeconds(in: app)
                try require(timer > previousTimer, "The real recording timer must advance between silent input observations")
                let liveCharacters = liveTextCharacterCount(in: app)
                if ProcessInfo.processInfo.systemUptime - began >= 120 {
                    try require(liveCharacters > 0, "Silent input must expose live captions within the first two observed minutes")
                }
                previousTimer = timer
                tick += 1
                let step = String(format: "05-recording-tick-%04d", tick)
                try saveVisibleCheckpoint(step, app: app, revision: revision, directory: checkpoints)
                print("[SILENT_LONG_UI_TICK] step=\(step) wallSeconds=\(Int(ProcessInfo.processInfo.systemUptime - began)) timerSeconds=\(timer) liveCharacters=\(liveCharacters)")
            }
            try verifyVisibleRecording(in: app)
            try require(liveTextCharacterCount(in: app) > 0, "Direct file input must produce actual visible live text before Stop")
            try saveVisibleCheckpoint("06-parent-stop-signal", app: app, revision: revision, directory: checkpoints)
            try tap(app.buttons["meeting.stop"], "Stop the real recording after the parent observes input EOF")
            try await waitForVisibleProcessingOrCompletion(in: app, timeout: 30)
            try saveVisibleCheckpoint("09-processing", app: app, revision: revision, directory: checkpoints)
            print("[VISIBLE_UI_CHECKPOINT] step=09-processing directory=\(checkpoints.path) revision=\(revision)")
            try await waitForCompletedTranscript(in: app, timeout: 60 * 60)
            ownsRecording = false
            let paragraphs = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript.paragraph."))
            try require(paragraphs.count > 0, "Joined completion must expose actual transcript paragraphs")
            let speakers = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript.speaker."))
            print("[SILENT_LONG_UI_COMPLETED] paragraphs=\(paragraphs.count) speakers=\(speakers.count) revision=\(revision)")
            try await visibleCheckpoint("10-completed", app: app, revision: revision, directory: checkpoints)
        } catch {
            if ownsRecording {
                let cleanup = Task { @MainActor in
                    app.activate()
                    let identifiedStop = app.buttons["meeting.stop"]
                    let stop = identifiedStop.exists ? identifiedStop : app.buttons["meeting.recording"]
                    if stop.waitForExistence(timeout: 30), stop.isEnabled { stop.tap() }
                    do { try await self.waitForCompletedTranscript(in: app, timeout: 60 * 60) }
                    catch { print("[SILENT_LONG_UI_CLEANUP] joined_completion_requires_parent_inspection") }
                    try? self.saveVisibleCheckpoint("failure-owned-recording-cleanup", app: app,
                                                    revision: revision, directory: checkpoints)
                }
                await cleanup.value
            } else {
                try? saveVisibleCheckpoint("failure-current-state", app: app, revision: revision, directory: checkpoints)
            }
            throw error
        }
        #endif
    }

    @MainActor private func saveVisibleCheckpoint(_ step: String, app: XCUIApplication,
                                                  revision: String, directory: URL) throws {
        let screenshot = XCUIScreen.main.screenshot()
        try screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(step).png"), options: .atomic)
        let details = "test=\(name)\nstep=\(step)\nrevision=\(revision)\nuptime=\(ProcessInfo.processInfo.systemUptime)\nappState=\(app.state.rawValue)\n\n\(app.debugDescription)\n"
        try details.write(to: directory.appendingPathComponent("\(step).txt"), atomically: true, encoding: .utf8)
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(name)-\(step)-\(revision)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func visibleCheckpoint(_ step: String, app: XCUIApplication,
                                              revision: String, directory: URL) async throws {
        try saveVisibleCheckpoint(step, app: app, revision: revision, directory: directory)
        print("[VISIBLE_UI_CHECKPOINT] step=\(step) directory=\(directory.path) revision=\(revision)")
        let acknowledgement = directory.appendingPathComponent("\(step).ack")
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: acknowledgement.path) {
                print("[VISIBLE_UI_ACK] step=\(step)")
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw verificationFailure("Parent did not acknowledge native checkpoint \(step) within 120 seconds")
    }

    @MainActor private func verifyVisibleRecording(in app: XCUIApplication) throws {
        try require(app.state == .runningForeground, "The recording AUT must remain visibly foreground")
        try require(app.descendants(matching: .any)["meeting.recording"].firstMatch.exists
                    && app.buttons["meeting.stop"].exists && app.buttons["meeting.stop"].isEnabled
                    && app.descendants(matching: .any)["meeting.timer"].firstMatch.exists,
                    "Actual recording UI must expose its recording container, enabled Stop action and timer")
        try require(app.alerts.count == 0 && !app.buttons["meeting.retry"].exists,
                    "The actual recording must not show an error or permission alert")
    }

    @MainActor private func visibleTimerSeconds(in app: XCUIApplication) throws -> Int {
        let timer = app.descendants(matching: .any)["meeting.timer"].firstMatch
        try require(timer.exists, "The actual recording timer must exist")
        let components = timer.label.split(separator: ":").map { Int($0) }
        try require((2...3).contains(components.count) && components.allSatisfy { $0 != nil && $0! >= 0 },
                    "The visible recording timer must use a readable timestamp")
        return components.reduce(0) { $0 * 60 + $1! }
    }

    @MainActor private func waitForVisibleRecording(in app: XCUIApplication, timeout: TimeInterval,
                                                    microphonePromptRevision: String? = nil) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var grantedPrompt = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            if let revision = microphonePromptRevision {
                let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
                let alerts = springboard.alerts.count > 0 ? springboard.alerts : app.alerts
                if alerts.count > 0 {
                    try require(!grantedPrompt && alerts.count == 1 && revision == PhysicalOwnedPlaybackAuthorization.frozenRevision,
                                "Only one explicitly authorized microphone permission prompt may be handled")
                    let alert = alerts.firstMatch
                    if springboard.alerts.count > 0 && app.alerts.count > 0 {
                        let other = app.alerts.firstMatch
                        try require(app.alerts.count == 1 && PhysicalMicrophonePrompt.grantIndex(
                            texts: [other.label] + other.staticTexts.allElementsBoundByIndex.map(\.label),
                            buttons: other.buttons.allElementsBoundByIndex.map(\.label)) != nil,
                            "Any additional or different application prompt denies microphone handling")
                    }
                    let texts = [alert.label] + alert.staticTexts.allElementsBoundByIndex.map(\.label)
                    let buttons = alert.buttons.allElementsBoundByIndex
                    let index = try XCTUnwrap(PhysicalMicrophonePrompt.grantIndex(texts: texts, buttons: buttons.map(\.label)),
                                             "Reject every prompt except the exact Pichi Voice microphone purpose and unique grant action")
                    let grant = buttons[index]
                    try require(grant.waitForExistence(timeout: 5) && grant.isHittable && grant.isEnabled,
                                "Only the exact authorized microphone grant control may receive the event")
                    try Task.checkCancellation()
                    grant.tap()
                    try require(alert.waitForNonExistence(timeout: 5), "The owned microphone prompt must close normally")
                    grantedPrompt = true
                    print("[PHYSICAL_MICROPHONE_PROMPT] exactOwnedPromptGranted=true revision=\(revision)")
                }
            }
            if app.buttons["meeting.stop"].exists && app.buttons["meeting.stop"].isEnabled {
                try verifyVisibleRecording(in: app)
                return
            }
            if app.buttons["meeting.recording"].exists {
                throw verificationFailure("The recording container identifier replaced the Stop button identifier")
            }
            if app.alerts.count > 0 || app.buttons["meeting.retry"].exists {
                throw verificationFailure("The real Start action exposed an alert or failed attempt")
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw verificationFailure("The real Start action did not reach active recording")
    }

    @MainActor private func observeVisibleRecording(in app: XCUIApplication, player: AVAudioPlayer?,
                                                   seconds: TimeInterval) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            try verifyVisibleRecording(in: app)
            if let player {
                try require(player.isPlaying, "Owned synthetic playback must remain active during recording")
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        try verifyVisibleRecording(in: app)
    }

    @MainActor private func waitForVisibleProcessingOrCompletion(in app: XCUIApplication,
                                                                timeout: TimeInterval) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if app.descendants(matching: .any)["meeting.processing"].firstMatch.exists
                || (app.buttons["transcript.more"].exists && !app.buttons["meeting.stop"].exists) { return }
            if app.alerts.count > 0 || app.buttons["meeting.retry"].exists {
                throw verificationFailure("The actual Stop action failed instead of processing")
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw verificationFailure("Stop did not enter processing or joined completion")
    }

    @MainActor private func openNavigation(_ app: XCUIApplication, _ identifier: String, titles: [String], revision: String) throws {
        let sidebar = app.buttons["navigation.\(identifier)"]
        if sidebar.exists { try tap(sidebar, "Open \(identifier)") }
        else {
            let tab = try XCTUnwrap(titles.map { app.tabBars.buttons[$0] }.first { $0.exists })
            try tap(tab, "Open \(identifier)")
        }
        capture("navigation-\(identifier)", revision: revision)
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication, revision: String,
                                   container: XCUIElement? = nil) throws {
        try PhysicalControlReveal.run(ready: { element.exists && element.isHittable }, scroll: { upward, step in
            let scroll = container ?? (app.collectionViews.firstMatch.exists
                ? app.collectionViews.firstMatch : app.tables.firstMatch)
            try require(scroll.exists && scroll.isHittable && app.alerts.count == 0,
                        "Settings must expose its visible native form without a prompt")
            if upward { scroll.swipeUp() } else { scroll.swipeDown() }
            capture("settings-scroll-\(upward ? "up" : "down")-\(step)", revision: revision)
        })
    }

    @MainActor private func historyIDs(in app: XCUIApplication) -> Set<String> {
        Set(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "history.session.")).allElementsBoundByIndex
            .map { String($0.identifier.dropFirst("history.session.".count)) })
    }

    @MainActor private func liveTextCharacterCount(in app: XCUIApplication) -> Int {
        liveParagraphs(in: app).reduce(0) { $0 + $1.label.count }
    }

    private func normalizedVisibleSpeech(_ value: String) -> String {
        value.lowercased().components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    @MainActor private func liveParagraphs(in app: XCUIApplication) -> [XCUIElement] {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "meeting.liveParagraph.")).allElementsBoundByIndex
    }

    @MainActor private func waitForPhysicalCaptionLatestControl(in app: XCUIApplication, revision: String) async throws -> XCUIElement {
        var selected: XCUIElement?
        do {
            try await PhysicalUITransitionWait.until(timeout: 5, condition: {
                let viewports = app.tables.matching(identifier: PhysicalCaptionLatestControl.viewportID)
                guard app.state == .runningForeground, app.alerts.count == 0, viewports.count == 1,
                      app.buttons["meeting.stop"].exists, app.buttons["meeting.stop"].isEnabled else { return false }
                // Query Button and Table separately: source 1a can propagate the outer
                // viewport ID to its inset Jump button on the actual native AX tree.
                let buttons = app.buttons.matching(NSPredicate(format: "identifier IN %@",
                    [PhysicalCaptionLatestControl.canonicalID, PhysicalCaptionLatestControl.viewportID])).allElementsBoundByIndex
                let candidates = buttons.map {
                    PhysicalCaptionLatestControl.Candidate(identifier: $0.identifier, label: $0.label, frame: $0.frame,
                                                           enabled: $0.isEnabled, hittable: $0.isHittable)
                }
                guard let index = PhysicalCaptionLatestControl.select(candidates, viewport: viewports.firstMatch.frame) else { return false }
                selected = buttons[index]
                print("[PHYSICAL_CAPTION_JUMP] selectedID=\(candidates[index].identifier) canonical=\(candidates[index].identifier == PhysicalCaptionLatestControl.canonicalID)")
                return true
            })
            return try XCTUnwrap(selected)
        } catch {
            capture("caption-jump-control-admission-failure", revision: revision)
            throw error
        }
    }

    @MainActor private func waitForPhysicalCommittedCaptionHistory(in app: XCUIApplication, player: AVAudioPlayer,
                                                                   revision: String) async throws {
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + 60
        do {
            while true {
                try Task.checkCancellation()
                try verifyVisibleRecording(in: app)
                try require(player.isPlaying, "The owned fixture must remain playing while committed scroll history grows")
                let viewports = app.tables.matching(identifier: PhysicalCaptionLatestControl.viewportID)
                try require(viewports.count == 1, "Committed history readiness requires the unique actual native Table viewport")
                let paragraphs = liveParagraphs(in: app).map {
                    PhysicalCaptionGeometry.ParagraphFrame(identifier: $0.identifier, frame: $0.frame)
                }
                let extent = PhysicalCaptionGeometry.committedHistory(paragraphs, viewport: viewports.firstMatch.frame)
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                print("[PHYSICAL_CAPTION_HISTORY] revision=\(revision) elapsed=\(elapsed) sampled=\(paragraphs.count) committed=\(extent.validParagraphCount) "
                    + "invalid=\(extent.invalidParagraphCount) duplicateIDs=\(extent.duplicateIdentifiers) span=\(extent.span) "
                    + "viewportHeight=\(extent.viewportHeight) ready=\(extent.isReady)")
                if extent.isReady { return }
                try require(ProcessInfo.processInfo.systemUptime < deadline,
                            "Committed captions did not reach two distinct earlier paragraphs spanning 1.75 native viewports within 60 additional seconds")
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        } catch {
            print("[PHYSICAL_CAPTION_HISTORY] readiness_failed=true revision=\(revision)")
            throw error
        }
    }

    @MainActor private func exercisePhysicalCaptionScrollAndJump(in app: XCUIApplication, revision: String, prefix: String) async throws {
        try verifyVisibleRecording(in: app)
        try await verifyLatestCaptionVisible(in: app, revision: revision)
        let paragraphs = liveParagraphs(in: app)
        try require(paragraphs.count >= 2, "Scroll acceptance requires actual committed caption history, never a skipped assertion")
        let formerTailID = try XCTUnwrap(paragraphs.last).identifier
        let viewports = app.tables.matching(identifier: PhysicalCaptionLatestControl.viewportID)
        try require(viewports.count == 1 && viewports.firstMatch.isHittable,
                    "The native caption Table must uniquely own the recording viewport and scroll gesture")
        capture("\(prefix)-01-following", revision: revision)
        viewports.firstMatch.swipeDown()
        let latest = try await waitForPhysicalCaptionLatestControl(in: app, revision: revision)
        let formerTail = app.descendants(matching: .any).matching(identifier: formerTailID).firstMatch
        try require(!formerTail.exists || !PhysicalCaptionGeometry.Sample(identifier: formerTailID,
            paragraph: formerTail.frame, viewport: viewports.firstMatch.frame).tailIsVisible,
            "A real scroll must expose older history with the former latest tail outside the viewport")
        try require(!liveParagraphs(in: app).isEmpty, "Older committed captions must remain readable after scrolling")
        capture("\(prefix)-02-reading-older", revision: revision)
        try tap(latest, "Return to the latest captions through the uniquely admitted native Jump button")
        try await verifyLatestCaptionVisible(in: app, revision: revision)
        try await PhysicalUITransitionWait.until(timeout: 5, condition: {
            let buttons = app.buttons.matching(NSPredicate(format: "identifier IN %@ AND label IN %@",
                [PhysicalCaptionLatestControl.canonicalID, PhysicalCaptionLatestControl.viewportID], PhysicalCaptionLatestControl.labels))
            return buttons.count == 0
        })
        capture("\(prefix)-03-returned-to-latest", revision: revision)
    }

    @MainActor private func verifyLatestCaptionVisible(in app: XCUIApplication, revision: String) async throws {
        var settling = PhysicalCaptionGeometry.Settling()
        do {
            try await PhysicalUITransitionWait.until(timeout: 5, condition: {
                guard let latest = liveParagraphs(in: app).last else {
                    settling = PhysicalCaptionGeometry.Settling()
                    print("[PHYSICAL_CAPTION_GEOMETRY] committed_paragraph_missing=true")
                    return false
                }
                let viewports = app.tables.matching(identifier: PhysicalCaptionLatestControl.viewportID)
                guard viewports.count == 1 else { return false }
                let viewport = viewports.firstMatch
                let sample = PhysicalCaptionGeometry.Sample(identifier: latest.identifier,
                                                            paragraph: latest.frame, viewport: viewport.frame)
                // A noninteractive accessibility paragraph may be readable even when
                // XCTest cannot hit-test its full, partly offscreen text-and-wave row.
                print("[PHYSICAL_CAPTION_GEOMETRY] identifier=\(sample.identifier) paragraph=\(sample.paragraph) "
                    + "viewport=\(sample.viewport) intersection=\(sample.paragraph.intersection(sample.viewport)) "
                    + "hittable=\(latest.isHittable) tailVisible=\(sample.tailIsVisible)")
                return settling.observe(sample)
            })
        } catch {
            capture("caption-tail-visibility-failure", revision: revision)
            throw error
        }
    }

    @MainActor private func firstButton(in app: XCUIApplication, labels: [String]) -> XCUIElement? {
        labels.map { app.buttons[$0].firstMatch }.first { $0.exists }
    }

    @MainActor private func waitForOwnedShareSaveAction(in app: XCUIApplication, revision: String) async throws {
        let activity = app.otherElements["ActivityListView"]
        // System versions expose this observation-only action with different AX types.
        // Match an exact supported label inside only the share UI opened by the caller.
        let action = activity.descendants(matching: .any).matching(NSPredicate(format: "label IN %@",
            ["Save to Files", "Сохранить в Файлы", "Сохранить в «Файлы»"])).firstMatch
        capture("native-json-share-before-action-query", revision: revision)
        do {
            try await PhysicalUITransitionWait.until(timeout: 15, condition: {
                activity.exists && app.alerts.count == 0 && action.exists
            })
            print("[PHYSICAL_JSON_SHARE] save_action_observed=true axType=\(action.elementType.rawValue) action_tapped=false")
        } catch {
            capture("native-json-share-action-query-failure", revision: revision)
            throw error
        }
    }

    @MainActor private func waitForCompletedTranscript(in app: XCUIApplication, timeout: TimeInterval) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if app.buttons["transcript.more"].exists && !app.buttons["meeting.stop"].exists { return }
            if app.buttons["meeting.retry"].exists || app.alerts.count > 0 {
                throw verificationFailure("The actual recording failed or was interrupted instead of completing")
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw verificationFailure("Completion did not join and expose the transcript within the deadline")
    }

    @MainActor private func tap(_ element: XCUIElement, _ message: String) throws {
        try require(element.waitForExistence(timeout: 5) && element.isHittable && element.isEnabled, message)
        element.tap()
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw verificationFailure(message) }
    }

    private func verificationFailure(_ message: String) -> NSError {
        NSError(domain: "PhysicalReleaseUI", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func capture(_ step: String, revision: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(name)-\(step)-\(revision)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

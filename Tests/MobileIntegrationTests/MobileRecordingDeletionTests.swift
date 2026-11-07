import Foundation
import XCTest
@testable import PichiVoiceMobile

@MainActor
final class MobileRecordingDeletionTests: XCTestCase {
    func testDeleteCommitsOnlySelectedRecordingAndItsFiles() async throws {
        let fixture = try Fixture()
        addTeardownBlock { await fixture.close() }
        let selected = try await fixture.save("Selected")
        let survivor = try await fixture.save("Survivor")
        let directory = try await fixture.store.sessionDirectory(for: selected.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("session.json").path))
        try await MobileMeetingDeletionActions.delete(selected, coordinator: fixture.coordinator, canDelete: { true })
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let cold = MeetingSessionStore(rootDirectory: fixture.root)
        let remaining = try await cold.loadHistory()
        XCTAssertEqual(remaining.map(\.id), [survivor.id])
    }

    func testRetiredAdmissionLeavesRecordingAndHistoryUntouched() async throws {
        let fixture = try Fixture()
        addTeardownBlock { await fixture.close() }
        let selected = try await fixture.save("Retained")
        do {
            try await MobileMeetingDeletionActions.delete(selected, coordinator: fixture.coordinator, canDelete: { false })
            XCTFail("A retired UI action must not delete")
        } catch is CancellationError {}
        let remaining = try await fixture.store.loadHistory()
        XCTAssertEqual(remaining.map(\.id), [selected.id])
    }

    func testConcealedRecordingCannotBeDeletedByHistoryAction() async throws {
        let fixture = try Fixture()
        addTeardownBlock { await fixture.close() }
        var selected = try await fixture.save("Retained")
        selected.requiresEncryptedPersistence = true
        selected.profileOwnership = foreignOwnership
        XCTAssertTrue(selected.isLocalContentConcealed)
        do {
            try await MobileMeetingDeletionActions.delete(selected, coordinator: fixture.coordinator, canDelete: { true })
            XCTFail("A concealed row must not delete")
        } catch is CancellationError {}
        let remaining = try await fixture.store.loadHistory()
        XCTAssertEqual(remaining.map(\.id), [selected.id])
    }

    func testOwnershipFailurePreservesRecording() async throws {
        let fixture = try Fixture()
        addTeardownBlock { await fixture.close() }
        var selected = try await fixture.save("Retained")
        selected.profileOwnership = foreignOwnership
        do {
            try await MobileMeetingDeletionActions.delete(selected, coordinator: fixture.coordinator, canDelete: { true })
            XCTFail("Stale row ownership must fail")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        let remaining = try await fixture.store.loadHistory()
        XCTAssertEqual(remaining.map(\.id), [selected.id])
    }

    func testCancelledActionPreservesRecording() async throws {
        let fixture = try Fixture()
        addTeardownBlock { await fixture.close() }
        let selected = try await fixture.save("Retained")
        let task = Task { @MainActor in
            try await MobileMeetingDeletionActions.delete(selected, coordinator: fixture.coordinator, canDelete: { true })
        }
        task.cancel()
        do { try await task.value; XCTFail("Cancelled deletion must not commit") }
        catch is CancellationError {}
        let remaining = try await fixture.store.loadHistory()
        XCTAssertEqual(remaining.map(\.id), [selected.id])
    }

    private var foreignOwnership: MeetingProfileOwnership {
        .init(profileID: "other-account", issuer: "https://identity.invalid", subject: "other",
              internalUserID: "other", organizationID: "org", workspaceID: "workspace")
    }

    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "RecordingDeletion.\(UUID().uuidString)"
        let defaults: UserDefaults
        let store: MeetingSessionStore
        let services: AppServices
        var coordinator: MeetingSessionCoordinator { services.meetingSessionCoordinator }

        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let settings = SettingsStore(defaults: defaults)
            settings.meetingAudioRetentionPolicy = .never
            store = MeetingSessionStore(rootDirectory: root)
            services = AppServices(store: store, settings: settings)
        }

        func save(_ title: String) async throws -> MeetingSession {
            let configuration = MeetingCaptureConfiguration(mode: .inRoom, title: title,
                microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic"), audioStorageMode: .memoryOnly)
            var session = MeetingSession(configuration: configuration, timebase: .init(startedHostTime: 0,
                machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil))
            session.state = .completed
            session.profileOwnership = .guest
            session.endedAt = session.startedAt.addingTimeInterval(30)
            session.audioTracks = [.init(id: UUID(), kind: .microphone, sourceIdentifier: "synthetic",
                sourceDisplayName: "Synthetic", format: nil, timebase: session.timebase, health: .waiting, chunks: [])]
            try await store.create(session)
            return session
        }

        func close() async {
            await services.shutdownForTermination()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

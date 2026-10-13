@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import UIKit
@testable import PichiVoiceMobile
import XCTest

/// Counts real hardware buffers without keeping their audio content or writing files.
private final nonisolated class PhysicalMicrophoneProbe: MeetingMemoryAudioConsuming, @unchecked Sendable {
    private let lock = NSLock()
    private var samples = 0
    private var events: [String] = []
    func enqueue(_ buffer: CMSampleBuffer) -> Bool {
        lock.withLock { samples += CMSampleBufferGetNumSamples(buffer) }
        return true
    }
    func finish() async throws { }
    func event(_ event: MeetingCaptureEvent) {
        lock.withLock {
            if events.count < 20 { events.append(String(describing: event)) }
        }
    }
    func count() -> Int { lock.withLock { samples } }
    func recordedEvents() -> [String] { lock.withLock { events } }
}

@MainActor
final class PhysicalDevicePrerequisiteTests: XCTestCase {
    func testMicrophonePermissionWithoutModelInstallation() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("This prerequisite checks the physical iPad microphone permission")
        #else
        let capture = IOSMeetingCaptureEngine()
        try await capture.preflightPermissions()
        XCTAssertEqual(AVAudioApplication.shared.recordPermission, .granted)
        await capture.shutdownForTermination()
        #endif
    }

    func testPhysicalMicrophoneDeliversPCMWithoutAudioFiles() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires a physical iPad or iPhone")
        #else
        guard ProcessInfo.processInfo.environment["PICHI_PHYSICAL_MIC_TEST"] == "1" else {
            throw XCTSkip("Explicitly enable the three-second physical microphone test")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = PhysicalMicrophoneProbe()
        let capture = IOSMeetingCaptureEngine(memoryConsumerFactory: { _, _, _, _ in probe })
        let microphone = try await IOSMeetingCaptureEngine.defaultMicrophone()
        let configuration = MeetingCaptureConfiguration(mode: .inRoom, title: "Hardware microphone probe",
            microphone: microphone, audioStorageMode: .memoryOnly)
        let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1,
            machTimebaseDenominator: 1, firstPresentationTime: nil)
        let session = MeetingSession(configuration: configuration, timebase: timebase)
        let duration = Double(ProcessInfo.processInfo.environment["PICHI_PHYSICAL_MIC_SECONDS"] ?? "3") ?? 3
        guard duration >= 3, duration <= 90 else { throw NSError(domain: "PhysicalMicrophoneProbe", code: 1) }
        let requiresBackground = ProcessInfo.processInfo.environment["PICHI_PHYSICAL_MIC_BACKGROUND"] == "1"
        var backgroundSamples = 0
        var stateObservations: [[String: Any]] = []
        let evidence = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MobileDeviceEvidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var protectedEvidence = evidence; try protectedEvidence.setResourceValues(values)
        func saveEvidence(error: Error? = nil) throws {
            let audioSession = AVAudioSession.sharedInstance()
            let report: [String: Any] = [
                "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
                "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                "processorCount": ProcessInfo.processInfo.processorCount,
                "microphone": microphone.displayName, "capturedSamples": probe.count(),
                "audioFiles": 0, "category": audioSession.category.rawValue,
                "inputs": audioSession.currentRoute.inputs.map(\.uid),
                "availableInputs": (audioSession.availableInputs ?? []).map(\.uid),
                "events": probe.recordedEvents(), "error": error?.localizedDescription ?? "",
                "backgroundSamples": backgroundSamples, "durationSeconds": duration,
                "applicationStates": stateObservations,
            ]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: evidence.appendingPathComponent("microphone.json"), options: .atomic)
        }
        try saveEvidence()
        do {
            try await capture.preflightPermissions()
            _ = try await capture.start(session: session, configuration: configuration,
                sessionDirectory: root, eventHandler: { probe.event($0) })
            var previousCount = probe.count()
            for second in 0..<Int(duration.rounded(.up)) {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let count = probe.count()
                let state = UIApplication.shared.applicationState
                if state == .background { backgroundSamples += count - previousCount }
                stateObservations.append(["second": second + 1, "state": state.rawValue, "samples": count])
                previousCount = count
            }
            try saveEvidence()
            let result = try await capture.stop(sessionID: session.id)
            XCTAssertGreaterThan(probe.count(), 16_000)
            XCTAssertTrue(result.tracks.allSatisfy { $0.chunks.isEmpty })
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
            if requiresBackground { XCTAssertGreaterThan(backgroundSamples, 80_000, "Real background capture must deliver over five seconds of PCM") }
            await capture.shutdownForTermination()
        } catch {
            try? saveEvidence(error: error)
            await capture.shutdownForTermination()
            throw error
        }
        #endif
    }
}

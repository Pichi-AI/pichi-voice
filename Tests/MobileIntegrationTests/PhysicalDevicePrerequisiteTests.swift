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
    /// Run alone in a fresh host process, before any model work. This deletes only
    /// Apple's regeneratable execution cache, never installed models or recordings.
    func testAuthorizedCleanupOfDerivedCoreMLCache() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires the explicitly authorized physical device")
        #else
        guard ProcessInfo.processInfo.environment["PICHI_CLEAR_DERIVED_COREML_CACHE"] == "1" else {
            throw XCTSkip("Derived CoreML cache cleanup requires an explicit opt-in")
        }
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else {
                throw NSError(domain: "PhysicalDerivedCoreMLCacheProbe", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        let asr = AppServices.shared.asr
        try require(asr.activeExclusiveActivity == nil && !asr.hasActiveModelPreparation
                    && !asr.hasActiveModelDownload && !asr.isAsrReady
                    && !MeetingModelResidencyCoordinator.shared.isExclusive,
                    "Cleanup requires an idle fresh host without prepared models")
        let lease = try asr.acquireExclusiveActivity(.modelMaintenance)
        defer { asr.releaseExclusiveActivity(lease) }

        let files = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL
        let caches = try files.url(for: .cachesDirectory, in: .userDomainMask,
                                   appropriateFor: nil, create: false).standardizedFileURL
        try require(caches.pathComponents == home.appendingPathComponent("Library/Caches", isDirectory: true).pathComponents,
                    "Cleanup must remain in this sandbox's cache directory")
        let bundleID = try XCTUnwrap(Bundle.main.bundleIdentifier)
        try require(!bundleID.isEmpty && bundleID != "." && bundleID != ".."
                    && !bundleID.contains("/") && !bundleID.contains("\\")
                    && !bundleID.hasSuffix(".xctrunner"), "A trusted host bundle identifier is required")
        let bundleCache = caches.appendingPathComponent(bundleID, isDirectory: true)
        let target = bundleCache.appendingPathComponent("com.apple.e5rt.e5bundlecache", isDirectory: true)
        try require(target.deletingLastPathComponent() == bundleCache
                    && bundleCache.deletingLastPathComponent() == caches,
                    "Derived cache target must not escape its cache root")
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        func existsWithoutSymlink(_ url: URL) throws -> Bool {
            do {
                let attributes = try files.attributesOfItem(atPath: url.path)
                try require(attributes[.type] as? FileAttributeType != .typeSymbolicLink,
                            "Cache cleanup refuses symbolic links")
                try require(attributes[.type] as? FileAttributeType == .typeDirectory,
                            "Cache cleanup requires ordinary directories")
                return true
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                return false
            }
        }
        for root in [home.appendingPathComponent("Library", isDirectory: true), caches, bundleCache] {
            _ = try existsWithoutSymlink(root)
        }
        func cacheSize() throws -> (bytes: UInt64, files: Int) {
            guard try existsWithoutSymlink(target) else { return (0, 0) }
            var enumerationFailed = false
            guard let contents = files.enumerator(at: target, includingPropertiesForKeys: Array(keys),
                options: [], errorHandler: { _, _ in enumerationFailed = true; return false }) else {
                try require(false, "Derived cache enumeration could not start")
                return (0, 0)
            }
            var bytes: UInt64 = 0
            var count = 0
            for case let item as URL in contents {
                count += 1
                try require(count <= 100_000, "Derived cache enumeration exceeded its safety bound")
                try require(item.standardizedFileURL.pathComponents.starts(with: target.pathComponents),
                            "Derived cache entry escaped its root")
                let values = try item.resourceValues(forKeys: keys)
                try require(values.isSymbolicLink != true, "Cache cleanup refuses symbolic link descendants")
                if values.isRegularFile == true {
                    let size = values.fileSize ?? 0
                    try require(size >= 0 && UInt64(size) <= UInt64.max - bytes, "Invalid derived cache size")
                    bytes += UInt64(size)
                }
            }
            try require(!enumerationFailed, "Derived cache enumeration failed")
            return (bytes, count)
        }
        func record(_ stage: String) throws {
            let attributes = try files.attributesOfFileSystem(forPath: home.path)
            let size = try cacheSize()
            let report: [String: Any] = ["stage": stage,
                "volumeFilesystemFreeSize": try XCTUnwrap(attributes[.systemFreeSize] as? NSNumber),
                "volumeFilesystemSize": try XCTUnwrap(attributes[.systemSize] as? NSNumber),
                "cacheLogicalBytes": size.bytes, "cacheEntryCount": size.files]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "derived-coreml-cache-\(stage)"
            attachment.lifetime = .keepAlways
            self.add(attachment)
        }
        try record("before")
        if try existsWithoutSymlink(target) {
            do { try files.removeItem(at: target) }
            catch { try require(false, "Removing the authorized derived CoreML cache failed") }
        }
        try require(try !existsWithoutSymlink(target), "Derived CoreML cache must be removed")
        try record("after")
        #endif
    }

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

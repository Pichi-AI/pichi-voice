// Test-only paired mobile screen capture. No audio output and no permission prompts.
import AVFoundation
import CoreMediaIO
import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreImage
import Darwin

struct CaptureFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
// Paired screen devices appear asynchronously after CMIO discovery is enabled.
// Wait only for the caller's already filtered exact match; ambiguity is fatal.
func waitForSingleMatch<Match>(timeout: Double, now: () -> Double, stopped: () -> Bool,
                               matches: () -> [Match], wait: () -> Void) throws -> Match {
    let start = now()
    guard timeout.isFinite, timeout > 0, timeout <= 5 else { throw CaptureFailure("Invalid discovery deadline") }
    while true {
        guard !stopped() else { throw CaptureFailure("Screen discovery stopped") }
        guard now() - start < timeout else { throw CaptureFailure("Exact paired muxed screen device unavailable") }
        let current = matches()
        guard !stopped(), now() - start < timeout else { throw CaptureFailure("Screen discovery stopped or expired") }
        guard current.count <= 1 else { throw CaptureFailure("Ambiguous paired screen device") }
        if let match = current.first { return match }
        wait()
    }
}

func discoverySelfTest() throws {
    func require(_ condition: Bool) throws {
        guard condition else { throw CaptureFailure("Discovery self-test failed") }
    }
    func rejects(_ operation: () throws -> Void) -> Bool {
        do { try operation(); return false } catch { return true }
    }
    let immediate: String = try waitForSingleMatch(timeout: 5, now: { 0 }, stopped: { false },
        matches: { ["synthetic"] }, wait: { })
    try require(immediate == "synthetic")
    var clock = 0.0, polls = 0
    let delayed: String = try waitForSingleMatch(timeout: 5, now: { clock }, stopped: { false },
        matches: { polls += 1; return polls == 3 ? ["synthetic"] : [] }, wait: { clock += 1 })
    try require(delayed == "synthetic" && polls == 3 && clock == 2)
    try require(rejects {
        let _: String = try waitForSingleMatch(timeout: 5, now: { 0 }, stopped: { false },
            matches: { ["first", "second"] }, wait: { })
    })
    clock = 0
    try require(rejects {
        let _: String = try waitForSingleMatch(timeout: 5, now: { clock }, stopped: { false },
            matches: { [] }, wait: { clock += 1 })
    } && clock == 5)
    polls = 0
    try require(rejects {
        let _: String = try waitForSingleMatch(timeout: 5, now: { 0 }, stopped: { true },
            matches: { polls += 1; return ["synthetic"] }, wait: { })
    } && polls == 0)
    var cancelled = false
    polls = 0
    try require(rejects {
        let _: String = try waitForSingleMatch(timeout: 5, now: { 0 }, stopped: { cancelled },
            matches: { polls += 1; return [] }, wait: { cancelled = true })
    } && polls == 1)
    clock = 0
    try require(rejects {
        let _: String = try waitForSingleMatch(timeout: 5, now: { clock }, stopped: { false },
            matches: { clock = 6; return ["late"] }, wait: { })
    })
    cancelled = false
    try require(rejects {
        let _: String = try waitForSingleMatch(timeout: 5, now: { 0 }, stopped: { cancelled },
            matches: { cancelled = true; return ["cancelled"] }, wait: { })
    })
    print("{\"discoveryTestsPassed\":8,\"deviceOpened\":false}")
}
func utc() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}
func atomicJSON(_ value: [String: Any], to url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]).write(to: url, options: .atomic)
}
final class FrameWriter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let directory: URL
    let prefix: String
    let index: FileHandle
    let context = CIContext(options: [.cacheIntermediates: false])
    var firstPTS: Double?
    var lastSlot = -1
    var saved = 0
    var droppedNativeSamples = 0
    var missed = 0
    var lastAdvancingPTS: Double?
    var lastArrival = ProcessInfo.processInfo.systemUptime
    var failure: String?
    init(directory: URL, prefix: String, index: FileHandle) {
        self.directory = directory; self.prefix = prefix; self.index = index
    }
    func event(_ value: [String: Any]) {
        do {
            var bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            bytes.append(10)
            try index.write(contentsOf: bytes)
        } catch { failure = "Cannot persist native frame index: \(error)" }
    }
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        droppedNativeSamples += 1
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        autoreleasepool {
            guard failure == nil else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let seconds = CMTimeGetSeconds(pts)
            guard seconds.isFinite, let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                failure = "Video sample lacks finite PTS or image buffer"; return
            }
            if let prior = lastAdvancingPTS, seconds < prior { failure = "Native PTS moved backwards"; return }
            if lastAdvancingPTS == nil || seconds > lastAdvancingPTS! { lastArrival = now; lastAdvancingPTS = seconds }
            if firstPTS == nil { firstPTS = seconds }
            let elapsedPTS = seconds - firstPTS!
            guard elapsedPTS >= 0, elapsedPTS <= 86400 else { failure = "Native PTS discontinuity"; return }
            let slot = Int(floor(elapsedPTS))
            guard slot > lastSlot else { return }
            let gap = max(0, slot - lastSlot - 1)
            let file = "\(prefix)-\(String(format: "%06d", slot)).png"
            let final = directory.appendingPathComponent(file)
            let temporary = directory.appendingPathComponent(".\(file).pending")
            do {
                guard let image = context.createCGImage(CIImage(cvPixelBuffer: pixel), from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel))),
                      let destination = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    throw CaptureFailure("Cannot encode native image")
                }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw CaptureFailure("Cannot finalize PNG") }
                try FileManager.default.moveItem(at: temporary, to: final)
                event(["kind": "frame", "file": "frames/\(file)", "requestedSecond": slot,
                       "capturedAtUTC": utc(), "hostUptimeSeconds": now,
                       "ptsValue": pts.value, "ptsTimescale": pts.timescale, "ptsSeconds": seconds,
                       "elapsedPTSSeconds": seconds - firstPTS!, "missedSlotsBefore": gap,
                       "dimensions": [image.width, image.height], "valid": true])
                missed += gap; lastSlot = slot; saved += 1
            } catch { failure = String(describing: error) }
        }
    }
}

func main() throws {
    if Array(CommandLine.arguments.dropFirst()) == ["--self-test"] { try discoverySelfTest(); return }
    var options: [String: String] = [:]
    var cursor = 1
    let argv = CommandLine.arguments
    while cursor < argv.count {
        guard cursor + 1 < argv.count, argv[cursor].hasPrefix("--"), options[argv[cursor]] == nil else {
            throw CaptureFailure("Expected unique --key value arguments")
        }
        options[argv[cursor]] = argv[cursor + 1]; cursor += 2
    }
    guard Set(options.keys).isSubset(of: ["--stream-device-id", "--output", "--prefix", "--duration"]),
          let deviceID = options["--stream-device-id"], !deviceID.isEmpty,
          let path = options["--output"], let prefix = options["--prefix"], !prefix.isEmpty,
          prefix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }),
          let duration = Double(options["--duration"] ?? "7200"), duration.isFinite, duration > 0, duration <= 43200 else {
        throw CaptureFailure("Required: --stream-device-id ID --output EXISTING_EMPTY_OUTPUT --prefix SAFE_NAME [--duration SECONDS]")
    }
    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
        throw CaptureFailure("Video authorization must already be granted; no permission request will be made")
    }
    let root = URL(fileURLWithPath: path, isDirectory: true)
    let frames = root.appendingPathComponent("frames", isDirectory: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: frames.path, isDirectory: &isDirectory), isDirectory.boolValue,
          try FileManager.default.contentsOfDirectory(atPath: frames.path).isEmpty else {
        throw CaptureFailure("Output frames directory must exist and be empty")
    }
    let indexURL = root.appendingPathComponent("native-frames.jsonl")
    guard !FileManager.default.fileExists(atPath: indexURL.path), FileManager.default.createFile(atPath: indexURL.path, contents: nil) else {
        throw CaptureFailure("Native index must be new")
    }
    let index = try FileHandle(forWritingTo: indexURL)
    defer { try? index.close() }
    var address = CMIOObjectPropertyAddress(mSelector: UInt32(kCMIOHardwarePropertyAllowScreenCaptureDevices), mScope: UInt32(kCMIOObjectPropertyScopeGlobal), mElement: UInt32(kCMIOObjectPropertyElementMain))
    var allow: UInt32 = 1
    let discoveryStatus = CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
    guard discoveryStatus == noErr else { throw CaptureFailure("Cannot expose paired screen devices: \(discoveryStatus)") }
    // The exact explicit ID and muxed requirement prevent fallback to a Mac camera.
    let discoveryDeadline = ProcessInfo.processInfo.systemUptime + 5
    let device = try waitForSingleMatch(timeout: 5, now: { ProcessInfo.processInfo.systemUptime },
        stopped: { FileManager.default.fileExists(atPath: root.appendingPathComponent("STOP").path) },
        matches: { AVCaptureDevice.devices().filter { $0.uniqueID == deviceID && $0.hasMediaType(.muxed) } },
        wait: { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1)) })
    let session = AVCaptureSession()
    guard ProcessInfo.processInfo.systemUptime < discoveryDeadline,
          !FileManager.default.fileExists(atPath: root.appendingPathComponent("STOP").path) else {
        throw CaptureFailure("Screen discovery stopped or expired")
    }
    let input = try AVCaptureDeviceInput(device: device)
    let output = AVCaptureVideoDataOutput()
    output.alwaysDiscardsLateVideoFrames = true
    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    let queue = DispatchQueue(label: "mobile.screen.frames")
    let writer = FrameWriter(directory: frames, prefix: prefix, index: index)
    output.setSampleBufferDelegate(writer, queue: queue)
    session.beginConfiguration()
    guard session.canAddInput(input) else { throw CaptureFailure("Cannot add explicit screen input") }
    session.addInput(input)
    guard session.canAddOutput(output) else { throw CaptureFailure("Screen does not support video sample output") }
    session.addOutput(output)
    session.commitConfiguration()
    guard output.connection(with: .video) != nil,
          session.outputs.count == 1, session.outputs.allSatisfy({ $0 is AVCaptureVideoDataOutput }) else {
        throw CaptureFailure("Expected a video-only screen capture connection")
    }
    let start = ProcessInfo.processInfo.systemUptime
    var stopped = false
    var reason = "duration"
    signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
    let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { stopped = true; reason = "stopRequested" }
        source.resume(); return source
    }
    defer { signals.forEach { $0.cancel() } }
    queue.sync { writer.event(["kind": "started", "startedAtUTC": utc(), "intervalSeconds": 1, "audioOutputs": 0, "discoveryStatus": discoveryStatus]) }
    session.startRunning()
    defer {
        session.stopRunning()
        output.setSampleBufferDelegate(nil, queue: nil)
        queue.sync {}
    }
    while !stopped && ProcessInfo.processInfo.systemUptime - start < duration {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("STOP").path) { stopped = true; reason = "stopRequested" }
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: root.path)
        if (attributes[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0 < 2 * 1024 * 1024 * 1024 { stopped = true; reason = "insufficientDiskSpace" }
        queue.sync {
            if writer.failure != nil { stopped = true; reason = "captureFailure" }
            if ProcessInfo.processInfo.systemUptime - writer.lastArrival > 5 { stopped = true; reason = "noNativeFramesForFiveSeconds" }
        }
    }
    session.stopRunning()
    output.setSampleBufferDelegate(nil, queue: nil)
    var summary: [String: Any] = [:]
    queue.sync {
        summary = ["status": "stopped", "stopReason": reason, "endedAtUTC": utc(),
                   "savedFrames": writer.saved, "missedScheduleSlots": writer.missed,
                   "droppedNativeSamples": writer.droppedNativeSamples,
                   "elapsedSeconds": ProcessInfo.processInfo.systemUptime - start, "audioOutputs": 0]
        if let failure = writer.failure { summary["error"] = failure }
        writer.event(["kind": "stopped", "summary": summary])
    }
    try atomicJSON(summary, to: root.appendingPathComponent("native-status.json"))
    guard ["duration", "stopRequested"].contains(reason), writer.saved > 0 else { throw CaptureFailure("Capture ended: \(reason)") }
}
do { try main() } catch { fputs("Screen capture failed: \(error)\n", stderr); exit(1) }

import CTranscribe
import Darwin
import Foundation

/// Caller-owned, time-major features from the final acoustic encoder before its
/// decoding head. This is not a speaker embedding. The native model supplies the
/// dimension and sample clock; callers bind the snapshot to their frozen model.
public struct EncoderFeatureSnapshot: Sendable, Equatable {
    public let values: [Float]
    public let frameCount: Int
    public let dimension: Int
    public let sampleRate: Int
    public let frameHopSamples: Int
    public let nativeGeneration: UInt64
    public let recipeVersion: UInt32

    public var frameDuration: Double { Double(frameHopSamples) / Double(sampleRate) }
}

/// Transcript and encoder features copied during one successful run while the
/// model's existing compute lock is held. No native pointer escapes the run.
public struct EncoderFeatureRunSnapshot: Sendable, Equatable {
    public let transcript: Transcript
    public let encoderFeatures: EncoderFeatureSnapshot
}

/// A successful ASR result can be published even when optional feature capture
/// is unavailable or rejected. ASR failure and cancellation still throw.
public struct OptionalEncoderFeatureRunSnapshot: Sendable, Equatable {
    public let transcript: Transcript
    public let encoderFeatures: EncoderFeatureSnapshot?
}

/// Shared single-pass policy, invoked while Session holds the model run lock.
/// Keeping the run outside the optional-copy catch prevents an acoustic
/// dictionary failure from causing another ASR pass or masking an ASR error.
func performEncoderFeatureRun(
    required: Bool, run: () throws -> Transcript, copy: (() throws -> EncoderFeatureSnapshot)?,
    cancelled: () -> Bool, discard: () -> Void
) throws -> OptionalEncoderFeatureRunSnapshot {
    func requireNotCancelled() throws {
        guard !cancelled() else {
            throw TranscribeError.aborted(message: "Encoder feature capture cancelled", partial: nil)
        }
    }
    do {
        if required, copy == nil {
            throw TranscribeError.notImplemented("The loaded native SDK/model does not support encoder feature snapshots")
        }
        let transcript = try run()
        try requireNotCancelled()
        guard let copy else {
            return OptionalEncoderFeatureRunSnapshot(transcript: transcript, encoderFeatures: nil)
        }
        do {
            let features = try copy()
            try requireNotCancelled()
            return OptionalEncoderFeatureRunSnapshot(transcript: transcript, encoderFeatures: features)
        } catch {
            discard()
            try requireNotCancelled()
            if error is CancellationError { throw error }
            if case TranscribeError.aborted = error { throw error }
            guard !required else { throw error }
            return OptionalEncoderFeatureRunSnapshot(transcript: transcript, encoderFeatures: nil)
        }
    } catch {
        discard()
        throw error
    }
}

struct EncoderFeatureMetadata: Equatable {
    var frameCount: UInt32 = 0
    var dimension: UInt32 = 0
    var sampleRate: UInt32 = 0
    var hopSamples: UInt32 = 0
    var generation: UInt64 = 0

    func elementCount(maximumBytes: Int) throws -> Int {
        guard (1...2 * 1_024 * 1_024).contains(maximumBytes),
              (1...600).contains(frameCount), (1...1_024).contains(dimension),
              (1...384_000).contains(sampleRate), (1...sampleRate).contains(hopSamples),
              generation > 0 else {
            throw TranscribeError.invalidArgument("Invalid or oversized encoder feature metadata")
        }
        let (count, overflow) = Int(frameCount).multipliedReportingOverflow(by: Int(dimension))
        guard !overflow, count <= maximumBytes / MemoryLayout<Float>.size else {
            throw TranscribeError.inputTooLong("Encoder feature snapshot exceeds the caller's byte limit")
        }
        return count
    }
}

/// Optional ABI adapter. The shipped SDK can lack these symbols completely.
/// Resolve from the image owning transcribe_run, never an unrelated loaded SDK.
struct NativeEncoderFeatureAPI {
    typealias Getter = (OpaquePointer?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?,
        UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt64>?,
        UnsafeMutablePointer<Float>?, UInt64) -> Int32
    typealias CGetter = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?,
        UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt64>?,
        UnsafeMutablePointer<Float>?, UInt64) -> Int32
    typealias CVersion = @convention(c) () -> UInt32
    typealias CSupported = @convention(c) (OpaquePointer?) -> Int32
    typealias CClear = @convention(c) (OpaquePointer?) -> Int32
    typealias CRun = @convention(c) (OpaquePointer?, UnsafePointer<Float>?, Int32,
        UnsafePointer<transcribe_run_params>?) -> transcribe_status

    let supports: (OpaquePointer) -> Bool
    let clear: (OpaquePointer) -> Int32
    let get: Getter

    static let resolved: Self? = {
        var info = Dl_info()
        // Keep the C function convention explicit. Inference as a Swift closure
        // creates a two-word value that cannot be cast to a code pointer.
        let run: CRun = transcribe_run
        guard dladdr(unsafeBitCast(run, to: UnsafeRawPointer.self), &info) != 0,
              let filename = info.dli_fname,
              let image = dlopen(filename, RTLD_LAZY | RTLD_NOLOAD) else { return nil }
        defer { dlclose(image) }
        return resolve { dlsym(image, $0) }
    }()

    static func resolve(_ lookup: (String) -> UnsafeMutableRawPointer?) -> Self? {
        guard let versionSymbol = lookup("transcribe_encoder_features_api_version"),
              let supportedSymbol = lookup("transcribe_encoder_features_supported"),
              let clearSymbol = lookup("transcribe_clear_encoder_features"),
              let getSymbol = lookup("transcribe_get_encoder_features") else { return nil }
        let version = unsafeBitCast(versionSymbol, to: CVersion.self)
        guard version() == 1 else { return nil }
        let supported = unsafeBitCast(supportedSymbol, to: CSupported.self)
        let clear = unsafeBitCast(clearSymbol, to: CClear.self)
        let get = unsafeBitCast(getSymbol, to: CGetter.self)
        return Self(supports: { supported($0) == 1 }, clear: { clear($0) },
                    get: { get($0, $1, $2, $3, $4, $5, $6, $7) })
    }

    func copy(session: OpaquePointer, maximumBytes: Int, cancelled: () -> Bool) throws -> EncoderFeatureSnapshot {
        func requireNotCancelled() throws {
            guard !cancelled() else {
                _ = self.clear(session)
                throw TranscribeError.aborted(message: "Encoder feature snapshot cancelled", partial: nil)
            }
        }
        func read(_ metadata: inout EncoderFeatureMetadata, destination: UnsafeMutablePointer<Float>?, count: UInt64) throws {
            let code = self.get(session, &metadata.frameCount, &metadata.dimension, &metadata.sampleRate,
                                &metadata.hopSamples, &metadata.generation, destination, count)
            try TranscribeError.check(transcribe_status(rawValue: UInt32(bitPattern: code)), context: "encoder_features")
        }
        try requireNotCancelled()
        var expected = EncoderFeatureMetadata()
        try read(&expected, destination: nil, count: 0)
        let count = try expected.elementCount(maximumBytes: maximumBytes)
        var values = [Float](repeating: 0, count: count)
        var actual = EncoderFeatureMetadata()
        try values.withUnsafeMutableBufferPointer {
            try read(&actual, destination: $0.baseAddress, count: UInt64($0.count))
        }
        try requireNotCancelled()
        guard actual == expected, values.allSatisfy(\.isFinite) else {
            _ = self.clear(session)
            throw TranscribeError.invalidArgument("Encoder features changed generation or contain nonfinite values")
        }
        return EncoderFeatureSnapshot(values: values, frameCount: Int(actual.frameCount), dimension: Int(actual.dimension),
            sampleRate: Int(actual.sampleRate), frameHopSamples: Int(actual.hopSamples),
            nativeGeneration: actual.generation, recipeVersion: 1)
    }
}

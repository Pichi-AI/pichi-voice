import Darwin
import Foundation
import XCTest
@testable import TranscribeCpp

#if os(macOS)
/// Tiny synthetic libraries exercise Darwin's real dependency lookup without
/// loading a model or replacing the linked SDK. Every process and file is owned
/// by the test and joined/removed before the test returns.
final class EncoderFeatureLoaderTests: XCTestCase {
    private let symbols = [
        "transcribe_encoder_features_api_version", "transcribe_encoder_features_supported",
        "transcribe_clear_encoder_features", "transcribe_get_encoder_features",
    ]
    private let definitions = [
        "uint32_t transcribe_encoder_features_api_version(void) { return 1; }",
        "int32_t transcribe_encoder_features_supported(const void *p) { return 1; }",
        "int32_t transcribe_clear_encoder_features(void *p) { return 0; }",
        "int32_t transcribe_get_encoder_features(const void *p, uint32_t *f, uint32_t *d, uint32_t *r, uint32_t *h, uint64_t *g, float *out, uint64_t cap) { return 0; }",
    ]

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("encoder-loader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("Could not remove owned loader fixture: \(error)") }
        }
        try body(root)
    }

    private func library(_ name: String, source: String, directory: URL, dependency: URL? = nil) throws -> URL {
        let input = directory.appendingPathComponent(name + ".c")
        let output = directory.appendingPathComponent("lib" + name + ".dylib")
        try source.write(to: input, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["clang", "-dynamiclib", input.path, "-o", output.path,
            "-Wl,-install_name," + output.path]
        if let dependency { process.arguments?.append(dependency.path) }
        let diagnostics = Pipe()
        process.standardOutput = diagnostics
        process.standardError = diagnostics
        try process.run()
        let data = diagnostics.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "EncoderFeatureLoaderTests", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
        }
        return output
    }

    private func withImage(_ url: URL, _ body: (UnsafeMutableRawPointer, UnsafeRawPointer) throws -> Void) throws {
        guard let image = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
            throw NSError(domain: "EncoderFeatureLoaderTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: dlerror().map { String(cString: $0) } ?? "dlopen failed"])
        }
        defer { dlclose(image) }
        let run = try XCTUnwrap(dlsym(image, "transcribe_run"))
        try body(image, UnsafeRawPointer(run))
    }

    func testLegacyOwnerRejectsFeaturesFoundInDependency() throws {
        try withDirectory { root in
            let foreign = try library("foreign", source: "#include <stdint.h>\nint foreign_anchor(void) { return 1; }\n" + definitions.joined(separator: "\n"), directory: root)
            let owner = try library("owner", source: "extern int foreign_anchor(void); int transcribe_run(void) { return foreign_anchor(); }", directory: root, dependency: foreign)
            try withImage(owner) { image, address in
                // Reproduce the unsafe prior lookup: all four symbols can be
                // resolved from a legacy owner's dependency on Darwin.
                for symbol in symbols { XCTAssertNotNil(dlsym(image, symbol)) }
                XCTAssertNotNil(NativeEncoderFeatureAPI.resolve { dlsym(image, $0) })
                XCTAssertNil(NativeEncoderFeatureAPI.resolve(ownerAddress: address))
            }
        }
    }

    func testSameImageFeatureProviderIsAccepted() throws {
        try withDirectory { root in
            let owner = try library("same", source: "#include <stdint.h>\nint transcribe_run(void) { return 0; }\n" + definitions.joined(separator: "\n"), directory: root)
            try withImage(owner) { _, address in
                let api = try XCTUnwrap(NativeEncoderFeatureAPI.resolve(ownerAddress: address))
                XCTAssertTrue(api.supports(OpaquePointer(bitPattern: 1)!))
            }
        }
    }

    func testEveryMissingOwnSymbolRejectsDependencyFallback() throws {
        try withDirectory { root in
            let foreign = try library("fallback", source: "#include <stdint.h>\nint foreign_anchor(void) { return 1; }\n" + definitions.joined(separator: "\n"), directory: root)
            for missing in definitions.indices {
                let ownDefinitions = definitions.enumerated().filter { $0.offset != missing }.map(\.element)
                let owner = try library("partial\(missing)", source: "#include <stdint.h>\nextern int foreign_anchor(void); int transcribe_run(void) { return foreign_anchor(); }\n" + ownDefinitions.joined(separator: "\n"), directory: root, dependency: foreign)
                try withImage(owner) { image, address in
                    XCTAssertNotNil(NativeEncoderFeatureAPI.resolve { dlsym(image, $0) }, symbols[missing])
                    XCTAssertNil(NativeEncoderFeatureAPI.resolve(ownerAddress: address), symbols[missing])
                }
            }
        }
    }
}
#endif

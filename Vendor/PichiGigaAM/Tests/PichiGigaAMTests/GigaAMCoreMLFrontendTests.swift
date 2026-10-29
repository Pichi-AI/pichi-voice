import Foundation
import XCTest
@testable import PichiGigaAM

final class GigaAMCoreMLFrontendTests: XCTestCase {
    func testPublishedTablesUseBinMajorLayoutWithoutRegeneratingWeights() throws {
        let root = try self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var window = [Float](repeating: 0, count: 320)
        window[0] = 1
        var filters = [Float](repeating: 0, count: 64 * 161)
        for mel in 0..<64 { filters[mel * 64 + mel] = Float(mel + 1) / 67 }
        try self.write(window, to: root.appendingPathComponent("window.f32"))
        try self.write(filters, to: root.appendingPathComponent("filters.f32"))
        let frontend = try GigaAMFrontend(windowURL: root.appendingPathComponent("window.f32"),
                                         melFilterbankURL: root.appendingPathComponent("filters.f32"))
        var samples = [Float](repeating: 0, count: 320)
        samples[0] = 2
        let output = frontend.features(samples)
        XCTAssertEqual(output.frameCount, 1)
        for mel in 0..<64 {
            XCTAssertEqual(output.values[mel], log(4 * Float(mel + 1) / 67), accuracy: 0.00001)
        }
    }

    func testTablesRejectIncompletePairTruncationAndNonfiniteValues() throws {
        let root = try self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let window = root.appendingPathComponent("window.f32")
        let filters = root.appendingPathComponent("filters.f32")
        try self.write([Float](repeating: 1, count: 320), to: window)
        try self.write([Float](repeating: 0, count: 64 * 161), to: filters)
        XCTAssertThrowsError(try GigaAMFrontend(windowURL: window))
        XCTAssertThrowsError(try GigaAMFrontend(melFilterbankURL: filters))
        try self.write([Float](repeating: 1, count: 319), to: window)
        XCTAssertThrowsError(try GigaAMFrontend(windowURL: window, melFilterbankURL: filters))
        var invalid = [Float](repeating: 1, count: 320)
        invalid[3] = .nan
        try self.write(invalid, to: window)
        XCTAssertThrowsError(try GigaAMFrontend(windowURL: window, melFilterbankURL: filters))
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gigaam-tables-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ values: [Float], to url: URL) throws {
        var data = Data()
        for value in values {
            var bits = value.bitPattern.littleEndian
            data.append(Data(bytes: &bits, count: MemoryLayout<UInt32>.size))
        }
        try data.write(to: url)
    }
}

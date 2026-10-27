import Darwin
import Foundation

@main struct FluidServeProfileBoundaryTests {
    static func main() throws {
        let manager = FileManager.default
        guard let physical = realpath(manager.temporaryDirectory.path, nil) else { throw CocoaError(.fileReadUnknown) }
        defer { free(physical) }
        let temporary = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent("synthetic-helper-profile-" + UUID().uuidString)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("Meetings")
        let profiles = temporary.appendingPathComponent("Profiles")
        let marker = profiles.appendingPathComponent("active-profile-v1.json")
        var checks = 0
        func require(_ condition: @autoclosure () throws -> Bool, _ code: String) throws {
            checks += 1
            if try !condition() { throw NSError(domain: code, code: 1) }
        }
        func deny(_ code: String) throws {
            checks += 1
            do { _ = try FluidServeMeetings.guestAccessToken(root: root); throw NSError(domain: code, code: 1) }
            catch is FluidServeFileBoundary.Rejection {}
            catch is FluidServeMeetings.ReadError {}
        }
        func data(_ id: String = "guest", readable: Bool = true, version: Int = 1) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["schemaVersion": version, "profileID": id,
                "isReadable": readable, "generation": UUID().uuidString])
        }
        try require(try FluidServeMeetings.guestAccessToken(root: root).isEmpty, "legacy-absence")
        try manager.createDirectory(at: profiles, withIntermediateDirectories: true)
        try require(try FluidServeMeetings.guestAccessToken(root: root).isEmpty, "missing-marker")
        let original = try data()
        try original.write(to: marker)
        try require(try FluidServeMeetings.guestAccessToken(root: root) == original, "readable-guest")
        for (name, bytes) in [("hidden", try data(readable: false)), ("account", try data("account-digest")),
                              ("unknown-schema", try data(version: 2)), ("malformed", Data("{".utf8)),
                              ("missing-generation", Data("{\"schemaVersion\":1,\"profileID\":\"guest\",\"isReadable\":true}".utf8)),
                              ("oversized", Data(repeating: 32, count: 4_097))] {
            try bytes.write(to: marker)
            try deny(name)
            checks += 1
            do { _ = try FluidServeMeetings.checkedEntries(root: root); throw NSError(domain: name + "-direct-reader", code: 1) }
            catch is FluidServeFileBoundary.Rejection {}
            catch is FluidServeMeetings.ReadError {}
        }
        try manager.removeItem(at: marker)
        let foreign = temporary.appendingPathComponent("foreign-marker")
        try original.write(to: foreign)
        try manager.createSymbolicLink(at: marker, withDestinationURL: foreign)
        try deny("symlink")
        try manager.removeItem(at: marker)
        try manager.linkItem(at: foreign, to: marker)
        try deny("hardlink")
        try manager.removeItem(at: marker)
        try require(mkfifo(marker.path, 0o600) == 0, "fifo-created")
        try deny("fifo-nonblocking")
        try manager.removeItem(at: marker)
        let replacement = try data()
        try replacement.write(to: marker)
        try require(try FluidServeMeetings.guestAccessToken(root: root) != original, "generation-invalidates-result")
        try manager.removeItem(at: marker)
        try manager.removeItem(at: profiles)
        try manager.createSymbolicLink(at: profiles, withDestinationURL: temporary)
        try deny("profiles-symlink")
        print("FluidServe profile boundary: \(checks) synthetic absence/marker/unsafe-file/admission checks passed")
    }
}

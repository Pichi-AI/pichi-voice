import Darwin
import Foundation

@main
struct FluidServeSkillContainmentTests {
    static func main() throws {
        let manager = FileManager.default
        guard let physical = realpath(manager.temporaryDirectory.path, nil) else { fatalError("Missing fixture parent") }
        defer { free(physical) }
        let base = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("pichi-skill-fixture-" + UUID().uuidString)
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        let agent = FluidServeSkillInstaller.Agent.codex
        let tool = "/synthetic/fixture/fv-serve"
        var checks = 0
        func check(_ value: Bool, _ reason: String) { precondition(value, reason); checks += 1 }
        func home(_ name: String) throws -> URL {
            let url = base.appendingPathComponent(name)
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func refuses(_ home: URL) {
            check(FluidServeSkillInstaller.status(for: agent, toolPath: tool, home: home) == .foreign, "Unsafe target must be foreign")
            do { try FluidServeSkillInstaller.install(for: agent, toolPath: tool, home: home); preconditionFailure("Install overwrote an unsafe target") } catch { checks += 1 }
            do { try FluidServeSkillInstaller.remove(for: agent, home: home); preconditionFailure("Remove changed an unsafe target") } catch { checks += 1 }
        }
        let valid = try home("valid")
        try manager.createDirectory(at: valid.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try FluidServeSkillInstaller.install(for: agent, toolPath: tool, home: valid)
        let validFile = FluidServeSkillInstaller.skillFile(for: agent, home: valid)
        check(FluidServeSkillInstaller.status(for: agent, toolPath: tool, home: valid) == .installed, "Valid installation remains available")
        let first = try Data(contentsOf: validFile)
        try FluidServeSkillInstaller.install(for: agent, toolPath: tool + "-moved", home: valid)
        check(FluidServeSkillInstaller.status(for: agent, toolPath: tool + "-moved", home: valid) == .installed, "Owned update remains available")
        check(try Data(contentsOf: validFile) != first, "Update writes the new canonical instruction document")
        try FluidServeSkillInstaller.remove(for: agent, home: valid)
        check(!manager.fileExists(atPath: validFile.deletingLastPathComponent().path), "Owned removal cleans its empty skill folder")
        try FluidServeSkillInstaller.remove(for: agent, home: valid)
        checks += 1

        let foreign = base.appendingPathComponent("foreign")
        try manager.createDirectory(at: foreign, withIntermediateDirectories: true)
        let foreignFile = foreign.appendingPathComponent("SKILL.md")
        let foreignBytes = Data(FluidServeSkillInstaller.skillDocument(toolPath: "/foreign/fv-serve").utf8)
        try foreignBytes.write(to: foreignFile)
        for (name, destination) in [("dangling-leaf", foreign.appendingPathComponent("missing.md")), ("symlink-leaf", foreignFile)] {
            let root = try home(name)
            let file = FluidServeSkillInstaller.skillFile(for: agent, home: root)
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.createSymbolicLink(at: file, withDestinationURL: destination)
            refuses(root)
            check(try manager.destinationOfSymbolicLink(atPath: file.path) == destination.path, "Foreign symlink is preserved")
            check(try Data(contentsOf: foreignFile) == foreignBytes, "Foreign bytes are untouched")
        }
        for (name, components) in [("agent-dir", [String]()), ("skills-dir", [".codex"]), ("skill-dir", [".codex", "skills"])] {
            let root = try home(name)
            var parent = root
            for component in components { parent.appendPathComponent(component) }
            try manager.createDirectory(at: parent, withIntermediateDirectories: true)
            let leaf = components.isEmpty ? ".codex" : (components.count == 1 ? "skills" : "fluidmeet")
            let link = parent.appendingPathComponent(leaf)
            try manager.createSymbolicLink(at: link, withDestinationURL: foreign)
            refuses(root)
            check(try manager.destinationOfSymbolicLink(atPath: link.path) == foreign.path, "Redirected directory is preserved")
            check(try Data(contentsOf: foreignFile) == foreignBytes, "Redirected foreign directory is never written")
        }
        for name in ["directory-leaf", "fifo-leaf", "hardlink-leaf", "nonutf8-leaf", "oversized-leaf"] {
            let root = try home(name)
            let file = FluidServeSkillInstaller.skillFile(for: agent, home: root)
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch name {
            case "directory-leaf": try manager.createDirectory(at: file, withIntermediateDirectories: true)
            case "fifo-leaf": check(mkfifo(file.path, 0o600) == 0, "Synthetic FIFO was created")
            case "hardlink-leaf": try manager.linkItem(at: foreignFile, to: file)
            case "nonutf8-leaf": try Data([0xff, 0xfe]).write(to: file)
            default: try Data(repeating: 0x61, count: 64 * 1024 + 1).write(to: file)
            }
            var before = stat(); check(lstat(file.path, &before) == 0, "Fixture metadata exists")
            refuses(root)
            var after = stat(); check(lstat(file.path, &after) == 0 && before.st_ino == after.st_ino && before.st_mode == after.st_mode && before.st_size == after.st_size, "Nonregular/foreign target identity is preserved")
        }
        check(try Data(contentsOf: foreignFile) == foreignBytes, "All operations preserve the foreign document")
        print("FluidServe skill containment tests: \(checks) checks passed")
    }
}

import Darwin
import Foundation

/// Adds or removes the `fluidmeet` skill that tells Claude Code and Codex how to call `fv-serve`.
/// It only ever touches the one file it wrote: a skill of the same name from somewhere else is left alone.
nonisolated enum FluidServeSkillInstaller {
    static let skillName = FluidServeSkill.name
    static var marker: String { FluidServeSkill.marker(ownerBundleIdentifier: AppBrand.bundleIdentifier) }

    enum Agent: String, CaseIterable, Identifiable, Sendable {
        case claudeCode
        case codex

        var id: String { self.rawValue }

        var displayName: String {
            switch self {
            case .claudeCode: return "Claude Code"
            case .codex: return "Codex"
            }
        }

        /// Both tools keep personal skills in `<home folder>/skills/<name>/SKILL.md`.
        var homeFolderName: String {
            switch self {
            case .claudeCode: return ".claude"
            case .codex: return ".codex"
            }
        }
    }

    enum Status: Equatable, Sendable {
        /// The tool has never been set up on this Mac.
        case agentNotFound
        case notInstalled
        case installed
        /// Ours, but written by an older build or for an app that has since moved.
        case needsUpdate
        /// A `fluidmeet` skill that FluidVoice did not write.
        case foreign
    }

    enum InstallError: LocalizedError, Equatable {
        case foreignSkill(String)
        case toolMissing

        var errorDescription: String? {
            switch self {
            case let .foreignSkill(path):
                return AppBrand.format("A different %@ skill is already at %@. FluidVoice left it untouched.", FluidServeSkillInstaller.skillName, path)
            case .toolMissing:
                return AppBrand.format("This build of FluidVoice does not include %@.", FluidServeMeetings.toolName)
            }
        }
    }

    /// What a new chat is started with: enough for the agent to pick the skill, and nothing is sent until the user does.
    static let starterPrompt = "Use the \(skillName) skill to list my recent meetings."

    /// A link that opens a new Codex chat with `prompt` typed in but not sent.
    /// The Codex app handles `codex://threads/new`; `mode=codex` picks the agent that reads local skills.
    static func codexNewChatURL(prompt: String = starterPrompt) -> URL? {
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/new"
        components.queryItems = [URLQueryItem(name: "prompt", value: prompt), URLQueryItem(name: "mode", value: "codex")]
        return components.url
    }

    /// The command inside this copy of the app, or nil for a build that does not ship it.
    static func bundledToolURL(bundle: Bundle = .main, fileManager: FileManager = .default) -> URL? {
        let url = bundle.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(FluidServeMeetings.toolName, isDirectory: false)
        return fileManager.isExecutableFile(atPath: url.path) ? url : nil
    }

    static func skillFile(for agent: Agent, home: URL) -> URL {
        home.appendingPathComponent(agent.homeFolderName, isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(self.skillName, isDirectory: true)
            .appendingPathComponent("SKILL.md", isDirectory: false)
    }

    private static let maximumSkillBytes = 64 * 1024

    private static func directory(for agent: Agent, home: URL, create: Bool = false) throws -> FluidServeFileBoundary.Directory {
        let root = try FluidServeFileBoundary.Directory.open(home)
        let agentHome = try root.child(agent.homeFolderName, create: create)
        let skills = try agentHome.child("skills", create: create)
        return try skills.child(self.skillName, create: create)
    }

    static func status(for agent: Agent, toolPath: String, home: URL, fileManager: FileManager = .default) -> Status {
        do {
            let root = try FluidServeFileBoundary.Directory.open(home)
            do { _ = try root.child(agent.homeFolderName) }
            catch FluidServeFileBoundary.Rejection.missing { return .agentNotFound }
            let directory: FluidServeFileBoundary.Directory
            do { directory = try self.directory(for: agent, home: home) }
            catch FluidServeFileBoundary.Rejection.missing { return .notInstalled }
            guard let file = try directory.read("SKILL.md", maximumBytes: self.maximumSkillBytes) else { return .notInstalled }
            let existing = String(data: file.data, encoding: .utf8) ?? ""
            guard FluidServeSkill.isOurs(existing, ownerBundleIdentifier: AppBrand.bundleIdentifier) else { return .foreign }
            return existing == self.skillDocument(toolPath: toolPath) ? .installed : .needsUpdate
        } catch FluidServeFileBoundary.Rejection.missing { return .agentNotFound }
        catch { return .foreign }
    }

    static func install(for agent: Agent, toolPath: String, home: URL, fileManager: FileManager = .default) throws {
        let file = self.skillFile(for: agent, home: home)
        do {
            let directory = try self.directory(for: agent, home: home, create: true)
            let opened = try directory.read("SKILL.md", maximumBytes: self.maximumSkillBytes)
            if let opened, !FluidServeSkill.isOurs(String(data: opened.data, encoding: .utf8) ?? "", ownerBundleIdentifier: AppBrand.bundleIdentifier) {
                throw InstallError.foreignSkill(file.path)
            }
            let bytes = Data(self.skillDocument(toolPath: toolPath).utf8)
            guard bytes.count <= self.maximumSkillBytes else { throw InstallError.foreignSkill(file.path) }
            try directory.publish(bytes, name: "SKILL.md", replacing: opened)
        } catch { throw InstallError.foreignSkill(file.path) }
    }

    static func remove(for agent: Agent, home: URL, fileManager: FileManager = .default) throws {
        let file = self.skillFile(for: agent, home: home)
        do {
            let directory: FluidServeFileBoundary.Directory
            do { directory = try self.directory(for: agent, home: home) }
            catch FluidServeFileBoundary.Rejection.missing { return }
            guard let opened = try directory.read("SKILL.md", maximumBytes: self.maximumSkillBytes) else { return }
            guard FluidServeSkill.isOurs(String(data: opened.data, encoding: .utf8) ?? "", ownerBundleIdentifier: AppBrand.bundleIdentifier),
                  directory.matches("SKILL.md", identity: opened.identity) else { throw InstallError.foreignSkill(file.path) }
            let parked = ".fluidserve-remove-" + UUID().uuidString
            guard renameatx_np(directory.descriptor, "SKILL.md", directory.descriptor, parked, UInt32(RENAME_EXCL)) == 0 else { throw InstallError.foreignSkill(file.path) }
            let retained = directory.matches(parked, identity: opened.identity)
                ? try? directory.read(parked, maximumBytes: self.maximumSkillBytes) : nil
            guard let retained, retained.identity == opened.identity, retained.data == opened.data else {
                // A raced foreign entry is preserved, never deleted. Restore it
                // only if the original name is still free.
                _ = renameatx_np(directory.descriptor, parked, directory.descriptor, "SKILL.md", UInt32(RENAME_EXCL))
                throw InstallError.foreignSkill(file.path)
            }
            guard unlinkat(directory.descriptor, parked, 0) == 0 else { throw InstallError.foreignSkill(file.path) }
            if (try? directory.names(maximumEntries: 1).isEmpty) == true {
                let root = try FluidServeFileBoundary.Directory.open(home)
                let skills = try root.child(agent.homeFolderName).child("skills")
                let current = try skills.child(self.skillName)
                if current.identity == directory.identity { _ = unlinkat(skills.descriptor, self.skillName, AT_REMOVEDIR) }
            }
        } catch { throw InstallError.foreignSkill(file.path) }
    }

    static func skillDocument(toolPath: String, ownerBundleIdentifier: String = AppBrand.bundleIdentifier, appName: String = AppBrand.appName) -> String {
        FluidServeSkill.document(toolPath: toolPath, ownerBundleIdentifier: ownerBundleIdentifier, appName: appName)
    }
}

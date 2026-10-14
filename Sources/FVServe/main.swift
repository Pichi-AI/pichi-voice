import Foundation

// `fv-serve` ships inside FluidVoice.app/Contents/Helpers. It answers one question and exits:
// no server, no model, no audio. The switch that allows it lives in the app's own preferences.

/// Where this program really is, asked of the loader. Not `argv[0]`, which is just "fv-serve" when
/// it is found through PATH, and not `Bundle.main`, which an environment variable can redirect:
/// either would let the caller choose which app's switch is read.
func realExecutableURL() -> URL {
    var size = UInt32(0)
    _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buffer, &size) == 0 else { return URL(fileURLWithPath: "/") }
    return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
}

let executable = realExecutableURL()

/// The bundle identifier of the app this copy shipped in, so Debug and release builds each read their own switch.
func enclosingAppBundleIdentifier() -> String? {
    let infoPlist = executable.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Info.plist", isDirectory: false)
    if let info = NSDictionary(contentsOf: infoPlist), let identifier = info["CFBundleIdentifier"] as? String,
       !identifier.isEmpty, identifier != ".", identifier != "..",
       identifier.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) }) {
        return identifier
    }
    return nil
}

guard let bundleIdentifier = enclosingAppBundleIdentifier() else {
    FileHandle.standardError.write(Data("This meeting command must run from its enclosing application bundle.\n".utf8))
    exit(2)
}
let result = FluidServeCommand.run(
    arguments: Array(CommandLine.arguments.dropFirst()),
    root: FluidServeMeetings.defaultRoot(storageNamespace: bundleIdentifier),
    accessEnabled: FluidServeMeetings.isAccessEnabled(bundleIdentifier: bundleIdentifier),
    toolPath: executable.path,
    ownerBundleIdentifier: bundleIdentifier,
    appName: (NSDictionary(contentsOf: executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist"))?["CFBundleDisplayName"] as? String) ?? "Voice app",
    customPrompt: FluidServeMeetings.customSummaryPrompt(bundleIdentifier: bundleIdentifier)
)
let stream = result.exitCode == 0 ? FileHandle.standardOutput : FileHandle.standardError
stream.write(Data((result.output + "\n").utf8))
exit(result.exitCode)

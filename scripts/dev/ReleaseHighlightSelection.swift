import Foundation

/// Inspect the same offline definition the signed Mac app selects for this version.
@main
enum ReleaseHighlightSelection {
    static func main() throws {
        let content = ReleaseHighlightsContent.current(version: CommandLine.arguments[1])
        let data = try JSONEncoder().encode(content.features.map(\.id))
        FileHandle.standardOutput.write(data)
    }
}

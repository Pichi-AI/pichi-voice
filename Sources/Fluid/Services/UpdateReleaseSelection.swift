import Foundation

/// The approved tag and artifact travel together through discovery, download and install.
/// Pichi's public tag suffix is publication provenance, not a semantic prerelease.
nonisolated struct UpdateReleaseSelection: Equatable, Sendable {
    static let diskImageName = "Pichi-Voice.dmg"
    let tag: String
    let version: String
    let build: String?
    let assetName: String
    let assetURL: URL
    let digest: String?

    var displayVersion: String { build.map { "\(version) (\($0))" } ?? version }

    static func pichiVersion(_ tag: String) -> (version: String, build: String)? {
        guard tag.range(of: #"^v[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+-(public|beta)\.[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        let parts = tag.dropFirst().split(separator: "+")
        let build = String(parts[1].split(separator: "-")[0])
        guard Int(build) != nil, parts[0].split(separator: ".").allSatisfy({ Int($0) != nil }) else { return nil }
        return (String(parts[0]), build)
    }

    static func pichi(_ release: GHRelease, owner: String, repo: String) -> Self? {
        guard !release.draft, let identity = pichiVersion(release.tag_name) else { return nil }
        // New releases use the product name only. The immutable tag and sealed
        // bundle metadata bind version/build; old published assets stay compatible.
        let legacyName = "Pichi-Voice-\(identity.version)-\(identity.build)-macos-arm64.dmg"
        let name = release.assets.contains { $0.name == self.diskImageName } ? self.diskImageName : legacyName
        let expected = URL(string: "https://github.com/\(owner)/\(repo)/releases/download/\(release.tag_name)/\(name)")
        let matches = release.assets.filter { asset in
            guard let expected else { return false }
            let url = asset.browser_download_url
            return asset.name == name && url.scheme == "https" && url.host == "github.com"
                && url.user == nil && url.password == nil && url.port == nil
                && url.query == nil && url.fragment == nil && url.pathComponents == expected.pathComponents
        }
        guard matches.count == 1, let asset = matches.first,
              asset.size.map({ $0 > 0 && $0 <= UpdateDownload.maximumBytes }) ?? true else { return nil }
        return Self(tag: release.tag_name, version: identity.version, build: identity.build,
                    assetName: asset.name, assetURL: asset.browser_download_url, digest: asset.digest)
    }

    static func isOlder(version: String, build: String?, than currentVersion: String, build currentBuild: String?) -> Bool {
        let order = version.compare(currentVersion, options: .numeric)
        if order != .orderedSame { return order == .orderedAscending }
        guard let build, let currentBuild else { return false }
        return build.compare(currentBuild, options: .numeric) == .orderedAscending
    }
}

import SwiftUI

struct ChangelogView: View {
    @Environment(\.theme) private var theme
    @Environment(\.locale) private var interfaceLocale

    @State private var releases: [SimpleUpdater.ReleaseNote] = []
    @State private var isRefreshing = false
    @State private var errorMessage: String?

    private let owner = AppBrand.repositoryOwner
    private let repo = AppBrand.repositoryName
    private let releaseLimit = 3

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
                    if let errorMessage {
                        Label(PichiLocalization.text(errorMessage), systemImage: "wifi.exclamationmark")
                            .font(self.theme.typography.caption)
                            .foregroundStyle(self.theme.palette.warning)
                    }

                    if self.releases.isEmpty, self.isRefreshing {
                        self.loadingCard
                    } else if self.releases.isEmpty {
                        self.emptyCard
                    } else {
                        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                            ForEach(Array(self.releases.enumerated()), id: \.element) { index, release in
                                ChangelogReleaseCard(
                                    release: release,
                                    isLatest: index == 0,
                                    theme: self.theme,
                                    scrollTo: { proxy.scrollTo($0, anchor: .top) }
                                )
                            }
                        }
                    }

                    self.footer
                }
                .fluidPageContent(width: .reading)
            }
        }
        .fluidPageActions {
            Button {
                Task { await self.refreshReleases(force: true) }
            } label: {
                ZStack {
                    Image(systemName: "arrow.clockwise")
                        .fluidToolbarIcon()
                        .opacity(self.isRefreshing ? 0 : 1)
                    if self.isRefreshing { ProgressView().controlSize(.small) }
                }
                .frame(width: 22, height: 22)
            }
            .disabled(self.isRefreshing)
            .help(PichiLocalization.text("Refresh changelog"))
            .accessibilityLabel(PichiLocalization.text("Refresh changelog"))
        }
        .task {
            self.loadCachedReleases()
            await self.refreshReleases()
        }
    }

    private var loadingCard: some View {
        ThemedCard(style: .standard, hoverEffect: false) {
            HStack(spacing: self.theme.metrics.spacing.md) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading release notes...")
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
        }
    }

    private var emptyCard: some View {
        ThemedCard(style: .standard, hoverEffect: false) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                Text("No changelog available")
                    .font(self.theme.typography.sectionTitle)
                    .foregroundStyle(self.theme.palette.primaryText)
                Text(AppBrand.text("FluidVoice could not load GitHub release notes right now."))
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let url = URL(string: "https://github.com/\(self.owner)/\(self.repo)/releases") {
                Link(destination: url) {
                    Label("View older release notes on GitHub", systemImage: "arrow.up.right.square")
                        .font(self.theme.typography.bodySmallStrong)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                }
                .fluidButton(.glass, size: .medium)
                .buttonHoverEffect()
            }

            Spacer()
        }
    }

    private func loadCachedReleases() {
        let cacheKey = self.cacheKey
        guard
            let data = UserDefaults.standard.data(forKey: cacheKey),
            let cache = try? JSONDecoder().decode(ChangelogCache.self, from: data)
        else { return }

        self.releases = Array(cache.releases.prefix(self.releaseLimit))
    }

    private func refreshReleases(force _: Bool = false) async {
        guard !self.isRefreshing else { return }

        self.isRefreshing = true
        self.errorMessage = nil

        do {
            let includePrerelease = SettingsStore.shared.betaReleasesEnabled
            let fetched = try await SimpleUpdater.shared.fetchRecentReleaseNotes(
                owner: self.owner,
                repo: self.repo,
                limit: self.releaseLimit,
                includePrerelease: includePrerelease
            )
            let limitedReleases = Array(fetched.prefix(self.releaseLimit))
            self.releases = limitedReleases
            self.saveCachedReleases(limitedReleases)
        } catch {
            if self.releases.isEmpty {
                self.errorMessage = "Unable to load release notes."
            } else {
                self.errorMessage = "Showing saved release notes. Refresh failed."
            }
        }

        self.isRefreshing = false
    }

    private func saveCachedReleases(_ releases: [SimpleUpdater.ReleaseNote]) {
        let cache = ChangelogCache(releases: releases, savedAt: Date())
        guard let data = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: self.cacheKey)
    }

    private var cacheKey: String {
        let channel = SettingsStore.shared.betaReleasesEnabled ? "beta" : "stable"
        return "FluidVoiceChangelogCache.\(channel)"
    }
}

private struct ChangelogCache: Codable {
    let releases: [SimpleUpdater.ReleaseNote]
    let savedAt: Date
}

struct ChangelogReleaseCard: View {
    @Environment(\.locale) private var interfaceLocale
    let release: SimpleUpdater.ReleaseNote
    let isLatest: Bool
    let theme: AppTheme
    let scrollTo: (Position) -> Void

    struct Position: Hashable {
        let release: SimpleUpdater.ReleaseNote
        let index: Int
    }

    var body: some View {
        ThemedCard(style: self.isLatest ? .prominent : .standard, hoverEffect: false) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                HStack(alignment: .firstTextBaseline, spacing: self.theme.metrics.spacing.sm) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: self.theme.metrics.spacing.sm) {
                            Text(self.release.title)
                                .font(self.theme.typography.sectionTitle)
                                .foregroundStyle(self.theme.palette.primaryText)
                                .lineLimit(2)

                            if self.isLatest {
                                Text("Latest")
                                    .font(self.theme.typography.badge)
                                    .foregroundStyle(self.theme.palette.accentText)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule()
                                            .fill(self.theme.palette.elevatedCardBackground)
                                    )
                            }

                            if self.release.isPrerelease {
                                Text("Beta")
                                    .font(self.theme.typography.badge)
                                    .foregroundStyle(self.theme.palette.warning)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule()
                                            .fill(self.theme.palette.elevatedCardBackground)
                                    )
                            }
                        }

                        Text(self.metadataText)
                            .font(self.theme.typography.caption)
                            .foregroundStyle(self.theme.palette.tertiaryText)
                    }

                    Spacer()

                    if let url = self.release.url {
                        Link(destination: url) {
                            Image(systemName: "arrow.up.right")
                                .font(self.theme.typography.captionStrong)
                                .padding(7)
                        }
                        .buttonStyle(.borderless)
                        .help(PichiLocalization.text("Open this release on GitHub"))
                    }
                }

                let blocks = self.noteBlocks
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                        ChangelogNoteBlock(block: block, theme: self.theme)
                            .id(Position(release: self.release, index: index))
                    }
                }
                .environment(\.openURL, OpenURLAction { self.openLink($0, in: blocks) })
            }
        }
    }

    private var metadataText: String {
        if let publishedAt = self.release.publishedAt {
            return "\(self.release.version) - \(publishedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(self.interfaceLocale)))"
        }
        return self.release.version
    }

    var noteBlocks: [ChangelogNote] {
        ChangelogNote.make(
            from: self.release.notes,
            releaseTitle: self.release.title,
            version: self.release.version
        )
    }

    func openLink(_ url: URL, in blocks: [ChangelogNote]) -> OpenURLAction.Result {
        guard url.relativeString.hasPrefix("#"), let fragment = url.fragment(percentEncoded: false) else {
            return .systemAction
        }
        if let index = blocks.firstIndex(where: { $0.anchor == fragment }) {
            self.scrollTo(Position(release: self.release, index: index))
            return .handled
        }
        guard let releaseURL = self.release.url,
              let target = URL(string: url.relativeString, relativeTo: releaseURL) else { return .discarded }
        return .systemAction(target.absoluteURL)
    }
}

private struct ChangelogNoteBlock: View {
    let block: ChangelogNote
    let theme: AppTheme

    var body: some View {
        switch self.block.kind {
        case let .heading(level):
            Text(self.block.text)
                .font(level <= 2 ? self.theme.typography.bodyStrong : self.theme.typography.bodySmallStrong)
                .foregroundStyle(self.theme.palette.primaryText)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 2)
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: self.theme.metrics.spacing.sm) {
                Circle()
                    .fill(self.theme.palette.accent.opacity(0.75))
                    .frame(width: 4, height: 4)
                Text(self.block.text)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .paragraph:
            Text(self.block.text)
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        case .divider:
            Divider().accessibilityHidden(true)
        }
    }
}

#Preview {
    ChangelogView()
        .environment(\.theme, AppTheme.dark)
}

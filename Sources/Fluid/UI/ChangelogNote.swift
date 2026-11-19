import Foundation

/// The GitHub body stays intact in the release cache. Interpret its block structure for the native card.
nonisolated struct ChangelogNote: Equatable {
    enum Kind: Equatable {
        case heading(level: Int)
        case bullet
        case paragraph
        case divider
    }

    let kind: Kind
    let text: AttributedString
    let anchor: String?

    static func make(from notes: String, releaseTitle: String, version: String) -> [Self] {
        let markdown = (try? AttributedString(markdown: notes)) ?? AttributedString(notes)
        var blocks: [Self] = []
        var pendingAnchor: String?

        for (intent, range) in markdown.runs[\.presentationIntent] {
            let block = markdown[range]
            if case .thematicBreak = intent?.components.first?.kind {
                blocks.append(Self(kind: .divider, text: AttributedString(), anchor: pendingAnchor))
                pendingAnchor = nil
                continue
            }

            var text = AttributedString()
            for run in block.runs {
                let fragment = block[run.range]
                let syntax = run.inlinePresentationIntent
                if syntax?.contains(.inlineHTML) == true {
                    if let anchor = Self.namedAnchor(in: String(fragment.characters)) { pendingAnchor = anchor }
                } else if syntax?.contains(.blockHTML) == true {
                    // A GitHub <details> block may also contain visible summary/body text.
                    if let inline = try? AttributedString(markdown: String(fragment.characters),
                                                          options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                        for part in inline.runs where part.inlinePresentationIntent?.contains(.inlineHTML) != true {
                            text.append(AttributedString(inline[part.range]))
                        }
                    }
                } else {
                    text.append(AttributedString(fragment))
                }
            }
            let plain = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !plain.isEmpty else { continue }
            let kind: Kind
            if case let .header(level) = intent?.components.first?.kind {
                if plain.localizedCaseInsensitiveContains("contributors") || plain.localizedCaseInsensitiveContains("need help") { break }
                guard plain != releaseTitle, plain != version else { continue }
                kind = .heading(level: level)
            } else {
                let isBullet = intent?.components.contains { if case .listItem = $0.kind { true } else { false } } ?? false
                kind = isBullet ? .bullet : .paragraph
            }

            guard !isBoilerplate(plain) && !text.runs.contains(where: { isBoilerplate($0.link?.absoluteString ?? "") }) else { continue }
            text.presentationIntent = nil // The SwiftUI card supplies block layout and typography.
            blocks.append(Self(kind: kind, text: text, anchor: pendingAnchor))
            pendingAnchor = nil
        }
        return blocks
    }

    private static func namedAnchor(in tag: String) -> String? {
        let match = tag.wholeMatch(of: #/<a\s+(?:name|id)\s*=\s*(?:"([^"]+)"|'([^']+)')\s*>\s*(?:</a>)?/#.ignoresCase())
        return (match?.1 ?? match?.2).map(String.init)
    }

    private static func isBoilerplate(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return lowercased.contains("report issues:") ||
            lowercased.contains("github.com/altic-dev/fluidvoice/issues") ||
            lowercased.contains("github.com/altic-dev/fluid-oss/issues")
    }
}

import ActivityKit
import Foundation

/// The single data contract between the app and its Live Activity extension, compiled into both.
/// The extension cannot read the app's interface language, imported appearance or settings, so the
/// app resolves copy, product name, accent and type design once per recording. The extension only
/// renders these values and has no String Catalog, brand package or settings of its own.
nonisolated struct MobileRecordingActivityAttributes: ActivityAttributes, Sendable {
    /// The timer anchor is the session's own start, so the system counts without app updates.
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        var startedAt: Date
    }

    /// Resolved sRGB components, so the extension never parses brand data.
    nonisolated struct Swatch: Codable, Hashable, Sendable {
        var red: Double
        var green: Double
        var blue: Double
    }

    /// The shared typography's system design choice for one text role.
    nonisolated enum TypeDesign: String, Codable, Hashable, Sendable {
        case standard
        case serif
        case rounded
    }

    var sessionID: UUID
    var productName: String
    var recordingLabel: String
    var meetingKind: String
    var accentLight: Swatch
    var accentDark: Swatch
    /// A packaged distribution asset that the extension also compiles. Nil for imported appearance,
    /// whose logo data stays inside the app.
    var markAsset: String?
    var titleDesign: TypeDesign
    var bodyDesign: TypeDesign
}

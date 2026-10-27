import SwiftUI
import TipKit

/// One native hint under Start Recording after the first setup. Onboarding arms it when a first
/// setup finishes; a replayed setup and launches that restore a completed setup never show it.
struct FirstMeetingTip: Tip {
    @Parameter static var setupFinished: Bool = false

    var title: Text { Text(PichiLocalization.text("Start your first meeting")) }
    var message: Text? { Text(PichiLocalization.text("Record a meeting and return to its transcript.")) }
    var image: Image? { Image(systemName: "waveform") }
    var rules: [Rule] { [#Rule(Self.$setupFinished) { $0 }] }

    /// TipKit accepts one configuration per process, made at launch before onboarding can arm the tip.
    static func configure() {
        guard !isConfigured else { return }
        isConfigured = true
        #if DEBUG
        // Native screenshot review only; a distributed Release app cannot select it. Each review starts
        // a fresh store of its own, so the armed tip never reaches the app's data or later test runs.
        if ProcessInfo.processInfo.arguments.contains("-PichiShowTipsForReview") {
            let store = FileManager.default.temporaryDirectory.appending(path: "TipKitReview", directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: store)
            try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
            try? Tips.configure([.displayFrequency(.immediate), .datastoreLocation(.url(store))])
            setupFinished = true
            return
        }
        #endif
        try? Tips.configure([.displayFrequency(.immediate)])
    }
    private static var isConfigured = false
}

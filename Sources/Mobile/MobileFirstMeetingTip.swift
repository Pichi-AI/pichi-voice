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
        try? Tips.configure([.displayFrequency(.immediate)])
        #if DEBUG
        // Native screenshot review only; a distributed Release app cannot select it.
        if ProcessInfo.processInfo.arguments.contains("-PichiShowTipsForReview") { setupFinished = true }
        #endif
    }
    private static var isConfigured = false
}

import SwiftUI
import TipKit

/// One native hint under Start Recording after the first setup. Onboarding arms it when a first
/// setup finishes; a replayed setup and launches that restore a completed setup never show it.
struct FirstMeetingTip: Tip {
    @Parameter static var setupFinished: Bool = false

    var title: Text { Text(PichiLocalization.text("Start your first meeting")) }
    var message: Text? { Text(PichiLocalization.text("The transcript and participants appear as people speak.")) }
    var image: Image? { Image(systemName: "waveform") }
    var rules: [Rule] { [#Rule(Self.$setupFinished) { $0 }] }

    /// TipKit accepts one configuration per process, made at launch before onboarding can arm the tip.
    static func configure() {
        guard !isConfigured else { return }
        isConfigured = true
        var options: [Tips.ConfigurationOption] = [.displayFrequency(.immediate)]
        #if DEBUG
        // Native screenshot review only; a distributed Release app cannot select it. The review keeps
        // its own throwaway store, so the armed tip never leaks into the app's data or later test runs.
        let isReview = ProcessInfo.processInfo.arguments.contains("-PichiShowTipsForReview")
        if isReview {
            let store = FileManager.default.temporaryDirectory.appending(path: "TipKitReview", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
            options.append(.datastoreLocation(.url(store)))
        }
        #endif
        try? Tips.configure(options)
        #if DEBUG
        if isReview { setupFinished = true }
        #endif
    }
    private static var isConfigured = false
}

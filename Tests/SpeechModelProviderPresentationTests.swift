import SwiftUI

// Only unrelated app dependencies are stubbed; the provider descriptor and mark resolver are real.
enum SettingsStore {
    enum SpeechModel {
        enum Provider { case saluteDevices, nvidia, apple, openai, cohere, qwen, futureProvider }
    }
}
struct FixtureTheme {
    struct Palette {
        let cardBackground = Color.gray
        let accent = Color.purple
        let primaryText = Color.black
    }
    let palette = Palette()
}
private struct FixtureThemeKey: EnvironmentKey { static let defaultValue = FixtureTheme() }
extension EnvironmentValues {
    var theme: FixtureTheme {
        get { self[FixtureThemeKey.self] }
        set { self[FixtureThemeKey.self] = newValue }
    }
}
extension Font {
    static func fluidSystem(size: CGFloat, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
}

@main
struct SpeechModelProviderPresentationTests {
    static func main() {
        let missing = SpeechModelProviderPresentation(mark: .asset("MissingModelProviderAsset"), background: .neutral)
        var queries = 0
        precondition(missing.resolvedMark(assetAvailable: { _ in queries += 1; return false }) == .systemSymbol("waveform"))
        precondition(queries == 1)
        precondition(missing.resolvedMark(assetAvailable: { _ in true }) == .asset("MissingModelProviderAsset"))
        let publisher = SettingsStore.SpeechModel.Provider.saluteDevices.presentation
        precondition(publisher.resolvedMark(assetAvailable: { _ in fatalError("A provider without a bundled logo must not probe assets") }) == .systemSymbol("waveform"))
        let future = SettingsStore.SpeechModel.Provider.futureProvider.presentation
        precondition(future.resolvedMark(assetAvailable: { _ in fatalError("Unknown providers use the generic symbol") }) == .systemSymbol("waveform"))
        print("Missing provider assets and providers without a bundled logo have a generic mark")
    }
}

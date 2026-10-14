import SwiftUI

struct VoiceEngineSettingsView: View {
    @ObservedObject var viewModel: VoiceEngineSettingsViewModel
    @ObservedObject var settings: SettingsStore
    @Environment(\.colorScheme) var colorScheme
    @State var isShowingNemotronLanguagePicker = false
    @State var isShowingWhisperLanguagePicker = false
    @State var whisperLanguageSearchText = ""
    let theme: AppTheme

    var voiceEngineTitleText: Color {
        self.theme.palette.primaryText
    }

    var voiceEngineSecondaryText: Color {
        self.theme.palette.primaryText
    }

    var voiceEngineTertiaryText: Color {
        self.theme.palette.secondaryText
    }

    var body: some View {
        self.speechRecognitionCard
            .onAppear { self.viewModel.onAppear() }
            .onChange(of: self.settings.selectedSpeechModel) { _, newValue in
                self.viewModel.handleSelectedSpeechModelChange(newValue)
            }
    }
}

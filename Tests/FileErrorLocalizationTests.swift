import Foundation

// Only preference storage is inert. Localization, catalog resources, errorDescription
// and each service throw expression are production source compiled by the runner.
nonisolated final class UserDefaults: @unchecked Sendable {
    static let standard = UserDefaults()
    private var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { self.values[key] as? String }
    func set(_ value: Any?, forKey key: String) { self.values[key] = value }
}

@main @MainActor struct FileErrorLocalizationTests {
    static var checks = 0
    static func checkBytes(_ actual: String, _ expected: String, _ message: String) {
        self.checks += 1
        precondition(Array(actual.utf8) == Array(expected.utf8), message + "\nActual: " + actual + "\nExpected: " + expected)
    }

    static func main() {
        precondition(Bundle.main.localizations.contains("ru"), "Use the real compiled RU catalog")
        let opaqueDiagnostics = [
            "OSStatus -43: Е\u{0308}жик / отч\u{0308}т 100%@.wav\nProvider says %1$@, literal %% and {raw}",
            "Transcription provider not ready",
            "Could not open audio file: %@",
            "Речь пользователя: Ёжик живёт у ёлки. Не отправляй счёт 48217 на 73 рубля.",
        ]
        let englishPrefixes = [
            "modelLoadFailed": "Failed to load ASR models: ",
            "audioConversionFailed": "Failed to convert audio: ",
            "transcriptionFailed": "Transcription failed: ",
            "fileNotSupported": "File format not supported: ",
            "activityInProgress": "",
        ]
        let russianPrefixes = [
            "modelLoadFailed": "Не удалось загрузить модели распознавания речи: ",
            "audioConversionFailed": "Не удалось преобразовать аудио: ",
            "transcriptionFailed": "Не удалось распознать речь: ",
            "fileNotSupported": "Формат файла не поддерживается: ",
            "activityInProgress": "",
        ]
        for language in ["en", "ru"] {
            UserDefaults.standard.set(language, forKey: PichiInterfaceLanguage.defaultsKey)
            for count in [0] + Array(2...8) {
                let picker = FileSpeakerCountPickerCopy(settings: .init(fileTranscriptionExpectedSpeakerCount: count))
                self.checkBytes(picker.menuTitle, language == "ru" ? "Количество говорящих" : "Number of speakers",
                                "The actual Files title must localize inside the shared native picker menu")
                self.checkBytes(picker.selectedTitle, count == 0 ? (language == "ru" ? "Авто" : "Auto") : String(count),
                                "Owned Auto text localizes while selected numeric speaker counts stay unchanged")
            }
            precondition(FileSpeakerCountPickerCopy.optionTags == [0] + Array(2...8),
                         "Localizing the native menu heading must not change persisted speaker counts")
            for value in ["Number of speakers", "Output device", "100%@ Ё Voice", "Импортированный профиль"] {
                self.checkBytes(SharedPickerSelectionCopy(selectedTitle: value).label, value,
                                "Native picker selected labels remain verbatim data, including values matching owned keys")
            }
            let prefixes = language == "ru" ? russianPrefixes : englishPrefixes
            for diagnostic in opaqueDiagnostics {
                let cases: [(String, FileTranscriptionService.TranscriptionError)] = [
                    ("activityInProgress", .activityInProgress(diagnostic)),
                    ("modelLoadFailed", .modelLoadFailed(diagnostic)),
                    ("audioConversionFailed", .audioConversionFailed(diagnostic)),
                    ("transcriptionFailed", .transcriptionFailed(diagnostic)),
                    ("fileNotSupported", .fileNotSupported(diagnostic)),
                ]
                for (kind, error) in cases {
                    let expected = prefixes[kind]! + diagnostic
                    self.checkBytes(error.errorDescription ?? "", expected,
                                    "Localize only the owned prefix; diagnostics and user data must remain byte-identical")
                    self.checkBytes(error.localizedDescription, expected,
                                    "Foundation LocalizedError rendering must use production owned-copy localization")
                }

                let fileExtension = "E\u{0308}JIK%@"
                let details: [String: String] = language == "ru" ? [
                    "This file is already being transcribed.": "Этот файл уже распознаётся.",
                    "Transcription provider not ready": "Модуль распознавания речи не готов",
                    "Could not open audio file: %@": "Не удалось открыть аудиофайл: " + diagnostic,
                    "Invalid audio file: sample rate is 0": "Некорректный аудиофайл: частота дискретизации равна 0",
                    "Could not create audio buffer": "Не удалось создать аудиобуфер",
                    "Could not read audio chunk: %@": "Не удалось прочитать фрагмент аудио: " + diagnostic,
                    "Could not resample audio: %@": "Не удалось изменить частоту дискретизации аудио: " + diagnostic,
                    "Format .%@ not supported. %@": "Формат ." + fileExtension + " не поддерживается. Поддерживаются WAV, MP3, M4A, OGG, OPUS, MP4, MOV и другие форматы",
                ] : [
                    "This file is already being transcribed.": "This file is already being transcribed.",
                    "Transcription provider not ready": "Transcription provider not ready",
                    "Could not open audio file: %@": "Could not open audio file: " + diagnostic,
                    "Invalid audio file: sample rate is 0": "Invalid audio file: sample rate is 0",
                    "Could not create audio buffer": "Could not create audio buffer",
                    "Could not read audio chunk: %@": "Could not read audio chunk: " + diagnostic,
                    "Could not resample audio: %@": "Could not resample audio: " + diagnostic,
                    "Format .%@ not supported. %@": "Format ." + fileExtension + " not supported. Supported: WAV, MP3, M4A, OGG, OPUS, MP4, MOV, and more",
                ]
                for site in FileTranscriptionService.productionErrors(diagnostic: diagnostic, fileExtension: fileExtension) {
                    let detail = site.key.map { details[$0]! } ?? diagnostic
                    self.checkBytes(site.error.localizedDescription, prefixes[site.kind]! + detail,
                                    "Actual production throw expression must localize nested owned copy and preserve opaque arguments")
                }
            }
            let accepted = "Accepted file types: WAV, MP3, M4A, OGG, OPUS, MP4, MOV, and more."
            self.checkBytes(FileTranscriptionService.droppedFileError(), language == "ru"
                ? "Допустимые типы файлов: WAV, MP3, M4A, OGG, OPUS, MP4, MOV и другие."
                : accepted, "Dropped-file owned error uses the same catalog boundary")
        }
        print("File copy localization: \(self.checks) checks passed; production errors and speaker-count picker expressions, compiled RU/EN catalog and verbatim opaque data; no UI, models or real preferences")
    }
}

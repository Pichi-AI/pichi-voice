import Foundation
import Combine
import SwiftUI
#if canImport(FluidAudio)
import FluidAudio
#endif

extension SettingsStore {
    enum SpeechModel: String, CaseIterable, Identifiable, Codable {
        /// The legacy FluidAudio Qwen preview remains disabled independently of the public GGUF model.
        static let qwenPreviewEnabled = false

        // MARK: - FluidAudio Models (Apple Silicon Only)

        case parakeetTDT = "parakeet-tdt"
        case parakeetTDTv2 = "parakeet-tdt-v2"
        case fluidParakeetMini = "fluid-parakeet-mini"
        case fluidParakeetPico = "fluid-parakeet-pico"
        case fluidParakeetPro = "fluid-parakeet-pro"
        case parakeetRealtime = "parakeet-realtime"
        case qwen3Asr = "qwen3-asr"
        case cohereTranscribeSixBit = "cohere-transcribe-6bit"
        case nemotronOffline = "nemotron-3.5-offline"
        case nemotronStreaming = "nemotron-3.5-streaming"
        case nemotronStreaming320 = "nemotron-3.5-streaming-320"

        // MARK: - Russian Models

        case gigaam = "gigaam-v3-eou"

        // MARK: - Apple Native

        case appleSpeech = "apple-speech"
        case appleSpeechAnalyzer = "apple-speech-analyzer"

        // MARK: - Whisper Models (Universal)

        case whisperTiny = "whisper-tiny"
        case whisperBase = "whisper-base"
        case whisperSmall = "whisper-small"
        case whisperMedium = "whisper-medium"
        case whisperLargeTurbo = "whisper-large-turbo"
        case whisperLarge = "whisper-large"

        // MARK: - Other transcribe.cpp Models

        case qwen3Asr17B = "qwen3-asr-1.7b"

        var parakeetDescriptor: ParakeetSpeechModelCatalog.Descriptor? {
            ParakeetSpeechModelCatalog.descriptor(forModelID: self.rawValue)
        }

        var libraryMetadata: SpeechModelLibraryMetadata? {
            guard self == .gigaam else { return nil }
            return PichiGigaAMModelStore.preferredLibraryMetadata
        }

        /// Relative product ratings for display and sorting, not benchmark accuracy.
        var hasPerformanceRatings: Bool {
            if self.libraryMetadata != nil { return true }
            guard let descriptor = self.parakeetDescriptor else { return true }
            return descriptor.performanceRatings != nil
        }

        var id: String {
            rawValue
        }

        /// Installation transport is engine metadata; common screens call the same service API.
        var supportsFolderImport: Bool { self == .gigaam }

        /// A folder import remains optional when the registered engine has a pinned download.
        var supportsAutomaticDownload: Bool { self != .gigaam || PichiGigaAMModelStore.supportsDefaultDownload }
        var requiresFolderImport: Bool { self.supportsFolderImport && !self.supportsAutomaticDownload }

        /// Trusted localization template. The picker inserts the model name exactly once.
        var importFolderPrompt: String { "Choose the folder containing the %@ model files." }

        var defaultDownloadSourceName: String? { self == .gigaam ? "Hugging Face" : nil }

        var modelFolderSourceLabel: String? {
            guard self == .gigaam else { return nil }
            return PichiGigaAMModelStore.shared.usesImportedModelSource ? "Imported model folder" : "Hugging Face (default)"
        }

        var importFolderInstructions: String? {
            guard self == .gigaam else { return nil }
            return "Choose a folder, not an individual file. For the public model it must contain v3_e2e_ctc.int8.onnx and v3_e2e_ctc_vocab.txt. For the custom E2E model use v3_e2e_ctc_eou_v5.fp16.onnx and the same vocabulary file. Only supported exports with matching checksums can be imported."
        }

        // MARK: - Display Properties

        var displayName: String {
            switch self {
            case .gigaam: return "GigaAM v3"
            case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico, .fluidParakeetPro: return self.parakeetDescriptor?.displayName ?? self.rawValue
            case .parakeetRealtime: return "Parakeet Flash (Beta)"
            case .qwen3Asr: return "Qwen3 ASR (Beta)"
            case .cohereTranscribeSixBit: return "Cohere Transcribe"
            case .nemotronOffline: return "Nemotron 3.5 Multilingual"
            case .nemotronStreaming: return "Nemotron Speech 3.5 - Ultra Fast Low Latency"
            case .nemotronStreaming320: return "Nemotron Speech 3.5 - Ultra Fast Low Latency"
            case .appleSpeech: return "Apple ASR Legacy"
            case .appleSpeechAnalyzer: return "Apple Speech - macOS 26+"
            case .whisperTiny: return "Whisper Tiny"
            case .whisperBase: return "Whisper Base"
            case .whisperSmall: return "Whisper Small"
            case .whisperMedium: return "Whisper Medium"
            case .whisperLargeTurbo: return "Whisper Large Turbo"
            case .whisperLarge: return "Whisper Large"
            case .qwen3Asr17B: return "Qwen3 ASR 1.7B"
            }
        }

        var languageSupport: String {
            switch self {
            case .gigaam: return "Russian"
            case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico, .fluidParakeetPro: return self.parakeetDescriptor?.languageSupport ?? "English Only"
            case .parakeetRealtime: return "English Only (Live Streaming)"
            case .qwen3Asr, .qwen3Asr17B: return "30 Languages"
            case .cohereTranscribeSixBit: return "14 Languages (Select Manually)"
            case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320: return "Around 40 Languages"
            case .appleSpeech: return "System Languages"
            case .appleSpeechAnalyzer: return "EN, ES, FR, DE, IT, JA, KO, PT, ZH"
            case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
                return "99 Languages"
            }
        }

        var downloadSize: String {
            switch self {
            case .gigaam: return String(format: "~%.1f MiB", Double(PichiGigaAMModelStore.defaultDownloadByteCount) / 1_048_576)
            case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico, .fluidParakeetPro: return self.parakeetDescriptor?.downloadSize ?? ""
            case .parakeetRealtime: return "~428.4 MiB"
            case .qwen3Asr: return "~2.0 GiB"
            case .cohereTranscribeSixBit: return "~1.54 GiB"
            case .nemotronOffline: return "~530.8 MiB"
            case .nemotronStreaming: return "~668.2 MiB"
            case .nemotronStreaming320: return "~668.2 MiB"
            case .appleSpeech: return "Built-in"
            case .appleSpeechAnalyzer: return "Built-in"
            case .whisperTiny: return "~43.9 MiB"
            case .whisperBase: return "~81.0 MiB"
            case .whisperSmall: return "~257.3 MiB"
            case .whisperMedium: return "~793.0 MiB"
            case .whisperLargeTurbo: return "~845.3 MiB"
            case .whisperLarge: return "~1.55 GiB"
            case .qwen3Asr17B: return "~2.03 GiB"
            }
        }

        var expectedDownloadBytes: Int64 {
            switch self {
            case .gigaam: return PichiGigaAMModelStore.defaultDownloadByteCount
            case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico, .fluidParakeetPro: return self.parakeetDescriptor?.expectedDownloadBytes ?? 0
            case .parakeetRealtime: return 449_190_189
            case .qwen3Asr: return 2000 * 1024 * 1024
            case .cohereTranscribeSixBit: return 1_650_748_785
            case .nemotronOffline: return 556_552_620
            case .nemotronStreaming, .nemotronStreaming320: return 700_685_415
            case .whisperTiny: return 45_981_088
            case .whisperBase: return 84_962_880
            case .whisperSmall: return 269_751_136
            case .whisperMedium: return 831_538_144
            case .whisperLargeTurbo: return 886_381_728
            case .whisperLarge: return 1_668_741_440
            case .qwen3Asr17B: return 2_185_030_624
            case .appleSpeech, .appleSpeechAnalyzer: return 0
            }
        }

        var requiresAppleSilicon: Bool {
            switch self {
            case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico, .fluidParakeetPro, .parakeetRealtime, .qwen3Asr, .qwen3Asr17B, .cohereTranscribeSixBit, .nemotronOffline, .nemotronStreaming, .nemotronStreaming320: return true
            default: return false
            }
        }

        var isWhisperModel: Bool {
            switch self {
            case .gigaam: return false
            case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico, .fluidParakeetPro, .parakeetRealtime, .qwen3Asr, .qwen3Asr17B, .cohereTranscribeSixBit, .nemotronOffline, .nemotronStreaming, .nemotronStreaming320, .appleSpeech,
                 .appleSpeechAnalyzer: return false
            default: return true
            }
        }

        /// The GGUF filename for models handled by the existing transcribe.cpp adapter.
        var whisperModelFile: String? {
            switch self {
            case .whisperTiny: return "whisper-tiny-Q8_0.gguf"
            case .whisperBase: return "whisper-base-Q8_0.gguf"
            case .whisperSmall: return "whisper-small-Q8_0.gguf"
            case .whisperMedium: return "whisper-medium-Q8_0.gguf"
            case .whisperLargeTurbo: return "whisper-large-v3-turbo-Q8_0.gguf"
            case .whisperLarge: return "whisper-large-v3-Q8_0.gguf"
            case .qwen3Asr17B: return "Qwen3-ASR-1.7B-Q8_0.gguf"
            default: return nil
            }
        }

        var legacyWhisperModelFile: String? {
            switch self {
            case .whisperTiny: return "ggml-tiny.bin"
            case .whisperBase: return "ggml-base.bin"
            case .whisperSmall: return "ggml-small.bin"
            case .whisperMedium: return "ggml-medium.bin"
            case .whisperLargeTurbo: return "ggml-large-v3-turbo.bin"
            case .whisperLarge: return "ggml-large-v3.bin"
            default: return nil
            }
        }

        static let legacyWhisperModelFiles: Set<String> = [
            "ggml-tiny.bin",
            "ggml-base.bin",
            "ggml-small.bin",
            "ggml-medium.bin",
            "ggml-large-v3-turbo.bin",
            "ggml-large-v3.bin",
        ]

        /// The short model name for whisper.cpp internal usage
        var whisperModelName: String? {
            switch self {
            case .whisperTiny: return "tiny"
            case .whisperBase: return "base"
            case .whisperSmall: return "small"
            case .whisperMedium: return "medium"
            case .whisperLargeTurbo: return "large-v3-turbo"
            case .whisperLarge: return "large-v3"
            default: return nil
            }
        }

        // MARK: - Architecture Filtering

        /// Requires macOS 26 (Tahoe) or later
        var requiresMacOS26: Bool {
            switch self {
            case .appleSpeechAnalyzer: return true
            default: return false
            }
        }

        /// Requires macOS 15 or later.
        var requiresMacOS15: Bool {
            switch self {
            case .fluidParakeetMini, .fluidParakeetPico, .fluidParakeetPro, .qwen3Asr, .cohereTranscribeSixBit: return true
            default: return false
            }
        }

        /// Cohere's owning runtime requires iOS 18; its persisted ID remains unchanged.
        var requiresIOS18: Bool { self == .cohereTranscribeSixBit }

        /// Returns models available for the current platform's architecture and OS
        static var availableModels: [SpeechModel] {
            allCases.filter { model in
                if model == .whisperLargeTurbo, !CPUArchitecture.isAppleSilicon {
                    return false
                }
                if model == .whisperLarge, !CPUArchitecture.isAppleSilicon {
                    return false
                }
                if model == .qwen3Asr, !Self.qwenPreviewEnabled {
                    return false
                }
                if model == .nemotronStreaming320 {
                    return false
                }
                // Filter by Apple Silicon requirement
                if model.requiresAppleSilicon, !CPUArchitecture.isAppleSilicon {
                    return false
                }
                // Filter by macOS 15 requirement
                if model.requiresMacOS15, #unavailable(macOS 15.0) {
                    return false
                }
                #if os(iOS)
                if model.requiresIOS18, #unavailable(iOS 18.0) {
                    return false
                }
                #endif
                // Filter by macOS 26 requirement
                if model.requiresMacOS26 {
                    if #available(macOS 26.0, *) {
                        return true
                    } else {
                        return false
                    }
                }
                return true
            }
        }

        /// First-run engine uses the shipped onboarding language's existing route.
        static var defaultModel: SpeechModel {
            VoiceEngineLanguageCatalog.packagedDefaultSpeechModel(
                availableModels: self.availableModels,
                packagedLanguageID: AppBrand.packagedPackage.style?.defaultOnboardingLanguageID
            ) ?? (CPUArchitecture.isAppleSilicon ? .parakeetTDT : .whisperBase)
        }

        // MARK: - UI Card Metadata

        /// Human-readable marketing name for the card UI
        var humanReadableName: String {
            switch self {
            case .gigaam: return "GigaAM - Russian"
            case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico, .fluidParakeetPro: return self.parakeetDescriptor?.humanReadableName ?? self.rawValue
            case .parakeetRealtime: return "Flash Dictation"
            case .qwen3Asr: return "Qwen3 - Multilingual"
            case .cohereTranscribeSixBit: return "Cohere - High Accuracy"
            case .nemotronOffline: return "Nemotron 3.5 Multilingual"
            case .nemotronStreaming: return "Nemotron Speech 3.5 - Ultra Fast Low Latency"
            case .nemotronStreaming320: return "Nemotron Speech 3.5 - Ultra Fast Low Latency"
            case .appleSpeech: return "Apple ASR Legacy"
            case .appleSpeechAnalyzer: return "Apple Speech - macOS 26+"
            case .whisperTiny: return "Fast & Light"
            case .whisperBase: return "Standard Choice"
            case .whisperSmall: return "Balanced Speed & Accuracy"
            case .whisperMedium: return "Medium Quality"
            case .whisperLargeTurbo: return "Higher Quality but Faster"
            case .whisperLarge: return "Maximum Accuracy"
            case .qwen3Asr17B: return "Qwen3 - Multilingual 1.7B"
            }
        }

        /// One-line description for the card UI
        var cardDescription: String {
            switch self {
            case .gigaam: return "On-device recognition for Russian speech."
            case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico, .fluidParakeetPro:
                return self.parakeetDescriptor?.cardDescription ?? ""
            case .parakeetRealtime:
                return "English-only streaming local dictation with low-latency partial text and end-of-utterance detection."
            case .qwen3Asr:
                return "Qwen3 multilingual ASR via FluidAudio. Higher quality, heavier memory footprint."
            case .cohereTranscribeSixBit:
                return "High-accuracy multilingual transcription. Select the language manually before dictation for best results."
            case .nemotronOffline:
                return "Slower but more accurate NVIDIA Nemotron 3.5 transcription. Supports 40 language-locales with auto or manual language selection."
            case .nemotronStreaming:
                return "NVIDIA Nemotron 3.5 streaming-capable transcription. Supports 40 language-locales with auto or manual language selection."
            case .nemotronStreaming320:
                return "NVIDIA Nemotron 3.5 streaming-capable transcription. Supports 40 language-locales with auto or manual language selection."
            case .appleSpeech:
                return "Built-in macOS speech recognition. No model download required."
            case .appleSpeechAnalyzer:
                return "Advanced and modern on-device recognition for newer macOS devices."
            case .whisperTiny:
                return "Compact multilingual model. Recognition can be less accurate, especially for mixed speech."
            case .whisperBase:
                return "Good balance of speed and accuracy. Works on any Mac."
            case .whisperSmall:
                return "Better accuracy than Base. Moderate resource usage."
            case .whisperMedium:
                return "High accuracy for demanding tasks. Requires more memory."
            case .whisperLargeTurbo:
                return "Near-maximum accuracy with optimized speed."
            case .whisperLarge:
                return "Best possible accuracy. Large download and memory usage."
            case .qwen3Asr17B:
                return "Automatically detects 30 languages. Transcribes on your Mac after you stop recording."
            }
        }

        /// Credit for the model's original publisher, available to model surfaces and details.
        var creditLine: String? {
            switch self {
            case .gigaam: return "Built on GigaAM-v3 by SaluteDevices."
            default: return self.parakeetDescriptor?.creditLine
            }
        }

        /// Minimum recommended RAM in GB for this model to run safely
        var requiredMemoryGB: Double {
            switch self {
            case .gigaam: return 4.0
            case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico, .fluidParakeetPro, .parakeetRealtime:
                return 4.0
            case .qwen3Asr:
                return 8.0
            case .cohereTranscribeSixBit:
                return 8.0
            case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
                return 8.0
            case .appleSpeech, .appleSpeechAnalyzer:
                return 2.0 // Built-in, minimal overhead
            case .whisperTiny:
                return 2.0
            case .whisperBase:
                return 3.0
            case .whisperSmall:
                return 4.0
            case .whisperMedium:
                return 5.0
            case .whisperLargeTurbo:
                return 6.0
            case .whisperLarge:
                return 8.0
            case .qwen3Asr17B:
                return 6.0
            }
        }

        /// Warning text for models with high memory requirements, nil if no warning needed
        var memoryWarning: String? {
            switch self {
            case .qwen3Asr:
                return "⚠️ Requires 8GB+ RAM. Best on newer Apple Silicon Macs."
            case .whisperLarge:
                return "⚠️ Requires 10GB+ RAM. May crash on systems with limited memory."
            case .whisperLargeTurbo:
                return "⚠️ Requires 8GB+ RAM. May be unstable on some systems."
            case .whisperMedium:
                return "Requires 6GB+ RAM for stable operation."
            default:
                return nil
            }
        }

        /// Speed rating (1-5, higher is faster)
        var speedRating: Int {
            switch self {
            case .gigaam: return self.libraryMetadata?.performanceRatings.speedRating ?? 0
            case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico, .fluidParakeetPro: return self.parakeetDescriptor?.performanceRatings?.speedRating ?? 0
            case .parakeetRealtime: return 5
            case .qwen3Asr: return 3
            case .cohereTranscribeSixBit: return 3
            case .nemotronOffline: return 3
            case .nemotronStreaming, .nemotronStreaming320: return 4
            case .appleSpeech: return 4
            case .appleSpeechAnalyzer: return 4
            case .whisperTiny: return 4
            case .whisperBase: return 4
            case .whisperSmall: return 3
            case .whisperMedium: return 2
            case .whisperLargeTurbo: return 3
            case .whisperLarge: return 1
            case .qwen3Asr17B: return 3
            }
        }

        /// Accuracy rating (1-5, higher is more accurate)
        var accuracyRating: Int {
            switch self {
            case .gigaam: return self.libraryMetadata?.performanceRatings.accuracyRating ?? 0
            case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico, .fluidParakeetPro: return self.parakeetDescriptor?.performanceRatings?.accuracyRating ?? 0
            case .parakeetRealtime: return 4
            case .qwen3Asr: return 4
            case .cohereTranscribeSixBit: return 5
            case .nemotronOffline: return 5
            case .nemotronStreaming, .nemotronStreaming320: return 4
            case .appleSpeech: return 4
            case .appleSpeechAnalyzer: return 4
            case .whisperTiny: return 2
            case .whisperBase: return 3
            case .whisperSmall: return 4
            case .whisperMedium: return 4
            case .whisperLargeTurbo: return 5
            case .whisperLarge: return 5
            case .qwen3Asr17B: return 5
            }
        }

        /// Exact speed percentage (0.0 - 1.0) for the liquid bars
        var speedPercent: Double {
            switch self {
            case .gigaam: return self.libraryMetadata?.performanceRatings.speedPercent ?? 0
            case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico, .fluidParakeetPro: return self.parakeetDescriptor?.performanceRatings?.speedPercent ?? 0
            case .parakeetRealtime: return 1.0
            case .qwen3Asr: return 0.45
            case .cohereTranscribeSixBit: return 0.85
            case .nemotronOffline: return 0.85
            case .nemotronStreaming, .nemotronStreaming320: return 1.0
            case .appleSpeech: return 0.60
            case .appleSpeechAnalyzer: return 0.85
            case .whisperTiny: return 0.90
            case .whisperBase: return 0.80
            case .whisperSmall: return 0.60
            case .whisperMedium: return 0.40
            case .whisperLargeTurbo: return 0.65
            case .whisperLarge: return 0.20
            case .qwen3Asr17B: return 0.50
            }
        }

        /// Exact accuracy percentage (0.0 - 1.0) for the liquid bars
        var accuracyPercent: Double {
            switch self {
            case .gigaam: return self.libraryMetadata?.performanceRatings.accuracyPercent ?? 0
            case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico, .fluidParakeetPro: return self.parakeetDescriptor?.performanceRatings?.accuracyPercent ?? 0
            case .parakeetRealtime: return 0.75
            case .qwen3Asr: return 0.90
            case .cohereTranscribeSixBit: return 0.98
            case .nemotronOffline: return 0.90
            case .nemotronStreaming, .nemotronStreaming320: return 0.85
            case .appleSpeech: return 0.60
            case .appleSpeechAnalyzer: return 0.80
            case .whisperTiny: return 0.40
            case .whisperBase: return 0.60
            case .whisperSmall: return 0.70
            case .whisperMedium: return 0.80
            case .whisperLargeTurbo: return 0.95
            case .whisperLarge: return 1.00
            case .qwen3Asr17B: return 1.00
            }
        }

        /// Optional badge text for the card (e.g., "FluidVoice Pick")
        var badgeText: String? {
            switch self {
            case .parakeetTDT: return AppBrand.text("FluidVoice Pick")
            case .parakeetTDTv2: return AppBrand.text("FluidVoice Pick")
            case .fluidParakeetMini, .fluidParakeetPico, .fluidParakeetPro: return "New"
            case .parakeetRealtime: return "Beta"
            case .qwen3Asr: return "Beta"
            case .qwen3Asr17B: return nil
            case .cohereTranscribeSixBit: return "New"
            case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320: return "New + Beta"
            case .appleSpeechAnalyzer: return "New"
            default: return nil
            }
        }

        /// Optimization level for Apple Silicon (for display)
        var appleSiliconOptimized: Bool {
            switch self {
            case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico, .fluidParakeetPro, .parakeetRealtime, .qwen3Asr, .cohereTranscribeSixBit, .nemotronOffline, .nemotronStreaming, .nemotronStreaming320, .appleSpeechAnalyzer:
                return true
            default:
                return false
            }
        }

        /// Whether this model supports real-time streaming/chunk processing.
        /// Large Whisper models are too slow for streaming, so they only do final transcription on stop.
        var supportsStreaming: Bool {
            switch self {
            case .qwen3Asr, .qwen3Asr17B, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
                return false // Too slow for real-time chunk processing
            default:
                return true // All other models support streaming
            }
        }

        /// Existing encoder-backed providers can learn a spelling after a kept
        /// voice match. Acoustic-template providers require explicit text rules.
        var learnsDictionarySpellingsAutomatically: Bool {
            switch self {
            case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico:
                return true
            default:
                return false
            }
        }

        var supportsPronunciationMatching: Bool {
            #if os(macOS)
            if self == .gigaam { return true }
            #endif
            #if arch(arm64)
            switch self {
            case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico, .fluidParakeetPro:
                return true
            default:
                return false
            }
            #else
            return false
            #endif
        }

        /// Preview update cadence for real-time transcription.
        /// Models without native incremental decoding should use a slower interval.
        var streamingPreviewIntervalSeconds: Double {
            switch self {
            case .gigaam: return 0.5
            case .parakeetRealtime:
                return 0.2
            case .nemotronStreaming, .nemotronStreaming320:
                return 0.32
            case .cohereTranscribeSixBit:
                return 1.0
            default:
                return 0.6
            }
        }

        /// Minimum audio required before attempting a preview decode.
        /// Cohere performs better with a slightly larger prefix than the default 1 second.
        var minimumStreamingPreviewSeconds: Double {
            switch self {
            case .gigaam: return 0.5
            case .parakeetRealtime:
                return 0.2
            case .nemotronStreaming, .nemotronStreaming320:
                return 0.64
            case .cohereTranscribeSixBit:
                return 1.5
            default:
                return 1.0
            }
        }

        /// Provider category for tab grouping
        enum Provider: String, CaseIterable {
            case saluteDevices = "SaluteDevices"
            case nvidia = "NVIDIA"
            case apple = "Apple"
            case openai = "OpenAI"
            case qwen = "Qwen"
            case cohere = "Cohere"
        }

        /// Which provider this model belongs to
        var provider: Provider {
            switch self {
            case .gigaam: return .saluteDevices
            case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico, .fluidParakeetPro, .parakeetRealtime, .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
                return .nvidia
            case .appleSpeech, .appleSpeechAnalyzer:
                return .apple
            case .qwen3Asr, .qwen3Asr17B:
                return .qwen
            case .cohereTranscribeSixBit:
                return .cohere
            case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
                return .openai
            }
        }

        /// Get models filtered by provider
        static func models(for provider: Provider) -> [SpeechModel] {
            self.availableModels.filter { $0.provider == provider }
        }

        /// Whether this model is built-in or already downloaded on disk
        var isInstalled: Bool {
            switch self {
            case .gigaam: return PichiGigaAMModelStore.shared.modelsExistOnDisk()
            case .appleSpeech, .appleSpeechAnalyzer:
                return true
            case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico, .fluidParakeetPro:
                #if canImport(FluidAudio)
                guard let descriptor = self.parakeetDescriptor else { return false }
                return Self.parakeetModelsExist(descriptor: descriptor)
                #else
                return false
                #endif
            case .parakeetRealtime:
                #if canImport(FluidAudio)
                return Self.parakeetRealtimeModelsExist()
                #else
                return false
                #endif
            case .qwen3Asr:
                #if canImport(FluidAudio) && ENABLE_QWEN
                if #available(macOS 15.0, *) {
                    return Qwen3AsrModels.modelsExist(at: Qwen3AsrModels.defaultCacheDirectory())
                }
                return false
                #else
                return false
                #endif
            case .cohereTranscribeSixBit:
                guard
                    let spec = self.externalCoreMLSpec,
                    let directory = SettingsStore.shared.externalCoreMLArtifactsDirectory(for: self)
                else {
                    return false
                }
                return spec.validatesInstalledArtifacts(at: directory)
            case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
                let hint: String
                switch self {
                case .nemotronOffline:
                    hint = "nemotron-3.5-asr-offline-6bit-CoreML"
                default:
                    hint = "nemotron-3.5-asr-streaming320-int8-CoreML"
                }
                let directory: URL? = AppBrand.cachesDirectory
                    .appendingPathComponent(hint, isDirectory: true)
                #if os(macOS) && arch(arm64)
                return directory.map { NemotronProvider.artifactsAreComplete(at: $0) } ?? false
                #else
                return false
                #endif
            default:
                // GGUF models handled by the shared native adapter.
                guard let whisperFile = self.whisperModelFile else { return false }
                let directory: URL? = AppBrand.cachesDirectory
                    .appendingPathComponent("WhisperModels")
                let modelURL = directory?.appendingPathComponent(whisperFile)
                guard
                    let modelURL,
                    let attributes = try? FileManager.default.attributesOfItem(atPath: modelURL.path),
                    let size = attributes[.size] as? NSNumber,
                    size.int64Value > 0
                else {
                    return false
                }
                return size.int64Value == self.expectedDownloadBytes
            }
        }

        #if canImport(FluidAudio)
        private static func parakeetModelsExist(descriptor: ParakeetSpeechModelCatalog.Descriptor) -> Bool {
            let modelsDirectory = AppBrand.modelsDirectory
            let directory = descriptor.cacheDirectory(in: modelsDirectory)
            return descriptor.artifactsAreComplete(at: directory)
        }

        private static func parakeetRealtimeModelsExist() -> Bool {
            let modelsDirectory = AppBrand.modelsDirectory
            let modelDirectory = modelsDirectory
                .appendingPathComponent("parakeet-eou-streaming", isDirectory: true)
                .appendingPathComponent(Repo.parakeetEou160.folderName, isDirectory: true)

            return ModelNames.ParakeetEOU.requiredModels.allSatisfy { modelName in
                let artifact = modelDirectory.appendingPathComponent(modelName)
                return HuggingFaceModelDownloader.artifactIsComplete(
                    at: artifact,
                    isDirectory: modelName.hasSuffix(".mlmodelc")
                )
            }
        }
        #endif

        /// Brand/provider name for the model (NVIDIA, Apple, OpenAI)
        var brandName: String {
            switch self {
            case .gigaam: return "SaluteDevices"
            case .fluidParakeetMini, .fluidParakeetPico, .fluidParakeetPro:
                return "FluidVoice"
            case .parakeetTDT, .parakeetTDTv2, .parakeetRealtime, .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
                return "NVIDIA"
            case .qwen3Asr, .qwen3Asr17B:
                return "Qwen"
            case .cohereTranscribeSixBit:
                return "Cohere"
            case .appleSpeech, .appleSpeechAnalyzer:
                return "Apple"
            case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
                return "OpenAI"
            }
        }

        /// Whether this model uses Apple's SF Symbol for branding (apple.logo)
        var usesAppleLogo: Bool {
            switch self {
            case .appleSpeech, .appleSpeechAnalyzer: return true
            default: return false
            }
        }

        /// Brand color for the provider badge
        var brandColorHex: String {
            switch self {
            case .gigaam: return "#8E8E93" // Neutral: no bundled publisher logo or color
            case .fluidParakeetMini, .fluidParakeetPico, .fluidParakeetPro:
                return "#1A75FF" // FluidBrandColors.blue
            case .parakeetTDT, .parakeetTDTv2, .parakeetRealtime, .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
                return "#76B900"
            case .qwen3Asr, .qwen3Asr17B:
                return "#E67E22"
            case .cohereTranscribeSixBit:
                return "#FA6B3C"
            case .appleSpeech, .appleSpeechAnalyzer:
                return "#A2AAAD" // Apple Gray
            case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
                return "#10A37F" // OpenAI Teal
            }
        }
    }

}

extension SettingsStore.SpeechModel {
    var supportedLanguageCodes: String? {
        switch self {
        case .gigaam:
            return "RU"
        case .parakeetTDT, .fluidParakeetMini, .fluidParakeetPico, .fluidParakeetPro:
            return "BG, HR, CS, DA, NL, EN, ET, FI, FR, DE, EL, HU, IT, LV, LT, MT, PL, PT, RO, SK, SL, ES, SV, RU, UK"
        case .parakeetRealtime:
            return "EN"
        case .cohereTranscribeSixBit:
            return "AR, DE, EL, EN, ES, FR, IT, JA, KO, NL, PL, PT, VI, ZH"
        case .qwen3Asr, .qwen3Asr17B:
            // https://huggingface.co/Qwen/Qwen3-ASR-1.7B#released-models-description-and-download
            return "ZH, EN, YUE, AR, DE, FR, ES, PT, ID, IT, KO, RU, TH, VI, JA, TR, HI, MS, NL, SV, DA, FI, PL, CS, FIL, FA, EL, HU, MK, RO"
        case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
            return "40 language-locales"
        case .appleSpeechAnalyzer:
            return "EN, ES, FR, DE, IT, JA, KO, PT, ZH"
        default:
            return nil
        }
    }

    var supportedLanguageNames: String? {
        switch self {
        case .gigaam:
            return "Russian"
        case .parakeetTDT, .fluidParakeetMini, .fluidParakeetPico, .fluidParakeetPro:
            return """
            Bulgarian, Croatian, Czech, Danish, Dutch, English, Estonian, Finnish, French, German, Greek, Hungarian, Italian, Latvian, Lithuanian, Maltese, Polish, Portuguese, Romanian, Slovak, Slovenian, Spanish, Swedish, Russian, and Ukrainian
            """
        case .cohereTranscribeSixBit:
            return "Arabic, German, Greek, English, Spanish, French, Italian, Japanese, Korean, Dutch, Polish, Portuguese, Vietnamese, and Mandarin Chinese"
        case .qwen3Asr, .qwen3Asr17B:
            return "Chinese, English, Cantonese, Arabic, German, French, Spanish, Portuguese, Indonesian, Italian, Korean, Russian, Thai, " +
                "Vietnamese, Japanese, Turkish, Hindi, Malay, Dutch, Swedish, Danish, Finnish, Polish, Czech, Filipino, Persian, Greek, " +
                "Hungarian, Macedonian, and Romanian"
        case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
            return "Spanish, Italian, Portuguese, Hindi, Korean, English, German, French, Russian, Turkish, Vietnamese, Dutch, Japanese, Arabic, " +
                "Ukrainian; Polish, Norwegian Bokmal, Finnish, Mandarin, Czech, Bulgarian, Slovak, Swedish, Croatian, Romanian, Estonian, " +
                "Danish, and Hungarian are Alpha; Greek, Hebrew, Lithuanian, Slovenian, Latvian, Maltese, Thai, and Norwegian Nynorsk are Experimental."
        default:
            return nil
        }
    }
}

extension SettingsStore {
    enum CohereLanguage: String, CaseIterable, Identifiable, Codable {
        case arabic = "ar"
        case german = "de"
        case greek = "el"
        case english = "en"
        case spanish = "es"
        case french = "fr"
        case italian = "it"
        case japanese = "ja"
        case korean = "ko"
        case dutch = "nl"
        case polish = "pl"
        case portuguese = "pt"
        case vietnamese = "vi"
        case mandarinChinese = "zh"

        var id: String {
            self.rawValue
        }

        var displayName: String {
            switch self {
            case .arabic: return "Arabic"
            case .german: return "German"
            case .greek: return "Greek"
            case .english: return "English"
            case .spanish: return "Spanish"
            case .french: return "French"
            case .italian: return "Italian"
            case .japanese: return "Japanese"
            case .korean: return "Korean"
            case .dutch: return "Dutch"
            case .polish: return "Polish"
            case .portuguese: return "Portuguese"
            case .vietnamese: return "Vietnamese"
            case .mandarinChinese: return "Mandarin Chinese"
            }
        }

        var tokenString: String {
            "<|\(self.rawValue)|>"
        }
    }

    // MARK: - Unified Speech Model Selection

    /// The selected speech recognition model.
    /// This unified setting replaces the old TranscriptionProviderOption + WhisperModelSize combination.
    var selectedSpeechModel: SpeechModel {
        get {
            // Check if already using new system
            if let rawValue = defaults.string(forKey: Keys.selectedSpeechModel),
               let model = SpeechModel(rawValue: rawValue)
            {
                // If Qwen was previously selected, transparently fall back while preview is disabled.
                if model == .qwen3Asr, !SpeechModel.qwenPreviewEnabled {
                    return SpeechModel.defaultModel
                }
                if model == .nemotronStreaming320 {
                    return .nemotronStreaming
                }
                let requiresAppleSiliconWhisper = model == .whisperLargeTurbo || model == .whisperLarge
                if requiresAppleSiliconWhisper, !CPUArchitecture.isAppleSilicon {
                    return .whisperBase
                }
                // Validate model is available on this architecture
                if model.requiresAppleSilicon && !CPUArchitecture.isAppleSilicon {
                    return .whisperBase
                }
                if model.requiresMacOS15, #unavailable(macOS 15.0) {
                    return .whisperBase
                }
                if model.requiresMacOS26, #unavailable(macOS 26.0) {
                    return .whisperBase
                }
                #if os(iOS)
                if model.requiresIOS18, #unavailable(iOS 18.0) {
                    return SpeechModel.defaultModel
                }
                #endif
                return model
            }

            // Migration: Convert old settings to new SpeechModel
            return self.migrateToSpeechModel()
        }
        set {
            objectWillChange.send()
            let model = newValue == .nemotronStreaming320 ? SpeechModel.nemotronStreaming : newValue
            self.defaults.set(model.rawValue, forKey: Keys.selectedSpeechModel)
        }
    }

    /// The language Whisper should transcribe, or `nil` to detect it from each recording.
    /// Existing installs keep automatic detection until the user selects a language.
    var selectedWhisperLanguageCode: String? {
        get {
            Self.whisperLanguageCode(fromStoredValue: self.defaults.string(forKey: Keys.selectedWhisperLanguageCode))
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue ?? Self.automaticWhisperLanguageCode, forKey: Keys.selectedWhisperLanguageCode)
        }
    }

    static func whisperLanguageCode(fromStoredValue value: String?) -> String? {
        guard let value, value != self.automaticWhisperLanguageCode else { return nil }
        return VoiceEngineLanguageCatalog.whisperLanguage(forCode: value) == nil ? nil : value
    }

    static func whisperLanguageBackupValue(for languageCode: String?) -> String {
        languageCode ?? self.automaticWhisperLanguageCode
    }

    static func whisperLanguageCode(fromBackupValue value: String) -> String? {
        value == self.automaticWhisperLanguageCode ? nil : value
    }

    var selectedCohereLanguage: CohereLanguage {
        get {
            if let rawValue = self.defaults.string(forKey: Keys.selectedCohereLanguage),
               let language = CohereLanguage(rawValue: rawValue)
            {
                return language
            }
            return .english
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.selectedCohereLanguage)
        }
    }

    var selectedNemotronLanguage: NemotronLanguage {
        get {
            if let rawValue = self.defaults.string(forKey: Keys.selectedNemotronLanguage),
               let language = NemotronLanguage.supportedLanguage(rawValue: rawValue)
            {
                return language
            }
            return .english
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.selectedNemotronLanguage)
        }
    }

    /// Read only the persisted choice; callers can resolve the fallback off the main thread.
    func storedExternalCoreMLArtifactsPath(for model: SpeechModel) -> String? {
        let paths = self.defaults.dictionary(forKey: Keys.externalCoreMLArtifactsDirectories) as? [String: String] ?? [:]
        guard let path = paths[model.rawValue], !path.isEmpty else { return nil }
        return path
    }

    func externalCoreMLArtifactsDirectory(for model: SpeechModel) -> URL? {
        guard let spec = model.externalCoreMLSpec else { return nil }
        let paths = self.defaults.dictionary(forKey: Keys.externalCoreMLArtifactsDirectories) as? [String: String] ?? [:]
        if let storedPath = paths[model.rawValue], storedPath.isEmpty == false {
            return URL(fileURLWithPath: storedPath, isDirectory: true)
        }

        let cachesDirectory: URL? = AppBrand.cachesDirectory
        let fallback = cachesDirectory?.appendingPathComponent(spec.artifactFolderHint, isDirectory: true)
        guard let fallback else { return nil }
        if FileManager.default.fileExists(atPath: fallback.path) {
            return fallback
        }
        return nil
    }

    func setExternalCoreMLArtifactsDirectory(_ directory: URL?, for model: SpeechModel) {
        guard model.requiresExternalArtifacts else { return }
        objectWillChange.send()
        var paths = self.defaults.dictionary(forKey: Keys.externalCoreMLArtifactsDirectories) as? [String: String] ?? [:]
        if let directory {
            paths[model.rawValue] = directory.standardizedFileURL.path
        } else {
            paths.removeValue(forKey: model.rawValue)
        }
        self.defaults.set(paths, forKey: Keys.externalCoreMLArtifactsDirectories)
    }

    /// Migrates old TranscriptionProviderOption + WhisperModelSize settings to new SpeechModel
    private func migrateToSpeechModel() -> SpeechModel {
        let oldProvider = self.defaults.string(forKey: Keys.selectedTranscriptionProvider)
        let oldWhisperSize = self.defaults.string(forKey: Keys.whisperModelSize)
        let newModel = Self.migratedSpeechModel(legacyProvider: oldProvider, legacyWhisperSize: oldWhisperSize,
                                               isAppleSilicon: CPUArchitecture.isAppleSilicon,
                                               freshDefault: SpeechModel.defaultModel)

        // Persist only after checking both current and legacy selections.
        self.defaults.set(newModel.rawValue, forKey: Keys.selectedSpeechModel)
        DebugLogger.shared.info("Migrated speech model settings: \(oldProvider ?? "unset")/\(oldWhisperSize ?? "unset") -> \(newModel.rawValue)", source: "SettingsStore")
        return newModel
    }

    /// Keep old installations' explicit automatic/engine selections while applying
    /// the packaged first-run default only when no speech choice has been saved.
    static func migratedSpeechModel(legacyProvider: String?, legacyWhisperSize: String?,
                                    isAppleSilicon: Bool, freshDefault: SpeechModel) -> SpeechModel {
        guard legacyProvider != nil || legacyWhisperSize != nil else { return freshDefault }
        switch legacyProvider ?? "auto" {
        case "whisper":
            switch legacyWhisperSize ?? "ggml-base.bin" {
            case "ggml-tiny.bin": return .whisperTiny
            case "ggml-base.bin": return .whisperBase
            case "ggml-small.bin": return .whisperSmall
            case "ggml-medium.bin": return .whisperMedium
            case "ggml-large-v3.bin": return isAppleSilicon ? .whisperLarge : .whisperBase
            default: return .whisperBase
            }
        case "fluidAudio":
            return isAppleSilicon ? .parakeetTDT : .whisperBase
        default:
            return isAppleSilicon ? .parakeetTDT : .whisperBase
        }
    }
}

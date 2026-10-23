import Foundation
import Darwin

@MainActor final class SettingsStore {
    static let shared = SettingsStore()
    enum SpeechModel: Equatable {
        case parakeetTDT, qwen3Asr, other
        var parakeetDescriptor: ParakeetSpeechModelCatalog.Descriptor? { .init(modelID: "A") }
    }
    struct CustomDictionaryEntry { let id: UUID; let replacement: String }
    var selectedSpeechModel = SpeechModel.parakeetTDT
    var customDictionaryEntries: [CustomDictionaryEntry] = [.init(id: UUID(), replacement: "A")]
    var experimentalParakeetUnifiedFinalEnabled = true
    var automaticDictionaryLearningEnabled = true
    var selectedAppleSpeechLocale = Locale(identifier: "ru-RU")
}
nonisolated struct PrivateProfileSnapshot: Sendable {
    let rootDirectory: URL
    var legacyRootDirectory: URL { rootDirectory }
    var isGuest: Bool { true }
    var id: String { "guest" }
}
nonisolated enum PrivateProfileStorage {
    nonisolated(unsafe) static var current = PrivateProfileSnapshot(rootDirectory: URL(fileURLWithPath: "/unused"))
    nonisolated(unsafe) static var readable = true
    static func isReadable(_ profile: PrivateProfileSnapshot) -> Bool { readable && profile.rootDirectory == current.rootDirectory }
}
@MainActor enum PrivateProfileObjectCache {
    static func value<Value>(key: String, create: () -> Value) -> Value { create() }
}
nonisolated enum AppBrand { static let appName = "Synthetic"; static let modelsDirectory = URL(fileURLWithPath: "/synthetic-models") }
nonisolated final class DebugLogger: Sendable { static let shared = DebugLogger(); func debug(_ message: String, source: String) {} }
nonisolated enum ParakeetSpeechModelCatalog {
    struct Descriptor: Equatable, Sendable {
        let modelID: String
        var pronunciationModelKey: String { modelID }
        func cacheDirectory(in root: URL) -> URL { root.appendingPathComponent(modelID) }
        func installedArchiveSHA256(at directory: URL) -> String? { nil }
    }
    static func descriptor(forInstalledPronunciationModelKey key: String) -> Descriptor? { .init(modelID: key) }
    static func isOutdatedCompactPronunciationModelKey(_ key: String) -> Bool { false }
}
@MainActor final class CompactSpeechModelReleaseCatalog {
    static let shared = CompactSpeechModelReleaseCatalog()
    var selected = ParakeetSpeechModelCatalog.Descriptor(modelID: "A")
    func descriptor(for model: SettingsStore.SpeechModel) -> ParakeetSpeechModelCatalog.Descriptor? { selected }
}
nonisolated enum DictionaryMatcherExperiment {
    nonisolated(unsafe) static var sharedFeaturesEnabled = true
    nonisolated(unsafe) static var generation = "A"
    nonisolated(unsafe) static var collectNegatives = true
    nonisolated(unsafe) static var compareNegatives = true
}
nonisolated enum PrivateProfileDefaults {
    static let shared = Defaults()
    final class Defaults: Sendable { func bool(forKey key: String) -> Bool { true } }
}
nonisolated struct PronunciationEnrollmentCapture {
    var modelKey = "A"
    var values: [Float] = [1, 0]
    var sourceFrameCount = 10
    var inspectionID: UUID? = nil
    var edgeEmbedding: [Float]? = [1, 0]
    var edgeFrameCount: Int? = 10
}
nonisolated struct PronunciationDictionaryProfile {
    var automaticMatchingEnabled: Bool? = true
    var modelKey = "A"
    var hiddenSize = 2
    var hasOriginalAudio = false
    var enrollments = Array(repeating: PronunciationEnrollmentCapture(), count: 3)
}
nonisolated struct PronunciationEmbedding { let values: [Float]; let sourceFrameCount: Int }
nonisolated enum PronunciationEmbeddingMatcher {
    static func prototype(from embeddings: [PronunciationEmbedding]) -> PronunciationEmbedding? { embeddings.first }
}
nonisolated struct DictionaryAudioInspection {}
nonisolated struct DictionaryMatchFrames {}
nonisolated enum PronunciationDictionaryStoreError: Error { case staleEvidence, inconsistentEnrollment }
@MainActor final class PronunciationDictionaryStore {
    static let shared = PronunciationDictionaryStore()
    final class CaptureRead {
        var active = true
        var profiles: [PronunciationDictionaryProfile] { active ? [.init(automaticMatchingEnabled: true)] : [] }
        func close(leaseID: UUID) { active = false }
        func inspection(for id: UUID) throws -> DictionaryAudioInspection { .init() }
        func originalAudioSamples(for capture: PronunciationEnrollmentCapture, entryID: UUID) throws -> [Float] { [1] }
    }
    func admitCaptureRead(leaseID: UUID, modelKey: String, entryIDs: Set<UUID>) throws -> CaptureRead { .init() }
    func profiles(modelKey: String) async -> [PronunciationDictionaryProfile] { [] }
    func inspection(for id: UUID) async throws -> DictionaryAudioInspection { .init() }
    func originalAudioSamples(for capture: PronunciationEnrollmentCapture, entryID: UUID) async throws -> [Float] { [] }
}
@MainActor final class DictionaryNegativeExampleStore {
    static let shared = DictionaryNegativeExampleStore()
    final class CaptureRead {
        let revision = UUID()
        var active = true
        func frames(entryID: UUID, profileKey: String, modelKey: String) -> [DictionaryMatchFrames] { active ? [.init()] : [] }
        func close(leaseID: UUID) { active = false }
    }
    func admitCaptureRead(leaseID: UUID, modelKey: String, entryIDs: Set<UUID>) throws -> CaptureRead { .init() }
    func revision() async -> UUID { UUID() }
    func frames(entryID: UUID, profileKey: String, modelKey: String) async -> [DictionaryMatchFrames] { [] }
}
nonisolated struct MeetingOptions {
    let experimentalUnifiedFinalEnabled: Bool
    let pronunciationMatchingEnabled: Bool
    let customDictionaryRewritingEnabled: Bool
}
nonisolated struct CustomVocabularyTerm { let text: String; let weight: Float?; let aliases: [String]; let tokenIds: [Int]?; let ctcTokenIds: [Int] }
nonisolated struct CustomVocabularyContext {
    let terms: [CustomVocabularyTerm]; let alpha: Float; let minCtcScore: Float
    let minSimilarity: Float; let minCombinedConfidence: Float; let minTermLength: Int
}
nonisolated struct CtcModels {
    enum Variant { case ctc110m }
    let variant: Variant
    static func downloadAndLoad(variant: Variant) async throws -> Self { await Task.yield(); return .init(variant: variant) }
    static func defaultCacheDirectory(for variant: Variant) -> URL { URL(fileURLWithPath: "/synthetic-ctc") }
}
nonisolated struct CtcTokenizer {
    static func load(from url: URL) async throws -> Self { await Task.yield(); return .init() }
    func encode(_ text: String) -> [Int] { text.utf8.map(Int.init) }
}

nonisolated final class GigaAMPreferences: @unchecked Sendable {
    var importedID: String? = "private"
    func string(forKey key: String) -> String? { importedID }
}
nonisolated struct GigaAMModelDescriptor: Sendable {
    let id: String
    func filesExist(in root: URL) -> Bool { root.lastPathComponent == id }
}
nonisolated enum GigaAMError: Error { case incompatibleModel }

// ACTUAL_PROVIDER_CAPTURE_SOURCE

actor TestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false
    func hold() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func waitUntilEntered() async { while !entered { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}

@main struct Main {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pichi-capture-config-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        PrivateProfileStorage.current = .init(rootDirectory: root)
        let vocabulary = ParakeetVocabularyStore(profile: PrivateProfileStorage.current)
        try vocabulary.saveRawJSON("{\"terms\":[{\"text\":\"A private boost\",\"weight\":9}]}")
        let provider = FluidAudioProvider(), lease = UUID()
        try provider.beginAdmittedTranscription(leaseID: lease)
        let captured = provider.dictationCaptureOptions!
        check(captured.model == .parakeetTDT, "admit model A")
        check(captured.descriptor?.modelID == "A", "admit artifact descriptor A")
        check(captured.pronunciation?.profiles.count == 1, "admit selected pronunciation snapshot")
        check(captured.negatives?.frames(entryID: UUID(), profileKey: "A", modelKey: "A").count == 1, "admit negative frames")
        try provider.beginAdmittedTranscription(leaseID: lease)
        do { try provider.beginAdmittedTranscription(leaseID: UUID()); preconditionFailure("overlap must reject") } catch { checks += 1 }

        SettingsStore.shared.selectedSpeechModel = .other
        SettingsStore.shared.customDictionaryEntries = []
        SettingsStore.shared.experimentalParakeetUnifiedFinalEnabled = false
        SettingsStore.shared.automaticDictionaryLearningEnabled = false
        CompactSpeechModelReleaseCatalog.shared.selected = .init(modelID: "B")
        DictionaryMatcherExperiment.sharedFeaturesEnabled = false
        DictionaryMatcherExperiment.generation = "B"
        DictionaryMatcherExperiment.collectNegatives = false
        DictionaryMatcherExperiment.compareNegatives = false
        PrivateProfileStorage.readable = false
        check(provider.resolvedSpeechModel == .parakeetTDT, "conceal cannot change model")
        check(provider.effectiveExperimentalUnifiedFinalEnabled, "conceal cannot change final mode")
        check(provider.effectiveCustomDictionaryEntries.map(\.replacement) == ["A"], "conceal cannot replace dictionary")
        check(provider.automaticLearningEnabled && provider.sharedFeaturesEnabled, "admitted learning/matcher options remain fixed")
        check(provider.pronunciationGeneration == "A" && provider.collectNegativeExamples && provider.compareNegativeExamples, "admitted matcher generation remains fixed")
        check(provider.captureInspectionEnabled, "admitted capture option remains fixed")
        let originalProfiles = [PronunciationDictionaryProfile()]
        check(originalProfiles[0].edgeCalibration == nil, "ordinary hidden calibration remains disabled")
        let admittedProfiles = FluidAudioProvider.preparedEdgeProfiles(originalProfiles, cache: [:], enabled: provider.sharedFeaturesEnabled)
        check(admittedProfiles.count == 1, "admitted profile preparation keeps frozen calibration after conceal")
        let admittedReferences = DictionaryPronunciationReferences.make(profiles: admittedProfiles, compatibleModelKey: "A", pronunciationEnabled: provider.sharedFeaturesEnabled)
        check(admittedReferences.count == 1 && admittedReferences[0].sampleNumber == 0, "admitted helper chain retains calibrated reference after conceal")
        check(DictionaryPronunciationReferences.make(profiles: originalProfiles, compatibleModelKey: "A").count == 3, "ordinary helper still follows live policy")
        check(await provider.storedPronunciationProfiles().count == 1, "provider consumes admitted profile metadata")
        check(await provider.negativeRevision() == captured.negatives?.revision, "provider consumes admitted negative revision")
        check(await provider.negativeFrames(entryID: UUID(), profileKey: "A", modelKey: "A").count == 1, "provider consumes admitted negative frames")
        do { _ = try vocabulary.loadResolvedConfig(); preconditionFailure("ordinary hidden vocabulary read must fail") } catch { checks += 1 }
        let resolved = try captured.vocabulary!.get()
        let bundle = try await captured.vocabularyStore.loadTokenizedVocabularyBundle(resolvedConfig: resolved)
        check(bundle?.vocabulary.terms.map(\.text) == ["A private boost"], "cold tokenization uses immutable A configuration after conceal")
        check(captured.descriptor?.modelID == "A", "catalog refresh cannot alter admitted artifacts")
        await provider.endAdmittedTranscription(leaseID: UUID())
        check(provider.dictationCaptureOptions != nil && captured.pronunciation?.profiles.count == 1, "stale end cannot close A")
        let warmGate = TestGate()
        provider.temporalWarmTask = Task { await warmGate.hold() }
        await warmGate.waitUntilEntered()
        let ending = Task { @MainActor in await provider.endAdmittedTranscription(leaseID: lease) }
        await Task.yield()
        check(provider.dictationCaptureOptions != nil && captured.pronunciation?.profiles.count == 1, "reference worker retains options until its actual return")
        await warmGate.release()
        await ending.value
        check(provider.dictationCaptureOptions == nil, "matching end releases options")
        check(captured.pronunciation?.profiles.isEmpty == true && captured.negatives?.frames(entryID: UUID(), profileKey: "A", modelKey: "A").isEmpty == true, "matching end closes private read capabilities")
        check(provider.resolvedSpeechModel == .other && provider.effectiveCustomDictionaryEntries.isEmpty, "future capture follows its current profile")

        PrivateProfileStorage.readable = true
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent("parakeet_custom_vocabulary.json"))
        try handle.truncate(atOffset: 0); try handle.write(contentsOf: Data(repeating: 65, count: 1025)); try handle.close()
        do { _ = try vocabulary.loadResolvedConfig(maximumBytes: 1024); preconditionFailure("oversized capture config must reject") } catch { checks += 1 }
        let vocabularyURL = root.appendingPathComponent("parakeet_custom_vocabulary.json")
        try FileManager.default.removeItem(at: vocabularyURL)
        precondition(mkfifo(vocabularyURL.path, 0o600) == 0)
        do { _ = try vocabulary.loadResolvedConfig(maximumBytes: 1024); preconditionFailure("FIFO must reject without blocking") } catch { checks += 1 }
        try FileManager.default.removeItem(at: vocabularyURL)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("pichi-vocabulary-outside-\(UUID())")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("{\"terms\":[]}".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: vocabularyURL, withDestinationURL: outside)
        do { _ = try vocabulary.loadResolvedConfig(maximumBytes: 1024); preconditionFailure("symlink must not escape original profile") } catch { checks += 1 }
        let analyzer = AppleSpeechAnalyzerProvider(), analyzerLease = UUID()
        try analyzer.beginAdmittedTranscription(leaseID: analyzerLease)
        SettingsStore.shared.selectedAppleSpeechLocale = Locale(identifier: "en-US")
        check(analyzer.selectedSpeechLocale().identifier == "ru-RU", "cold analyzer retains admitted locale")
        analyzer.endAdmittedTranscription(leaseID: UUID())
        check(analyzer.selectedSpeechLocale().identifier == "ru-RU", "stale analyzer end cannot clear locale")
        analyzer.endAdmittedTranscription(leaseID: analyzerLease)
        check(analyzer.selectedSpeechLocale().identifier == "en-US", "analyzer future capture resolves its own locale")
        let gigaamStore = PichiGigaAMModelStore(), gigaamLease = UUID()
        let gigaam = PichiGigaAMProvider(store: gigaamStore)
        try gigaam.beginAdmittedTranscription(leaseID: gigaamLease)
        check(gigaam.admittedSource?.selection?.descriptor.id == "private", "GigaAM admits original imported artifact")
        gigaamStore.preferences.importedID = nil
        check(try gigaamStore.selectedArtifact().descriptor.id == "public", "ordinary GigaAM source follows current defaults")
        check(gigaam.admittedSource?.selection?.descriptor.id == "private", "cold GigaAM keeps admitted imported artifact after conceal")
        gigaam.endAdmittedTranscription(leaseID: UUID())
        check(gigaam.admittedSource?.selection?.descriptor.id == "private", "stale GigaAM end cannot change artifact")
        gigaam.endAdmittedTranscription(leaseID: gigaamLease)
        check(gigaam.admittedSource == nil, "matching GigaAM end releases source")
        print("FluidAudio capture configuration: \(checks) assertions passed")
    }
}

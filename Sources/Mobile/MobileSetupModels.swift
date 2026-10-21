import Combine
import Foundation

extension SettingsStore {
    private static let mobileSetupVersionKey = "MobileSetupVersion"
    private static let mobileSetupStepKey = "MobileSetupStep"
    private static let mobileBehaviorVersionKey = "MobileMeetingBehaviorVersion"
    private static let privacyRequestedKey = "MeetingPIIRedactionRequested"

    var mobileSetupCompleted: Bool {
        get { defaults.integer(forKey: Self.mobileSetupVersionKey) >= 1 }
        set { objectWillChange.send(); defaults.set(newValue ? 1 : 0, forKey: Self.mobileSetupVersionKey) }
    }
    var mobileSetupStep: Int {
        get { min(5, max(0, defaults.integer(forKey: Self.mobileSetupStepKey))) }
        set { objectWillChange.send(); defaults.set(min(5, max(0, newValue)), forKey: Self.mobileSetupStepKey) }
    }
    var meetingPIIRedactionRequested: Bool {
        get { defaults.object(forKey: Self.privacyRequestedKey) as? Bool ?? meetingPIIRedactionEnabled }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Self.privacyRequestedKey) }
    }

    /// Preferences affect only new attempts. Encoded sessions and recovery pins are untouched.
    /// Existing installations keep their model, audio policy, explicit privacy and voice profile.
    func migrateMobileSetup() {
        if defaults.object(forKey: Self.mobileSetupVersionKey) == nil {
            let existing = [Keys.selectedSpeechModel, Keys.meetingRecordingDefaults, Keys.meetingSaveAudio,
                            Keys.meetingPIIRedactionEnabled, Keys.meetingSpeakerLabelsEnabled,
                            Keys.meetingSpeakerProcessingMode].contains { defaults.object(forKey: $0) != nil }
            defaults.set(existing ? 1 : 0, forKey: Self.mobileSetupVersionKey)
        }
        guard defaults.integer(forKey: Self.mobileBehaviorVersionKey) < 1 else { return }
        // Preserve an unknown future value. Known legacy timing choices are retired.
        let raw = defaults.string(forKey: Keys.meetingSpeakerProcessingMode)
        if raw == nil || raw.flatMap(MeetingSpeakerProcessingMode.init(rawValue:)) != nil {
            defaults.removeObject(forKey: Keys.meetingSpeakerProcessingMode)
        }
        defaults.set(true, forKey: Keys.meetingSpeakerLabelsEnabled)
        defaults.set(1, forKey: Self.mobileBehaviorVersionKey)
    }
}

/// Presentation and joining of the existing artifact operations. This owner never loads
/// inference engines or captures PCM. Background setup, onboarding and Start share one job.
@MainActor
final class MobileRequiredResources: ObservableObject {
    enum Phase: Equatable { case idle, speechActivity, speakers, ready, failed(String) }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var modelID: String?
    private var operation: (id: UUID, modelID: String, task: Task<Void, Error>)?
    private var progressObservers: Set<AnyCancellable> = []
    private let speech: MeetingSpeechActivityResources
    private let speakerStore: (String) -> MeetingDiarizationModelStore?

    init(speech: MeetingSpeechActivityResources = .shared,
         speakerStore: @escaping (String) -> MeetingDiarizationModelStore? = {
             PichiMeetingProviderFactory.speakerModelStore(for: $0, speakerProcessingMode: .streaming)
         }) {
        self.speech = speech; self.speakerStore = speakerStore
    }

    var isPreparing: Bool { operation != nil }
    var progress: Double? {
        switch phase {
        case .speechActivity: return speech.isPreparing ? speech.progress : nil
        case .speakers:
            if let modelID, case .downloading(let fraction) = speakerStore(modelID)?.state { return fraction }
            return nil
        default: return nil
        }
    }

    func prepare(modelID requested: String) async throws {
        if let operation {
            try await operation.task.value
            try Task.checkCancellation()
            if operation.modelID == requested { return }
            if self.operation?.id == operation.id { self.operation = nil }
        }
        // Revalidate via the owning stores on a new explicit request. Their existing
        // operation owners join any capture/enrollment work and never redownload valid files.
        modelID = requested
        progressObservers.removeAll()
        for publisher in [speech.objectWillChange, speakerStore(requested)?.objectWillChange].compactMap({ $0 }) {
            publisher.sink { [weak self] in self?.objectWillChange.send() }.store(in: &progressObservers)
        }
        let id = UUID()
        let task = Task { @MainActor in
            do {
                self.phase = .speechActivity
                try await self.speech.prepare()
                try Task.checkCancellation()
                guard let store = self.speakerStore(requested) else { throw MeetingProcessingError.modelUnavailable }
                self.phase = .speakers
                _ = try await store.ensureInstalled(includingVoiceEncoder: store.supportsOwnerVoiceVerification)
                try Task.checkCancellation()
                self.phase = .ready
            } catch {
                self.phase = .failed(error.localizedDescription)
                throw error
            }
        }
        operation = (id, requested, task)
        defer { if operation?.id == id { operation = nil } }
        try await task.value
        try Task.checkCancellation()
    }
}

/// The persisted request is separate from committed activation. A cancelled/failed
/// preparation cannot advertise active protection, and a restart resumes a requested enable.
@MainActor
final class MobilePrivacyActivation: ObservableObject {
    enum State: Equatable { case off, enabling, active, failed(String) }
    @Published private(set) var state: State = .off
    @Published private(set) var downloadProgress: Double?
    private let settings: SettingsStore
    private let prepare: (@escaping @Sendable (Double) -> Void) async throws -> Void
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    var isRequested: Bool { settings.meetingPIIRedactionRequested }
    var isPreparing: Bool { state == .enabling }

    init(settings: SettingsStore, prepare: @escaping (@escaping @Sendable (Double) -> Void) async throws -> Void) {
        self.settings = settings; self.prepare = prepare
        if settings.meetingPIIRedactionRequested { state = .enabling }
    }

    func restore() {
        if settings.meetingPIIRedactionRequested { setEnabled(true) }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled, operation != nil { return }
        settings.meetingPIIRedactionRequested = enabled
        settings.meetingPIIRedactionEnabled = false
        let previous = operation
        previous?.cancel()
        generation = UUID()
        let selected = generation
        downloadProgress = nil
        state = enabled ? .enabling : .off
        let prepare = self.prepare
        operation = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled, self.generation == selected else { return }
            guard enabled else { self.operation = nil; return }
            do {
                try await prepare { value in
                    Task { @MainActor in
                        guard self.generation == selected, self.state == .enabling else { return }
                        self.downloadProgress = max(0, min(1, value))
                    }
                }
                try Task.checkCancellation()
                guard self.generation == selected, self.settings.meetingPIIRedactionRequested else { return }
                self.settings.meetingPIIRedactionEnabled = true
                self.state = .active
            } catch {
                guard self.generation == selected else { return }
                self.state = error is CancellationError ? .off : .failed(error.localizedDescription)
            }
            if self.generation == selected { self.operation = nil; self.downloadProgress = nil }
        }
    }

    func waitUntilReadyIfRequested() async throws {
        guard isRequested else { return }
        if operation == nil, state != .active { setEnabled(true) }
        await operation?.value
        try Task.checkCancellation()
        guard state == .active else { throw MeetingProcessingError.modelUnavailable }
    }
}

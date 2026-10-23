#if os(macOS)
import Foundation

/// Freezes the existing dictation history destination and privacy choices at capture start.
/// The retained controller can finish this one output while its private interface is concealed.
@MainActor final class PrivateDictationCaptureOutput {
    let id: UUID
    let profile: PrivateProfileSnapshot
    let history: TranscriptionHistoryStore
    let admission: DictationHistoryWriteAdmission?
    let savesAudio: Bool
    let transcriptionModel: String
    private var audioWrites: [Task<Void, Never>] = []

    init(id: UUID, savesHistory: Bool, savesAudio: Bool, transcriptionModel: String,
         history: TranscriptionHistoryStore? = nil) throws {
        self.id = id
        self.profile = PrivateProfileStorage.current
        self.history = history ?? TranscriptionHistoryStore.shared
        self.savesAudio = savesHistory && savesAudio
        self.transcriptionModel = transcriptionModel
        self.admission = savesHistory ? try self.history.admitRecordingWrite() : nil
    }

    var isVisible: Bool {
        PrivateProfileStorage.isReadable(profile) && PrivateProfileStorage.acceptsNewWork
    }

    func saveAudio(_ snapshot: DictationAudioSnapshot?, timestamp: Date, model: String) {
        guard savesAudio, let snapshot, let admission else { return }
        let audio: DictationAudioSaveAdmission
        do { audio = try admission.admitAudioSave(timestamp: timestamp) }
        catch { return }
        let worker = Task.detached(priority: .utility) {
            defer { audio.complete() }
            do {
                let metadata = try audio.save(snapshot: snapshot, model: model)
                try await admission.attachAudio(metadata, from: audio)
            } catch {
                audio.discardUnattached()
                // A concealed capture must not repopulate the next profile's logger/UI.
                await MainActor.run {
                    if self.isVisible {
                        DebugLogger.shared.error("Failed to save dictation audio", source: "ContentView")
                    }
                }
            }
        }
        audioWrites.append(worker)
    }

    func finish() async {
        for worker in audioWrites { await worker.value }
        audioWrites.removeAll()
        do { try await admission?.finish() }
        catch {
            // The history store retains the admitted payload for an explicit cleanup retry.
            if isVisible {
                DebugLogger.shared.error("Dictation history requires a persistence retry", source: "ContentView")
            }
        }
    }
}
#endif

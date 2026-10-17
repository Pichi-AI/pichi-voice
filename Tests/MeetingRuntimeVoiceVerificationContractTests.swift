import Foundation

// Compile the actual production encoder-admission method against a synthetic encoder.
// The test never installs or loads an encoder, voice profile, model or personal recording.
nonisolated enum AppBrand {
    static let storageNamespace = "owner-verification-contract-tests"
    static func format(_ key: String, _ value: String) -> String { key.replacingOccurrences(of: "%@", with: value) }
}
nonisolated struct MeetingSpeakerVoiceSamples: Sendable {}
nonisolated struct MeetingSpeakerVoiceProfile: Sendable {}
nonisolated enum MeetingPCMRuntimeDiagnostics {
    enum Phase { case voice }
    static func begin(_ phase: Phase) -> Int { 0 }
    static func completed(_ phase: Phase, since: Int, samples: Int) {}
}
nonisolated final class EncoderCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func record() { self.lock.withLock { self.calls += 1 } }
    var count: Int { self.lock.withLock { self.calls } }
}
nonisolated enum MeetingSpeakerVoiceEncoder {
    static let calls = EncoderCalls()
    static func encode(samples: [MeetingSpeakerVoiceSamples], directory: URL,
                       validateDefaultRoot: Bool) throws -> [MeetingSpeakerVoiceProfile] {
        self.calls.record()
        return [.init()]
    }
}
private nonisolated struct LegacyInjectedLocator: MeetingNemotronModelLocating {
    func locate() throws -> MeetingNemotronModelArtifact { throw Refusal.notUsed }
    func recheck(_ artifact: MeetingNemotronModelArtifact) throws -> MeetingNemotronModelArtifact { throw Refusal.notUsed }
}
private nonisolated enum Refusal: Error { case notUsed }

@main struct MeetingRuntimeVoiceVerificationContractTests {
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "OwnerVerificationContract", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func main() async throws {
        for profile in MeetingNemotronModelProfile.allCases {
            let locator: any MeetingNemotronModelLocating = MeetingNemotronModelLocator(profile: profile)
            let enabled = locator.supportsOwnerVoiceVerification
            let runtime = VoiceVerificationProbe(verificationEnabled: enabled)
            let before = MeetingSpeakerVoiceEncoder.calls.count
            let result = try await runtime.speakerVoiceProfiles(samples: [.init()])
            try require(result.count == (enabled ? 1 : 0), "Only the frozen profile's optional owner stage can produce embeddings")
            try require(MeetingSpeakerVoiceEncoder.calls.count == before + (enabled ? 1 : 0),
                        "Anonymous retained retries cannot invoke an encoder missing from their resource plan")
            let empty = try await runtime.speakerVoiceProfiles(samples: [])
            try require(empty.isEmpty && MeetingSpeakerVoiceEncoder.calls.count == before + (enabled ? 1 : 0),
                        "Empty voice work cannot load a model")
        }
        let legacy: any MeetingNemotronModelLocating = LegacyInjectedLocator()
        try require(legacy.supportsOwnerVoiceVerification, "An existing injected locator keeps the legacy capability")
        let cancelled = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await VoiceVerificationProbe(verificationEnabled: false).speakerVoiceProfiles(samples: [.init()])
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw Refusal.notUsed } catch is CancellationError {}
        print("PASS actual runtime voice admission, three immutable profiles, legacy existential compatibility and cancellation")
    }
}

import Foundation

// Compile the actual production encoder-admission method against a synthetic encoder.
// The test never installs or loads an encoder, voice profile, model or personal recording.
nonisolated enum AppBrand {
    static let storageNamespace = "owner-verification-contract-tests"
    static func format(_ key: String, _ value: String) -> String { key.replacingOccurrences(of: "%@", with: value) }
}
nonisolated enum MeetingSpeakerVoiceModelArtifacts { static let revision = "synthetic-pinned-voice-revision" }
nonisolated struct MeetingAnalysisEpochID: Hashable, Sendable { var trackID = UUID(); var ordinal = 0 }
nonisolated struct MeetingBackendSpeakerToken: Hashable, Sendable { var analysisEpochID = MeetingAnalysisEpochID(); var label = "probe" }
nonisolated struct MeetingSpeakerIdentityLink: Sendable { let token: MeetingBackendSpeakerToken; let canonicalToken: MeetingBackendSpeakerToken }
nonisolated struct MeetingSpeakerVoiceSamples: Sendable { static let maximumProfiles = 128 }
nonisolated struct MeetingSpeakerVoiceProfile: Sendable {
    var token = MeetingBackendSpeakerToken()
    var embeddings: [[Float]] = [[1] + [Float](repeating: 0, count: 255), [1] + [Float](repeating: 0, count: 255)]
}
nonisolated struct MeetingOwnerVoiceProfileSnapshot: Sendable { let embeddings: [[Float]] }
nonisolated enum MeetingOwnerVoiceProfileStore {
    static func isValid(_ owner: MeetingOwnerVoiceProfileSnapshot) -> Bool {
        let profile = MeetingSpeakerVoiceProfile(embeddings: owner.embeddings)
        return MeetingSpeakerVoiceMatcher.distance(profile, profile).map { $0 <= 0.25 } ?? false
    }
}
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
            try require(profile.acceptsStreamingImplementationFingerprint(profile.implementationFingerprint),
                        "An exact anonymous streaming recipe remains admissible")
            try require(profile.acceptsStreamingImplementationFingerprint(profile.streamingImplementationFingerprint),
                        "The exact current composite recipe remains admissible")
            try require(!profile.verifiesStreamingOwner(implementationFingerprint: profile.implementationFingerprint),
                        "An old anonymous fingerprint cannot authorize owner confirmation")
            try require(profile.verifiesStreamingOwner(implementationFingerprint: profile.streamingImplementationFingerprint)
                        == profile.supportsOwnerVoiceVerification, "Only the exact supported composite enables owner verification")
            for changed in [profile.implementationFingerprint + "-changed", profile.streamingImplementationFingerprint + ";compute=cpuAndGPU"] {
                try require(!profile.acceptsStreamingImplementationFingerprint(changed), "Unregistered recipe changes remain refused")
            }
            try require(profile.acceptsStreamingImplementationFingerprint(profile.legacyOwnerStreamingImplementationFingerprint),
                        "Exact owner-v1 retained recipes remain admissible")
            try require(profile.verifiesStreamingOwner(implementationFingerprint: profile.legacyOwnerStreamingImplementationFingerprint)
                        == profile.supportsOwnerVoiceVerification, "Owner-v1 keeps its original optional encoder")
            try require(!profile.usesAdaptiveStreamingOwnerEvidence(implementationFingerprint: profile.legacyOwnerStreamingImplementationFingerprint),
                        "Owner-v1 cannot silently acquire new clip selection or verification")
            try require(profile.usesAdaptiveStreamingOwnerEvidence(implementationFingerprint: profile.streamingImplementationFingerprint)
                        == profile.supportsOwnerVoiceVerification, "Only the exactV2recipe opts into adaptive evidence")
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
        let legacyAnonymous = MeetingNemotronModelLocator(profile: .experimentalFast128FP16CPU).withoutOwnerVoiceVerification()
        try require(!legacyAnonymous.supportsOwnerVoiceVerification,
                    "A frozen anonymous streaming recipe cannot load the newly supported owner encoder")
        let beforeLegacy = MeetingSpeakerVoiceEncoder.calls.count
        let anonymousResult = try await VoiceVerificationProbe(verificationEnabled: legacyAnonymous.supportsOwnerVoiceVerification)
            .speakerVoiceProfiles(samples: [.init()])
        try require(anonymousResult.isEmpty && MeetingSpeakerVoiceEncoder.calls.count == beforeLegacy,
                    "Resuming a legacy anonymous recipe keeps its original encoder-free resource plan")
        let legacy: any MeetingNemotronModelLocating = LegacyInjectedLocator()
        try require(legacy.supportsOwnerVoiceVerification, "An existing injected locator keeps the legacy capability")
        let cancelled = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await VoiceVerificationProbe(verificationEnabled: false).speakerVoiceProfiles(samples: [.init()])
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw Refusal.notUsed } catch is CancellationError {}
        try ownerPolicyContracts()
        print("PASS actual runtime voice admission, three immutable profiles, legacy existential compatibility and cancellation")
    }
    private static func ownerPolicyContracts() throws {
        let track = UUID()
        func vector(_ angle: Float) -> [Float] { [cos(angle), sin(angle)] + [Float](repeating: 0, count: 254) }
        func profile(_ slot: Int, _ angle: Float, second: Float? = nil, epoch: Int = 0) -> MeetingSpeakerVoiceProfile {
            .init(token: .init(analysisEpochID: .init(trackID: track, ordinal: epoch), label: "slot-\(slot)"),
                embeddings: [vector(angle), vector(second ?? angle)])
        }
        let owner = MeetingOwnerVoiceProfileSnapshot(embeddings: [vector(0), vector(0)])
        let cross = profile(0, 1)
        try require(MeetingOwnerVoiceVerifier.confirmedTokens(owner: owner, profiles: [cross]).isEmpty,
                    "Default/batch/v1 keep their old strict cross-recording decision")
        try require(MeetingOwnerVoiceVerifier.confirmedTokens(owner: owner, profiles: [cross], policy: .streamingV2) == [cross.token],
                    "V2 owner reference distance is separate from anonymous clustering")
        let variable = profile(0, -0.4, second: 0.5)
        try require(MeetingOwnerVoiceVerifier.confirmedTokens(owner: owner, profiles: [variable]).isEmpty,
                    "Old query self-quality remains byte-compatible")
        try require(MeetingOwnerVoiceVerifier.confirmedTokens(owner: owner, profiles: [variable], policy: .streamingV2) == [variable.token],
                    "V2 has a separate bounded query-consistency operating point")
        try require(MeetingSpeakerVoiceMatcher.maximumDistance == 0.25 && MeetingSpeakerVoiceMatcher.ambiguityMargin == 0.10,
                    "Owner policy cannot relax global anonymous clustering")
        try require(MeetingOwnerVoiceVerifier.confirmedTokens(owner: owner, profiles: [profile(0, 1.5)], policy: .streamingV2).isEmpty,
                    "A different reference voice remains unconfirmed")
        try require(MeetingOwnerVoiceVerifier.confirmedTokens(owner: owner, profiles: [profile(0, 0, second: .pi / 2)], policy: .streamingV2).isEmpty,
                    "A reused slot with inconsistent first/latest voices stays anonymous")
        let ambiguous = profile(1, 1.05)
        try require(MeetingOwnerVoiceVerifier.confirmedTokens(owner: owner, profiles: [cross, ambiguous], policy: .streamingV2).isEmpty,
                    "Two plausible owner slots cannot both or arbitrarily become the owner")
        let clear = profile(1, 1.5)
        try require(MeetingOwnerVoiceVerifier.confirmedTokens(owner: owner, profiles: [cross, clear], policy: .streamingV2) == [cross.token],
                    "An independent well-separated participant does not hide the owner")
        let strict = profile(0, 0.2)
        try require(MeetingOwnerVoiceVerifier.confirmedTokens(owner: owner, profiles: [strict, strict]) == [strict.token],
                    "Preserve the exact legacy duplicate-observation behavior")
        try require(MeetingOwnerVoiceVerifier.confirmedTokens(owner: owner, profiles: [strict, strict], policy: .streamingV2).isEmpty,
                    "V2 duplicate evidence for one token cannot manufacture independent identity")
        let colliding = profile(1, 0.2)
        let invalid = MeetingSpeakerIdentityLink(token: colliding.token, canonicalToken: strict.token)
        try require(MeetingOwnerVoiceVerifier.confirmedTokens(owner: owner, profiles: [strict, colliding], identityLinks: [invalid], policy: .streamingV2).isEmpty,
                    "V2 cannot merge two simultaneous slot identities through an invalid link")
        let later = profile(2, 1, epoch: 1)
        let valid = MeetingSpeakerIdentityLink(token: later.token, canonicalToken: cross.token)
        try require(MeetingOwnerVoiceVerifier.confirmedTokens(owner: owner, profiles: [cross, later], identityLinks: [valid], policy: .streamingV2) == [cross.token, later.token],
                    "Validated cross-epoch continuity remains one verified owner")
        let invalidReference = MeetingOwnerVoiceProfileSnapshot(embeddings: [vector(0), vector(.pi / 2)])
        try require(MeetingOwnerVoiceVerifier.confirmedTokens(owner: invalidReference, profiles: [cross], policy: .streamingV2).isEmpty,
                    "Stored reference quality remains strict under V2")
        print("PASS actual ownerV2policy, strict legacy default, global thresholds, independent evidence and ambiguity contracts")
    }

}

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
nonisolated struct MeetingSpeakerVoiceSamples: Sendable {
    static let maximumProfiles = 128
    var token = MeetingBackendSpeakerToken()
    var clips: [[Float]] = []
}
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
nonisolated final class DebugLogger: @unchecked Sendable {
    static let shared = DebugLogger()
    private let lock = NSLock()
    private var lines: [String] = []
    func info(_ message: String, source: String) { self.lock.withLock { self.lines.append(message) } }
    var messages: [String] { self.lock.withLock { self.lines } }
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
            try require(profile.acceptsStreamingImplementationFingerprint(profile.ownerV2StreamingImplementationFingerprint),
                        "Frozen V2 remains admitted without acquiring live inference")
            try require(!profile.verifiesLiveStreamingOwner(implementationFingerprint: profile.ownerV2StreamingImplementationFingerprint)
                        && !profile.verifiesLiveStreamingOwner(implementationFingerprint: profile.legacyOwnerStreamingImplementationFingerprint),
                        "Earlier saved owner recipes preserve final-only verification")
            let exactV3 = profile.ownerV2StreamingImplementationFingerprint + (profile.supportsOwnerVoiceVerification
                ? ";owner-live=serial-v3;owner-retry=2s-to10s-then10s" : "")
            try require(profile.ownerV3StreamingImplementationFingerprint == exactV3,
                        "Frozen V3 retains the exact previously deployed identity")
            try require(profile.streamingImplementationFingerprint == exactV3 + (profile.supportsOwnerVoiceVerification
                ? ";owner-final=live-cadence-v1" : ""),
                        "Only the independently versioned final cadence changes the current recipe")
            try require(profile.acceptsStreamingImplementationFingerprint(exactV3)
                        && profile.verifiesLiveStreamingOwner(implementationFingerprint: exactV3) == profile.supportsOwnerVoiceVerification
                        && profile.usesAdaptiveStreamingOwnerEvidence(implementationFingerprint: exactV3) == profile.supportsOwnerVoiceVerification
                        && profile.verifiesStreamingOwner(implementationFingerprint: exactV3) == profile.supportsOwnerVoiceVerification,
                        "Exact old V3 remains admitted with its original live owner resource contract")
            for old in [profile.implementationFingerprint, profile.legacyOwnerStreamingImplementationFingerprint,
                        profile.ownerV2StreamingImplementationFingerprint, exactV3] {
                try require(!profile.preservesStreamingOwnerCadenceAtEOF(implementationFingerprint: old),
                            "Existing saved recipes cannot silently acquire changed final cadence")
            }
            try require(profile.verifiesLiveStreamingOwner(implementationFingerprint: profile.streamingImplementationFingerprint)
                        == profile.supportsOwnerVoiceVerification
                        && profile.preservesStreamingOwnerCadenceAtEOF(implementationFingerprint: profile.streamingImplementationFingerprint)
                            == profile.supportsOwnerVoiceVerification,
                        "Only the exact supported new recipe enables live owner cadence at EOF")
            let changedFinal = profile.streamingImplementationFingerprint + ";owner-final=unknown"
            try require(!profile.acceptsStreamingImplementationFingerprint(changedFinal)
                        && !profile.preservesStreamingOwnerCadenceAtEOF(implementationFingerprint: changedFinal),
                        "Arbitrary final-cadence suffixes remain inadmissible")
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
        try ownerDiagnosticContracts()
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

    private static func ownerDiagnosticContracts() throws {
        let track = UUID()
        func vector(_ angle: Float) -> [Float] { [cos(angle), sin(angle)] + [Float](repeating: 0, count: 254) }
        func profile(_ slot: Int, _ angle: Float = 0, second: Float? = nil, epoch: Int = 0) -> MeetingSpeakerVoiceProfile {
            .init(token: .init(analysisEpochID: .init(trackID: track, ordinal: epoch), label: "PRIVATE-NAME-\(slot)"),
                  embeddings: [vector(angle), vector(second ?? angle)])
        }
        let owner = MeetingOwnerVoiceProfileSnapshot(embeddings: [vector(0), vector(0)])
        let originalAPI: (MeetingOwnerVoiceProfileSnapshot?, [MeetingSpeakerVoiceProfile], [MeetingSpeakerIdentityLink],
                          MeetingOwnerVoiceVerifier.Policy) -> Set<MeetingBackendSpeakerToken> = MeetingOwnerVoiceVerifier.confirmedTokens
        try require(originalAPI(owner, [profile(0)], [], .legacy) == [profile(0).token],
                    "The original four-argument function API remains source-compatible")
        func check(_ profiles: [MeetingSpeakerVoiceProfile], _ expected: MeetingOwnerVoiceVerifier.Diagnostics.Outcome,
                   policy: MeetingOwnerVoiceVerifier.Policy = .streamingV2,
                   links: [MeetingSpeakerIdentityLink] = [], reference: MeetingOwnerVoiceProfileSnapshot? = owner
        ) throws -> MeetingOwnerVoiceVerifier.Diagnostics {
            var reports: [MeetingOwnerVoiceVerifier.Diagnostics] = []
            let plain = MeetingOwnerVoiceVerifier.confirmedTokens(owner: reference, profiles: profiles, identityLinks: links, policy: policy)
            let observed = MeetingOwnerVoiceVerifier.confirmedTokens(owner: reference, profiles: profiles,
                identityLinks: links, policy: policy, diagnostics: { reports.append($0) })
            try require(plain == observed && reports.count == 1 && reports[0].outcome == expected,
                        "Observing verifier: expected=\(expected.rawValue) actual=\(reports.first?.outcome.rawValue ?? "none") parity=\(plain == observed) count=\(reports.count)")
            let fields = reports[0].diagnosticFields
            try require(!fields.contains("PRIVATE-NAME") && !fields.contains(track.uuidString)
                        && !fields.contains("embeddings") && !fields.contains("nan") && !fields.contains("inf"),
                        "Scalar diagnostics cannot expose synthetic private identifiers, vectors or nonfinite values")
            return reports[0]
        }
        _ = try check([profile(0)], .missingOwner, reference: nil)
        _ = try check([profile(0)], .invalidOwner,
                      reference: .init(embeddings: [vector(0), vector(.pi / 2)]))
        _ = try check([], .noValidCandidates)
        let first = profile(0, 1)
        let confirmed = try check([first, profile(1, 1.5)], .confirmed)
        try require(confirmed.validProfileCount == 2 && confirmed.rejectedProfileCount == 0
                    && confirmed.bestReferenceDistance != nil && confirmed.runnerReferenceDistance != nil
                    && (confirmed.winnerMargin ?? 0) >= 0.1, "Confirmed evidence must report actual competing distances")
        let far = try check([profile(0, 1.5)], .referenceDistance)
        try require((far.bestReferenceDistance ?? 0) > 0.65 && far.winnerMargin == nil,
                    "A lone out-of-reference voice fails the reference gate without inventing a runner")
        let ambiguous = try check([first, profile(1, 1.05)], .winnerMargin)
        try require((ambiguous.winnerMargin ?? 1) < 0.1, "Close independent participants fail the actual ambiguity gate")
        let inconsistent = try check([profile(0, 0, second: .pi / 2)], .noValidCandidates)
        try require(inconsistent.queries.first?.gate == .querySelfDistance
                    && (inconsistent.queries.first?.selfDistance ?? 0) > 0.45
                    && inconsistent.queries.first?.referenceDistance == nil && inconsistent.rejectedProfileCount == 1,
                    "Self rejection reports the measured distance and never computes or invents a reference distance")
        var malformed = profile(5); malformed.embeddings = [[0], [0]]
        let invalid = try check([malformed, first], .confirmed)
        try require(invalid.rejectedProfileCount == 1 && invalid.validProfileCount == 1
                    && invalid.queries.contains { $0.gate == .invalidQuery && $0.selfDistance == nil },
                    "Malformed competitors remain excluded with unavailable scalar measurements")
        let strict = profile(0, 0.2)
        _ = try check([strict, strict], .duplicateTokens)
        _ = try check([strict, strict], .confirmed, policy: .legacy)
        let other = profile(1, 0.2)
        let badLink = MeetingSpeakerIdentityLink(token: other.token, canonicalToken: strict.token)
        _ = try check([strict, other], .invalidLinks, links: [badLink])
        _ = try check([strict, other], .confirmed, policy: .legacy, links: [badLink])
        let later = profile(2, 1.5, epoch: 1)
        let linked = try check([first, later], .referenceDistance,
                              links: [.init(token: later.token, canonicalToken: first.token)])
        try require(linked.validGroupCount == 1 && linked.bestReferenceDistance == far.bestReferenceDistance,
                    "Linked epochs retain their worst all-pairs reference distance")
        let unmeasured = profile(3, 0, epoch: 1)
        let earlyFailure = try check([malformed, unmeasured], .noValidCandidates,
            links: [.init(token: unmeasured.token, canonicalToken: malformed.token)])
        try require(earlyFailure.validProfileCount == 0 && earlyFailure.rejectedProfileCount == 1
                    && earlyFailure.diagnosticFields.contains("skippedProfiles=1"),
                    "A rejected linked group preserves short circuit and labels later observations unmeasured")
        let many = (0..<300).map { profile($0, 0.2) }
        let bounded = try check(many, .winnerMargin, policy: .legacy)
        try require(bounded.queries.count == 128 && bounded.validProfileCount == 300
                    && bounded.diagnosticFields.count < 20_000 && bounded.diagnosticFields.contains("omittedQueries=172"),
                    "Diagnostic storage and output are bounded even beyond the production profile limit")
        let before = DebugLogger.shared.messages.count
        let observer = MeetingPCMRuntimeDiagnostics.ownerVerificationObserver(
            samples: [.init(token: profile(9).token, clips: [[0]]),
                      .init(token: first.token, clips: [[Float](repeating: 0, count: 48_000), [Float](repeating: 0, count: 64_000)])],
            profiles: [first], streaming: true)
        let enabled = ProcessInfo.processInfo.environment["PICHI_MEETING_DETAILED_PROFILE"] == "1"
        try require((observer != nil) == enabled, "Only the exact existing local profiling opt-in enables scalar support logs")
        observer?(confirmed)
        try require(DebugLogger.shared.messages.count == before + (enabled ? 1 : 0),
                    "Disabled diagnostics produce no log; the opt-in uses the ordinary Release info path")
        if enabled {
            try require(DebugLogger.shared.messages.last?.contains("excerptFramesByProfile=[0:48000+64000]") == true,
                        "Clip lengths follow the admitted profile after a skipped encoder input; no source timestamps are invented")
            MeetingPCMRuntimeDiagnostics.ownerVerificationObserver(samples: [.init(token: first.token, clips: [[0]]),
                .init(token: first.token, clips: [[0, 0]])], profiles: [first], streaming: true)?(confirmed)
            try require(DebugLogger.shared.messages.last?.contains("excerptFramesByProfile=[0:unavailable]") == true,
                        "Ambiguous duplicate encoder inputs cannot manufacture clip metadata")
        }
        print("PASS actual owner diagnostic gates, result parity, legacy links, bounded privacy and Release opt-in")
    }

}

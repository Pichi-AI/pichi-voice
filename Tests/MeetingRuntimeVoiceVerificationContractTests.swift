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
            let ownerV1 = profile.implementationFingerprint + (profile.supportsOwnerVoiceVerification
                ? ";voice=wespeaker@synthetic-pinned-voice-revision;owner-stream=bounded-two-3s-v1" : "")
            let ownerV2 = profile.implementationFingerprint + (profile.supportsOwnerVoiceVerification
                ? ";voice=wespeaker@synthetic-pinned-voice-revision;owner-stream=first-latest-3to5s-v2;owner-ref=0.65;owner-self=0.45;owner-margin=0.10;owner-quality-block=0.5s;owner-lookback=16s;owner-horizon=0.36s" : "")
            let ownerV3 = ownerV2 + (profile.supportsOwnerVoiceVerification
                ? ";owner-live=serial-v3;owner-retry=2s-to10s-then10s" : "")
            let ownerV4 = ownerV3 + (profile.supportsOwnerVoiceVerification ? ";owner-confirm=full-two-5s-v4" : "")
            let cadenceV1 = ownerV3 + (profile.supportsOwnerVoiceVerification ? ";owner-final=live-cadence-v1" : "")
            let combined = ownerV4 + (profile.supportsOwnerVoiceVerification ? ";owner-final=live-cadence-v1" : "")
            let continuity = combined + (profile.supportsOwnerVoiceVerification ? ";owner-refresh=measured-continuity-v1" : "")
            try require(profile.legacyOwnerStreamingImplementationFingerprint == ownerV1
                        && profile.ownerV2StreamingImplementationFingerprint == ownerV2
                        && profile.ownerV3StreamingImplementationFingerprint == ownerV3
                        && profile.ownerV4StreamingImplementationFingerprint == ownerV4
                        && profile.ownerCadenceStreamingImplementationFingerprint == cadenceV1
                        && profile.ownerV4CadenceStreamingImplementationFingerprint == combined
                        && profile.streamingImplementationFingerprint == continuity,
                        "Earlier literal recipes remain frozen; current recipe adds measured evidence continuity")
            let recipes: [(String, Bool, Bool, Bool, Bool, Bool)] = [
                (profile.implementationFingerprint, false, false, false, false, false),
                (ownerV1, true, false, false, false, false),
                (ownerV2, true, true, false, false, false),
                (ownerV3, true, true, true, false, false),
                (ownerV4, true, true, true, true, false),
                (cadenceV1, true, true, true, false, true),
                (combined, true, true, true, true, true),
                (continuity, true, true, true, true, true)
            ]
            for (fingerprint, owner, adaptive, live, full, cadence) in recipes {
                let supported = profile.supportsOwnerVoiceVerification
                try require(profile.acceptsStreamingImplementationFingerprint(fingerprint),
                            "Each exact frozen recipe remains admitted")
                try require(profile.verifiesStreamingOwner(implementationFingerprint: fingerprint) == (supported && owner)
                            && profile.usesAdaptiveStreamingOwnerEvidence(implementationFingerprint: fingerprint) == (supported && adaptive)
                            && profile.verifiesLiveStreamingOwner(implementationFingerprint: fingerprint) == (supported && live)
                            && profile.requiresFullStreamingOwnerEvidence(implementationFingerprint: fingerprint) == (supported && full)
                            && profile.preservesStreamingOwnerCadenceAtEOF(implementationFingerprint: fingerprint) == (supported && cadence),
                            "Frozen recipes preserve their independent evidence, live and EOF capabilities")
                try require(profile.preservesStreamingOwnerEvidenceOnInconclusiveRefresh(implementationFingerprint: fingerprint)
                            == (supported && fingerprint == continuity),
                            "Only the current exact recipe may preserve unavailable refresh evidence")
            }
            for fingerprint in [profile.implementationFingerprint, ownerV1, ownerV2, ownerV3, ownerV4, cadenceV1, combined, continuity] {
                for suffix in [";changed", ";compute=cpuAndGPU", ";owner-final=unknown"] {
                    let changed = fingerprint + suffix
                    try require(!profile.acceptsStreamingImplementationFingerprint(changed)
                                && !profile.verifiesStreamingOwner(implementationFingerprint: changed)
                                && !profile.verifiesLiveStreamingOwner(implementationFingerprint: changed)
                                && !profile.usesAdaptiveStreamingOwnerEvidence(implementationFingerprint: changed)
                                && !profile.requiresFullStreamingOwnerEvidence(implementationFingerprint: changed)
                                && !profile.preservesStreamingOwnerCadenceAtEOF(implementationFingerprint: changed)
                                && !profile.preservesStreamingOwnerEvidenceOnInconclusiveRefresh(implementationFingerprint: changed),
                                "Arbitrary suffixes cannot acquire any owner capability")
                }
            }
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
        try ownerV4EvidenceContracts()
        try ownerEvidenceBindingContracts()
        try ownerDiagnosticContracts()
        print("PASS actual runtime voice admission, three immutable profiles, legacy existential compatibility and cancellation")
    }

    private static func ownerEvidenceBindingContracts() throws {
        let first = MeetingSpeakerVoiceProfile()
        let second = MeetingSpeakerVoiceProfile()
        let short = MeetingSpeakerVoiceSamples(token: first.token, clips: [[0], [0, 0]])
        let other = MeetingSpeakerVoiceSamples(token: second.token, clips: [[0, 0, 0], [0, 0, 0, 0]])
        try require(MeetingOwnerVoiceVerifier.clipFramesByToken(samples: [other, short], profiles: [first, second])
                    == [first.token: [1, 2], second.token: [3, 4]],
                    "Frame provenance binds each encoded result to its matching actual input instead of array order")
        try require(MeetingOwnerVoiceVerifier.clipFramesByToken(samples: [other], profiles: [first]).isEmpty,
                    "A skipped or missing encoder input cannot manufacture frame provenance")
        try require(MeetingOwnerVoiceVerifier.clipFramesByToken(samples: [short, short, other], profiles: [first, second])
                    == [second.token: [3, 4]], "Duplicate input tokens invalidate only their own frame provenance")
        try require(MeetingOwnerVoiceVerifier.clipFramesByToken(samples: [short, other], profiles: [first, first, second])
                    == [second.token: [3, 4]], "Duplicate encoded result tokens cannot acquire ambiguous frame provenance")
        for clips in [[], [[Float](repeating: 0, count: 80_000)],
                      [[Float](repeating: 0, count: 80_000), [Float](repeating: 0, count: 80_000), [0]]] {
            try require(MeetingOwnerVoiceVerifier.clipFramesByToken(samples: [.init(token: first.token, clips: clips)], profiles: [first]).isEmpty,
                        "A non-two-clip input stays unknown rather than reporting a mature two-element prefix")
        }
        let full = MeetingSpeakerVoiceSamples(token: first.token,
            clips: [[Float](repeating: 0, count: 80_000), [Float](repeating: 0, count: 80_000)])
        try require(MeetingOwnerVoiceVerifier.clipFramesByToken(samples: [full], profiles: [first]) == [first.token: [80_000, 80_000]],
                    "Exactly two full encoded input clips retain their actual scalar lengths")
        try require(MeetingOwnerVoiceVerifier.clipFramesByToken(samples: Array(repeating: short, count: 129), profiles: [first]).isEmpty
                    && MeetingOwnerVoiceVerifier.clipFramesByToken(samples: [short], profiles: Array(repeating: first, count: 129)).isEmpty,
                    "Frame binding refuses work outside the existing profile bound")
        print("PASS unique bounded encoder-input/result scalar provenance binding")
    }

    private static func ownerV4EvidenceContracts() throws {
        let track = UUID()
        func vector(_ distance: Float) -> [Float] {
            let angle = acos(1 - distance)
            return [cos(angle), sin(angle)] + [Float](repeating: 0, count: 254)
        }
        func profile(_ slot: Int, _ distance: Float, epoch: Int = 0) -> MeetingSpeakerVoiceProfile {
            .init(token: .init(analysisEpochID: .init(trackID: track, ordinal: epoch), label: "slot-\(slot)"),
                  embeddings: [vector(distance), vector(distance)])
        }
        let owner = MeetingOwnerVoiceProfileSnapshot(embeddings: [vector(0), vector(0)])
        let short = profile(0, 0.55)
        let mature = profile(1, 0.58)
        let full = [80_000, 80_000]
        let frames = [short.token: [48_000, 48_000], mature.token: full]
        func check(_ profiles: [MeetingSpeakerVoiceProfile], _ evidence: [MeetingBackendSpeakerToken: [Int]],
                   outcome: MeetingOwnerVoiceVerifier.Diagnostics.Outcome,
                   expected: Set<MeetingBackendSpeakerToken> = [], links: [MeetingSpeakerIdentityLink] = [],
                   reference: MeetingOwnerVoiceProfileSnapshot? = owner
        ) throws -> MeetingOwnerVoiceVerifier.Diagnostics {
            var reports: [MeetingOwnerVoiceVerifier.Diagnostics] = []
            let plain = MeetingOwnerVoiceVerifier.confirmedTokens(owner: reference, profiles: profiles, identityLinks: links,
                policy: .streamingV4, clipFramesByToken: evidence)
            let observed = MeetingOwnerVoiceVerifier.confirmedTokens(owner: reference, profiles: profiles, identityLinks: links,
                policy: .streamingV4, clipFramesByToken: evidence, diagnostics: { reports.append($0) })
            try require(plain == expected && observed == plain && reports.count == 1 && reports[0].outcome == outcome,
                        "Actual V4 result/diagnostic parity: expected=\(outcome.rawValue) actual=\(reports.first?.outcome.rawValue ?? "none")")
            try require(reports[0].diagnosticFields.contains("policy=streamingV4 outcome=\(outcome.rawValue)")
                        && !reports[0].diagnosticFields.contains("slot-")
                        && !reports[0].diagnosticFields.contains(track.uuidString)
                        && reports[0].queries.allSatisfy { ($0.clipFrames?.count ?? 0) <= 2 },
                        "V4 reports its final gate with bounded scalar metadata and no token identity")
            return reports[0]
        }
        let ambiguous = try check([short, mature], frames, outcome: .winnerMargin)
        try require(ambiguous.validProfileCount == 2 && ambiguous.validGroupCount == 2
                    && abs((ambiguous.bestReferenceDistance ?? 0) - 0.55) < 0.0001
                    && abs((ambiguous.runnerReferenceDistance ?? 0) - 0.58) < 0.0001,
                    "A valid short rival participates in actual scoring and margin before maturity")
        let worse = profile(1, 0.64)
        _ = try check([profile(0, 0.20), worse], [short.token: [48_000, 48_000], worse.token: full], outcome: .insufficientEvidence)
        let winner = profile(0, 0.20)
        _ = try check([winner], [winner.token: full], outcome: .missingOwner, reference: nil)
        _ = try check([winner], [winner.token: full], outcome: .invalidOwner,
                      reference: .init(embeddings: [vector(0), vector(1)]))
        let confirmed = try check([winner, worse], [winner.token: full, worse.token: [48_000, 48_000]],
                                  outcome: .confirmed, expected: [winner.token])
        try require(confirmed.queries.first { $0.ordinal == 0 }?.hasFullEvidence == true
                    && confirmed.queries.first { $0.ordinal == 1 }?.hasFullEvidence == false,
                    "Each query's maturity comes from its own bound entry, including short competitors")
        for invalid in [[], [80_000], [48_000, 48_000], [80_000, 79_999], [80_000, 80_001],
                        [0, 80_000], [-1, 80_000], [80_000, 80_000, 80_000]] {
            let report = try check([winner], [winner.token: invalid], outcome: .insufficientEvidence)
            try require(report.queries.first?.hasFullEvidence == false
                        && report.queries.first?.clipCount == invalid.count
                        && report.queries.first?.clipFrames == Array(invalid.prefix(2)),
                        "Only exactly two actual full five-second clip lengths make the winning evidence mature")
        }
        let unknown = try check([winner], [:], outcome: .insufficientEvidence)
        try require(unknown.queries.first?.clipCount == nil && unknown.queries.first?.clipFrames == nil
                    && unknown.queries.first?.hasFullEvidence == false,
                    "Missing cache provenance cannot be inferred from two embeddings")
        _ = try check([winner], [worse.token: full], outcome: .insufficientEvidence)
        _ = try check([winner, winner], [winner.token: full], outcome: .duplicateTokens)
        let colliding = profile(1, 0.20)
        _ = try check([winner, colliding], [winner.token: full, colliding.token: full], outcome: .invalidLinks,
                      links: [.init(token: colliding.token, canonicalToken: winner.token)])
        _ = try check([profile(0, 0.70)], [winner.token: full], outcome: .referenceDistance)
        var inconsistent = winner
        inconsistent.embeddings = [vector(0), vector(1)]
        _ = try check([inconsistent], [winner.token: full], outcome: .noValidCandidates)
        var malformed = winner; malformed.embeddings = [[0], [0]]
        _ = try check([malformed], [winner.token: full], outcome: .noValidCandidates)
        let later = profile(2, 0.20, epoch: 1)
        let links = [MeetingSpeakerIdentityLink(token: later.token, canonicalToken: winner.token)]
        _ = try check([winner, later], [winner.token: full, later.token: [48_000, 48_000]],
                      outcome: .insufficientEvidence, links: links)
        _ = try check([winner, later], [winner.token: full], outcome: .insufficientEvidence, links: links)
        _ = try check([winner, later], [winner.token: full, later.token: full],
                      outcome: .confirmed, expected: [winner.token, later.token], links: links)
        let farLater = profile(2, 0.70, epoch: 1)
        _ = try check([winner, farLater], [winner.token: full, farLater.token: full], outcome: .referenceDistance,
                      links: [.init(token: farLater.token, canonicalToken: winner.token)])
        for policy in [MeetingOwnerVoiceVerifier.Policy.legacy, .streamingV2] {
            for evidence in [[:], [winner.token: [-1]]] {
                try require(MeetingOwnerVoiceVerifier.confirmedTokens(owner: owner, profiles: [winner], policy: policy,
                    clipFramesByToken: evidence) == [winner.token], "Legacy and V2 ignore new clip metadata")
            }
        }
        let many = (0..<300).map { profile($0, 0.20) }
        let bounded = try check(many, Dictionary(uniqueKeysWithValues: many.map { ($0.token, full) }), outcome: .winnerMargin)
        try require(bounded.queries.count == 128 && bounded.validProfileCount == 300
                    && bounded.diagnosticFields.count < 20_000 && bounded.diagnosticFields.contains("omittedQueries=172"),
                    "V4 duration diagnostics retain the existing scalar count and output bounds")
        try require(MeetingOwnerVoiceVerifier.Policy.streamingV4.maximumReferenceDistance == 0.65
                    && MeetingOwnerVoiceVerifier.Policy.streamingV4.maximumQuerySelfDistance == 0.45
                    && MeetingOwnerVoiceVerifier.Policy.streamingV4.ambiguityMargin == 0.10,
                    "V4 changes full-evidence admission without tuning score thresholds")
        print("PASS actual V4 scoring before maturity, short rivals, no fallback, linked evidence and frozen thresholds")
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
                          MeetingOwnerVoiceVerifier.Policy) -> Set<MeetingBackendSpeakerToken> = { owner, profiles, links, policy in
            MeetingOwnerVoiceVerifier.confirmedTokens(owner: owner, profiles: profiles, identityLinks: links, policy: policy)
        }
        try require(originalAPI(owner, [profile(0)], [], .legacy) == [profile(0).token],
                    "Original four-argument calls retain source compatibility through defaulted metadata")
        let evidenceAPI: (MeetingOwnerVoiceProfileSnapshot?, [MeetingSpeakerVoiceProfile], [MeetingSpeakerIdentityLink],
                          MeetingOwnerVoiceVerifier.Policy, [MeetingBackendSpeakerToken: [Int]]) -> Set<MeetingBackendSpeakerToken>
            = MeetingOwnerVoiceVerifier.confirmedTokens
        try require(evidenceAPI(owner, [profile(0)], [], .streamingV4, [profile(0).token: [80_000, 80_000]]) == [profile(0).token],
                    "The evidence function API binds the full metadata input")
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

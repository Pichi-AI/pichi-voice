import Foundation

/// Synthetic contracts and metamorphic properties, not claims about acoustic model accuracy.
@main
struct MeetingSpeakerAttributionTests {
    nonisolated static let epoch = MeetingAnalysisEpochID(trackID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, ordinal: 0)
    static var checks = 0

    static func check(_ condition: Bool, _ message: String = #function, line: Int = #line) {
        self.checks += 1
        guard condition else { fatalError("Check failed line \(line): \(message)") }
    }

    static func token(_ label: String, epoch: MeetingAnalysisEpochID = Self.epoch) -> MeetingBackendSpeakerToken {
        .init(analysisEpochID: epoch, label: label)
    }

    static func unit(
        _ id: String, _ start: Double, _ end: Double, _ speaker: MeetingBackendSpeakerAssignment = .unassigned,
        epoch: MeetingAnalysisEpochID = Self.epoch, precision: MeetingTextUnitPrecision = .word
    ) -> MeetingFinalTextUnit {
        .init(id: id, trackID: epoch.trackID, analysisEpochID: epoch, precision: precision, text: "word-\(id)",
              analysisStart: start, analysisEnd: end, speaker: speaker, analysisSpanIDs: ["span"])
    }

    static func activity(_ label: String, _ start: Double, _ end: Double, epoch: MeetingAnalysisEpochID = Self.epoch)
        -> MeetingBackendSpeakerActivity { .init(token: self.token(label, epoch: epoch), start: start, end: end) }

    static func resolve(
        _ units: [MeetingFinalTextUnit], _ activity: [MeetingBackendSpeakerActivity],
        // This corpus also verifies replay of the frozen policy before complete reading.
        // Current-default coverage lives beside the native assembler integration regressions.
        policy: MeetingSpeakerAttributionPolicy = .init(enableProvisionalSpeakerIdentities: true,
            enableStableSpeakerOpening: true), barriers: Set<String> = [],
        epochs: Set<MeetingAnalysisEpochID> = [],
        contextualBarriers: [MeetingSpeakerAttributionContextBarrier] = []
    ) throws -> [MeetingSpeakerAttributionDecision] {
        try MeetingSpeakerAttribution.resolve(units: units, activity: activity, policy: policy,
                                              barrierUnitIDs: barriers, contextualBarrierEpochIDs: epochs, contextualBarriers: contextualBarriers)
    }

    // Replay the previously frozen interruption policy independently of the new default.
    static func resolveLegacy(
        _ units: [MeetingFinalTextUnit], _ activity: [MeetingBackendSpeakerActivity],
        policy: MeetingSpeakerAttributionPolicy = .init(enableMainSpeakerContinuation: false, enableIndependentAcousticAnchors: false),
        barriers: Set<String> = [], epochs: Set<MeetingAnalysisEpochID> = []
    ) throws -> [MeetingSpeakerAttributionDecision] {
        try self.resolve(units, activity, policy: policy, barriers: barriers, epochs: epochs)
    }

    static func expectError(_ body: () throws -> Void) {
        do { try body(); self.check(false, "Expected a typed attribution error") }
        catch is MeetingSpeakerAttributionError { self.check(true) }
        catch { self.check(false, "Unexpected error \(error)") }
    }

    static func main() async throws {
        try self.acoustics()
        try self.initialAcousticProjection()
        try self.neighbors()
        try self.independentAcousticAnchors()
        try self.mixedIncomingNeighbors()
        self.neighborAdmission()
        try self.sameSpeakerPauses()
        try self.interruptions()
        try self.interruptionWordSupport()
        try self.mainSpeakerContinuation()
        try self.independentReplyBoundaries()
        try self.continuationAdmission()
        try self.scopeAndChronology()
        try self.contextBarrierIntervals()
        try self.invalidInputsAndCoding()
        try self.metamorphic()
        try self.exactBoundaries()
        try await self.cancellation()
        try self.scale()
        print("Meeting speaker attribution: \(self.checks) checks passed")
    }

    static func neighborAdmission() {
        let policy = MeetingSpeakerAttributionPolicy.standard
        func admitted(
            _ values: [(Double, Double)], policy: MeetingSpeakerAttributionPolicy = .standard,
            sameSpeaker: Bool = false
        ) -> Bool {
            MeetingSpeakerAttribution.admitsNeighborRun(values.map { .init(start: $0.0, end: $0.1) },
                                                        policy: policy, sameSpeaker: sameSpeaker)
        }
        for (before, start, end, after) in [(2.96, 3.28, 3.32, 3.44), (17.52, 17.64, 17.68, 17.84),
                                           (69.32, 69.88, 69.92, 70.04), (97.80, 97.88, 97.92, 98.40)] {
            self.check(admitted([(before - 0.1, before), (start, end), (after, after + 0.1)]))
        }
        self.check(admitted([(0, 1), (1, 1 + policy.maximumUnknownRunSeconds),
                             (1 + policy.maximumUnknownRunSeconds, 5)]))
        self.check(!admitted([(0, 1), (1, 1 + policy.maximumUnknownRunSeconds + 0.01), (4.6, 5)]))
        self.check(admitted([(0, 1), (1.8, 2), (2.8, 3)]))
        self.check(!admitted([(0, 1), (1.81, 2), (2.8, 3)]))
        self.check(!admitted([(0, 1), (0.9, 2), (2, 3)]))
        self.check(!admitted([(0, 1), (1, 2), (1.9, 3)]))
        self.check(!admitted([(0, 1), (1, 1), (1, 2)]))
        self.check(!admitted([(0, 1), (.nan, 2), (2, 3)]))
        self.check(!admitted([(-1, 0), (0, 1), (1, 2)]))
        self.check(!admitted([(0, 1), (1, .infinity), (2, 3)]))
        self.check(!admitted([(0, 1), (1, 2)]))
        self.check(!admitted([(0, 1), (1, 2), (2, 3)], policy: .init(enableNeighborResolution: false)))
        for offset in [0.0, 10_000.0] {
            func shifted(_ values: [(Double, Double)]) -> [(Double, Double)] {
                values.map { ($0.0 + offset, $0.1 + offset) }
            }
            let exactBudget = shifted([(0, 1), (3.68, 4.1), (6.1, 6.3)])
            self.check(admitted(exactBudget, sameSpeaker: true), "Matching anchors lost the exact 5.1-second budget")
            self.check(!admitted(exactBudget), "Different or unspecified anchors shared a pause budget")
            self.check(!admitted(exactBudget, policy: .init(enableSameSpeakerPauseResolution: false), sameSpeaker: true))
            self.check(!admitted(shifted([(0, 1), (3.68, 4.1), (6.100_001, 6.3)]), sameSpeaker: true))
            self.check(admitted(shifted([(0, 1), (2.6, 6.1), (6.1, 6.3)]), sameSpeaker: true))
            self.check(!admitted(shifted([(0, 1), (2.5, 6.000_001), (6.1, 6.3)]), sameSpeaker: true),
                       "Sharing pauses expanded the 3.5-second unknown-span cap")
            self.check(admitted(shifted([(0, 1), (1.1, 1.2), (2.2, 2.3), (3.2, 3.4)]), sameSpeaker: true))
            self.check(!admitted(shifted([(0, 1), (0.9, 1.2), (3.2, 3.4)]), sameSpeaker: true))
            self.check(!admitted(shifted([(0, 1), (1.1, 1.3), (1.2, 1.4), (3.2, 3.4)]), sameSpeaker: true))
            self.check(!admitted(shifted([(0, 1), (1.1, 1.3), (1.2, 1.4)]), sameSpeaker: true))
        }
        func blocked(_ values: [(Double, Double)]) -> Set<Int> {
            MeetingSpeakerAttribution.overlappingIntervalIndices(values.map { .init(start: $0.0, end: $0.1) },
                tolerance: policy.comparisonTolerance, checkpoint: { _ in })
        }
        self.check(blocked([(0, 10), (1, 2), (2, 2.1), (2.1, 3)]) == Set(0..<4))
        self.check(blocked([(0, 1), (1, 2), (2, 2.1), (2.1, 3)]).isEmpty)
        self.check(blocked([(0, 1), (0, 10), (2, 3)]) == Set(0..<3))
        self.check(blocked([(0, 4), (1, 2), (3, 5), (4.5, 6), (6, 7)]) == Set(0..<4))
        self.check(blocked([(0, 1), (2, 3), (2.5, 4), (5, 6)]) == [1, 2])
        self.check(blocked([]).isEmpty)
    }

    static func acoustics() throws {
        let a = self.token("a"), b = self.token("b")
        let simple = try self.resolve([self.unit("x", 0, 1, .assigned(a))], [self.activity("a", 0, 1)])[0]
        self.check(simple.rawAssignment == .assigned(a) && simple.selectedToken == a)
        self.check(simple.activeSupportSeconds == 1 && simple.rule == .singleAcousticSupport)
        let absent = try self.resolve([self.unit("x", 0, 1, .assigned(a))], [])[0]
        self.check(absent.selectedToken == a && absent.rule == .rawOnly)
        let conflict = try self.resolve([self.unit("x", 0, 1, .assigned(a))], [self.activity("b", 0, 1)])[0]
        self.check(conflict.relation == .conflict && conflict.selectedToken == nil)
        self.check(conflict.candidates.count == 2 && conflict.candidates.first { $0.token == a }?.supportSeconds == 0)
        let partialConflict = try self.resolve([self.unit("x", 0, 1, .ambiguous([a, b]))], [self.activity("a", 0, 1)])[0]
        self.check(partialConflict.relation == .conflict && partialConflict.selectedToken == nil)
        let halfOpen = try self.resolve([self.unit("x", 0, 1)], [self.activity("a", 0, 1), self.activity("b", 1, 2)])[0]
        self.check(halfOpen.candidates.count == 1 && halfOpen.selectedToken == a)
        let consecutive = try self.resolve([self.unit("x", 0, 2)], [self.activity("a", 0, 1.8), self.activity("b", 1.8, 2)])[0]
        self.check(consecutive.relation == .consecutive && consecutive.selectedToken == nil)
        let overlap = try self.resolve([self.unit("x", 0, 1, .ambiguous([a, b]))],
                                       [self.activity("a", 0, 1), self.activity("b", 0.25, 0.75)])[0]
        self.check(overlap.relation == .simultaneous && overlap.selectedToken == nil)
        self.check(overlap.simultaneousIntervals == [.init(tokens: [a, b], interval: .init(start: 0.25, end: 0.75))])
        let three = try self.resolve([self.unit("x", 0, 1)], [self.activity("a", 0, 1), self.activity("b", 0.5, 0.8), self.activity("c", 0.6, 0.7)])[0]
        self.check(three.selectedToken == nil && three.candidates.count == 3)
        self.check(three.simultaneousIntervals.contains { $0.tokens.count == 3 })
        let tiny = try self.resolve([self.unit("x", 0, 1)], [self.activity("a", 0.5, 0.51)])[0]
        self.check(tiny.rule == .singleAcousticSupport && tiny.candidates.count == 1)
        self.check(!tiny.candidates[0].isSuppressed && tiny.candidates[0].supportSeconds > 0)
        let residual = try self.resolve([self.unit("x", 0, 1)], [self.activity("a", 0, 0.5), self.activity("b", 0.25, 0.255)])[0]
        self.check(residual.candidates.first { $0.token == b }?.isSuppressed == true)
        var padded: [MeetingSpeakerAttributionDecision] = []
        for end in [0.4, 0.6, 0.8, 3.0] {
            padded.append(try self.resolve([self.unit("x", 0, end)], [self.activity("a", 0, 0.3), self.activity("b", 0.2, 0.3)])[0])
        }
        self.check(padded.dropFirst().allSatisfy { $0 == padded[0] }, "Silent padding changed the acoustic decision")
        let dominant = try self.resolve([self.unit("x", 0, 2)], [self.activity("a", 0, 1), self.activity("b", 0.2, 0.3)])[0]
        self.check(dominant.rule == .acousticDominance && dominant.selectedToken == a && dominant.rule.isHeuristic)
        for assignment in [MeetingBackendSpeakerAssignment.unassigned, .assigned(b)] {
            let residual = try self.resolve([self.unit("residual", 0, 0.1, assignment)],
                                            [self.activity("a", 0, 0.095), self.activity("b", 0.095, 0.1)])[0]
            self.check(residual.selectedToken == a && residual.rule == .residualSuppression && residual.rule.isHeuristic)
            self.check(residual.rawAssignment == assignment && residual.relation == .consecutive)
            self.check(residual.candidates.first { $0.token == b }?.supportSeconds ?? 0 > 0)
        }
        self.check(!simple.rule.isHeuristic, "Direct sole-source evidence was marked as a policy inference")
        let utterance = try self.resolve([self.unit("x", 0, 2, precision: .utterance)], [self.activity("a", 0, 1), self.activity("b", 0.2, 0.3)])[0]
        self.check(utterance.selectedToken == nil && utterance.rule == .ambiguous)
        let merged = try MeetingSpeakerAttribution.unionedIntervals([.init(start: 0, end: 1), .init(start: 1, end: 2), .init(start: 0.5, end: 1.5)])
        self.check(merged == [.init(start: 0, end: 2)])
    }

    static func initialAcousticProjection() throws {
        let a = self.token("a"), b = self.token("b")
        let words = [self.unit("left", 0, 0.2), self.unit("unknown", 0.3, 0.5), self.unit("right", 0.6, 0.8)]
        let activity = [self.activity("a", 0, 0.2), self.activity("b", 0.6, 0.8)]
        let assigned = try MeetingSpeakerAttribution.acousticAssignments(units: words, activity: activity)
        self.check(assigned.count == 3 && assigned["left"] == .assigned(a) && assigned["right"] == .assigned(b))
        self.check(assigned["unknown"] == .unassigned, "Initial acoustic projection ran contextual interpolation")
        let mixedActivity = [self.activity("a", 0, 1), self.activity("b", 0.4, 0.5)]
        let mixed = [self.unit("word", 0, 1), self.unit("utterance", 0, 1, precision: .utterance)]
        let projection = try MeetingSpeakerAttribution.acousticAssignments(units: mixed, activity: mixedActivity)
        self.check(projection["word"] == .assigned(a))
        self.check(projection["utterance"] == .ambiguous([a, b]))
        self.expectError {
            _ = try MeetingSpeakerAttribution.acousticAssignments(units: [self.unit("assigned", 0, 1, .assigned(a))], activity: [])
        }
        self.expectError {
            _ = try MeetingSpeakerAttribution.acousticAssignments(units: [self.unit("bad", .nan, 1)], activity: [])
        }
        self.expectError {
            _ = try MeetingSpeakerAttribution.acousticAssignments(units: [words[0], words[0]], activity: activity)
        }
        let epochs: Set<MeetingAnalysisEpochID> = [Self.epoch]
        let direct = try MeetingSpeakerAttribution.resolve(units: words, activity: activity, contextualBarrierEpochIDs: epochs)
        self.check(direct.allSatisfy { !$0.rule.isHeuristic })
        for decision in direct {
            if let selected = decision.selectedToken { self.check(assigned[decision.unitID] == .assigned(selected)) }
            else { self.check(assigned[decision.unitID] == .unassigned) }
        }
    }

    static func neighbors() throws {
        let a = self.token("a"), b = self.token("b")
        let units = [self.unit("left", 0, 0.2, .assigned(a)), self.unit("unknown", 0.3, 0.5), self.unit("right", 0.6, 0.8, .assigned(b))]
        let activity = [self.activity("a", 0, 0.2), self.activity("b", 0.6, 0.8)]
        let incoming = try self.resolve(units, activity)[1]
        self.check(incoming.rule == .incomingSpeaker && incoming.selectedToken == b)
        self.check(incoming.rawAssignment == .unassigned && incoming.cueUnitIDs == ["left", "right"])
        let agreementUnits = [units[0], units[1], self.unit("right", 0.6, 0.8, .assigned(a))]
        let agreement = try self.resolve(agreementUnits, [self.activity("a", 0, 0.2), self.activity("a", 0.6, 0.8)])[1]
        self.check(agreement.rule == .neighborAgreement && agreement.selectedToken == a)
        let boundary = try self.resolve(units, activity + [self.activity("a", 0.3, 0.32)])[1]
        self.check(boundary.rule == .singleAcousticSupport && boundary.selectedToken == a)
        let multi = [units[0], self.unit("tail", 0.3, 0.5), self.unit("later", 0.6, 0.7), self.unit("right", 0.8, 1, .assigned(b))]
        let mixed = try self.resolve(multi, [self.activity("a", 0, 0.2), self.activity("a", 0.3, 0.32), self.activity("b", 0.8, 1)])
        self.check(mixed[1].rule == .singleAcousticSupport && mixed[1].selectedToken == a)
        self.check(mixed[2].selectedToken == nil, "A raw-unassigned outgoing tail became a contextual anchor")
        let blocked = try self.resolve(units, activity, barriers: ["unknown"])[1]
        self.check(blocked.rule == .barrier && blocked.selectedToken == nil)
        let scopeBlocked = try self.resolve(units, activity, epochs: [Self.epoch])[1]
        self.check(scopeBlocked.selectedToken == nil)
        let noActivity = try self.resolve(units, [])
        self.check(noActivity[1].selectedToken == nil && noActivity[0].rule == .rawOnly)
        let noRight = try self.resolve(Array(units.prefix(2)), activity)[1]
        self.check(noRight.selectedToken == nil)
        let noLeft = try self.resolve(Array(units.suffix(2)), activity)[0]
        self.check(noLeft.selectedToken == nil)
        let longGap = [units[0], self.unit("unknown", 1.1, 1.2), self.unit("right", 1.3, 1.5, .assigned(b))]
        self.check(try self.resolve(longGap, [activity[0], self.activity("b", 1.3, 1.5)])[1].selectedToken == nil)
        let longRun = [units[0], self.unit("unknown", 0.3, 4), self.unit("right", 4.1, 4.3, .assigned(b))]
        self.check(try self.resolve(longRun, [activity[0], self.activity("b", 4.1, 4.3)])[1].selectedToken == nil)
        let noCascade = [units[0], self.unit("first", 0.3, 0.4), self.unit("acoustic", 0.5, 0.7), self.unit("second", 0.8, 0.9), self.unit("right", 1, 1.2, .assigned(b))]
        let noCascadeOutput = try self.resolve(noCascade, [activity[0], self.activity("a", 0.5, 0.7), self.activity("b", 1, 1.2)])
        self.check(noCascadeOutput[1].selectedToken == nil && noCascadeOutput[3].selectedToken == nil)
        let contradictory = [units[0], self.unit("unknown", 0.3, 0.5, .assigned(self.token("c"))), units[2]]
        self.check(try self.resolve(contradictory, activity + [self.activity("c", 0.3, 0.5)])[1].selectedToken == self.token("c"))
        let utterance = [units[0], self.unit("unknown", 0.3, 0.5, precision: .utterance), units[2]]
        self.check(try self.resolve(utterance, activity)[1].selectedToken == nil)
        let foreignWeak = try self.resolve(units, activity + [self.activity("c", 0.3, 0.32)])[1]
        self.check(foreignWeak.selectedToken == self.token("c") && foreignWeak.rule == .singleAcousticSupport)
    }

    static func mixedIncomingNeighbors() throws {
        let a = self.token("a"), c = self.token("c")
        for offset in [0.0, 10_000.0] {
            let left = self.unit("left", offset, offset + 0.2, .assigned(a))
            let right = self.unit("right", offset + 0.7, offset + 0.9, .assigned(c))
            let activity = [self.activity("a", offset, offset + 0.2), self.activity("a", offset + 0.3, offset + 0.6),
                            self.activity("c", offset + 0.3, offset + 0.6), self.activity("c", offset + 0.7, offset + 0.9)]
            for raw in [MeetingBackendSpeakerAssignment.unassigned, .ambiguous([a, c]), .assigned(a)] {
                let words = [left, self.unit("mixed", offset + 0.3, offset + 0.6, raw), right]
                let original = try self.resolve(words, activity, epochs: [Self.epoch])[1]
                self.check(original.selectedToken == nil && original.rule == .ambiguous)
                let incoming = try self.resolve(words, activity)[1]
                self.check(incoming.selectedToken == c && incoming.rule == .incomingSpeaker)
                self.check(incoming.cueUnitIDs == ["left", "right"] && incoming.backgroundTokens.isEmpty)
                self.check(incoming.rawAssignment == original.rawAssignment && incoming.candidates == original.candidates
                           && incoming.simultaneousIntervals == original.simultaneousIntervals
                           && incoming.activeSupportSeconds == original.activeSupportSeconds && incoming.relation == original.relation)
                let legacy = try self.resolve(words, activity, policy: .init(enableMainSpeakerContinuation: false))[1]
                self.check(legacy.selectedToken == nil && legacy.rule == .ambiguous)
                let third = try self.resolve(words, activity + [self.activity("b", offset + 0.4, offset + 0.5)])[1]
                self.check(third.selectedToken == nil && third.rule == .ambiguous && third.candidates.count == 3,
                           "Incoming attribution consumed a voice outside both anchors")
                for barrier in ["left", "mixed", "right"] {
                    self.check(try self.resolve(words, activity, barriers: [barrier])[1].rule != .incomingSpeaker)
                }
                let utterance = [left, self.unit("mixed", offset + 0.3, offset + 0.6, raw, precision: .utterance), right]
                self.check(try self.resolve(utterance, activity)[1].selectedToken == nil)
            }
            let mixedRun = [left] + (0..<5).map {
                self.unit("mixed-\($0)", offset + 0.3 + Double($0) * 0.05,
                          offset + 0.35 + Double($0) * 0.05, .ambiguous([a, c]))
            } + [right]
            let runOutput = try self.resolve(mixedRun, activity)
            self.check(runOutput[1...5].allSatisfy { $0.selectedToken == c && $0.rule == .incomingSpeaker },
                       "A contiguous mixed run between different anchors retained an uncertainty island")
            // The contextual path cannot replace an already selected acoustic foreground.
            let dominant = [left, self.unit("dominant", offset + 0.3, offset + 0.6, .ambiguous([a, c])), right]
            let strongA = [activity[0], activity[1], self.activity("c", offset + 0.4, offset + 0.41), activity[3]]
            let foreground = try self.resolve(dominant, strongA)[1]
            self.check(foreground.selectedToken == a && foreground.rule == .residualSuppression)
            // Matching A anchors reject C under the incoming rule and use the later explicit
            // continuation convention, with original overlap evidence retained.
            let same = [left, dominant[1], self.unit("right", offset + 0.7, offset + 0.9, .assigned(a))]
            let sameActivity = Array(activity.dropLast()) + [self.activity("a", offset + 0.7, offset + 0.9)]
            self.check(try self.resolve(same, sameActivity)[1].rule == .mainSpeakerContinuation)
        }
    }

    static func sameSpeakerPauses() throws {
        let a = self.token("a"), b = self.token("b")
        for offset in [0.0, 10_000.0] {
            for pause in [0.84, 1.08, 1.36, 1.92, 2.68] {
                for pauseBefore in [true, false] {
                    let start = offset + 1 + (pauseBefore ? pause : 0.1)
                    let end = start + 0.1
                    let right = end + (pauseBefore ? 0.1 : pause)
                    let units = [self.unit("left", offset, offset + 1, .assigned(a)),
                                 self.unit("unknown", start, end),
                                 self.unit("right", right, right + 0.2, .assigned(a))]
                    let activity = [self.activity("a", offset, offset + 1), self.activity("a", right, right + 0.2)]
                    let result = try self.resolve(units, activity)[1]
                    self.check(result.selectedToken == a && result.rule == .neighborAgreement)
                    self.check(result.rawAssignment == .unassigned && result.cueUnitIDs == ["left", "right"])
                    self.check(result.candidates.isEmpty && result.activeSupportSeconds == 0)
                    let disabled = try self.resolve(units, activity, policy: .init(enableSameSpeakerPauseResolution: false))[1]
                    self.check(disabled.selectedToken == nil, "Disabled pause policy changed the old per-gap rule")
                    let different = [units[0], units[1], self.unit("right", right, right + 0.2, .assigned(b))]
                    let differentActivity = [activity[0], self.activity("b", right, right + 0.2)]
                    self.check(try self.resolve(different, differentActivity)[1].selectedToken == nil)
                    self.check(try self.resolve(units, activity, barriers: ["unknown"])[1].selectedToken == nil)
                    let gap = MeetingSpeakerAttributionContextBarrier(analysisEpochID: Self.epoch,
                        interval: .init(start: offset + 1, end: start))
                    self.check(try self.resolve(units, activity, contextualBarriers: [gap])[1].selectedToken == nil)
                    self.check(try self.resolve(units, [activity[0]])[1].selectedToken == nil,
                               "A raw-only right identity became an independent acoustic anchor")
                }
            }
            for (right, expected) in [(6.1, true), (6.100_001, false)] {
                let units = [self.unit("left", offset, offset + 1, .assigned(a)),
                             self.unit("unknown", offset + 3.68, offset + 4.1),
                             self.unit("right", offset + right, offset + right + 0.2, .assigned(a))]
                let result = try self.resolve(units, [self.activity("a", offset, offset + 1),
                                                      self.activity("a", offset + right, offset + right + 0.2)])[1]
                self.check((result.selectedToken == a) == expected)
            }
        }
    }

    static func interruptions() throws {
        let a = self.token("a"), b = self.token("b")
        let units = [self.unit("left", 0, 0.2, .assigned(a)), self.unit("mix", 0.3, 0.8, .ambiguous([a, b])), self.unit("right", 0.9, 1.1, .assigned(a))]
        let activity = [self.activity("a", 0, 1.1), self.activity("b", 0.4, 0.6)]
        let output = try self.resolveLegacy(units, activity)
        self.check(output[1].rule == .briefInterruption && output[1].selectedToken == b)
        self.check(output[1].backgroundTokens == [a] && output[1].rawAssignment == units[1].speaker)
        self.check(output[1].simultaneousIntervals == [.init(tokens: [a, b], interval: .init(start: 0.4, end: 0.6))])
        let split = [units[0], self.unit("mix1", 0.3, 0.5, .ambiguous([a, b])), self.unit("mix2", 0.5, 0.8, .ambiguous([a, b])), units[2]]
        let splitOutput = try self.resolveLegacy(split, activity)
        self.check(splitOutput[1].rule == .briefInterruption && splitOutput[2].rule == .briefInterruption)
        self.check(splitOutput[1].selectedToken == b && splitOutput[2].selectedToken == b)
        let gapWords = [units[0], self.unit("gapmix1", 0.3, 0.45, .ambiguous([a, b])),
                        self.unit("gapmix2", 0.6, 0.8, .ambiguous([a, b])), units[2]]
        let gapActivity = [self.activity("a", 0, 1.1), self.activity("b", 0.35, 0.7)]
        let noThird = try self.resolveLegacy(gapWords, gapActivity)
        self.check(noThird[1].rule == .briefInterruption && noThird[2].rule == .briefInterruption)
        let hiddenThird = try self.resolveLegacy(gapWords, gapActivity + [self.activity("c", 0.5, 0.55)])
        self.check(hiddenThird[1].rule != .briefInterruption && hiddenThird[2].rule != .briefInterruption,
                   "A third voice in the full bout was hidden by the gap between ASR words")
        self.check(hiddenThird[1].selectedToken == nil && hiddenThird[2].selectedToken == nil)
        self.check(hiddenThird[1].candidates == noThird[1].candidates && hiddenThird[2].candidates == noThird[2].candidates)
        let contextThird = try self.resolveLegacy(gapWords, gapActivity + [self.activity("c", 0.22, 0.25)])
        self.check(contextThird[1].rule != .briefInterruption && contextThird[2].rule != .briefInterruption)
        let outsideThird = try self.resolveLegacy(gapWords, gapActivity + [self.activity("c", 1.2, 1.3)])
        self.check(outsideThird[1].rule == .briefInterruption && outsideThird[2].rule == .briefInterruption)
        let nativeBMiddle = [units[0], self.unit("mix1", 0.3, 0.45, .ambiguous([a, b])), self.unit("bword", 0.45, 0.55, .assigned(b)), self.unit("mix2", 0.55, 0.8, .ambiguous([a, b])), units[2]]
        let nativeBActivity = [self.activity("a", 0, 0.45), self.activity("a", 0.55, 1.1), self.activity("b", 0.4, 0.6)]
        let nativeBOutput = try self.resolveLegacy(nativeBMiddle, nativeBActivity)
        self.check(nativeBOutput[1].rule == .briefInterruption && nativeBOutput[3].rule == .briefInterruption)
        self.check(nativeBOutput[2].rule == .singleAcousticSupport && nativeBOutput[2].selectedToken == b)
        let missingMain = try self.resolveLegacy(units, [self.activity("a", 0, 0.2), self.activity("a", 0.9, 1.1), self.activity("b", 0.4, 0.6)])[1]
        self.check(missingMain.rule != .briefInterruption && missingMain.relation == .conflict)
        let tinyB = try self.resolveLegacy(units, [self.activity("a", 0, 1.1), self.activity("b", 0.4, 0.401)])[1]
        self.check(tinyB.rule != .briefInterruption)
        let three = try self.resolveLegacy(units, activity + [self.activity("c", 0.45, 0.55)])[1]
        self.check(three.rule != .briefInterruption && three.selectedToken == nil)
        let barrier = try self.resolveLegacy(units, activity, barriers: ["mix"])[1]
        self.check(barrier.rule == .barrier && barrier.selectedToken == nil)
        let utterance = [units[0], self.unit("mix", 0.3, 0.8, .ambiguous([a, b]), precision: .utterance), units[2]]
        self.check(try self.resolveLegacy(utterance, activity)[1].selectedToken == nil)
        let longB = try self.resolveLegacy(units, [self.activity("a", 0, 1.1), self.activity("b", 0.4, 3)])[1]
        self.check(longB.rule != .briefInterruption)
        let noOutgoing = [self.unit("left", 0, 0.2, .assigned(b)), units[1], units[2]]
        self.check(try self.resolveLegacy(noOutgoing, activity)[1].rule != .briefInterruption)
        let disabled = try self.resolveLegacy(units, activity, policy: .init(enableBriefInterruption: false, enableMainSpeakerContinuation: false))[1]
        self.check(disabled.rule != .briefInterruption)
        let consecutive = try self.resolveLegacy(units, [self.activity("a", 0, 0.4), self.activity("b", 0.4, 0.8), self.activity("a", 0.9, 1.1)])[1]
        self.check(consecutive.relation == .consecutive && consecutive.rule != .briefInterruption)
        let fragmented = [self.activity("a", 0, 1.1), self.activity("b", 0.4, 0.45), self.activity("b", 0.47, 0.52), self.activity("b", 0.54, 0.6)]
        self.check(try self.resolveLegacy(units, fragmented)[1].rule == .briefInterruption)
        let twoBouts = [self.activity("a", 0, 1.1), self.activity("b", 0.31, 0.42), self.activity("b", 0.65, 0.78)]
        self.check(try self.resolveLegacy(units, twoBouts)[1].rule != .briefInterruption)
    }

    static func interruptionWordSupport() throws {
        // The whole interrupter bout establishes conversational roles, but does not make a
        // few milliseconds at an adjacent word boundary sufficient to own that whole word.
        for offset in [0.0, 10_000.0] {
            for labels in [("a", "b"), ("renamed-main", "renamed-interrupter")] {
                let a = self.token(labels.0), b = self.token(labels.1)
                let native = [self.unit("left", offset, offset + 0.2),
                              self.unit("leading", offset + 0.3, offset + 0.5),
                              self.unit("mixed1", offset + 0.5, offset + 0.7),
                              self.unit("mixed2", offset + 0.7, offset + 0.9),
                              self.unit("trailing", offset + 0.9, offset + 1.1),
                              self.unit("right", offset + 1.2, offset + 1.4)]
                let activity = [self.activity(labels.0, offset, offset + 1.4),
                                self.activity(labels.1, offset + 0.495, offset + 0.905)]
                let projection = try MeetingSpeakerAttribution.acousticAssignments(units: native, activity: activity)
                let units = native.map { self.unit($0.id, $0.analysisStart, $0.analysisEnd, projection[$0.id]!) }
                let base = try self.resolveLegacy(units, activity, epochs: [Self.epoch])
                let output = try self.resolveLegacy(units, activity)
                for position in [1, 4] {
                    self.check(output[position] == base[position], "Suppressed interrupter stole an adjacent word")
                    self.check(output[position].selectedToken == a && output[position].rule == .residualSuppression)
                    self.check(output[position].candidates.first { $0.token == b }?.isSuppressed == true)
                }
                for position in [2, 3] {
                    self.check(output[position].selectedToken == b && output[position].rule == .briefInterruption)
                    self.check(output[position].backgroundTokens == [a] && output[position].cueUnitIDs == ["left", "right"])
                    self.check(output[position].rawAssignment == units[position].speaker
                               && output[position].candidates == base[position].candidates
                               && output[position].simultaneousIntervals == base[position].simultaneousIntervals)
                }
                let fragmented = activity.flatMap { entry in
                    let middle = (entry.start + entry.end) / 2
                    return [entry, MeetingBackendSpeakerActivity(token: entry.token, start: entry.start, end: middle),
                            MeetingBackendSpeakerActivity(token: entry.token, start: middle, end: entry.end)]
                }
                self.check(try self.resolveLegacy(units.reversed(), fragmented.reversed()) == output,
                           "Word-level interruption eligibility depended on interval fragmentation or ordering")
                // A real short word may be wholly inside the bout. Reusing the relative
                // candidate gate must not become an absolute minimum duration per ASR word.
                let short = [self.unit("left", offset, offset + 0.2, .assigned(a)),
                             self.unit("short", offset + 0.5, offset + 0.508, .ambiguous([a, b])),
                             self.unit("right", offset + 0.9, offset + 1.1, .assigned(a))]
                let shortOutput = try self.resolveLegacy(short, [self.activity(labels.0, offset, offset + 1.1),
                                                          self.activity(labels.1, offset + 0.4, offset + 0.6)])
                self.check(shortOutput[1].selectedToken == b && shortOutput[1].rule == .briefInterruption)
                self.check(shortOutput[1].candidates.allSatisfy { !$0.isSuppressed })
            }
            for (start, suppressed) in [(0.46, false), (0.460_001, true)] {
                let a = self.token("a"), b = self.token("b")
                let units = [self.unit("left", offset, offset + 0.2, .assigned(a)),
                             self.unit("edge", offset + 0.3, offset + 0.5, .ambiguous([a, b])),
                             self.unit("mixed", offset + 0.5, offset + 0.8, .ambiguous([a, b])),
                             self.unit("right", offset + 0.9, offset + 1.1, .assigned(a))]
                let output = try self.resolveLegacy(units, [self.activity("a", offset, offset + 1.1),
                                                      self.activity("b", offset + start, offset + 0.65)])
                self.check(output[1].candidates.first { $0.token == b }?.isSuppressed == suppressed)
                self.check(output[1].selectedToken == (suppressed ? a : b))
                self.check(output[1].rule == (suppressed ? .residualSuppression : .briefInterruption))
                self.check(output[2].selectedToken == b && output[2].rule == .briefInterruption)
            }
        }
    }

    static func mainSpeakerContinuation() throws {
        let a = self.token("a"), b = self.token("b")
        for offset in [0.0, 10_000.0] {
            let left = self.unit("left", offset, offset + 0.2, .assigned(a))
            let right = self.unit("right", offset + 0.9, offset + 1.1, .assigned(a))
            let activity = [self.activity("a", offset, offset + 1.1), self.activity("b", offset + 0.4, offset + 0.6)]
            for raw in [MeetingBackendSpeakerAssignment.ambiguous([a, b]), .assigned(b), .unassigned] {
                let words = [left, self.unit("mixed", offset + 0.3, offset + 0.8, raw), right]
                let original = try self.resolve(words, activity, epochs: [Self.epoch])
                let output = try self.resolve(words, activity)
                let mixed = output[1]
                self.check(mixed.selectedToken == a && mixed.rule == .mainSpeakerContinuation && mixed.rule.isHeuristic)
                self.check(mixed.backgroundTokens.isEmpty && mixed.cueUnitIDs == ["left", "right"])
                self.check(mixed.rawAssignment == raw && mixed.candidates == original[1].candidates)
                self.check(mixed.activeSupportSeconds == original[1].activeSupportSeconds
                           && mixed.simultaneousIntervals == original[1].simultaneousIntervals && mixed.relation == original[1].relation)
                self.check(output[0] == original[0] && output[2] == original[2])
                self.check(try self.resolve(words.reversed(), activity.reversed()) == output)
                for barrier in ["left", "mixed", "right"] {
                    self.check(try self.resolve(words, activity, barriers: [barrier])[1].rule != .mainSpeakerContinuation)
                }
                let gap = MeetingSpeakerAttributionContextBarrier(analysisEpochID: Self.epoch,
                    interval: .init(start: offset + 0.2, end: offset + 0.3))
                self.check(try self.resolve(words, activity, contextualBarriers: [gap])[1].rule != .mainSpeakerContinuation)
                self.check(try self.resolve(words, activity, epochs: [Self.epoch])[1].rule != .mainSpeakerContinuation)
                for position in words.indices {
                    var changed = words
                    changed[position] = self.unit(words[position].id, words[position].analysisStart,
                        words[position].analysisEnd, words[position].speaker, precision: .utterance)
                    self.check(try self.resolve(changed, activity)[1].rule != .mainSpeakerContinuation)
                }
                self.check(try self.resolve(Array(words.dropLast()), activity)[1].rule != .mainSpeakerContinuation)
                self.check(try self.resolve(Array(words.dropFirst()), activity)[0].rule != .mainSpeakerContinuation)
                self.check(try self.resolve(words, activity + [self.activity("c", offset + 0.22, offset + 0.25)])[1].rule == .mainSpeakerContinuation)
                let several = try self.resolve(words, activity + [self.activity("c", offset + 0.45, offset + 0.55)])[1]
                self.check(several.rule == .mainSpeakerContinuation && several.selectedToken == a)
                self.check(several.candidates.count == 3 && several.simultaneousIntervals.contains { $0.tokens.count == 3 },
                           "Reading ownership erased original third-voice evidence")
                let overlap = words + [self.unit("nested", offset + 0.35, offset + 0.45)]
                self.check(try self.resolve(overlap, activity).first { $0.unitID == "mixed" }?.rule != .mainSpeakerContinuation)
            }
            let cleanActivity = [self.activity("a", offset, offset + 0.2), self.activity("b", offset + 0.3, offset + 0.8),
                                 self.activity("a", offset + 0.9, offset + 1.1)]
            for raw in [MeetingBackendSpeakerAssignment.assigned(b), .unassigned] {
                let clean = [left, self.unit("reply", offset + 0.3, offset + 0.8, raw), right]
                let cleanOutput = try self.resolve(clean, cleanActivity)
                self.check(cleanOutput[1].selectedToken == b && cleanOutput[1].rule == .singleAcousticSupport,
                           "A clean distinct reply lost its speaker")
            }
            let noAnchors = [self.unit("left", offset, offset + 0.2),
                             self.unit("mixed", offset + 0.3, offset + 0.8, .ambiguous([a, b])),
                             self.unit("right", offset + 0.9, offset + 1.1)]
            self.check(try self.resolve(noAnchors, activity)[1].rule != .mainSpeakerContinuation)
            let adjacent = [left, self.unit("unknown1", offset + 0.25, offset + 0.3),
                            self.unit("mixed", offset + 0.4, offset + 0.7, .ambiguous([a, b])),
                            self.unit("unknown2", offset + 0.75, offset + 0.8), right]
            let sparse = [self.activity("a", offset, offset + 0.2), self.activity("a", offset + 0.4, offset + 0.7),
                          self.activity("b", offset + 0.45, offset + 0.6), self.activity("a", offset + 0.9, offset + 1.1)]
            let filled = try self.resolve(adjacent, sparse)
            for position in 1...3 {
                self.check(filled[position].selectedToken == a && filled[position].rule == .mainSpeakerContinuation)
                self.check(filled[position].backgroundTokens.isEmpty)
            }
            self.check(filled[1].candidates.isEmpty && filled[3].candidates.isEmpty)
            let wholeBout = [left, self.unit("mixed1", offset + 0.3, offset + 0.45, .ambiguous([a, b])),
                             self.unit("clean-b", offset + 0.45, offset + 0.55, .assigned(b)),
                             self.unit("mixed2", offset + 0.55, offset + 0.8, .ambiguous([a, b])), right]
            let boutActivity = [self.activity("a", offset, offset + 0.45),
                                self.activity("a", offset + 0.55, offset + 1.1), self.activity("b", offset + 0.4, offset + 0.6)]
            let boutOutput = try self.resolve(wholeBout, boutActivity)
            for position in 1...3 {
                self.check(boutOutput[position].selectedToken == b,
                           "Mixed context cannot swallow an independently supported reply")
            }
            self.check(boutOutput[2].rule == .singleAcousticSupport)
            self.check(boutOutput[2].rawAssignment == .assigned(b) && boutOutput[2].relation == .single)
            self.check(boutOutput[2].candidates.map(\.token) == [b] && boutOutput[2].candidates[0].supportSeconds > 0)
            self.check(try self.resolve(wholeBout.reversed(), boutActivity.reversed()) == boutOutput)
            let frozenBout = try self.resolve(wholeBout, boutActivity, policy: .init(preserveIndependentSpeakerTurns: false))
            self.check(frozenBout[1...3].allSatisfy { $0.selectedToken == a && $0.rule == .mainSpeakerContinuation },
                       "A frozen older policy must retain its previous ownership semantics")
            let nearestOwner = [self.unit("older-a", offset + 3.5, offset + 3.7, .assigned(a)),
                                self.unit("main-b", offset + 4.6, offset + 4.8, .assigned(b)),
                                self.unit("mixed-before", offset + 4.9, offset + 5.1, .ambiguous([a, b])),
                                self.unit("interior-a", offset + 5.2, offset + 5.4, .assigned(a)),
                                self.unit("mixed-after", offset + 5.5, offset + 5.7, .ambiguous([a, b])),
                                self.unit("return-b", offset + 6, offset + 6.2, .assigned(b))]
            let nearestActivity = [self.activity("a", offset + 3.5, offset + 3.7),
                                   self.activity("b", offset + 4.6, offset + 5.1),
                                   self.activity("a", offset + 4.9, offset + 5.7),
                                   self.activity("b", offset + 5.5, offset + 6.2)]
            let nearest = try self.resolve(nearestOwner, nearestActivity)
            self.check(nearest[0].selectedToken == a && nearest[0].rule == .singleAcousticSupport,
                       "An earlier independent A word changed ownership")
            self.check(nearest[1].selectedToken == b && nearest[1].rule == .singleAcousticSupport)
            for position in 2...4 {
                self.check(nearest[position].selectedToken == a,
                           "A clean reply starts a new turn even when a different participant returns")
            }
            self.check(nearest[3].rule == .singleAcousticSupport)
            self.check(nearest[3].rawAssignment == .assigned(a) && nearest[3].candidates.map(\.token) == [a])
            self.check(try self.resolve(nearestOwner.reversed(), nearestActivity.reversed()) == nearest)
            let old = try self.resolve([left, adjacent[2], right], sparse, policy: .init(enableMainSpeakerContinuation: false))
            self.check(old[1].selectedToken == b && old[1].rule == .briefInterruption && old[1].backgroundTokens == [a])
            for target in [MeetingAnalysisEpochID(trackID: Self.epoch.trackID, ordinal: 1),
                           MeetingAnalysisEpochID(trackID: Self.epoch.trackID, ordinal: 0, generation: 1),
                           MeetingAnalysisEpochID(trackID: UUID(), ordinal: 0)] {
                let split = [left, adjacent[2], self.unit("right", right.analysisStart, right.analysisEnd,
                    .assigned(self.token("a", epoch: target)), epoch: target)]
                let splitActivity = Array(sparse.dropLast()) + [self.activity("a", right.analysisStart, right.analysisEnd, epoch: target)]
                self.check(try self.resolve(split, splitActivity).first { $0.unitID == "mixed" }?.rule != .mainSpeakerContinuation)
            }
            for (start, end, after, expected) in [(3.68, 4.1, 6.1, true), (3.68, 4.1, 6.100_001, false),
                                                (1.1, 4.6, 4.7, true), (1.1, 4.600_001, 4.7, false)] {
                let words = [self.unit("left", offset, offset + 1, .assigned(a)),
                             self.unit("mixed", offset + start, offset + end, .ambiguous([a, b])),
                             self.unit("right", offset + after, offset + after + 0.2, .assigned(a))]
                let support = [self.activity("a", offset, offset + 1), self.activity("a", offset + start, offset + end),
                               self.activity("b", offset + start, offset + end), self.activity("a", offset + after, offset + after + 0.2)]
                self.check((try self.resolve(words, support)[1].rule == .mainSpeakerContinuation) == expected,
                           "Continuation did not honor exact span/pause budgets")
            }
        }
    }

    static func independentReplyBoundaries() throws {
        let a = self.token("a"), b = self.token("b"), c = self.token("c")
        for offset in [0.0, 815.48, 6_243.68, 10_000.0] {
            for duration in [0.04, 0.1, 0.56, 1.0] {
                for reply in [b, c] {
                    let replyStart = offset + 0.7, replyEnd = replyStart + duration
                    let words = [self.unit("before", offset, offset + 0.2, .assigned(a)),
                                 self.unit("mixed-before", offset + 0.3, offset + 0.6, .ambiguous([a, reply])),
                                 self.unit("independent-reply", replyStart, replyEnd, .assigned(reply)),
                                 self.unit("mixed-after", replyEnd + 0.1, replyEnd + 0.4, .ambiguous([a, reply])),
                                 self.unit("return", replyEnd + 0.5, replyEnd + 0.7, .assigned(a))]
                    let activity = [self.activity("a", offset, offset + 0.6),
                                    self.activity(reply.label, offset + 0.4, replyEnd + 0.3),
                                    self.activity("a", replyEnd + 0.1, replyEnd + 0.7)]
                    let result = try self.resolve(words, activity)
                    let independent = try self.resolve(words, activity, epochs: [Self.epoch])[2]
                    self.check(result[2] == independent && result[2].rule == .singleAcousticSupport
                               && result[2].selectedToken == reply,
                               "A genuinely independent short reply must retain its original acoustic decision")
                    self.check(result[0].selectedToken == a && result[4].selectedToken == a)
                    self.check(try self.resolve(words.reversed(), activity.reversed()) == result)
                    let frozen = try self.resolve(words, activity, policy: .init(preserveIndependentSpeakerTurns: false))
                    self.check(frozen[2].selectedToken == a && frozen[2].rule == .mainSpeakerContinuation,
                               "The synthetic regression must reproduce the old mixed-bout swallowing defect")
                }
            }
        }
    }

    static func independentAcousticAnchors() throws {
        for rule in [MeetingSpeakerAttributionRule.singleAcousticSupport, .residualSuppression, .acousticDominance] {
            self.check(rule.isIndependentAcousticSelection)
        }
        for rule in [MeetingSpeakerAttributionRule.rawOnly, .rawAssigned, .ambiguous, .conflict, .barrier,
                     .neighborAgreement, .incomingSpeaker, .boundaryContinuation, .briefInterruption, .mainSpeakerContinuation, .existingParticipantContext] {
            self.check(!rule.isIndependentAcousticSelection, "Contextual results cannot become acoustic anchors")
        }
        for offset in [0.0, 70.0, 3600.0] {
            for dominance in [false, true] {
                for same in [false, true] {
                    let a = token("a"), b = token(same ? "a" : "b")
                    let words = [unit("left", offset, offset + 1, .assigned(a)),
                                 unit("gap", offset + 1.1, offset + 1.2),
                                 unit("right", offset + 1.3, offset + 2.3, .assigned(b))]
                    let noise = dominance ? 0.15 : 0.02
                    let support = [activity("a", offset, offset + 1), activity("noise", offset + 0.1, offset + 0.1 + noise),
                                   activity(b.label, offset + 1.3, offset + 2.3), activity("noise", offset + 1.4, offset + 1.4 + noise)]
                    let baseline = try resolve(words, support, policy: .init(enableIndependentAcousticAnchors: false))
                    let changed = try resolve(words, support)
                    self.check(baseline[1].selectedToken == nil, "Frozen older attempts retain old anchor behavior")
                    self.check(changed[0].rule == (dominance ? .acousticDominance : .residualSuppression))
                    self.check(changed[2].rule == changed[0].rule)
                    self.check(changed[1].selectedToken == b && changed[1].rule == (same ? .neighborAgreement : .incomingSpeaker))
                    self.check(changed[0].rawAssignment == baseline[0].rawAssignment && changed[0].candidates == baseline[0].candidates)
                    for raw in [MeetingBackendSpeakerAssignment.unassigned, .ambiguous([a, token("noise")])] {
                        var missingOriginal = words; missingOriginal[0] = unit("left", offset, offset + 1, raw)
                        self.check(try resolve(missingOriginal, support)[1].selectedToken == nil,
                                   "A selected token without original assigned native evidence cannot reanchor context")
                    }
                    self.check(try resolve(Array(words.dropLast()), support)[1].selectedToken == nil,
                               "A contextual output cannot supply a missing independent future anchor")
                    var conflict = support.filter { $0.start >= offset + 1.3 }
                    conflict.append(activity("wrong", offset, offset + 1))
                    self.check(try resolve(words, conflict)[1].selectedToken == nil)
                    self.check(try resolve(words, support, barriers: ["left"])[1].selectedToken == nil)
                }
            }
        }
        let intervals: [MeetingSpeakerAttributionInterval] = [.init(start: 0, end: 1), .init(start: 1.1, end: 1.2), .init(start: 1.3, end: 2)]
        self.check(try MeetingSpeakerAttribution.neighborRuns(intervals: intervals, eligible: [false, true, false],
            anchorIdentities: ["a", nil, "b"], candidateIdentities: [[], ["c"], []], policy: .standard).isEmpty,
                   "A third voice cannot be swallowed by endpoint context")
        self.check(try MeetingSpeakerAttribution.neighborRuns(intervals: intervals, eligible: [false, true, false],
            anchorIdentities: ["a", nil, nil], candidateIdentities: [[], [], []], policy: .standard).isEmpty)
        for dominance in [false, true] {
            let a = token("a"), b = token("b")
            let words = [unit("main-before", 0, 0.4, .assigned(a)),
                         unit("mixed-acoustic-b", 0.5, 1.5, .assigned(b)),
                         unit("main-after", 1.6, 2, .assigned(a))]
            let residual = dominance ? 0.15 : 0.02
            let support = [activity("a", 0, 0.4), activity("b", 0.5, 1.5),
                           activity("a", 0.6, 0.6 + residual), activity("a", 1.6, 2)]
            let output = try resolve(words, support)
            self.check(output[1].selectedToken == a && output[1].rule == .mainSpeakerContinuation,
                       "An independent mixed B selection cannot erase the preceding A before detecting A/B/A continuity")
            self.check(output[1].rawAssignment == .assigned(b), "Reading continuity preserves independent native evidence")
        }
    }

    static func continuationAdmission() throws {
        typealias Interval = MeetingSpeakerAttributionInterval
        let intervals: [Interval] = [.init(start: 0, end: 0.2), .init(start: 0.3, end: 0.4),
                                     .init(start: 0.5, end: 0.6), .init(start: 0.7, end: 0.8)]
        func runs(_ values: [Interval] = intervals, candidates: [Bool] = [false, true, true, false],
                  interruptions: [Bool] = [false, false, true, false], anchors: [Bool] = [true, false, false, true],
                  same: Bool = true, policy: MeetingSpeakerAttributionPolicy = .standard) throws
            -> [MeetingSpeakerAttribution.ContinuationRun] {
            try MeetingSpeakerAttribution.continuingSpeakerRuns(intervals: values, candidates: candidates,
                interruptions: interruptions,
                anchorIdentities: anchors.enumerated().map { index, anchor -> String? in
                    anchor ? (same || index == 0 ? "a" : "b") : nil
                }, policy: policy)
        }
        self.check(try runs() == [.init(first: 1, last: 2, before: 0, after: 3)])
        self.check(try runs(same: false).isEmpty)
        self.check(try runs(interruptions: [false, false, false, false]).isEmpty)
        self.check(try runs(candidates: [false, true, false, false]).isEmpty)
        self.check(try runs(anchors: [false, false, false, true]).isEmpty)
        self.check(try runs(policy: .init(enableMainSpeakerContinuation: false)).isEmpty)
        self.check(try runs(policy: .init(enableNeighborResolution: false)).isEmpty)
        self.check(try runs(candidates: []).isEmpty)
        self.check(try runs(interruptions: []).isEmpty)
        self.check(try runs(anchors: []).isEmpty)
        self.check(try runs(Array(intervals.reversed())).isEmpty)
        for invalid in [Interval(start: .nan, end: 0.4), .init(start: 0.3, end: .infinity),
                        .init(start: 0.4, end: 0.4), .init(start: -1, end: 0.4), .init(start: 0.3, end: 0.5)] {
            var values = intervals; values[1] = invalid
            if invalid.end == 0.5 { values[2] = .init(start: 0.4, end: 0.6) }
            self.check(try runs(values).isEmpty)
        }
        // A remote overlap cluster does not suppress a later independent chronological run.
        let values = [Interval(start: 0, end: 2), .init(start: 1, end: 1.5)]
            + intervals.map { Interval(start: $0.start + 3, end: $0.end + 3) }
        self.check(try runs(values, candidates: [false, false, false, true, true, false],
                            interruptions: [false, false, false, false, true, false],
                            anchors: [true, true, true, false, false, true]) == [.init(first: 3, last: 4, before: 2, after: 5)])
        // Frozen older policies let the nearest original owner consume interior speakers.
        // The current policy instead treats independent nonmixed replies as turn boundaries.
        let alternating = (0..<9).map { Interval(start: Double($0) * 0.3, end: Double($0) * 0.3 + 0.2) }
        let identities: [String?] = ["a", nil, "b", nil, "a", nil, "b", nil, "a"]
        let expected: [MeetingSpeakerAttribution.ContinuationRun] = [.init(first: 1, last: 3, before: 0, after: 4),
                                                                   .init(first: 5, last: 7, before: 4, after: 8)]
        self.check(try MeetingSpeakerAttribution.continuingSpeakerRuns(intervals: alternating,
            candidates: Array(repeating: true, count: 9), interruptions: [false, true, false, true, false, true, false, true, false],
            anchorIdentities: identities, policy: .init(preserveIndependentSpeakerTurns: false)) == expected)
        self.check(try MeetingSpeakerAttribution.continuingSpeakerRuns(intervals: alternating,
            candidates: Array(repeating: true, count: 9), interruptions: [false, true, false, true, false, true, false, true, false],
            anchorIdentities: identities, policy: .standard).isEmpty)
        self.check(try MeetingSpeakerAttribution.continuingSpeakerRuns(intervals: alternating,
            candidates: Array(repeating: true, count: 9), interruptions: Array(repeating: false, count: 9),
            anchorIdentities: identities, policy: .standard).isEmpty)
        let uuidA = UUID(), uuidB = UUID()
        self.check(try MeetingSpeakerAttribution.continuingSpeakerRuns(intervals: alternating,
            candidates: Array(repeating: true, count: 9), interruptions: [false, true, false, true, false, true, false, true, false],
            anchorIdentities: identities.map { $0.map { $0 == "a" ? uuidA : uuidB } },
            policy: .init(preserveIndependentSpeakerTurns: false)) == expected,
                   "Saved UUID identities changed generic continuation admission")
        self.check(try MeetingSpeakerAttribution.continuingSpeakerRuns(intervals: alternating,
            candidates: Array(repeating: true, count: 9), interruptions: [false, true, false, true, false, true, false, true, false],
            anchorIdentities: identities.map { $0.map { $0 == "a" ? uuidA : uuidB } }, policy: .standard).isEmpty,
                   "Independent turn boundaries must not depend on a model token representation")
        let antiHijack = (0..<6).map { Interval(start: Double($0) * 0.3, end: Double($0) * 0.3 + 0.2) }
        self.check(try MeetingSpeakerAttribution.continuingSpeakerRuns(intervals: antiHijack,
            candidates: Array(repeating: true, count: 6), interruptions: [false, false, true, false, true, false],
            anchorIdentities: ["a", "b", nil, "a", nil, "b"], policy: .init(preserveIndependentSpeakerTurns: false))
            == [.init(first: 2, last: 4, before: 1, after: 5)])
        let expired = [Interval(start: 0, end: 0.2), .init(start: 0.3, end: 0.5), .init(start: 1, end: 1.2),
                       .init(start: 5, end: 5.2), .init(start: 5.3, end: 5.5)]
        self.check(try MeetingSpeakerAttribution.continuingSpeakerRuns(intervals: expired,
            candidates: Array(repeating: true, count: 5), interruptions: [false, true, false, true, false],
            anchorIdentities: ["a", nil, "b", nil, "b"], policy: .standard)
            == [.init(first: 3, last: 3, before: 2, after: 4)],
                   "An expired bout did not yield to the nearest later clean speaker")
        let barrierReset = (0..<6).map { Interval(start: Double($0) * 0.3, end: Double($0) * 0.3 + 0.2) }
        self.check(try MeetingSpeakerAttribution.continuingSpeakerRuns(intervals: barrierReset,
            candidates: [true, true, false, true, true, true], interruptions: [false, true, false, false, true, false],
            anchorIdentities: ["a", nil, nil, "b", nil, "b"], policy: .standard)
            == [.init(first: 4, last: 4, before: 3, after: 5)])
        let largeCount = 100_000
        let dense = (0..<largeCount).map { Interval(start: Double($0) * 0.001, end: Double($0) * 0.001 + 0.0005) }
        let manyAnchors: [Int?] = (0..<largeCount).map { $0.isMultiple(of: 2) ? $0 % 100 : nil }
        let began = Date()
        let indexed = try MeetingSpeakerAttribution.continuingSpeakerRuns(intervals: dense,
            candidates: Array(repeating: true, count: largeCount), interruptions: (0..<largeCount).map { !$0.isMultiple(of: 2) },
            anchorIdentities: manyAnchors, policy: .init(preserveIndependentSpeakerTurns: false))
        self.check(!indexed.isEmpty)
        self.check(zip(indexed, indexed.dropFirst()).allSatisfy { $0.after <= $1.before })
        self.check(try MeetingSpeakerAttribution.continuingSpeakerRuns(intervals: dense,
            candidates: Array(repeating: true, count: largeCount), interruptions: (0..<largeCount).map { !$0.isMultiple(of: 2) },
            anchorIdentities: manyAnchors, policy: .standard).isEmpty,
                   "Dense independent replies must stay boundaries without repeated context scans")
        print("ATTRIBUTION_CONTINUATION_LINEAR units=\(largeCount) runs=\(indexed.count) elapsed=\(Date().timeIntervalSince(began))")
    }

    static func scopeAndChronology() throws {
        let a = self.token("a"), b = self.token("b")
        let base = [self.unit("left", 0, 0.2, .assigned(a)), self.unit("unknown", 0.3, 0.5), self.unit("right", 0.6, 0.8, .assigned(b))]
        let activity = [self.activity("a", 0, 0.2), self.activity("b", 0.6, 0.8)]
        let expected = try self.resolve(base, activity)
        let otherEpoch = MeetingAnalysisEpochID(trackID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, ordinal: 0)
        let unrelated = self.unit("unrelated", 0.4, 0.45, .assigned(self.token("z", epoch: otherEpoch)), epoch: otherEpoch)
        let interleaved = try self.resolve([base[2], unrelated, base[0], base[1]], activity + [self.activity("z", 0.4, 0.45, epoch: otherEpoch)])
        self.check(Array(interleaved.prefix(3)) == expected, "Unrelated track changed context")
        for target in [MeetingAnalysisEpochID(trackID: Self.epoch.trackID, ordinal: 1), MeetingAnalysisEpochID(trackID: Self.epoch.trackID, ordinal: 0, generation: 1)] {
            let split = [base[0], base[1], self.unit("right", 0.6, 0.8, .assigned(self.token("b", epoch: target)), epoch: target)]
            self.check(try self.resolve(split, [activity[0], self.activity("b", 0.6, 0.8, epoch: target)])[1].selectedToken == nil)
        }
        let equal = [base[0], base[1], self.unit("overlap", 0.3, 0.5, .assigned(a)), base[2]]
        self.check(try self.resolve(equal, activity + [self.activity("a", 0.3, 0.5)]).first { $0.unitID == "unknown" }?.rule != .incomingSpeaker)
        let nested = [self.unit("long", 0, 10, .assigned(a))] + base
        let nestedOutput = try self.resolve(nested, activity)
        self.check(nestedOutput.first { $0.unitID == "unknown" }?.selectedToken == nil)
        let validBarrier = [base[0], self.unit("excluded", 0.22, 0.25), base[1], base[2]]
        self.check(try self.resolve(validBarrier, activity, barriers: ["excluded"]).first { $0.unitID == "unknown" }?.selectedToken == nil)
    }

    static func contextBarrierIntervals() throws {
        let a = self.token("a"), b = self.token("b")
        let words = [self.unit("left", 5.6, 6, .assigned(a)), self.unit("unknown", 6.1, 6.2),
                     self.unit("right", 6.3, 6.5, .assigned(b))]
        let activity = [self.activity("a", 5.6, 6), self.activity("b", 6.3, 6.5)]
        let gap = MeetingSpeakerAttributionContextBarrier(analysisEpochID: Self.epoch, interval: .init(start: 6, end: 6.1))
        let baseline = try self.resolve(words, activity)
        let blocked = try self.resolve(words, activity, contextualBarriers: [gap])
        self.check(baseline[1].rule == .incomingSpeaker && blocked[1].selectedToken == nil,
                   "Neighbor inference crossed a proven missing-audio interval")
        self.check(zip(baseline, blocked).allSatisfy { lhs, rhs in
            lhs.rawAssignment == rhs.rawAssignment && lhs.candidates == rhs.candidates
                && lhs.activeSupportSeconds == rhs.activeSupportSeconds && lhs.relation == rhs.relation
        }, "A context barrier altered native acoustic evidence")
        self.check(blocked[0] == baseline[0] && blocked[2] == baseline[2])
        let later = [self.unit("later-left", 8, 8.2, .assigned(a)), self.unit("later-unknown", 8.3, 8.5),
                     self.unit("later-right", 8.6, 8.8, .assigned(b))]
        let local = try self.resolve(words + later, activity + [self.activity("a", 8, 8.2), self.activity("b", 8.6, 8.8)], contextualBarriers: [gap])
        self.check(local.first { $0.unitID == "unknown" }?.selectedToken == nil)
        self.check(local.first { $0.unitID == "later-unknown" }?.rule == .incomingSpeaker,
                   "One small discontinuity disabled an entire otherwise valid epoch")
        let mixedWords = [self.unit("left", 5.6, 6, .assigned(a)), self.unit("mixed", 6.1, 6.8, .ambiguous([a, b])),
                          self.unit("right", 6.9, 7.2, .assigned(a))]
        let mixedActivity = [self.activity("a", 5.6, 7.2), self.activity("b", 6.3, 6.6)]
        let mixedBaseline = try self.resolve(mixedWords, mixedActivity)
        let mixedBlocked = try self.resolve(mixedWords, mixedActivity, contextualBarriers: [gap])
        self.check(mixedBaseline[1].rule == .mainSpeakerContinuation && mixedBlocked[1].rule != .mainSpeakerContinuation)
        self.check(mixedBlocked[1].selectedToken == nil && mixedBlocked[1].candidates == mixedBaseline[1].candidates,
                   "Interruption roles crossed a gap before the first mixed word")
        let otherTrack = MeetingAnalysisEpochID(trackID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, ordinal: 0)
        let unrelated = [otherTrack, MeetingAnalysisEpochID(trackID: Self.epoch.trackID, ordinal: 1),
                         MeetingAnalysisEpochID(trackID: Self.epoch.trackID, ordinal: 0, generation: 1)].map {
            MeetingSpeakerAttributionContextBarrier(analysisEpochID: $0, interval: gap.interval)
        }
        self.check(try self.resolve(words, activity, contextualBarriers: unrelated) == baseline)
        self.check(try self.resolve(mixedWords, mixedActivity, contextualBarriers: unrelated) == mixedBaseline)
        let touching = [MeetingSpeakerAttributionContextBarrier(analysisEpochID: Self.epoch, interval: .init(start: 5.5, end: 5.6)),
                        MeetingSpeakerAttributionContextBarrier(analysisEpochID: Self.epoch, interval: .init(start: 6.5, end: 6.6))]
        self.check(try self.resolve(words, activity, contextualBarriers: touching) == baseline,
                   "Half-open barrier endpoints falsely intersected the cue path")
        let mixedTouching = [touching[0], MeetingSpeakerAttributionContextBarrier(analysisEpochID: Self.epoch, interval: .init(start: 7.2, end: 7.3))]
        self.check(try self.resolve(mixedWords, mixedActivity, contextualBarriers: mixedTouching) == mixedBaseline)
        let fragmented = [MeetingSpeakerAttributionContextBarrier(analysisEpochID: Self.epoch, interval: .init(start: 6, end: 6.04)),
                          MeetingSpeakerAttributionContextBarrier(analysisEpochID: Self.epoch, interval: .init(start: 6.04, end: 6.1)), gap]
        self.check(try self.resolve(words, activity, contextualBarriers: fragmented.reversed()) == blocked)
        self.check(try self.resolve(mixedWords, mixedActivity, contextualBarriers: fragmented + fragmented) == mixedBlocked)
        let roundTrip = try JSONDecoder().decode(MeetingSpeakerAttributionContextBarrier.self, from: JSONEncoder().encode(gap))
        self.check(roundTrip == gap)
        for bounds in [(Double.nan, 6.1), (6, Double.infinity), (-1, 6), (6, 6), (6.1, 6)] {
            self.expectError {
                _ = try self.resolve(words, activity, contextualBarriers: [.init(analysisEpochID: Self.epoch,
                                                                                 interval: .init(start: bounds.0, end: bounds.1))])
            }
        }
        self.expectError {
            _ = try self.resolve(words, activity, contextualBarriers: [.init(analysisEpochID: .init(trackID: Self.epoch.trackID, ordinal: -1), interval: gap.interval)])
        }
        let count = 5_000
        var manyWords: [MeetingFinalTextUnit] = [], manyActivity: [MeetingBackendSpeakerActivity] = []
        var manyBarriers: [MeetingSpeakerAttributionContextBarrier] = []
        for position in 0..<count {
            let start = Double(position) * 2
            manyWords += [self.unit("l\(position)", start, start + 0.2, .assigned(a)),
                          self.unit("u\(position)", start + 0.3, start + 0.5),
                          self.unit("r\(position)", start + 0.6, start + 0.8, .assigned(b))]
            manyActivity += [self.activity("a", start, start + 0.2), self.activity("b", start + 0.6, start + 0.8)]
            let gapStart = start + (position.isMultiple(of: 2) ? 0.2 : 1.2)
            manyBarriers.append(.init(analysisEpochID: Self.epoch, interval: .init(start: gapStart, end: gapStart + 0.05)))
        }
        let began = Date()
        let indexed = try self.resolve(manyWords, manyActivity, contextualBarriers: manyBarriers)
        let indexedByID = Dictionary(uniqueKeysWithValues: indexed.map { ($0.unitID, $0) })
        self.check((0..<count).allSatisfy { position in
            let decision = indexedByID["u\(position)"]!
            return position.isMultiple(of: 2) ? decision.selectedToken == nil : decision.rule == .incomingSpeaker
        })
        print("ATTRIBUTION_CONTEXT_BARRIERS units=\(manyWords.count) barriers=\(count) elapsed=\(Date().timeIntervalSince(began))")
    }

    static func invalidInputsAndCoding() throws {
        let a = self.token("a"), good = self.unit("x", 0, 1)
        for bounds in [(Double.nan, 1.0), (0, Double.infinity), (-1, 1), (1, 1), (2, 1)] {
            self.expectError { _ = try self.resolve([self.unit("x", bounds.0, bounds.1)], []) }
            self.expectError { _ = try self.resolve([good], [self.activity("a", bounds.0, bounds.1)]) }
        }
        self.expectError { _ = try self.resolve([good, good], []) }
        self.expectError { _ = try self.resolve([self.unit(" ", 0, 1)], []) }
        self.expectError { _ = try self.resolve([self.unit("x", 0, 1, .assigned(self.token(" ")))], []) }
        self.expectError { _ = try self.resolve([self.unit("x", 0, 1, .ambiguous([]))], []) }
        self.expectError { _ = try self.resolve([self.unit("x", 0, 1, .ambiguous([a, a]))], []) }
        let foreign = self.token("a", epoch: .init(trackID: Self.epoch.trackID, ordinal: 0, generation: 1))
        self.expectError { _ = try self.resolve([self.unit("x", 0, 1, .assigned(foreign))], []) }
        self.expectError { _ = try self.resolve([good], [], barriers: ["missing"]) }
        self.expectError { _ = try self.resolve([good], [], epochs: [.init(trackID: Self.epoch.trackID, ordinal: -1)]) }
        self.expectError { _ = try self.resolve([good], [], policy: .init(schemaVersion: 999)) }
        self.expectError { _ = try self.resolve([good], [], policy: .init(maximumCandidateNoiseSeconds: .nan)) }
        self.expectError { _ = try self.resolve([good], [], policy: .init(dominanceMinRatio: 0)) }
        self.expectError { _ = try self.resolve([good], [], policy: .init(maximumUnknownRunSeconds: -1)) }
        self.expectError { _ = try MeetingSpeakerAttribution.unionedIntervals([.init(start: .nan, end: 1)]) }
        let policy = MeetingSpeakerAttributionPolicy.standard
        self.check(policy.schemaVersion == 2 && policy.enableSameSpeakerPauseResolution && policy.enableMainSpeakerContinuation)
        let roundTrip = try JSONDecoder().decode(MeetingSpeakerAttributionPolicy.self, from: JSONEncoder().encode(policy))
        self.check(roundTrip == policy && roundTrip.fingerprint == policy.fingerprint)
        self.check(policy.fingerprint.count < 100)
        self.check(MeetingSpeakerAttributionPolicy(maximumCandidateNoiseSeconds: -0.0).fingerprint == MeetingSpeakerAttributionPolicy(maximumCandidateNoiseSeconds: 0).fingerprint)
        self.check(MeetingSpeakerAttributionPolicy(maximumUnknownRunSeconds: 4).fingerprint != policy.fingerprint)
        // Captured from v2 before the additive pause flag existed. Old attempt identity must
        // survive decoding and re-encoding, including checkpoints that store this fingerprint.
        let oldJSON = Data("""
        {"maximumUnknownRunSeconds":3.5,"maximumNeighborGapSeconds":0.8,"maximumBriefInterruptionGapSeconds":0.08,"maximumCandidateNoiseSeconds":0.08,"schemaVersion":2,"dominanceMinLeaderFraction":0.5,"dominanceMinRatio":2,"maximumCandidateNoiseActiveFraction":0.2,"maximumBoundaryResidualSeconds":0.08,"dominanceMaxRunnerFraction":0.2,"maximumBriefInterruptionSeconds":2,"enableBriefInterruption":true,"minimumInterruptionSupportSeconds":0.08,"maximumInterruptionWordSeconds":3,"enableNeighborResolution":true,"comparisonTolerance":1e-09,"enableDominance":true}
        """.utf8)
        let oldFingerprint = "speaker-attribution-v2:196d1cbbd5ce49c733b1fce3a7d1a9c3036448ccba13619cad8eb12b7e032a9a"
        let oldPolicy = try JSONDecoder().decode(MeetingSpeakerAttributionPolicy.self, from: oldJSON)
        self.check(!oldPolicy.enableSameSpeakerPauseResolution && !oldPolicy.enableMainSpeakerContinuation && oldPolicy.schemaVersion == 2)
        self.check(oldPolicy == MeetingSpeakerAttributionPolicy(enableSameSpeakerPauseResolution: false,
            enableMainSpeakerContinuation: false, enableIndependentAcousticAnchors: false,
            preserveIndependentSpeakerTurns: false, enableVoicedSpeakerAdmission: false))
        self.check(oldPolicy.fingerprint == oldFingerprint && policy.fingerprint != oldFingerprint)
        let oldRoundTrip = try JSONDecoder().decode(MeetingSpeakerAttributionPolicy.self, from: JSONEncoder().encode(oldPolicy))
        self.check(oldRoundTrip == oldPolicy && oldRoundTrip.fingerprint == oldFingerprint)
        var priorObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)) as! [String: Any]
        priorObject.removeValue(forKey: "enableCompleteReadingAssignment")
        // Encodings from before ad76f332 carry no token-emission context flag.
        priorObject.removeValue(forKey: "enableTokenEmissionContext")
        priorObject.removeValue(forKey: "enableIncomingGapReading")
        priorObject.removeValue(forKey: "enableProvisionalSpeakerIdentities")
        priorObject.removeValue(forKey: "enableStableSpeakerOpening")
        priorObject.removeValue(forKey: "enableMainSpeakerContinuation")
        priorObject.removeValue(forKey: "enableIndependentAcousticAnchors")
        priorObject.removeValue(forKey: "preserveIndependentSpeakerTurns")
        priorObject.removeValue(forKey: "enableVoicedSpeakerAdmission")
        let priorPolicy = try JSONDecoder().decode(MeetingSpeakerAttributionPolicy.self,
            from: JSONSerialization.data(withJSONObject: priorObject))
        self.check(priorPolicy.enableSameSpeakerPauseResolution && !priorPolicy.enableMainSpeakerContinuation)
        self.check(priorPolicy == .init(enableMainSpeakerContinuation: false, enableIndependentAcousticAnchors: false,
                                       preserveIndependentSpeakerTurns: false, enableVoicedSpeakerAdmission: false))
        self.check(priorPolicy.fingerprint == "speaker-attribution-v2:0207a0b121f07fa78e18222b5ddfbfd17ac65c2560a17b26f9e36cb365be8fb3")
        self.check(priorPolicy.fingerprint != policy.fingerprint && priorPolicy.fingerprint != oldFingerprint)
        self.check(try JSONDecoder().decode(MeetingSpeakerAttributionPolicy.self,
            from: JSONEncoder().encode(priorPolicy)).fingerprint == priorPolicy.fingerprint)
        var beforeAcoustic = try JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)) as! [String: Any]
        beforeAcoustic.removeValue(forKey: "enableCompleteReadingAssignment")
        // Encodings from before ad76f332 carry no token-emission context flag.
        beforeAcoustic.removeValue(forKey: "enableTokenEmissionContext")
        beforeAcoustic.removeValue(forKey: "enableIncomingGapReading")
        beforeAcoustic.removeValue(forKey: "enableProvisionalSpeakerIdentities")
        beforeAcoustic.removeValue(forKey: "enableStableSpeakerOpening")
        beforeAcoustic.removeValue(forKey: "enableIndependentAcousticAnchors")
        beforeAcoustic.removeValue(forKey: "preserveIndependentSpeakerTurns")
        beforeAcoustic.removeValue(forKey: "enableVoicedSpeakerAdmission")
        let frozen = try JSONDecoder().decode(MeetingSpeakerAttributionPolicy.self,
            from: JSONSerialization.data(withJSONObject: beforeAcoustic))
        self.check(!frozen.enableIndependentAcousticAnchors && policy.enableIndependentAcousticAnchors)
        self.check(frozen.fingerprint == "speaker-attribution-v2:00622a913604f7a3bb029e865dedb93e1ea27aa50cd86972d11115a1a78fe53a")
        self.check(frozen == .init(enableIndependentAcousticAnchors: false, preserveIndependentSpeakerTurns: false,
                                  enableVoicedSpeakerAdmission: false)
                   && frozen.fingerprint != policy.fingerprint)
        self.check(try JSONDecoder().decode(MeetingSpeakerAttributionPolicy.self,
            from: JSONEncoder().encode(frozen)) == frozen)
        var beforeTurnBoundaries = try JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)) as! [String: Any]
        beforeTurnBoundaries.removeValue(forKey: "enableCompleteReadingAssignment")
        // Encodings from before ad76f332 carry no token-emission context flag.
        beforeTurnBoundaries.removeValue(forKey: "enableTokenEmissionContext")
        beforeTurnBoundaries.removeValue(forKey: "enableIncomingGapReading")
        beforeTurnBoundaries.removeValue(forKey: "enableProvisionalSpeakerIdentities")
        beforeTurnBoundaries.removeValue(forKey: "enableStableSpeakerOpening")
        beforeTurnBoundaries.removeValue(forKey: "preserveIndependentSpeakerTurns")
        beforeTurnBoundaries.removeValue(forKey: "enableVoicedSpeakerAdmission")
        let frozenTurnPolicy = try JSONDecoder().decode(MeetingSpeakerAttributionPolicy.self,
            from: JSONSerialization.data(withJSONObject: beforeTurnBoundaries))
        self.check(!frozenTurnPolicy.preserveIndependentSpeakerTurns && policy.preserveIndependentSpeakerTurns)
        self.check(frozenTurnPolicy == .init(preserveIndependentSpeakerTurns: false, enableVoicedSpeakerAdmission: false)
                   && frozenTurnPolicy.fingerprint != policy.fingerprint,
                   "Previously saved attempts retain the old semantics and exact immutable policy identity")
        self.check(try JSONDecoder().decode(MeetingSpeakerAttributionPolicy.self,
            from: JSONEncoder().encode(frozenTurnPolicy)) == frozenTurnPolicy)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)) as! [String: Any]
        object["schemaVersion"] = MeetingSpeakerAttributionPolicy.currentVersion + 1
        do {
            _ = try JSONDecoder().decode(MeetingSpeakerAttributionPolicy.self, from: JSONSerialization.data(withJSONObject: object))
            self.check(false, "Future policy decoded")
        } catch { self.check(true) }
        object["schemaVersion"] = 1
        do {
            _ = try JSONDecoder().decode(MeetingSpeakerAttributionPolicy.self, from: JSONSerialization.data(withJSONObject: object))
            self.check(false, "An older interruption policy decoded with changed ownership semantics")
        } catch MeetingSpeakerAttributionError.unsupportedPolicyVersion(1) { self.check(true) }
        catch { self.check(false, "Unexpected policy incompatibility error: \(error)") }
        self.check(MeetingSpeakerAttributionPolicy(schemaVersion: 1).fingerprint != policy.fingerprint)
        let decisions = try self.resolve([self.unit("x", 0, 1, .assigned(a))], [self.activity("a", 0, 1)])
        let decisionRoundTrip = try JSONDecoder().decode([MeetingSpeakerAttributionDecision].self, from: JSONEncoder().encode(decisions))
        self.check(decisionRoundTrip == decisions)
    }

    static func exactBoundaries() throws {
        let a = self.token("a"), b = self.token("b")
        for offset in [0.0, 10_000.0] {
            let exact = try self.resolve([self.unit("x", offset, offset + 0.5)],
                                         [self.activity("a", offset, offset + 0.5), self.activity("b", offset, offset + 0.08)])[0]
            self.check(exact.candidates.first { $0.token == b }?.isSuppressed == false)
            let justBelow = try self.resolve([self.unit("x", offset, offset + 0.5)],
                                             [self.activity("a", offset, offset + 0.5), self.activity("b", offset, offset + 0.079_999)])[0]
            self.check(justBelow.candidates.first { $0.token == b }?.isSuppressed == true)
            let shortWords = [self.unit("left", offset, offset + 0.04, .assigned(a)),
                              self.unit("unknown", offset + 0.05, offset + 0.1),
                              self.unit("right", offset + 0.11, offset + 0.15, .assigned(b))]
            let shortActivity = [self.activity("a", offset, offset + 0.04), self.activity("b", offset + 0.11, offset + 0.15)]
            let shortOutput = try self.resolve(shortWords, shortActivity)
            self.check(shortOutput[0].rule == .singleAcousticSupport && shortOutput[2].rule == .singleAcousticSupport)
            self.check(shortOutput[1].rule == .incomingSpeaker && shortOutput[1].selectedToken == b,
                       "A whole short native word lost its voice merely because its envelope was short")
            let units = [self.unit("left", offset, offset + 0.2, .assigned(a)),
                         self.unit("unknown", offset + 0.3, offset + 3.8),
                         self.unit("right", offset + 3.9, offset + 4.1, .assigned(b))]
            let activity = [self.activity("a", offset, offset + 0.2), self.activity("b", offset + 3.9, offset + 4.1)]
            self.check(try self.resolve(units, activity)[1].rule == .incomingSpeaker)
            let boundaryWords = [self.unit("left", offset, offset + 0.2, .assigned(a)),
                                 self.unit("unknown", offset + 1.0, offset + 1.2),
                                 self.unit("right", offset + 2.0, offset + 2.2, .assigned(b))]
            self.check(try self.resolve(boundaryWords, [activity[0], self.activity("b", offset + 2.0, offset + 2.2)])[1].rule == .incomingSpeaker)
        }
        // A strict half-open endpoint does not become simultaneous through numerical slack.
        let touching = try self.resolve([self.unit("x", 0, 1)], [self.activity("a", 0, 0.5), self.activity("b", 0.5, 1)])[0]
        self.check(touching.relation == .consecutive && touching.simultaneousIntervals.isEmpty)
        // Positive sub-nanosecond evidence remains recorded, while its arithmetic noise does not
        // create a second meaningful voice or a contextual anchor contradiction.
        let tiny = try self.resolve([self.unit("x", 0, 1)], [self.activity("a", 0, 1), self.activity("b", 0.5, 0.500_000_000_1)])[0]
        self.check(tiny.candidates.count == 2 && !tiny.simultaneousIntervals.isEmpty && tiny.relation == .single)
        let zeroFloor = try self.resolve([self.unit("x", 0, 1)], [self.activity("b", 0.5, 0.500_000_000_1)], policy: .init(maximumCandidateNoiseSeconds: 0))[0]
        self.check(zeroFloor.selectedToken == nil && zeroFloor.candidates[0].isSuppressed)
    }

    static func cancellation() async throws {
        let words = [self.unit("x", 0, 1)]
        let task = Task.detached { () -> Bool in
            while !Task.isCancelled { await Task.yield() }
            do {
                _ = try MeetingSpeakerAttribution.resolve(units: words, activity: [])
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        task.cancel()
        let cancelled = await task.value
        self.check(cancelled, "Cancelled work produced an attribution result")
        // Exercise cancellation after entry into substantial work, including the empty-unit path
        // that still indexes a million native intervals. Initial cancellation alone cannot cover
        // the normalization, sorting, grouping and tree-construction loops.
        let a = self.token("a")
        let count = 1_000_000
        let activity = (0..<count).map {
            MeetingBackendSpeakerActivity(token: a, start: Double($0) * 0.001, end: Double($0) * 0.001 + 0.0005)
        }
        let began = Date()
        let baseline = try MeetingSpeakerAttribution.resolveWithDiagnostics(units: [], activity: activity)
        let baselineSeconds = Date().timeIntervalSince(began)
        self.check(baseline.diagnostics.normalizedIntervalCount == count && baseline.decisions.isEmpty)
        var cancelledDuringWork = 0
        for fraction in [0.15, 0.4, 0.7] {
            let task = Task.detached { () -> (String, Date) in
                do {
                    _ = try MeetingSpeakerAttribution.resolve(units: [], activity: activity)
                    return ("success", Date())
                } catch is CancellationError { return ("cancelled", Date()) }
                catch { return ("unexpected", Date()) }
            }
            try await Task.sleep(for: .seconds(baselineSeconds * fraction))
            let cancelledAt = Date()
            task.cancel()
            let (result, finishedAt) = await task.value
            self.check(result == "cancelled" || (result == "success" && finishedAt < cancelledAt),
                       "A cancellation during indexing returned success after cancellation")
            if result == "cancelled" { cancelledDuringWork += 1 }
            print("ATTRIBUTION_CANCEL intervals=\(count) baseline=\(baselineSeconds) fraction=\(fraction) result=\(result)")
        }
        self.check(cancelledDuringWork > 0, "The delayed cancellation probes never entered active work")
    }

    struct Random {
        var state: UInt64
        mutating func next(_ limit: Int) -> Int {
            self.state = self.state &* 6364136223846793005 &+ 1442695040888963407
            return Int((self.state >> 32) % UInt64(limit))
        }
    }

    static func metamorphic() throws {
        for seed in 0..<100 {
            var random = Random(state: UInt64(seed + 1))
            let words = (0..<20).map { self.unit("w\($0)", Double($0), Double($0) + 0.9) }
            var activities: [MeetingBackendSpeakerActivity] = []
            for _ in 0..<40 {
                let start = Double(random.next(190)) / 10
                let end = start + Double(random.next(15) + 1) / 10
                activities.append(self.activity("s\(random.next(4))", start, end))
            }
            let expected = try self.resolve(words, activities)
            var transformed: [MeetingBackendSpeakerActivity] = []
            for entry in activities {
                let middle = (entry.start + entry.end) / 2
                transformed.append(.init(token: entry.token, start: entry.start, end: middle))
                transformed.append(.init(token: entry.token, start: middle, end: entry.end))
                transformed.append(entry)
            }
            let actual = try self.resolve(words.reversed(), transformed.reversed())
            self.check(expected == actual, "Fragmentation/duplicates/order changed seed \(seed)")
            let offset = 1000.0
            let shiftedWords = words.map { self.unit($0.id, $0.analysisStart + offset, $0.analysisEnd + offset) }
            let shiftedActivity = activities.map { MeetingBackendSpeakerActivity(token: $0.token, start: $0.start + offset, end: $0.end + offset) }
            let shifted = try self.resolve(shiftedWords, shiftedActivity)
            self.check(zip(expected, shifted).allSatisfy { lhs, rhs in
                lhs.selectedToken == rhs.selectedToken && lhs.rule == rhs.rule && lhs.relation == rhs.relation
                    && abs(lhs.activeSupportSeconds - rhs.activeSupportSeconds) < 0.000_000_001
            }, "Time translation changed seed \(seed)")
            let renamed = activities.map { MeetingBackendSpeakerActivity(token: self.token("renamed-\($0.token.label.reversed())"), start: $0.start, end: $0.end) }
            let renamedOutput = try self.resolve(words, renamed)
            self.check(zip(expected, renamedOutput).allSatisfy { lhs, rhs in
                let selected = lhs.selectedToken.map { "renamed-\($0.label.reversed())" }
                return selected == rhs.selectedToken?.label && lhs.rule == rhs.rule && lhs.relation == rhs.relation
            }, "Slot rename changed seed \(seed)")
        }
    }

    static func scale() throws {
        for seconds in [600, 3600, 28_800] {
            let count = seconds * 2
            var words: [MeetingFinalTextUnit] = [], activity: [MeetingBackendSpeakerActivity] = []
            words.reserveCapacity(count); activity.reserveCapacity(count)
            for position in 0..<count {
                let start = Double(position) * 0.5
                let label = "speaker-\(position % 1000)"
                words.append(self.unit("w\(position)", start, start + 0.4, .assigned(self.token(label))))
                activity.append(self.activity(label, start, start + 0.4))
            }
            let began = Date()
            let resolution = try MeetingSpeakerAttribution.resolveWithDiagnostics(units: words, activity: activity)
            let presentationSeconds = Date().timeIntervalSince(began)
            self.check(resolution.decisions.count == count && resolution.decisions.allSatisfy { $0.rule == .singleAcousticSupport })
            self.check(resolution.diagnostics.returnedIntervalCount == count)
            self.check(resolution.diagnostics.visitedIntervalNodeCount < count * 40, "Index visits scaled with speaker count")
            if seconds == 600 {
                let encoded = try JSONEncoder().encode(resolution.decisions)
                print("ATTRIBUTION_METADATA units=\(count) bytes=\(encoded.count) fingerprintLength=\(MeetingSpeakerAttributionPolicy.standard.fingerprint.count)")
            }
            let nativeUnits = words.map { self.unit($0.id, $0.analysisStart, $0.analysisEnd) }
            let rawBegan = Date()
            let initial = try MeetingSpeakerAttribution.acousticAssignments(units: nativeUnits, activity: activity)
            let rawSeconds = Date().timeIntervalSince(rawBegan)
            self.check(initial.count == count)
            self.check(nativeUnits.enumerated().allSatisfy { position, unit in
                initial[unit.id] == .assigned(self.token("speaker-\(position % 1000)"))
            })
            print("ATTRIBUTION_RAW_SCALE seconds=\(seconds) units=\(count) voices=1000 elapsed=\(rawSeconds)")
            print("ATTRIBUTION_SCALE seconds=\(seconds) units=\(count) voices=1000 elapsed=\(presentationSeconds) visits=\(resolution.diagnostics.visitedIntervalNodeCount)")
        }
        let count = 20_000
        let words = [self.unit("long", 0, Double(count) + 1)] + (0..<count).map { self.unit("n\($0)", Double($0), Double($0) + 0.5) }
        let began = Date()
        let result = try self.resolve(words, [])
        self.check(result.count == count + 1 && result.allSatisfy { $0.selectedToken == nil })
        print("ATTRIBUTION_NESTED units=\(count + 1) elapsed=\(Date().timeIntervalSince(began))")
    }
}

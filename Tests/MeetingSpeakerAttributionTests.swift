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
        policy: MeetingSpeakerAttributionPolicy = .standard, barriers: Set<String> = [],
        epochs: Set<MeetingAnalysisEpochID> = [],
        contextualBarriers: [MeetingSpeakerAttributionContextBarrier] = []
    ) throws -> [MeetingSpeakerAttributionDecision] {
        try MeetingSpeakerAttribution.resolve(units: units, activity: activity, policy: policy,
                                              barrierUnitIDs: barriers, contextualBarrierEpochIDs: epochs, contextualBarriers: contextualBarriers)
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
        self.neighborAdmission()
        try self.interruptions()
        try self.interruptionWordSupport()
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
        func admitted(_ values: [(Double, Double)], policy: MeetingSpeakerAttributionPolicy = .standard) -> Bool {
            MeetingSpeakerAttribution.admitsNeighborRun(values.map { .init(start: $0.0, end: $0.1) }, policy: policy)
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

    static func interruptions() throws {
        let a = self.token("a"), b = self.token("b")
        let units = [self.unit("left", 0, 0.2, .assigned(a)), self.unit("mix", 0.3, 0.8, .ambiguous([a, b])), self.unit("right", 0.9, 1.1, .assigned(a))]
        let activity = [self.activity("a", 0, 1.1), self.activity("b", 0.4, 0.6)]
        let output = try self.resolve(units, activity)
        self.check(output[1].rule == .briefInterruption && output[1].selectedToken == b)
        self.check(output[1].backgroundTokens == [a] && output[1].rawAssignment == units[1].speaker)
        self.check(output[1].simultaneousIntervals == [.init(tokens: [a, b], interval: .init(start: 0.4, end: 0.6))])
        let split = [units[0], self.unit("mix1", 0.3, 0.5, .ambiguous([a, b])), self.unit("mix2", 0.5, 0.8, .ambiguous([a, b])), units[2]]
        let splitOutput = try self.resolve(split, activity)
        self.check(splitOutput[1].rule == .briefInterruption && splitOutput[2].rule == .briefInterruption)
        self.check(splitOutput[1].selectedToken == b && splitOutput[2].selectedToken == b)
        let gapWords = [units[0], self.unit("gapmix1", 0.3, 0.45, .ambiguous([a, b])),
                        self.unit("gapmix2", 0.6, 0.8, .ambiguous([a, b])), units[2]]
        let gapActivity = [self.activity("a", 0, 1.1), self.activity("b", 0.35, 0.7)]
        let noThird = try self.resolve(gapWords, gapActivity)
        self.check(noThird[1].rule == .briefInterruption && noThird[2].rule == .briefInterruption)
        let hiddenThird = try self.resolve(gapWords, gapActivity + [self.activity("c", 0.5, 0.55)])
        self.check(hiddenThird[1].rule != .briefInterruption && hiddenThird[2].rule != .briefInterruption,
                   "A third voice in the full bout was hidden by the gap between ASR words")
        self.check(hiddenThird[1].selectedToken == nil && hiddenThird[2].selectedToken == nil)
        self.check(hiddenThird[1].candidates == noThird[1].candidates && hiddenThird[2].candidates == noThird[2].candidates)
        let contextThird = try self.resolve(gapWords, gapActivity + [self.activity("c", 0.22, 0.25)])
        self.check(contextThird[1].rule != .briefInterruption && contextThird[2].rule != .briefInterruption)
        let outsideThird = try self.resolve(gapWords, gapActivity + [self.activity("c", 1.2, 1.3)])
        self.check(outsideThird[1].rule == .briefInterruption && outsideThird[2].rule == .briefInterruption)
        let nativeBMiddle = [units[0], self.unit("mix1", 0.3, 0.45, .ambiguous([a, b])), self.unit("bword", 0.45, 0.55, .assigned(b)), self.unit("mix2", 0.55, 0.8, .ambiguous([a, b])), units[2]]
        let nativeBActivity = [self.activity("a", 0, 0.45), self.activity("a", 0.55, 1.1), self.activity("b", 0.4, 0.6)]
        let nativeBOutput = try self.resolve(nativeBMiddle, nativeBActivity)
        self.check(nativeBOutput[1].rule == .briefInterruption && nativeBOutput[3].rule == .briefInterruption)
        self.check(nativeBOutput[2].rule == .singleAcousticSupport && nativeBOutput[2].selectedToken == b)
        let missingMain = try self.resolve(units, [self.activity("a", 0, 0.2), self.activity("a", 0.9, 1.1), self.activity("b", 0.4, 0.6)])[1]
        self.check(missingMain.rule != .briefInterruption && missingMain.relation == .conflict)
        let tinyB = try self.resolve(units, [self.activity("a", 0, 1.1), self.activity("b", 0.4, 0.401)])[1]
        self.check(tinyB.rule != .briefInterruption)
        let three = try self.resolve(units, activity + [self.activity("c", 0.45, 0.55)])[1]
        self.check(three.rule != .briefInterruption && three.selectedToken == nil)
        let barrier = try self.resolve(units, activity, barriers: ["mix"])[1]
        self.check(barrier.rule == .barrier && barrier.selectedToken == nil)
        let utterance = [units[0], self.unit("mix", 0.3, 0.8, .ambiguous([a, b]), precision: .utterance), units[2]]
        self.check(try self.resolve(utterance, activity)[1].selectedToken == nil)
        let longB = try self.resolve(units, [self.activity("a", 0, 1.1), self.activity("b", 0.4, 3)])[1]
        self.check(longB.rule != .briefInterruption)
        let noOutgoing = [self.unit("left", 0, 0.2, .assigned(b)), units[1], units[2]]
        self.check(try self.resolve(noOutgoing, activity)[1].rule != .briefInterruption)
        let disabled = try self.resolve(units, activity, policy: .init(enableBriefInterruption: false))[1]
        self.check(disabled.rule != .briefInterruption)
        let consecutive = try self.resolve(units, [self.activity("a", 0, 0.4), self.activity("b", 0.4, 0.8), self.activity("a", 0.9, 1.1)])[1]
        self.check(consecutive.relation == .consecutive && consecutive.rule != .briefInterruption)
        let fragmented = [self.activity("a", 0, 1.1), self.activity("b", 0.4, 0.45), self.activity("b", 0.47, 0.52), self.activity("b", 0.54, 0.6)]
        self.check(try self.resolve(units, fragmented)[1].rule == .briefInterruption)
        let twoBouts = [self.activity("a", 0, 1.1), self.activity("b", 0.31, 0.42), self.activity("b", 0.65, 0.78)]
        self.check(try self.resolve(units, twoBouts)[1].rule != .briefInterruption)
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
                let base = try self.resolve(units, activity, epochs: [Self.epoch])
                let output = try self.resolve(units, activity)
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
                self.check(try self.resolve(units.reversed(), fragmented.reversed()) == output,
                           "Word-level interruption eligibility depended on interval fragmentation or ordering")
                // A real short word may be wholly inside the bout. Reusing the relative
                // candidate gate must not become an absolute minimum duration per ASR word.
                let short = [self.unit("left", offset, offset + 0.2, .assigned(a)),
                             self.unit("short", offset + 0.5, offset + 0.508, .ambiguous([a, b])),
                             self.unit("right", offset + 0.9, offset + 1.1, .assigned(a))]
                let shortOutput = try self.resolve(short, [self.activity(labels.0, offset, offset + 1.1),
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
                let output = try self.resolve(units, [self.activity("a", offset, offset + 1.1),
                                                      self.activity("b", offset + start, offset + 0.65)])
                self.check(output[1].candidates.first { $0.token == b }?.isSuppressed == suppressed)
                self.check(output[1].selectedToken == (suppressed ? a : b))
                self.check(output[1].rule == (suppressed ? .residualSuppression : .briefInterruption))
                self.check(output[2].selectedToken == b && output[2].rule == .briefInterruption)
            }
        }
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
        self.check(mixedBaseline[1].rule == .briefInterruption && mixedBlocked[1].rule != .briefInterruption)
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
        let roundTrip = try JSONDecoder().decode(MeetingSpeakerAttributionPolicy.self, from: JSONEncoder().encode(policy))
        self.check(roundTrip == policy && roundTrip.fingerprint == policy.fingerprint)
        self.check(policy.fingerprint.count < 100)
        self.check(MeetingSpeakerAttributionPolicy(maximumCandidateNoiseSeconds: -0.0).fingerprint == MeetingSpeakerAttributionPolicy(maximumCandidateNoiseSeconds: 0).fingerprint)
        self.check(MeetingSpeakerAttributionPolicy(maximumUnknownRunSeconds: 4).fingerprint != policy.fingerprint)
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

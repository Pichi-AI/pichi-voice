#if os(macOS)
import CoreGraphics
import PichiCallObservation

nonisolated enum MeetingPTTChordMatcher {
    static let relevantFlags: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]
    static func modifiersMatch(_ chord: CommunicationPushToTalkChord, flags: UInt64) -> Bool {
        var expected: CGEventFlags = []
        for modifier in chord.modifiers {
            switch modifier {
            case .shift: expected.insert(.maskShift)
            case .control: expected.insert(.maskControl)
            case .option: expected.insert(.maskAlternate)
            case .command: expected.insert(.maskCommand)
            case .function: expected.insert(.maskSecondaryFn)
            }
        }
        return CGEventFlags(rawValue: flags).intersection(self.relevantFlags) == expected
    }
    static func chord(in chords: [CommunicationPushToTalkChord], keyCode: UInt16, flags: UInt64) -> CommunicationPushToTalkChord? {
        chords.first { $0.keyCode == keyCode && self.modifiersMatch($0, flags: flags) }
    }
}
#endif

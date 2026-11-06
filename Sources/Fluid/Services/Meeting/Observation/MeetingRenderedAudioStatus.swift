#if os(macOS)
import Foundation
nonisolated struct MeetingRenderedAudioStatusSnapshot {
    let callWindowID: UInt32?
    let state: MeetingMicrophoneMuteState?
    let temporaryHUDVisible: Bool?
    static let unavailable = Self(callWindowID: nil, state: nil, temporaryHUDVisible: nil)
}
nonisolated protocol MeetingRenderedAudioStatusObserving: AnyObject {
    func sample(processID: Int32, boundWindowID: UInt32?) -> MeetingRenderedAudioStatusSnapshot
    func ownsFocusedWindow(processID: Int32) -> Bool
    func invalidate()
}
#endif

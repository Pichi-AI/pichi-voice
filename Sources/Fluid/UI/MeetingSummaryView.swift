import SwiftUI

struct MeetingSummaryView: View {
    var session: MeetingSession? = nil
    var asrService: ASRService? = nil
    var isQuiescent = true
    var body: some View {
        PichiMeetingSummaryView(session: self.session, asrService: self.asrService, isQuiescent: self.isQuiescent)
    }
}

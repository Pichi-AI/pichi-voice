import SwiftUI

/// One content-free presentation for an encrypted recording on either platform.
/// The trusted publication service still reads the underlying session to upload it.
struct MeetingLocalContentConcealmentView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.md) {
            Label(PichiLocalization.text("recording.protection.concealed.title"), systemImage: "lock.fill")
                .font(theme.typography.sectionTitle)
            Text(PichiLocalization.text("recording.protection.concealed.detail"))
                .font(theme.typography.bodySmall)
                .foregroundStyle(theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(theme.palette.primaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting.localContent.concealed")
    }
}

import SwiftUI
import CoreLocation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Onboarding and Settings use the same preference and permission operation.
struct MeetingLocationSettingsContent: View {
    /// A native form places the toggle, status and permission action in separate rows and shows
    /// `MeetingLocationExplanation` as their section footer. Cards keep it beside the toggle.
    var asFormRows = false
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var location = AppServices.shared.meetingLocation
    @Environment(\.theme) private var theme

    var body: some View {
        if asFormRows {
            toggle.modifier(AuthorizationRefresh(location: location))
            status
        } else {
            VStack(alignment: .leading, spacing: 12) {
                toggle
                MeetingLocationExplanation()
                status
            }
            .modifier(AuthorizationRefresh(location: location))
        }
    }

    private var toggle: some View {
        Toggle(PichiLocalization.text("Use location for meeting addresses"), isOn: Binding(
            get: { settings.meetingLocationEnabled },
            set: { location.setEnabled($0) }
        ))
        .accessibilityIdentifier("meetingLocation.enabled")
    }

    @ViewBuilder private var status: some View {
        if settings.meetingLocationEnabled {
            Text(PichiLocalization.text(statusText))
                .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                .accessibilityIdentifier("meetingLocation.authorization")
            if location.authorizationStatus == .notDetermined {
                Button(PichiLocalization.text("Allow location access")) { location.requestAuthorization() }
                    .disabled(location.isRequestingAuthorization)
                    .accessibilityIdentifier("meetingLocation.requestPermission")
            } else if location.authorizationStatus == .denied {
                Button(PichiLocalization.text("Open system settings")) { openSystemSettings() }
                    .accessibilityIdentifier("meetingLocation.openSettings")
            }
        }
    }

    /// One refresh owner per presentation, whether the content is one card or several form rows.
    private struct AuthorizationRefresh: ViewModifier {
        let location: MeetingLocationService
        @Environment(\.scenePhase) private var scenePhase

        func body(content: Content) -> some View {
            content
                .task { location.refreshAuthorization() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { location.refreshAuthorization() }
                }
        }
    }

    private var statusText: String {
        if location.isRequestingAuthorization { return "Waiting for location permission…" }
        switch location.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return "Location access is allowed."
        case .notDetermined: return "Location access has not been requested."
        case .denied: return "Location access is denied. Allow it in system settings to save meeting addresses."
        case .restricted: return "Location access is restricted on this device."
        @unknown default: return "Location access is restricted on this device."
        }
    }

    private func openSystemSettings() {
        #if os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #else
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") else { return }
        NSWorkspace.shared.open(url)
        #endif
    }
}

/// What location saving does, shown beside the toggle in a card. A form shows `paragraphs`
/// in its own section footer style.
struct MeetingLocationExplanation: View {
    @Environment(\.theme) private var theme

    static var paragraphs: [String] {
        [PichiLocalization.text("Optional. Save the address where a meeting starts. Location is requested once per meeting, without background tracking."),
         PichiLocalization.text("Apple resolves the address. It is saved with the meeting and shown in your interface language.")]
    }

    var body: some View {
        let paragraphs = Self.paragraphs
        VStack(alignment: .leading, spacing: 12) {
            Text(paragraphs[0]).font(theme.typography.bodySmall).foregroundStyle(theme.palette.secondaryText)
            Text(paragraphs[1]).font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
        }
    }
}

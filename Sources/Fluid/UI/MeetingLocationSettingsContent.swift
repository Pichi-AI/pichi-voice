import SwiftUI
import CoreLocation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Onboarding and Settings use the same preference and permission operation.
struct MeetingLocationSettingsContent: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var location = AppServices.shared.meetingLocation
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(PichiLocalization.text("Use location for meeting addresses"), isOn: Binding(
                get: { settings.meetingLocationEnabled },
                set: { location.setEnabled($0) }
            ))
            .accessibilityIdentifier("meetingLocation.enabled")

            Text(PichiLocalization.text("Optional. Save the address where a meeting starts. Location is requested once per meeting, without background tracking."))
                .font(theme.typography.bodySmall).foregroundStyle(theme.palette.secondaryText)
            Text(PichiLocalization.text("Apple resolves the address. It is saved with the meeting and shown in your interface language."))
                .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)

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
        .task { location.refreshAuthorization() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { location.refreshAuthorization() }
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

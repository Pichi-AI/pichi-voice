import Foundation

/// Composition calls these hooks while private admission is concealed, before selecting the
/// next profile. Auth, recording ownership and cloud consent remain with their existing owners.
@MainActor enum PrivateProfileAuxiliaryServices {
    static func prepareForTransition() async {
        #if os(macOS)
        AppSearchService.shared.stop()
        await SearchIndexCoordinator.shared.stop()
        await AppSearchService.shared.stopAndJoinForProfileTransition()
        await FluidZeppelinRoot.shared.shutdown()
        await AnalyticsService.shared.suspendForProfileTransition()
        #endif
        await MeetingTimelineTrace.shared?.finishForProfileTransition()
        await DebugLogger.shared.joinForProfileTransition()
        await FileLogger.shared.suspendForProfileTransition()
    }

    /// Call after storage selection and cache reset, before making the profile readable in UI.
    static func activate(_ profile: PrivateProfileSnapshot) async {
        await FileLogger.shared.activateProfile(profile)
        #if os(macOS)
        AppSearchService.shared.activateCurrentProfile()
        AnalyticsService.shared.activateCurrentProfile()
        #endif
    }
}

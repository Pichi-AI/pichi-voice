import Foundation

/// Where an Edit Mode request runs. The shortcut and the request ask the same
/// question, so they can't disagree about whether the model is there.
enum EditModeRoute: Equatable {
    /// A cloud or custom provider, picked in AI Settings.
    case provider
    case local(PrivateAIRegisteredModel)
    /// The on-device provider is selected, but its Edit model is not downloaded.
    case modelMissing
    /// The selected on-device provider does not offer an Edit model in this build.
    case notOffered
    case unsupportedHardware

    /// Why Edit Mode can't run, or nil when it can.
    var failureMessage: String? {
        switch self {
        case .provider, .local: nil
        case .modelMissing: PichiLocalization.text("Edit Mode needs its model")
        case .notOffered: PichiLocalization.text("Choose an AI provider to use Edit Mode.")
        case .unsupportedHardware: PichiLocalization.text("On-device Edit Mode needs Apple Silicon. Choose an AI provider.")
        }
    }

    nonisolated static func resolve(
        providerID: String,
        privateProviderID: String?,
        editModel: PrivateAIRegisteredModel?,
        supportsLocalModel: Bool = true,
        isInstalled: (PrivateAIRegisteredModel) -> Bool
    ) -> EditModeRoute {
        let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let privateProviderID, trimmed == privateProviderID else { return .provider }
        guard supportsLocalModel else { return .unsupportedHardware }
        guard let editModel, editModel.isEnabled else { return .notOffered }
        return isInstalled(editModel) ? .local(editModel) : .modelMissing
    }

    /// Checks the model folder, so call it off the main thread where it matters.
    nonisolated static func current(providerID: String) -> EditModeRoute {
        self.resolve(
            providerID: providerID,
            privateProviderID: PrivateAIProviderFeature.shared.isAvailable ? PrivateAIProviderFeature.shared.providerID : nil,
            editModel: PrivateAIIntegrationService.editModel,
            supportsLocalModel: CPUArchitecture.isAppleSilicon,
            isInstalled: { PrivateAIIntegrationService.isModelInstalled($0) }
        )
    }
}

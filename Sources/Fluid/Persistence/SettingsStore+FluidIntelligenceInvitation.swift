import Combine
import Foundation

extension SettingsStore {
    var fluidIntelligenceInvitationDismissed: Bool {
        get { self.defaults.bool(forKey: FluidIntelligenceInvitation.dismissedKey) }
        set {
            self.objectWillChange.send()
            self.defaults.set(newValue, forKey: FluidIntelligenceInvitation.dismissedKey)
        }
    }

    var hasUsedFluidIntelligence: Bool {
        self.defaults.bool(forKey: FluidIntelligenceInvitation.usedKey)
    }

    func recordFluidIntelligenceUse(output: String) {
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !self.hasUsedFluidIntelligence else { return }
        self.objectWillChange.send()
        FluidIntelligenceInvitation.recordSuccess(output: output, defaults: self.defaults)
    }
}

import Foundation

/// The runner extracts the production weak registries, initializer registration,
/// operations and joins verbatim. Its surrounding settings dependencies are inert.
@main @MainActor struct PrivateSettingsOwnerRegistryTests {
    static var checks = 0
    static var failures = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        self.checks += 1
        if !condition() { self.failures += 1; print("FAIL: \(message)") }
    }

    static func eventually(_ condition: @escaping () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        self.check(false, "Owned work did not reach the expected state")
    }

    static func verifyRecreation() {
        // Keep one real owner of each registry live while transient screens churn.
        // Registration cleanup must neither retain dead owners nor lose these live ones.
        let liveModel = AIEnhancementSettingsViewModel()
        let liveController = PrivateAISettingsController(viewModel: liveModel)
        weak var lastModel: AIEnhancementSettingsViewModel?
        weak var lastController: PrivateAISettingsController?
        for _ in 0..<1_000 {
            let model = AIEnhancementSettingsViewModel()
            let controller = PrivateAISettingsController(viewModel: model)
            lastModel = model
            lastController = controller
        }
        self.check(lastModel == nil && lastController == nil, "Transient owners must release without an account transition")
        self.check(AIEnhancementSettingsViewModel.retainedRegistrationCount <= 2,
                   "Model registry must remain bounded after 1,000 same-profile recreations; got \(AIEnhancementSettingsViewModel.retainedRegistrationCount)")
        self.check(PrivateAISettingsController.retainedRegistrationCount <= 2,
                   "Controller registry must remain bounded after 1,000 same-profile recreations; got \(PrivateAISettingsController.retainedRegistrationCount)")
        withExtendedLifetime((liveModel, liveController)) {}
    }

    static func verifyJoinsKeepLiveOwners() async {
        let model = AIEnhancementSettingsViewModel()
        let controller = PrivateAISettingsController(viewModel: model)
        var modelStarted = false
        var modelCancelled = false
        var modelFinished = false
        var controllerStarted = false
        var controllerCancelled = false
        var controllerFinished = false
        let work = Task { @MainActor in
            defer { modelFinished = true }
            do {
                _ = try await model.run {
                    modelStarted = true
                    do { try await Task.sleep(for: .seconds(60)) }
                    catch { modelCancelled = Task.isCancelled; throw error }
                    return 1
                }
            } catch {}
        }
        controller.run {
            defer { controllerFinished = true }
            controllerStarted = true
            do { try await Task.sleep(for: .seconds(60)) }
            catch { controllerCancelled = Task.isCancelled }
        }
        await self.eventually { modelStarted && controllerStarted }
        // Exercise cleanup while active owners must remain registered for the join.
        for _ in 0..<100 {
            let transient = AIEnhancementSettingsViewModel()
            _ = PrivateAISettingsController(viewModel: transient)
        }
        await AIEnhancementSettingsViewModel.joinPrivateProfileRequests()
        await PrivateAISettingsController.joinPrivateProfileTasks()
        await work.value
        self.check(modelCancelled && modelFinished, "Registration pruning must preserve cancellation and joining of live model work")
        self.check(controllerCancelled && controllerFinished, "Registration pruning must preserve cancellation and joining of live controller work")
        self.check(AIEnhancementSettingsViewModel.retainedRegistrationCount == 1,
                   "Join must remove dead model registrations and retain the active owner")
        self.check(PrivateAISettingsController.retainedRegistrationCount == 1,
                   "Join must remove dead controller registrations and retain the active owner")
        // Joins remain safe when invoked again after all work has drained.
        await AIEnhancementSettingsViewModel.joinPrivateProfileRequests()
        await PrivateAISettingsController.joinPrivateProfileTasks()
        self.check(modelFinished && controllerFinished, "Repeated joins must not restart retired work")
    }

    static func verifyAllOwnersRelease() async {
        weak var model: AIEnhancementSettingsViewModel?
        weak var controller: PrivateAISettingsController?
        do {
            let temporaryModel = AIEnhancementSettingsViewModel()
            let temporaryController = PrivateAISettingsController(viewModel: temporaryModel)
            model = temporaryModel; controller = temporaryController
        }
        self.check(model == nil && controller == nil, "Weak registries must not retain the last settings owner")
        await AIEnhancementSettingsViewModel.joinPrivateProfileRequests()
        await PrivateAISettingsController.joinPrivateProfileTasks()
        self.check(AIEnhancementSettingsViewModel.retainedRegistrationCount == 0 && PrivateAISettingsController.retainedRegistrationCount == 0,
                   "Final join must release all dead registrations")
    }

    static func main() async {
        self.verifyRecreation()
        await self.verifyJoinsKeepLiveOwners()
        await self.verifyAllOwnersRelease()
        print("Private settings owner registries: \(self.checks) checks, \(self.failures) failures")
        if self.failures != 0 { exit(1) }
    }
}

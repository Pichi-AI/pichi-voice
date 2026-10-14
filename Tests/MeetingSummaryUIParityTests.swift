// Compiled with actual UI selection/action bodies and production preferences.
// Only controller/route effect boundaries are recorders; no inference or app stores are used.
@main enum SummaryUIParityTests {
    @MainActor static var checks = 0
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
        checks += 1
    }

    @MainActor static func main() throws {
        let suite = "SummaryUIParity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore()
        settings.catalog = [
            .init(providerID: "openai", providerName: "Synthetic A", modelID: "dictation-model", displayName: "D"),
            .init(providerID: "openai", providerName: "Synthetic A", modelID: "template-model", displayName: "T"),
            .init(providerID: "local-synthetic", providerName: "Synthetic B", modelID: "other-model", displayName: "B"),
        ]
        let owner = TemplateOwner(defaults, settings)
        check(owner.preferences.kind == .executive, "Fresh template kind stays executive")
        owner.reloadProviders()
        check(owner.catalogLoaded && owner.hasChoices, "Provider catalog is reachable")
        check(owner.providerID == "openai" && owner.modelID == "dictation-model", "First use chooses the verified global preference")
        owner.selectModel(settings.catalog[1])
        check(owner.modelID == "template-model", "Chosen template model replaces only summary selection")
        check(settings.writes == 0, "Summary choices must not mutate global provider/model selections")
        owner.preferences.kind = .custom
        owner.preferences.customPrompt = "  Перечисли задачи для Ёжика. Keep this wording.  "
        let identity = owner.refreshID
        owner.preferences.customPrompt += " Follow up tomorrow."
        check(owner.refreshID != identity, "Editing a custom prompt invalidates the saved custom summary")
        let rawPrompt = owner.preferences.customPrompt
        owner.generate()
        check(owner.controller.requests.count == 1, "Original Generate action calls the existing controller")
        let request = owner.controller.requests[0]
        check(request.kind == .custom && request.prompt == rawPrompt && request.model == "template-model", "Custom instructions and selected model reach the controller without translation")
        owner.preferences.customPrompt = " \n\t "
        check(owner.needsCustomPrompt, "Whitespace-only prompts remain unavailable")
        owner.generate()
        check(owner.controller.requests.count == 1, "Empty custom instructions cannot dispatch a controller request")
        owner.preferences.customPrompt = rawPrompt
        owner.preferences.thinksFirst = false
        let restored = MeetingSummaryPreferences(defaults: defaults)
        check(restored.kind == .custom && restored.customPrompt == rawPrompt && !restored.thinksFirst, "Template kind, prompt and thinking survive recreation")
        check(restored.selection == owner.preferences.selection, "Independent provider selection survives recreation")
        defaults.set("unknown-future-template", forKey: "MeetingSummaryKind")
        check(MeetingSummaryPreferences(defaults: defaults).kind == .executive, "Unknown stored kinds safely return to the original default")
        settings.selectedProviderID = "local-synthetic"
        settings.writes = 0
        owner.reloadProviders()
        check(owner.providerID == "openai" && owner.modelID == "template-model", "Later global provider changes do not overwrite the summary selection")
        check(settings.writes == 0, "Catalog reload does not write AI settings")
        owner.selectModel(settings.catalog[2])
        check(owner.providerKey == "custom:local-synthetic" && owner.modelID == "other-model", "Custom provider aliases use the production storage key")
        owner.selectProvider("openai")
        check(owner.modelID == "template-model", "Each provider remembers its selected summary model")
        let oldModels = owner.preferences.selection.modelsByProvider
        owner.controller.model = .init(displayName: "Synthetic on-device model")
        owner.reloadProviders()
        check(owner.modelOptions.first?.providerID == MeetingSummaryOnDevice.providerID, "Registry-provided on-device option joins the same chooser")
        owner.selectModel(owner.modelOptions[0])
        check(owner.usesOnDevice && owner.selectedOption?.displayName == "Synthetic on-device model", "On-device selection displays registry metadata")
        check(owner.preferences.selection.modelsByProvider == oldModels, "On-device selection does not rewrite any remote model")
        owner.generate()
        check(owner.controller.requests.last?.thinking == false && owner.controller.requests.last?.prompt == rawPrompt, "Original on-device action keeps thinking and custom instructions")
        check(owner.controller.receivedASR === owner.asrService, "Owner-provided ASR is used for on-device residency")
        owner.isQuiescent = false
        let activeBefore = owner.controller.requests.count
        owner.generate()
        check(owner.controller.requests.count == activeBefore, "An active capture cannot admit an on-device summary")
        owner.isQuiescent = true
        owner.session = nil
        let before = owner.controller.requests.count
        owner.generate()
        check(owner.controller.requests.count == before, "No meeting means no controller request")

        let workflow = WorkflowOwner(defaults)
        check(workflow.presentedWorkflow == .grounded, "Grounded summaries remain the default")
        workflow.workflowSelection.wrappedValue = .templates
        check(workflow.presentedWorkflow == .templates, "The template workflow can be selected")
        workflow.templateController.busy = true
        workflow.workflowSelection.wrappedValue = .grounded
        check(workflow.workflow == .templates && workflow.presentedWorkflow == .templates, "Download, generation and deletion prevent hiding their owner")
        workflow.workflow = .grounded
        check(workflow.presentedWorkflow == .templates, "Another window's stored choice cannot hide an active template operation")
        workflow.templateController.busy = false
        workflow.groundedController.checking = true
        workflow.workflowSelection.wrappedValue = .templates
        check(workflow.presentedWorkflow == .grounded && workflow.workflow == .grounded, "Grounded refresh locks workflow switching")
        workflow.groundedController.checking = false
        workflow.groundedController.generating = true
        workflow.workflowSelection.wrappedValue = .templates
        check(workflow.presentedWorkflow == .grounded && workflow.workflow == .grounded, "Grounded generation keeps its cancel button reachable")
        workflow.groundedController.generating = false
        workflow.workflowSelection.wrappedValue = .templates
        check(workflow.presentedWorkflow == .templates, "Switching unlocks after the existing controller drains")
        check(WorkflowOwner(defaults).workflow == .templates, "The real AppStorage workflow choice survives recreation in an isolated suite")

        let container = NSView(frame: .init(x: 0, y: 0, width: 300, height: 120))
        let marker = DictationTextTarget.Marker(frame: container.bounds)
        container.addSubview(marker)
        let editor = NSTextView(frame: container.bounds)
        container.addSubview(editor)
        check(DictationTextTarget.accepts(editor), "The real AppKit marker accepts the opted-in custom editor")
        editor.isEditable = false
        check(!DictationTextTarget.accepts(editor), "Read-only text remains protected")
        check(marker.hitTest(.zero) == nil, "The marker cannot steal editor clicks")
        print("Summary UI production selection/action/marker: \(checks) checks passed")
    }
}

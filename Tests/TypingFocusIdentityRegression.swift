// Compiled only inside the inert fixture, never the application or its native host.
typealias AXUIElement = SyntheticAXElement
enum AXError: Int32 { case success, invalidUIElement, failure }
nonisolated final class SyntheticAXElement: NSObject, @unchecked Sendable {
    let id: String
    let pid: pid_t
    let role: String
    let subrole: String
    init(_ id: String, pid: pid_t, role: String = "AXTextField", subrole: String = "") { self.id=id; self.pid=pid; self.role=role; self.subrole=subrole }
}
nonisolated final class SyntheticAXBackend: @unchecked Sendable {
    var focus: SyntheticAXElement?
    var trusted = true
    var unexpectedFocus = false
    var pidQueryFails = false
    var refusesRestore = false
    var removed: Set<String> = []
    var values: [String:String] = [:]
    var insertions: [String] = []
    var restoreCount = 0
    var activateCount = 0
    var sendCount = 0
    var onSetFocus: (() -> Void)?
    let system = SyntheticAXElement("system", pid: 0, role: "AXSystemWide")
}
nonisolated(unsafe) var syntheticAX = SyntheticAXBackend()
nonisolated let kAXFocusedUIElementAttribute = "AXFocusedUIElement"
nonisolated let kAXRoleAttribute = "AXRole"
nonisolated let kAXSubroleAttribute = "AXSubrole"
nonisolated let kAXSecureTextFieldSubrole = "AXSecureTextField"
nonisolated let kAXFocusedAttribute = "AXFocused"
nonisolated let kAXMainWindowAttribute = "AXMainWindow"
nonisolated let kAXFocusedWindowAttribute = "AXFocusedWindow"
nonisolated let kAXRaiseAction = "AXRaise"
nonisolated let kAXValueAttribute = "AXValue"
nonisolated func AXIsProcessTrusted() -> Bool { syntheticAX.trusted }
nonisolated func AXUIElementCreateSystemWide() -> AXUIElement { syntheticAX.system }
nonisolated func AXUIElementCreateApplication(_ pid: pid_t) -> AXUIElement { .init("app", pid: pid, role: "AXApplication") }
nonisolated func AXUIElementGetTypeID() -> CFTypeID { 123 }
nonisolated func CFGetTypeID(_ value: CFTypeRef) -> CFTypeID { value is SyntheticAXElement ? 123 : 124 }
nonisolated func CFEqual(_ left: CFTypeRef?, _ right: CFTypeRef?) -> Bool {
    guard let left = left as? SyntheticAXElement, let right = right as? SyntheticAXElement else { return false }
    return left.id == right.id && left.pid == right.pid
}
nonisolated func AXUIElementCopyAttributeValue(_ element: AXUIElement, _ attribute: CFString, _ value: inout CFTypeRef?) -> AXError {
    if syntheticAX.removed.contains(element.id) { return .invalidUIElement }
    switch attribute as String {
    case kAXFocusedUIElementAttribute:
        if syntheticAX.unexpectedFocus { value = "wrong type" as NSString; return .success }
        value = syntheticAX.focus; return value == nil ? .failure : .success
    case kAXRoleAttribute: value = element.role as NSString; return .success
    case kAXSubroleAttribute: value = element.subrole as NSString; return .success
    default: return .failure
    }
}
@discardableResult nonisolated func AXUIElementGetPid(_ element: AXUIElement, _ pid: inout pid_t) -> AXError {
    if syntheticAX.pidQueryFails || syntheticAX.removed.contains(element.id) { return .invalidUIElement }
    pid = element.pid; return .success
}
nonisolated func AXUIElementPerformAction(_ element: AXUIElement, _ action: CFString) -> AXError { .success }
nonisolated func AXUIElementSetAttributeValue(_ element: AXUIElement, _ attribute: CFString, _ value: CFTypeRef) -> AXError {
    guard !syntheticAX.removed.contains(element.id) else { return .invalidUIElement }
    if attribute as String == kAXFocusedAttribute {
        syntheticAX.restoreCount += 1
        syntheticAX.onSetFocus?()
        if !syntheticAX.refusesRestore { syntheticAX.focus = element }
    }
    return .success
}
nonisolated func AXUIElementIsAttributeSettable(_ element: AXUIElement, _ attribute: CFString, _ value: inout DarwinBoolean) -> AXError { value = false; return .success }
nonisolated enum NSApplication { struct ActivationOptions: OptionSet { let rawValue: Int; static let activateIgnoringOtherApps = Self(rawValue: 1) } }
nonisolated final class NSRunningApplication: @unchecked Sendable {
    let processIdentifier: pid_t
    var bundleIdentifier: String? { processIdentifier == 999 ? Bundle.main.bundleIdentifier : "synthetic.external" }
    init?(processIdentifier: pid_t) { self.processIdentifier = processIdentifier }
    func activate(options: NSApplication.ActivationOptions) -> Bool { syntheticAX.activateCount += 1; return true }
}
nonisolated final class NSWorkspace: @unchecked Sendable { static let shared = NSWorkspace(); var frontmostApplication: NSRunningApplication? { syntheticAX.focus.flatMap { NSRunningApplication(processIdentifier:$0.pid) } } }
@MainActor final class SyntheticPasteboard { var changeCount=0; var backup="" }
@MainActor final class SettingsStore {
    static let shared=SettingsStore(); var showPasteCheckAlerts=false
    enum TextInsertionMode: String { case reliablePaste }
    enum SpokenSendKey { case enter }
}
@MainActor enum PasteVerifier { static func capture() -> Int? { nil } }
struct OverlayCloseTrace { init(_ name:String) {}; mutating func finish() {} }
@MainActor final class DebugLogger { static let shared=DebugLogger(); func info(_ text:String, source:String) {} }
@MainActor final class AutomaticDictionaryCorrectionTracker { static let shared=AutomaticDictionaryCorrectionTracker(); func beginObservingInsertion(_ text:String,targetPID:pid_t?) {} }
@MainActor final class SyntheticApplication { var hideCount=0; func hide(_ sender:Any?) { hideCount += 1 } }
@MainActor let NSApp = SyntheticApplication()
@MainActor final class SyntheticASR { var errorTitle=""; var errorMessage=""; var showError=false }
@MainActor final class AppServices { static let shared=AppServices(); let asr=SyntheticASR() }
@MainActor final class NotchContentState { static let shared=NotchContentState(); var recordingTargetContext:TypingService.RecordingTargetContext? }

@main @MainActor struct TypingFocusIdentityRegression {
    static var checks=0
    static func check(_ condition: Bool, _ message:String) { checks += 1; precondition(condition,message) }
    static func context(_ element:SyntheticAXElement, window:String="window-A", pid:pid_t?=nil) -> TypingService.RecordingTargetContext {
        .init(id:UUID(),pid:pid ?? element.pid,bundleIdentifier:"synthetic.external",window:.init(window,pid:element.pid,role:"AXWindow"),element:element)
    }
    static func deliver(_ selected:TypingService.RecordingTargetContext?, text:String="synthetic marker", key:SettingsStore.SpokenSendKey?=nil, valid:@escaping @MainActor ()->Bool={true}) async -> TypingService.DeliveryOutcome {
        let snapshot=DictationStopSnapshot(target:selected)
        guard await snapshot.prepareDelivery(text,keepBackup:true,isOutputValid:valid), let selected else { return .rejected }
        let exact=selected.element.map { TypingService.CapturedFocusTarget(pid:selected.pid,window:selected.window,element:$0) }
        return await withCheckedContinuation { continuation in
            TypingService().typeOutputPlanInstantly(.plain(text),preferredTargetPID:selected.pid,textReadyAt:nil,postInsertionKey:key,requiredFocusTarget:exact,isOutputValid:valid) { continuation.resume(returning:$0) }
        }
    }
    static func reset(_ focus:SyntheticAXElement?) {
        syntheticAX=SyntheticAXBackend(); syntheticAX.focus=focus; PasteDeliveryCoordinator.shared.pasteboard.backup=""
        NotchContentState.shared.recordingTargetContext=nil
        NSApp.hideCount=0
        let activity=MeetingSummaryActivityCoordinator.shared
        activity.summary=nil; activity.processing=[]; activity.optionalProcessing=[:]; activity.isProcessing=false
        let asr=AppServices.shared.asr
        asr.errorTitle=""; asr.errorMessage=""; asr.showError=false
    }
    static func rewriteAcceptance() async {
        let a=SyntheticAXElement("A",pid:42)
        let b=SyntheticAXElement("B",pid:42)
        let service=RewriteModeService()
        service.rewrittenText="synthetic rewrite"
        reset(b); NotchContentState.shared.recordingTargetContext=context(a); syntheticAX.refusesRestore=true
        let failed:Any=await service.acceptRewrite(service.rewrittenText)
        check(syntheticAX.insertions.isEmpty && syntheticAX.values["B"]==nil,
              "Failed Rewrite target preparation must never paste into B; actual insertions: \(syntheticAX.insertions)")
        check(failed as? TextDeliveryResult == .recoverableFailure(.targetRestoreFailed),"Failed restore is surfaced through the existing delivery failure contract")
        check(service.rewrittenText=="synthetic rewrite" && !service.isAcceptingRewrite,"A failed accept retains its pending result and releases its owner")
        check(MeetingSummaryActivityCoordinator.shared.processing.isEmpty && !MeetingSummaryActivityCoordinator.shared.isProcessing,"Failed restore releases the actual summary activity token")

        reset(b); NotchContentState.shared.recordingTargetContext=context(a)
        let restored:Any=await service.acceptRewrite(service.rewrittenText)
        check(restored as? TextDeliveryResult == .commandPosted && syntheticAX.values["A"]=="synthetic rewrite" && syntheticAX.values["B"]==nil,"Successful Rewrite restores A before the actual typing intent dispatch")
        check(syntheticAX.restoreCount==1 && !service.isAcceptingRewrite && MeetingSummaryActivityCoordinator.shared.processing.isEmpty,"Successful acceptance releases ownership without repeating restore")
        reset(.init("A",pid:42)); NotchContentState.shared.recordingTargetContext=context(a)
        let exact:Any=await service.acceptRewrite(service.rewrittenText)
        check(exact as? TextDeliveryResult == .commandPosted && syntheticAX.restoreCount==0 && syntheticAX.values["A"]=="synthetic rewrite","Exact focused A keeps the existing successful dispatch path")

        reset(b); NotchContentState.shared.recordingTargetContext=context(a); syntheticAX.removed.insert("A")
        _ = await service.acceptRewrite(service.rewrittenText)
        check(syntheticAX.insertions.isEmpty,"Removed Rewrite targets cannot redirect text into B")
        reset(b); NotchContentState.shared.recordingTargetContext=context(a); syntheticAX.trusted=false
        let denied:Any=await service.acceptRewrite(service.rewrittenText)
        check(denied as? TextDeliveryResult == .recoverableFailure(.accessibilityNotTrusted) && syntheticAX.insertions.isEmpty,"Unavailable permission keeps its specific failure and performs no input")

        reset(b); NotchContentState.shared.recordingTargetContext=context(a)
        let cancelledBefore=Task { @MainActor in await service.acceptRewrite(service.rewrittenText) as Any }
        cancelledBefore.cancel()
        let cancelledBeforeResult=await cancelledBefore.value
        check(cancelledBeforeResult as? TextDeliveryResult == .cancelled && NSApp.hideCount==0 && syntheticAX.restoreCount==0 && syntheticAX.insertions.isEmpty,"Cancelled admission must have no hide/focus/paste effects")
        check(MeetingSummaryActivityCoordinator.shared.processing.isEmpty,"Cancelled admission acquires no activity token")

        reset(b); NotchContentState.shared.recordingTargetContext=context(a)
        var accepting:Task<Any,Never>?
        syntheticAX.onSetFocus={ accepting?.cancel() }
        accepting=Task { @MainActor in await service.acceptRewrite(service.rewrittenText) as Any }
        let cancelledDuring=await accepting!.value
        check(cancelledDuring as? TextDeliveryResult == .cancelled && syntheticAX.insertions.isEmpty,"Cancellation during focus restore must stop before the actual paste transport")
        check(!service.isAcceptingRewrite && service.rewrittenText=="synthetic rewrite" && MeetingSummaryActivityCoordinator.shared.processing.isEmpty,"Joined cancelled acceptance retains text and releases its activity and action owner")

        reset(b); NotchContentState.shared.recordingTargetContext=context(a)
        let first=Task { @MainActor in await service.acceptRewrite(service.rewrittenText) as Any }
        for _ in 0..<1000 where !service.isAcceptingRewrite { await Task.yield() }
        check(service.isAcceptingRewrite,"First acceptance must own the suspended restore before a reentrant action")
        let overlapping:Any=await service.acceptRewrite(service.rewrittenText)
        check(overlapping as? TextDeliveryResult == .cancelled && NSApp.hideCount==1 && MeetingSummaryActivityCoordinator.shared.processing.count==1,"A second queued acceptance does not acquire another owner or repeat hide")
        _ = await first.value
        check(syntheticAX.insertions==["A"] && !service.isAcceptingRewrite && MeetingSummaryActivityCoordinator.shared.processing.isEmpty,"Overlapping accept actions dispatch exactly once and release the original token")

        reset(b); MeetingSummaryActivityCoordinator.shared.summary=UUID()
        let busy:Any=await service.acceptRewrite(service.rewrittenText)
        check(busy as? TextDeliveryResult == .cancelled && AppServices.shared.asr.showError && syntheticAX.insertions.isEmpty && NSApp.hideCount==0,"Summary rejection preserves existing busy feedback and has no paste effects")
        reset(b)
        let empty:Any=await service.acceptRewrite("")
        check(empty as? TextDeliveryResult == .recoverableFailure(.emptyText) && NSApp.hideCount==0 && syntheticAX.insertions.isEmpty && MeetingSummaryActivityCoordinator.shared.processing.isEmpty,"Empty acceptance releases admission without hiding or typing")
        reset(b)
        let uncaptured:Any=await service.acceptRewrite(service.rewrittenText)
        check(uncaptured as? TextDeliveryResult == .commandPosted && syntheticAX.values["B"]=="synthetic rewrite","The existing uncaptured/current-field Rewrite fallback is preserved")

        #if !LEGACY_REWRITE
        let view=RewriteAcceptViewAction(service:service)
        var closes=0
        view.onClose={ closes += 1 }
        reset(b); NotchContentState.shared.recordingTargetContext=context(a); syntheticAX.refusesRestore=true
        view.accept(); await view.action!.value
        check(closes==0 && service.rewrittenText=="synthetic rewrite" && syntheticAX.insertions.isEmpty,"Actual Replace Original action retains its pending view on failed restore")
        check(AppServices.shared.asr.showError && AppServices.shared.asr.errorTitle==TextDeliveryFailure.targetRestoreFailed.userFacingMessage && !AppServices.shared.asr.errorMessage.isEmpty,"Actual view uses existing delivery failure copy and the shared error surface")
        reset(a); NotchContentState.shared.recordingTargetContext=context(a)
        view.accept(); await view.action!.value
        check(closes==1 && syntheticAX.insertions==["A"] && !AppServices.shared.asr.showError,"Actual view closes only after successful command dispatch, without claiming paste verification")
        reset(a); NotchContentState.shared.recordingTargetContext=context(a)
        view.accept(); view.action!.cancel(); await view.action!.value
        check(closes==1 && syntheticAX.insertions.isEmpty && NSApp.hideCount==0 && !AppServices.shared.asr.showError,"Cancelled Replace Original does not close pending view or present a false delivery failure")
        #endif
    }
    static func main() async {
        if CommandLine.arguments.contains("--rewrite-only") {
            await rewriteAcceptance()
            print("Rewrite acceptance: \(checks) checks PASS; actual production bodies, synthetic backend only")
            return
        }
        for role in ["AXTextField","AXTextArea","AXSearchField","AXComboBox","AXWebArea","AXGroup"] {
            for otherWindow in [false,true] {
                let a=SyntheticAXElement("A",pid:42)
                let b=SyntheticAXElement("B",pid:42,role:role)
                let start=context(a)
                let end=context(b,window:otherWindow ? "window-B":"window-A")
                reset(b)
                let selected=DictationStopSnapshot.selectTarget(current:end,original:start,returnToStartingField:true,ownOverlayFocused:false)
                let outcome=await deliver(selected)
                check(syntheticAX.values["A"]=="synthetic marker" && syntheticAX.values["B"]==nil,
                      "Captured A must receive text after restore, never same-PID B; actual insertions: \(syntheticAX.insertions)")
                check(outcome == .inserted && syntheticAX.restoreCount==1,"The actual prepare/typing chain must restore A before dispatch")
                check(selected?.id==start.id,"Preparing output must retain the immutable selected context")
                reset(b)
                let current=DictationStopSnapshot.selectTarget(current:end,original:start,returnToStartingField:false,ownOverlayFocused:false)
                _ = await deliver(current)
                check(syntheticAX.values["B"]=="synthetic marker" && syntheticAX.restoreCount==0,"Normal mode still follows current B without restoring A")
            }
        }
        let a=SyntheticAXElement("A",pid:42)
        let b=SyntheticAXElement("B",pid:42)
        reset(.init("A",pid:42))
        let same=context(a)
        check(TypingService.isCapturedFocusStillActive(same),"Distinct wrappers for the exact same AX identity remain equivalent")
        check(await TypingService.prepareTargetForDelivery(same) == .alreadyFocused,"Exact A needs no restore")
        for invalid in 0..<5 {
            reset(b)
            var target:TypingService.RecordingTargetContext?=same
            if invalid==0 { target=nil }
            if invalid==1 { syntheticAX.removed.insert("A") }
            if invalid==2 { target=context(a,pid:77) }
            if invalid==3 { syntheticAX.refusesRestore=true }
            if invalid==4 { syntheticAX.unexpectedFocus=true }
            let result=await deliver(target)
            check(result == .rejected && syntheticAX.insertions.isEmpty,"Invalid/removed/foreign-PID/unrestored focus must not redirect output to B")
        }
        reset(a); syntheticAX.pidQueryFails=true
        check(!TypingService.isCapturedFocusStillActive(same),"Failed PID observation cannot validate even an equal AX wrapper")
        for secure in ["AXSecureTextField","custom-secure-editor"] {
            let field=SyntheticAXElement("secure",pid:42,subrole:secure)
            reset(field)
            let result=await deliver(context(field),key:.enter)
            check(result == .actionSuppressed && syntheticAX.insertions.isEmpty && syntheticAX.sendCount==0,"Existing explicit-send policy rejects secure fields before insertion/action")
            reset(field)
            check(await deliver(context(field)) == .inserted,"Normal secure-field typing keeps its separate existing eligibility contract")
        }
        reset(b)
        var valid=true
        syntheticAX.onSetFocus={valid=false}
        check(await deliver(same,valid:{valid}) == .rejected && syntheticAX.insertions.isEmpty,"Output invalidation during restore must stop before any typing intent")
        reset(b)
        check(await deliver(same,valid:{false}) == .rejected && syntheticAX.restoreCount==0,"Invalid output cannot focus a target")
        reset(b); syntheticAX.trusted=false
        check(await deliver(same) == .rejected && syntheticAX.insertions.isEmpty,"Permission-unavailable preparation never invokes native input or another-field fallback")
        reset(.init("overlay",pid:999))
        let overlay=context(syntheticAX.focus!)
        let selected=DictationStopSnapshot.selectTarget(current:overlay,original:same,returnToStartingField:false,ownOverlayFocused:true)
        _ = await deliver(selected)
        check(syntheticAX.values["A"]=="synthetic marker" && syntheticAX.values["overlay"]==nil,"Own overlay recovers the original external field")
        check(OnboardingDictationOutputPolicy.usesSandbox(onboardingPracticeActive:true,isDictation:true,targetProcessID:999,fluidVoiceProcessID:999),"Onboarding's own-app output remains sandboxed")
        check(OnboardingDictationOutputPolicy.usesSandbox(onboardingPracticeActive:true,isDictation:true,targetProcessID:nil,fluidVoiceProcessID:999),"Unknown onboarding target stays in sandbox")
        check(!OnboardingDictationOutputPolicy.usesSandbox(onboardingPracticeActive:true,isDictation:true,targetProcessID:42,fluidVoiceProcessID:999),"Explicit external onboarding targets retain the existing policy")
        check(Bundle.main.bundleIdentifier != nil && !TypingService.activateAppForRecovery(pid:999),"The real recovery helper refuses its own bundle without activation")
        let targetPolicy=DictationTargetPolicy.resolve(returnToStartingField:true,focusedPID:42,ownPID:999,originalPID:42,originalFieldIsFocused:false)
        check(targetPolicy.shouldRestoreOriginalFocus && targetPolicy.pid==42,"Existing intent policy can now consume genuine field identity instead of same-PID role approximation")
        await rewriteAcceptance()
        print("Typing focus identity: \(checks) checks PASS; actual helper/prepare/stop selection/typing/Rewrite intents; synthetic AX and paste backend only, no UI, TCC, CGEvent or clipboard")
    }
}

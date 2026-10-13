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
    var allowCGEvents = true
    var onEventConstruct: (() -> Void)?
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
nonisolated let kAXSelectedTextAttribute = "AXSelectedText"
nonisolated let kAXSelectedTextRangeAttribute = "AXSelectedTextRange"
nonisolated let kAXChildrenAttribute = "AXChildren"
nonisolated let kAXTitleAttribute = "AXTitle"
nonisolated let kAXInsertionPointLineNumberAttribute = "AXInsertionPointLineNumber"
nonisolated func AXIsProcessTrusted() -> Bool { syntheticAX.trusted }
nonisolated func AXUIElementCreateSystemWide() -> AXUIElement { syntheticAX.system }
nonisolated func AXUIElementCreateApplication(_ pid: pid_t) -> AXUIElement { .init("app", pid: pid, role: "AXApplication") }
nonisolated func AXUIElementGetTypeID() -> CFTypeID { 123 }
nonisolated func CFGetTypeID(_ value: CFTypeRef) -> CFTypeID { value is SyntheticAXElement ? 123 : (value is AXValue ? 125 : 124) }
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
    case kAXValueAttribute: value = (syntheticAX.values[element.id] ?? "") as NSString; return .success
    case kAXSelectedTextRangeAttribute: value = AXValue(range:CFRange(location:0,length:0)); return .success
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
    } else if [kAXValueAttribute,kAXSelectedTextAttribute].contains(attribute as String) {
        syntheticAX.values[element.id] = value as? String ?? ""
        syntheticAX.insertions.append(element.id)
    }
    return .success
}
nonisolated func AXUIElementIsAttributeSettable(_ element: AXUIElement, _ attribute: CFString, _ value: inout DarwinBoolean) -> AXError { value = false; return .success }
nonisolated enum NSApplication { struct ActivationOptions: OptionSet { let rawValue: Int; static let activateIgnoringOtherApps = Self(rawValue: 1) } }
nonisolated final class NSRunningApplication: @unchecked Sendable {
    let processIdentifier: pid_t
    var bundleIdentifier: String? { processIdentifier == 999 ? Bundle.main.bundleIdentifier : "synthetic.external" }
    var localizedName: String? { "Synthetic application" }
    init?(processIdentifier: pid_t) { self.processIdentifier = processIdentifier }
    func activate(options: NSApplication.ActivationOptions) -> Bool { syntheticAX.activateCount += 1; return true }
}
nonisolated final class NSWorkspace: @unchecked Sendable { static let shared = NSWorkspace(); var frontmostApplication: NSRunningApplication? { syntheticAX.focus.flatMap { NSRunningApplication(processIdentifier:$0.pid) } } }
@MainActor final class SettingsStore {
    static let shared=SettingsStore(); var showPasteCheckAlerts=false
    var textInsertionMode: TextInsertionMode = .reliablePaste
    var copyTranscriptionToClipboard=false
    enum TextInsertionMode: String { case standard, reliablePaste }
    enum SpokenSendKey { case enter }
}
@MainActor enum PasteVerifier { static func capture() -> Int? { nil } }
struct OverlayCloseTrace { init(_ name:String) {}; mutating func finish() {} }
@MainActor final class DebugLogger {
    static let shared=DebugLogger()
    @TaskLocal static var pipelineID: String?
    func info(_ text:String, source:String) {}
    func benchmark(_ category:String,message:String,source:String) {}
    func error(_ text:String,source:String) {}
    func debug(_ text:String,source:String) {}
}
@MainActor final class AutomaticDictionaryCorrectionTracker { static let shared=AutomaticDictionaryCorrectionTracker(); func beginObservingInsertion(_ text:String,targetPID:pid_t?) {} }
@MainActor final class SyntheticApplication { var hideCount=0; func hide(_ sender:Any?) { hideCount += 1 } }
@MainActor let NSApp = SyntheticApplication()
@MainActor final class SyntheticASR { var errorTitle=""; var errorMessage=""; var showError=false }
@MainActor final class AppServices { static let shared=AppServices(); let asr=SyntheticASR() }
@MainActor final class NotchContentState {
    static let shared=NotchContentState()
    var recordingTargetContext:TypingService.RecordingTargetContext?
    var recordingTargetPID:pid_t?
    var onRetryTextDeliveryRequested:((String)->Void)?
}
@MainActor final class NotchOverlayManager { static let shared=NotchOverlayManager(); func updateTranscriptionText(_ text:String) {} }
@MainActor final class AutomaticRewriteDouble {
    var originalText="original synthetic text"; var rewrittenText=""; var clears=0
    var respond:CheckedContinuation<Void,Never>?
    func setPromptAppBundleID(_ id:String) {}
    func processRewriteRequest(_ text:String) async { await withCheckedContinuation { respond=$0 }; rewrittenText="automatic frozen text" }
    func clearState() { rewrittenText=""; originalText=""; clears += 1 }
}
@MainActor final class AutomaticMenuDouble {
    var isProcessing=false; var finishes=0
    func setProcessing(_ processing:Bool) { isProcessing=processing }
    func finishProcessingKeepingOverlayVisible() { finishes += 1; isProcessing=false }
    func finishProcessingAndHideOverlay() async { finishes += 1; isProcessing=false }
}
// Compile the actual localization helper without reading/writing real preferences.
nonisolated final class UserDefaults: @unchecked Sendable {
    static let standard=UserDefaults()
    private var values:[String:Any]=[:]
    func string(forKey key:String)->String? { self.values[key] as? String }
    func set(_ value:Any?,forKey key:String) { self.values[key]=value }
}
@MainActor var syntheticPasteboard=FakePasteboardManager(text:"original synthetic clipboard")
@MainActor var syntheticPoster=FakePasteCommandPoster()
@MainActor final class SystemPasteboardManager: PasteboardManaging {
    init() { fatalError("Real/default pasteboard initialization is forbidden") }
    var changeCount:Int { fatalError() }
    func captureSnapshot()->PasteboardSnapshot? { fatalError() }
    func writeTemporaryText(_ text:String,sessionID:String)->Bool { fatalError() }
    func writeIntentionalText(_ text:String)->Bool { fatalError() }
    func isOwned(sessionID:String,expectedText:String)->Bool { fatalError() }
    func restore(_ snapshot:PasteboardSnapshot)->Bool { fatalError() }
    func restoreTemporarySnapshot(_ snapshot:PasteboardSnapshot,sessionID:String,expectedText:String)->Bool { fatalError() }
}
@MainActor final class SystemPasteCommandPoster: PasteCommandPosting {
    init() { fatalError("Real/default command poster initialization is forbidden") }
    func postGlobalPasteCommand() async->Bool { fatalError() }
}

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
        if key == nil {
            let result=await StopDeliveryCaller().deliver(.plain(text),snapshot:snapshot)
            return result.wasDispatched ? .inserted : .insertionFailed
        }
        return await withCheckedContinuation { continuation in
            TypingService().typeOutputPlanInstantly(.plain(text),preferredTargetPID:selected.pid,textReadyAt:nil,postInsertionKey:key,requiredFocusTarget:exact,isOutputValid:valid) { continuation.resume(returning:$0) }
        }
    }
    static func reset(_ focus:SyntheticAXElement?) {
        PasteDeliveryCoordinator.shared.runPendingSettlementForTesting()
        syntheticAX=SyntheticAXBackend(); syntheticAX.focus=focus
        SettingsStore.shared.textInsertionMode = .reliablePaste
        syntheticPasteboard=FakePasteboardManager(text:"original synthetic clipboard")
        syntheticPoster=FakePasteCommandPoster()
        let board=syntheticPasteboard
        syntheticPoster.onPost={
            if let field=syntheticAX.focus {
                syntheticAX.values[field.id,default:""] += board.text
                syntheticAX.insertions.append(field.id)
            }
        }
        PasteDeliveryCoordinator.shared=PasteDeliveryCoordinator(pasteboard:syntheticPasteboard,commandPoster:syntheticPoster,settlementDelayNanoseconds:10_000_000_000)
        NotchContentState.shared.recordingTargetContext=nil
        NotchContentState.shared.recordingTargetPID=nil
        NotchContentState.shared.onRetryTextDeliveryRequested=nil
        NSApp.hideCount=0
        let activity=MeetingSummaryActivityCoordinator.shared
        activity.summary=nil; activity.processing=[]; activity.optionalProcessing=[:]; activity.isProcessing=false
        let asr=AppServices.shared.asr
        asr.errorTitle=""; asr.errorMessage=""; asr.showError=false
        UserDefaults.standard.set("en",forKey:PichiInterfaceLanguage.defaultsKey)
    }
    static func rewriteAcceptance() async {
        let a=SyntheticAXElement("A",pid:42)
        let b=SyntheticAXElement("B",pid:42)
        let service=RewriteModeService()
        service.rewrittenText="synthetic rewrite"
        reset(b); NotchContentState.shared.recordingTargetContext=context(a); syntheticAX.refusesRestore=true
        let failed:Any=await service.acceptRewrite(service.rewrittenText,targetContext:NotchContentState.shared.recordingTargetContext)
        check(syntheticAX.insertions.isEmpty && syntheticAX.values["B"]==nil,
              "Failed Rewrite target preparation must never paste into B; actual insertions: \(syntheticAX.insertions)")
        check(failed as? TextDeliveryResult == .recoverableFailure(.targetRestoreFailed),"Failed restore is surfaced through the existing delivery failure contract")
        check(service.rewrittenText=="synthetic rewrite" && !service.isAcceptingRewrite,"A failed accept retains its pending result and releases its owner")
        check(MeetingSummaryActivityCoordinator.shared.processing.isEmpty && !MeetingSummaryActivityCoordinator.shared.isProcessing,"Failed restore releases the actual summary activity token")

        reset(b); NotchContentState.shared.recordingTargetContext=context(a)
        let restored:Any=await service.acceptRewrite(service.rewrittenText,targetContext:NotchContentState.shared.recordingTargetContext)
        check(restored as? TextDeliveryResult == .commandPosted && syntheticAX.values["A"]=="synthetic rewrite" && syntheticAX.values["B"]==nil,"Successful Rewrite restores A before the actual typing intent dispatch")
        check(syntheticAX.restoreCount==1 && !service.isAcceptingRewrite && MeetingSummaryActivityCoordinator.shared.processing.isEmpty,"Successful acceptance releases ownership without repeating restore")
        reset(.init("A",pid:42)); NotchContentState.shared.recordingTargetContext=context(a)
        let exact:Any=await service.acceptRewrite(service.rewrittenText,targetContext:NotchContentState.shared.recordingTargetContext)
        check(exact as? TextDeliveryResult == .commandPosted && syntheticAX.restoreCount==0 && syntheticAX.values["A"]=="synthetic rewrite","Exact focused A keeps the existing successful dispatch path")

        reset(b); NotchContentState.shared.recordingTargetContext=context(a); syntheticAX.removed.insert("A")
        _ = await service.acceptRewrite(service.rewrittenText,targetContext:NotchContentState.shared.recordingTargetContext)
        check(syntheticAX.insertions.isEmpty,"Removed Rewrite targets cannot redirect text into B")
        reset(b); NotchContentState.shared.recordingTargetContext=context(a); syntheticAX.trusted=false
        let denied:Any=await service.acceptRewrite(service.rewrittenText,targetContext:NotchContentState.shared.recordingTargetContext)
        check(denied as? TextDeliveryResult == .recoverableFailure(.accessibilityNotTrusted) && syntheticAX.insertions.isEmpty,"Unavailable permission keeps its specific failure and performs no input")

        reset(b); NotchContentState.shared.recordingTargetContext=context(a)
        let cancelledBefore=Task { @MainActor in await service.acceptRewrite(service.rewrittenText,targetContext:NotchContentState.shared.recordingTargetContext) as Any }
        cancelledBefore.cancel()
        let cancelledBeforeResult=await cancelledBefore.value
        check(cancelledBeforeResult as? TextDeliveryResult == .cancelled && NSApp.hideCount==0 && syntheticAX.restoreCount==0 && syntheticAX.insertions.isEmpty,"Cancelled admission must have no hide/focus/paste effects")
        check(MeetingSummaryActivityCoordinator.shared.processing.isEmpty,"Cancelled admission acquires no activity token")

        reset(b); NotchContentState.shared.recordingTargetContext=context(a)
        var accepting:Task<Any,Never>?
        syntheticAX.onSetFocus={ accepting?.cancel() }
        accepting=Task { @MainActor in await service.acceptRewrite(service.rewrittenText,targetContext:NotchContentState.shared.recordingTargetContext) as Any }
        let cancelledDuring=await accepting!.value
        check(cancelledDuring as? TextDeliveryResult == .cancelled && syntheticAX.insertions.isEmpty,"Cancellation during focus restore must stop before the actual paste transport")
        check(!service.isAcceptingRewrite && service.rewrittenText=="synthetic rewrite" && MeetingSummaryActivityCoordinator.shared.processing.isEmpty,"Joined cancelled acceptance retains text and releases its activity and action owner")

        reset(b); NotchContentState.shared.recordingTargetContext=context(a)
        let first=Task { @MainActor in await service.acceptRewrite(service.rewrittenText,targetContext:NotchContentState.shared.recordingTargetContext) as Any }
        for _ in 0..<1000 where !service.isAcceptingRewrite { await Task.yield() }
        check(service.isAcceptingRewrite,"First acceptance must own the suspended restore before a reentrant action")
        let overlapping:Any=await service.acceptRewrite(service.rewrittenText,targetContext:NotchContentState.shared.recordingTargetContext)
        check(overlapping as? TextDeliveryResult == .cancelled && NSApp.hideCount==1 && MeetingSummaryActivityCoordinator.shared.processing.count==1,"A second queued acceptance does not acquire another owner or repeat hide")
        _ = await first.value
        check(syntheticAX.insertions==["A"] && !service.isAcceptingRewrite && MeetingSummaryActivityCoordinator.shared.processing.isEmpty,"Overlapping accept actions dispatch exactly once and release the original token")

        reset(b); MeetingSummaryActivityCoordinator.shared.summary=UUID()
        let busy:Any=await service.acceptRewrite(service.rewrittenText,targetContext:NotchContentState.shared.recordingTargetContext)
        check(busy as? TextDeliveryResult == .cancelled && AppServices.shared.asr.showError && syntheticAX.insertions.isEmpty && NSApp.hideCount==0,"Summary rejection preserves existing busy feedback and has no paste effects")
        reset(b)
        let empty:Any=await service.acceptRewrite("",targetContext:NotchContentState.shared.recordingTargetContext)
        check(empty as? TextDeliveryResult == .recoverableFailure(.emptyText) && NSApp.hideCount==0 && syntheticAX.insertions.isEmpty && MeetingSummaryActivityCoordinator.shared.processing.isEmpty,"Empty acceptance releases admission without hiding or typing")
        reset(b)
        let uncaptured:Any=await service.acceptRewrite(service.rewrittenText,targetContext:NotchContentState.shared.recordingTargetContext)
        check(uncaptured as? TextDeliveryResult == .commandPosted && syntheticAX.values["B"]=="synthetic rewrite","The existing uncaptured/current-field Rewrite fallback is preserved")

        #if !LEGACY_REWRITE
        let view=RewriteAcceptViewAction(service:service)
        var closes=0
        view.onClose={ closes += 1 }
        reset(b); NotchContentState.shared.recordingTargetContext=context(a); syntheticAX.refusesRestore=true
        view.accept(); await view.acceptanceTask!.value
        check(closes==0 && service.rewrittenText=="synthetic rewrite" && syntheticAX.insertions.isEmpty,"Actual Replace Original action retains its pending view on failed restore")
        check(AppServices.shared.asr.showError && AppServices.shared.asr.errorTitle==TextDeliveryFailure.targetRestoreFailed.userFacingMessage && !AppServices.shared.asr.errorMessage.isEmpty,"Actual view uses existing delivery failure copy and the shared error surface")
        reset(a); NotchContentState.shared.recordingTargetContext=context(a)
        view.accept(); await view.acceptanceTask!.value
        check(closes==1 && syntheticAX.insertions==["A"] && !AppServices.shared.asr.showError,"Actual view closes only after successful command dispatch, without claiming paste verification")
        reset(a); NotchContentState.shared.recordingTargetContext=context(a)
        view.accept(); view.acceptanceTask!.cancel(); await view.acceptanceTask!.value
        check(closes==1 && syntheticAX.insertions.isEmpty && NSApp.hideCount==0 && !AppServices.shared.asr.showError,"Cancelled Replace Original does not close pending view or present a false delivery failure")
        for (language,title,detail) in [
            ("ru","Не удалось вставить текст","Текст сохранён. Скопируйте его и вставьте в текстовое поле."),
            ("en","Oops, text wasn't inserted","Your transcript is saved. Copy it and paste it into a text field."),
        ] {
            reset(b); NotchContentState.shared.recordingTargetContext=context(a); syntheticAX.refusesRestore=true
            UserDefaults.standard.set(language,forKey:PichiInterfaceLanguage.defaultsKey)
            let localized=RewriteAcceptViewAction(service:service)
            localized.accept(); let action=localized.acceptanceTask!; await action.value
            check(AppServices.shared.asr.errorTitle==title && AppServices.shared.asr.errorMessage==detail,"Actual Rewrite failure action uses the compiled RU/EN catalog and shared localization helper")
            check(service.rewrittenText=="synthetic rewrite" && syntheticAX.insertions.isEmpty,"Localized failure never translates or discards pending user/model data")
        }
        #endif
    }
    static func waitUntil(_ condition:@escaping @MainActor ()->Bool) async {
        let deadline=ProcessInfo.processInfo.systemUptime+2
        while ProcessInfo.processInfo.systemUptime<deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds:1_000_000)
        }
        preconditionFailure("Actual production operation never reached the expected suspended boundary")
    }
    #if !LEGACY_REWRITE
    static func viewCancellation() async {
        let a=SyntheticAXElement("A",pid:42)
        let b=SyntheticAXElement("B",pid:42)
        for callback in ["close","escape","disappear"] {
            for phase in ["queued","restore","clipboard","direct"] {
                reset(phase=="restore" ? b:a)
                let service=RewriteModeService(); service.rewrittenText="owned rewrite"
                NotchContentState.shared.recordingTargetContext=context(a)
                let view=RewriteAcceptViewAction(service:service)
                var closes=0
                var closedWhileOwned=false
                view.onClose={
                    closes += 1
                    closedWhileOwned = service.isAcceptingRewrite || !MeetingSummaryActivityCoordinator.shared.processing.isEmpty
                }
                if phase=="clipboard" {
                    _ = await PasteDeliveryCoordinator.shared.deliver("held clipboard lease",preserveTranscriptOnClipboard:false)
                    syntheticAX.values=[:]; syntheticAX.insertions=[]
                }
                if phase=="direct" { SettingsStore.shared.textInsertionMode = .standard; TypingService.directInsertionQueue.suspend() }
                view.accept()
                let accepted=view.acceptanceTask!
                view.accept()
                if phase=="restore" || phase=="direct" { await waitUntil { service.isAcceptingRewrite }; await Task.yield() }
                if phase=="clipboard" { await waitUntil { PasteDeliveryCoordinator.shared.fixtureWaiterCount==1 } }
                switch callback { case "close": view.close(); case "escape": view.escape(); default: view.disappear() }
                let drain=view.acceptanceCancellationTask!
                if phase=="clipboard" {
                    check(closes==0,"Close must wait for the actual queued acceptance to join, without blocking UI")
                    PasteDeliveryCoordinator.shared.runPendingSettlementForTesting()
                }
                if phase=="direct" { TypingService.directInsertionQueue.resume() }
                await drain.value; await accepted.value
                check(syntheticAX.insertions.isEmpty && syntheticAX.values["A"]==nil && syntheticAX.values["B"]==nil,
                      "Actual \(callback) callback must cancel pending \(phase) operation before native transport")
                check(service.rewrittenText=="owned rewrite" && !service.isAcceptingRewrite && view.acceptanceTask==nil && MeetingSummaryActivityCoordinator.shared.processing.isEmpty,"Actual callback joins cleanup and retains pending rewrite")
                check(closes==(callback=="disappear" ? 0:1) && !closedWhileOwned,"X/Escape close only after joined cleanup; disappearance cannot issue a late navigation")
                check(syntheticPasteboard.text=="original synthetic clipboard" && !syntheticPasteboard.isTemporary && !PasteDeliveryCoordinator.shared.fixtureHasLease && PasteDeliveryCoordinator.shared.fixtureWaiterCount==0,"Cancelled callback leaves no temporary clipboard or delivery waiter")
                if phase=="queued" { check(NSApp.hideCount==0 && syntheticAX.restoreCount==0,"A closed queued action cannot begin focus/hide work") }
            }
        }
        reset(b)
        let service=RewriteModeService(); service.rewrittenText="frozen admission text"
        NotchContentState.shared.recordingTargetContext=context(a)
        let view=RewriteAcceptViewAction(service:service)
        view.accept()
        let accepted=view.acceptanceTask!
        service.rewrittenText="later draft"
        NotchContentState.shared.recordingTargetContext=context(b)
        await accepted.value
        check(syntheticAX.values["A"]=="frozen admission text" && syntheticAX.values["B"]==nil,"Actual synchronous acceptance freezes both text and target before its Task can start")
        check(service.rewrittenText=="later draft","Completing an earlier accepted snapshot never clears a newer draft")
        reset(b)
        let closing=RewriteAcceptViewAction(service:service)
        NotchContentState.shared.recordingTargetContext=context(a)
        var closes=0
        closing.onClose={ closes += 1 }
        closing.accept(); let pending=closing.acceptanceTask!
        await waitUntil { service.isAcceptingRewrite }
        closing.close(); let firstDrain=closing.acceptanceCancellationTask!
        closing.escape()
        closing.disappear(); let finalDrain=closing.acceptanceCancellationTask!
        await pending.value; await firstDrain.value; await finalDrain.value
        check(closes==0 && syntheticAX.insertions.isEmpty,"Disappearance invalidates a previous pending close callback without double navigation or paste")
    }
    #endif
    static func clipboardAndDirectBoundaries() async {
        let a=SyntheticAXElement("A",pid:42)
        let b=SyntheticAXElement("B",pid:42)
        for returnsToStart in [true,false] {
            let original=context(a), current=context(b)
            let chosen=DictationStopSnapshot.selectTarget(current:current,original:original,returnToStartingField:returnsToStart,ownOverlayFocused:false)!
            reset(chosen.element)
            _ = await PasteDeliveryCoordinator.shared.deliver("held clipboard lease",preserveTranscriptOnClipboard:false)
            syntheticAX.values=[:]; syntheticAX.insertions=[]
            let caller=StopDeliveryCaller()
            let output=Task { @MainActor in await caller.deliver(.plain("normal stopped marker"),snapshot:.init(target:chosen)) }
            await waitUntil { PasteDeliveryCoordinator.shared.fixtureWaiterCount==1 }
            syntheticAX.focus=returnsToStart ? b:a
            PasteDeliveryCoordinator.shared.runPendingSettlementForTesting()
            let result=await output.value
            check(result == .recoverableFailure(.targetUnavailable) && syntheticAX.insertions.isEmpty,
                  "Normal stop-snapshot caller must reject changed field after real clipboard slot wait, including current-target mode; actual insertions: \(syntheticAX.insertions)")
            check(syntheticPoster.postCount==1 && syntheticPasteboard.temporaryWriteCount==1 && syntheticPasteboard.text=="original synthetic clipboard" && !PasteDeliveryCoordinator.shared.fixtureIsDelivering,"Post-slot identity rejection creates no extra temporary write or event and releases its slot")
        }
        reset(a)
        let exact=TypingService.CapturedFocusTarget(pid:42,window:nil,element:a)
        syntheticPasteboard.onTemporaryWrite={ syntheticAX.focus=b }
        let changed=await TypingService().typeOutputPlanInstantly(.plain("pre-dispatch marker"),preferredTargetPID:42,textReadyAt:nil,requiredFocusTarget:exact)
        check(changed == .recoverableFailure(.targetUnavailable) && syntheticAX.insertions.isEmpty && syntheticPoster.postCount==0,"Exact field is rechecked after actual temporary clipboard write immediately before global post")
        check(syntheticPasteboard.text=="original synthetic clipboard" && syntheticPasteboard.restoreCount==1 && !syntheticPasteboard.isTemporary && !PasteDeliveryCoordinator.shared.fixtureIsDelivering,"A pre-dispatch focus rejection restores the owned original clipboard")
        reset(a)
        _ = await TypingService().typeOutputPlanInstantly(.plain("intentional backup"),preferredTargetPID:42,textReadyAt:nil,preserveTranscriptOnClipboard:true,requiredFocusTarget:exact)
        syntheticAX.focus=b
        PasteDeliveryCoordinator.shared.runPendingSettlementForTesting()
        check(syntheticPasteboard.text=="intentional backup" && syntheticPasteboard.intentionalWriteCount==1 && syntheticPasteboard.restoreCount==0,"Focus change after successful dispatch preserves the existing intentional backup preference")
        reset(a)
        _ = await PasteDeliveryCoordinator.shared.deliver("held clipboard lease",preserveTranscriptOnClipboard:false)
        syntheticAX.values=[:]; syntheticAX.insertions=[]
        let backup=Task { @MainActor in await TypingService().typeOutputPlanInstantly(.plain("failed target backup"),preferredTargetPID:42,textReadyAt:nil,preserveTranscriptOnClipboard:true,requiredFocusTarget:exact) }
        await waitUntil { PasteDeliveryCoordinator.shared.fixtureWaiterCount==1 }
        syntheticAX.focus=b
        PasteDeliveryCoordinator.shared.runPendingSettlementForTesting()
        let backupResult=await backup.value
        check(backupResult == .recoverableFailure(.targetUnavailable) && syntheticAX.insertions.isEmpty && syntheticPoster.postCount==1,"Failed post-slot target creates no extra native dispatch")
        check(syntheticPasteboard.text=="failed target backup" && syntheticPasteboard.intentionalWriteCount==1 && !syntheticPasteboard.isTemporary,"Explicit copy preference also retains transcript when final destination admission fails")

        reset(a); SettingsStore.shared.textInsertionMode = .standard
        let service=RewriteModeService(); service.rewrittenText="cancelled direct marker"
        TypingService.directInsertionQueue.suspend()
        let output=Task { @MainActor in await service.acceptRewrite(service.rewrittenText,targetContext:context(a)) as Any }
        await waitUntil { service.isAcceptingRewrite }; await Task.yield()
        output.cancel()
        TypingService.directInsertionQueue.resume()
        let cancelled=await output.value
        check(cancelled as? TextDeliveryResult == .cancelled && syntheticAX.insertions.isEmpty,
              "Attempt cancellation persists in the actual GCD/main.sync direct callback outside Swift Task; no late native write; actual insertions: \(syntheticAX.insertions)")
        check(MeetingSummaryActivityCoordinator.shared.processing.isEmpty && !service.isAcceptingRewrite && syntheticPoster.postCount==0,"Cancelled direct insertion joins its queue and does not use clipboard fallback")
        reset(a); SettingsStore.shared.textInsertionMode = .standard
        var constructing:Task<Any,Never>?
        var constructions=0
        syntheticAX.onEventConstruct={ constructions += 1; constructing?.cancel() }
        constructing=Task { @MainActor in await service.acceptRewrite(service.rewrittenText,targetContext:context(a)) as Any }
        let constructionCancellation=await constructing!.value
        check(constructions>0 && constructionCancellation as? TextDeliveryResult == .cancelled && syntheticAX.insertions.isEmpty,"Cancellation from actual background event construction persists through the pre-post MainActor callback")
        check(MeetingSummaryActivityCoordinator.shared.processing.isEmpty && !service.isAcceptingRewrite && syntheticPoster.postCount==0,"Background cancellation joins direct native work and blocks clipboard fallback")
        reset(a); SettingsStore.shared.textInsertionMode = .standard
        service.rewrittenText="frozen direct marker"
        TypingService.directInsertionQueue.suspend()
        let moving=Task { @MainActor in await service.acceptRewrite(service.rewrittenText,targetContext:context(a)) as Any }
        await waitUntil { service.isAcceptingRewrite }; await Task.yield()
        syntheticAX.focus=b
        TypingService.directInsertionQueue.resume()
        let moved=await moving.value
        check(moved as? TextDeliveryResult == .recoverableFailure(.targetUnavailable) && syntheticAX.values["B"]==nil && syntheticAX.insertions.isEmpty,"Actual queued direct insertion rechecks captured field before writing to the same PID; actual insertions: \(syntheticAX.insertions)")
        check(syntheticPoster.postCount==0 && syntheticPasteboard.temporaryWriteCount==0,"Changed direct destination also blocks global clipboard fallback")
        for allowEvents in [true,false] {
            reset(a); SettingsStore.shared.textInsertionMode = .standard; syntheticAX.allowCGEvents=allowEvents
            service.rewrittenText="Ёё synthetic direct 😀"
            let success:Any=await service.acceptRewrite(service.rewrittenText,targetContext:context(a))
            check(success as? TextDeliveryResult == .commandPosted && syntheticAX.values["A"]==service.rewrittenText && syntheticAX.values["B"]==nil,"Actual Unicode direct and AX fallback bodies preserve successful exact-target insertion")
            check(syntheticPoster.postCount==0,"Successful direct/AX insertion does not use a fake or actual clipboard fallback")
        }
    }
    static func restoredCallerBoundaries() async {
        let a=SyntheticAXElement("A",pid:42), b=SyntheticAXElement("B",pid:42)
        let appInfo=(name:"Synthetic editor",bundleId:"synthetic.editor",windowTitle:"Synthetic document")
        for callerKind in ["automatic","retry","history","reprocess"] {
            for transport in ["clipboard","direct"] {
                reset(callerKind=="automatic" || callerKind=="retry" ? a:b)
                NotchContentState.shared.recordingTargetContext=context(a)
                NotchContentState.shared.recordingTargetPID=42
                let caller=AutomaticDeliveryCaller()
                if transport=="clipboard" {
                    _ = await PasteDeliveryCoordinator.shared.deliver("held lease",preserveTranscriptOnClipboard:false)
                    syntheticAX.values=[:]; syntheticAX.insertions=[]
                } else { SettingsStore.shared.textInsertionMode = .standard; TypingService.directInsertionQueue.suspend() }
                var pending:Task<Void,Never>?
                if callerKind=="automatic" {
                    pending=Task { @MainActor in await caller.processRewriteWithVoiceInstruction("synthetic instruction",appInfo:appInfo,lifecycleID:1) }
                    await waitUntil { caller.rewriteModeService.respond != nil }
                    NotchContentState.shared.recordingTargetContext=context(b)
                    caller.rewriteModeService.respond?.resume()
                } else if callerKind=="retry" {
                    caller.registerRetry()
                    NotchContentState.shared.onRetryTextDeliveryRequested?("retry frozen text")
                    NotchContentState.shared.recordingTargetContext=context(b)
                } else {
                    let captured=context(a)
                    pending=Task { @MainActor in
                        if callerKind=="history" { await caller.historyProjection(.plain("history frozen text"),targetContext:captured) }
                        else { await caller.reprocessProjection(.plain("reprocess frozen text"),targetContext:captured) }
                    }
                }
                if transport=="clipboard" {
                    await waitUntil { PasteDeliveryCoordinator.shared.fixtureWaiterCount==1 }
                } else {
                    if callerKind=="automatic" { await waitUntil { caller.rewriteModeService.rewrittenText=="automatic frozen text" } }
                    else if callerKind=="retry" { await waitUntil { caller.menuBarManager.isProcessing } }
                    else { await waitUntil { syntheticAX.focus?.id=="A" } }
                    for _ in 0..<20 { await Task.yield() }
                }
                NotchContentState.shared.recordingTargetContext=context(b)
                syntheticAX.focus=b
                if callerKind=="automatic" { caller.rewriteModeService.rewrittenText="newer pending draft" }
                if transport=="clipboard" { PasteDeliveryCoordinator.shared.runPendingSettlementForTesting() }
                else { TypingService.directInsertionQueue.resume() }
                if let pending { await pending.value } else { await waitUntil { !caller.failures.isEmpty } }
                check(caller.failures==[.targetUnavailable] && syntheticAX.values["B"]==nil && syntheticAX.insertions.isEmpty,
                      "Actual \(callerKind) forwarding must protect the frozen restored field across \(transport) wait; actual insertions: \(syntheticAX.insertions)")
                let expected=callerKind=="automatic" ? "automatic frozen text" : callerKind+" frozen text"
                check(caller.failedTranscript==expected,"Failure UI uses immutable accepted output rather than a newer draft/recording")
                if callerKind=="automatic" { check(caller.rewriteModeService.rewrittenText=="newer pending draft" && caller.rewriteModeService.clears==0,"Automatic failure preserves the newer pending result") }
                check(syntheticPasteboard.text=="original synthetic clipboard" && !syntheticPasteboard.isTemporary && !PasteDeliveryCoordinator.shared.fixtureIsDelivering,"Restored caller releases clipboard ownership without a wrong-field write")
            }
        }
        reset(a)
        NotchContentState.shared.recordingTargetContext=context(a)
        let retry=AutomaticDeliveryCaller(); retry.registerRetry()
        _ = await PasteDeliveryCoordinator.shared.deliver("held lease",preserveTranscriptOnClipboard:false)
        syntheticAX.values=[:]; syntheticAX.insertions=[]
        NotchContentState.shared.onRetryTextDeliveryRequested?("cancelled retry")
        await waitUntil { PasteDeliveryCoordinator.shared.fixtureWaiterCount==1 }
        retry.cancelledOutputLifecycleID=1
        PasteDeliveryCoordinator.shared.runPendingSettlementForTesting()
        await waitUntil { PasteDeliveryCoordinator.shared.fixtureWaiterCount==0 && !PasteDeliveryCoordinator.shared.fixtureIsDelivering }
        for _ in 0..<20 { await Task.yield() }
        check(syntheticAX.insertions.isEmpty && retry.failures.isEmpty && retry.hides==0,"Actual Retry lifecycle cancellation suppresses dispatch and stale failure/hide callbacks")
        reset(a)
        NotchContentState.shared.recordingTargetContext=context(a)
        let exact=AutomaticDeliveryCaller(); exact.registerRetry()
        NotchContentState.shared.onRetryTextDeliveryRequested?("exact retry")
        await waitUntil { exact.hides==1 }
        check(syntheticAX.values["A"]=="exact retry" && exact.failures.isEmpty,"Exact current Retry target keeps its successful PID selection without forcing restoration")
    }
    static func main() async {
        if CommandLine.arguments.contains("--rewrite-only") {
            await rewriteAcceptance()
            print("Rewrite acceptance: \(checks) checks PASS; actual production bodies, synthetic backend only")
            return
        }
        if CommandLine.arguments.contains("--ambient_cancel") || CommandLine.arguments.contains("--clipboard_focus") || CommandLine.arguments.contains("--direct_focus") {
            await clipboardAndDirectBoundaries()
            return
        }
        if CommandLine.arguments.contains("--restored_forwarding") { await restoredCallerBoundaries(); return }
        #if !LEGACY_REWRITE
        if CommandLine.arguments.contains("--view_cancel") { await viewCancellation(); return }
        #endif
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
        await clipboardAndDirectBoundaries()
        await restoredCallerBoundaries()
        #if !LEGACY_REWRITE
        await viewCancellation()
        #endif
        PasteDeliveryCoordinator.shared.runPendingSettlementForTesting()
        print("Typing focus identity: \(checks) checks PASS; actual helper/prepare/stop selection/typing/Rewrite intents; synthetic AX and paste backend only, no UI, TCC, CGEvent or clipboard")
    }
}

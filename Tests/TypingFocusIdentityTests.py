#!/usr/bin/env python3
"""Execute actual target, clipboard, direct and Rewrite lifecycle bodies with inert transports.

No native frameworks are imported. Only AX/CG observations and final transports are doubles.
Optional reference/mutation modes deliberately demonstrate the earlier unsafe behavior.
"""
from pathlib import Path
import argparse
import re
import plistlib
import subprocess

repo = Path(__file__).resolve().parents[1]
output = repo / '.build/typing-focus-identity-tests'
output.mkdir(parents=True, exist_ok=True)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('reference', nargs='?', default='', help='Project this revision of the identity helper into current caller contracts')
parser.add_argument('--rewrite-reference', default='', help='Project original Rewrite acceptance body for the independent failed-restore proof')
parser.add_argument('--conditional-reference', default='', help='Compare earlier history/reprocess field binding without changing current delivery gates')
parser.add_argument('--direct-reference', default='', help='Execute this earlier direct pipeline for the partial-output regression')
parser.add_argument('--ownership-reference', default='', help='Execute this earlier coordinator for the newer-clipboard ownership regression')
parser.add_argument('--ax-reference', default='', help='Execute this earlier direct AX candidate pipeline with current inert edges')
parser.add_argument('--mutation', choices=['ambient_cancel', 'clipboard_focus', 'direct_focus', 'view_cancel','restored_forwarding'])
args = parser.parse_args()
def read(path, reference=''):
    return subprocess.check_output(['git', 'show', f'{reference}:{path}'], cwd=repo, text=True) if reference else (repo / path).read_text()
def block(text, marker):
    assert text.count(marker) == 1, f'Expected one source boundary: {marker}'
    start = text.index(marker)
    indent = len(marker) - len(marker.lstrip())
    end = text.index('\n' + ' ' * indent + '}', start) + indent + 2
    value = text[start:end]
    assert '"""' not in value, 'Bounded extraction does not admit multiline strings'
    return value
def method(text, name, static=False):
    matches = list(re.finditer(r'(?m)^    (?:private )?(?:nonisolated )?' + ('static ' if static else '') + r'func '+name+r'\(', text))
    if name == 'elapsedMs':
        matches = [match for match in matches if 'from start:' in text[match.start():text.index('\n',match.start())]]
    assert len(matches) == 1, (name,len(matches))
    marker = text[matches[0].start():text.index('\n',matches[0].start())]
    return block(text, marker).replace('private ', '', 1)
def mutate(text, old, new, count=1):
    assert text.count(old) == count, (old,text.count(old))
    return text.replace(old,new)
source = read('Sources/Fluid/Services/TypingService.swift',args.ax_reference or args.direct_reference)
declarations = [block(source, '    struct '+name+' {') for name in ('CapturedFocusTarget','RecordingTargetContext')]
declarations += [block(source, '    enum '+name+': '+base+' {') for name,base in [('DeliveryOutcome','Equatable'),('FocusPreparationResult','String')]]
declarations += [block(read('Sources/Fluid/Services/TypingService.swift'),'    nonisolated enum DirectDispatchOutcome: Equatable, Sendable {')]
static_names = ('currentFocusedPID','captureSystemFocusTarget','copyAXElementAttribute','isExactFocusTargetActive','prepareTargetForDelivery','restoreExactTarget','isCapturedFocusStillActive','activateAppForRecovery','canDispatchPostInsertionAction','canInsertBeforePostInsertionAction','stringAXAttribute','isCurrentlyFocusedElement','elapsedMs','unicodeChunkEnd','isHighSurrogate','isLowSurrogate')
methods = [method(source,name,static=True) for name in static_names]
if args.reference:
    original = read('Sources/Fluid/Services/TypingService.swift',args.reference)
    methods[static_names.index('isCurrentlyFocusedElement')] = method(original,'isCurrentlyFocusedElement',static=True)
attempts=list(re.finditer(r'(?m)^    nonisolated static func attemptDirectInsertion\(',source))
assert len(attempts)==(1 if args.direct_reference else 2)
methods += [block(source,source[match.start():source.index('\n',match.start())]) for match in attempts]
for name in ('insertTextDirectlyOffMain','insertTextDirectly','insertTextBulkInstant','insertTextBulkHIDInstant','postUnicodeChunks','insertTextViaAccessibility','getFocusedTextElement','findTextElementInFrontmostApp','findTextElementRecursively','findKeyboardFocusedElement','tryAllTextInsertionMethods','getElementAttribute','getSystemFocusedElementAndPID','getElementStringValue','getSelectedTextRange','insertTextAtCursorUsingSelectedRange','setTextViaValue','setTextViaSelection','insertTextAtInsertionPoint'):
    methods.append(method(source,name))
for name, expected in [('typeOutputPlanInstantly',2),('typeTextInstantly',3)]:
    matches=list(re.finditer(r'(?m)^    func '+name+r'\(',source))
    assert len(matches)==expected,(name,len(matches))
    methods += [source[match.start():source.index('\n    }',match.start())+len('\n    }')] for match in matches]
if args.mutation=='direct_focus':
    methods=[mutate(value,'{ isOutputValid() && targetIsReady() }','{ isOutputValid() }') if 'let insertionIsValid:' in value else value for value in methods]
snapshot = read('Sources/Fluid/Services/DictationStopSnapshot.swift')
snapshot_methods = '\n'.join(block(snapshot,marker) for marker in ('    var focusTarget: TypingService.CapturedFocusTarget? {','    static func selectTarget(','    func prepareDelivery('))
coordinator = read('Sources/Fluid/Services/PasteDeliveryCoordinator.swift')
coord_source = read('Sources/Fluid/Services/PasteDeliveryCoordinator.swift',args.ownership_reference)
coord_marker = ('final class PasteDeliveryCoordinator: PrivateProfileTransitionParticipant {' if 'final class PasteDeliveryCoordinator: PrivateProfileTransitionParticipant {' in coord_source else 'final class PasteDeliveryCoordinator {')
coord_body = block(coord_source,coord_marker)
coord_body = mutate(coord_body,'static let shared = PasteDeliveryCoordinator()','static var shared = PasteDeliveryCoordinator(pasteboard: syntheticPasteboard, commandPoster: syntheticPoster, settlementDelayNanoseconds: 10_000_000_000)')
if args.mutation=='clipboard_focus':
    gate=block(coord_body,'        guard targetIsReady() else {\n            // Match copyBackup admission without acquiring the slot we already own.')
    coord_body=mutate(coord_body,gate,'        // Mutant: omit the post-slot destination gate')
    guard=block(coord_body,'        guard targetIsReady() else {\n            self.finishFailedDelivery(')
    coord_body=mutate(coord_body,guard,'        // Mutant: omit the pre-command destination gate')
clipboard_types='\n'.join(block(coordinator,marker) for marker in ('enum TextDeliveryFailure: String, Equatable {','enum TextDeliveryResult: Equatable {','struct PasteboardSnapshot: Equatable {','protocol PasteboardManaging: AnyObject {','extension PasteboardManaging {','protocol PasteCommandPosting: AnyObject {'))
clipboard_types=clipboard_types.replace('protocol PasteboardManaging','@MainActor protocol PasteboardManaging').replace('protocol PasteCommandPosting','@MainActor protocol PasteCommandPosting')
clipboard_tests=read('Tests/FluidDictationIntegrationTests/PasteDeliveryCoordinatorTests.swift')
clipboard_doubles='\n'.join(block(clipboard_tests,marker) for marker in ('private final class FakePasteboardManager: PasteboardManaging {','private final class FakePasteCommandPoster: PasteCommandPosting {','private final class SuspendingFakePasteCommandPoster: PasteCommandPosting {'))
clipboard_doubles=clipboard_doubles.replace('private final class','@MainActor final class')
literal=block(read('Sources/Fluid/Services/ASRService+DictationLiteralFormatting.swift'),'struct DictationLiteralOutputPlan: Equatable {')
assessment=read('Sources/Fluid/Services/DeliveryTargetAssessment.swift').replace('import ApplicationServices\n','').replace('import AppKit\n','')
analytics=block(read('Sources/Fluid/Analytics/AnalyticsEvent.swift'),'enum AnalyticsInsertionPath: String {')
fixture='import Foundation\nimport CoreFoundation\n'+clipboard_types+'\n'+literal+'\n'+analytics+'\n'+assessment+'\n'
for marker in ('final class PasteRecoveryEvidence {', 'final class PasteRecoverySequence {'):
    fixture+='@MainActor '+block(read('Sources/Fluid/Services/PasteVerifier.swift'),marker)+'\n'
fixture+='extension Notification.Name { static let fluidPasteRecoveryAvailable = Notification.Name("synthetic.pasteRecovery") }\n'
fixture+='''nonisolated struct PrivateProfileSnapshot {}
nonisolated enum PrivateProfileStorage {
    static var current: PrivateProfileSnapshot { .init() }
    static let acceptsNewWork = true
    static func isReadable(_ profile: PrivateProfileSnapshot) -> Bool { true }
}
@MainActor protocol PrivateProfileTransitionParticipant: AnyObject {
    func prepareForPrivateProfileTransition() async throws
}
@MainActor final class PrivateProfileService {
    static let shared = PrivateProfileService()
    func register(_ participant: any PrivateProfileTransitionParticipant) {}
}
'''
fixture+=read('Sources/Fluid/Account/PrivateProfileOperationOwner.swift').replace('import Foundation\n','')+'\n'
failure_card=block(read('Sources/Fluid/Views/DeliveryFailureOverlay.swift'),'    enum Kind: Equatable {')
fixture+='@MainActor final class DeliveryFailureOverlayController {\n'+failure_card+'\n}\n'
fixture+=(repo/'Tests/Support/TypingNativeTransportFixture.swift').read_text()+'\n'+clipboard_doubles+'\n@MainActor '+coord_body+'\n'
fixture+='extension PasteDeliveryCoordinator { var fixtureWaiterCount:Int { self.deliveryWaiters.count }; var fixtureHasLease:Bool { self.lease != nil }; var fixtureIsDelivering:Bool { self.isDelivering } }\n'
methods += [method(read('Sources/Fluid/Services/TypingService.swift'), name) for name in ('verifyPasteLanded', 'capturePasteBaseline')]
fixture+='@MainActor final class TypingService {\n'+'\n'.join(declarations+methods)+'''
    nonisolated static let directInsertionQueue = DispatchQueue(label: "test.synthetic.direct-insertion")
    nonisolated static let cgEventUnicodeChunkSize = 200
    static let recoveryActivationOptions: NSApplication.ActivationOptions = [.activateIgnoringOtherApps]
    var textInsertionMode: SettingsStore.TextInsertionMode { SettingsStore.shared.textInsertionMode }
    nonisolated static func logFocusState(_ text: String) {}
    nonisolated func log(_ text: String) {}
    func bench(_ text: String) {}
    func ghosttyTargetPID(preferredTargetPID: pid_t?) -> pid_t? { nil }
    func recordInsertionLatency(path: AnalyticsInsertionPath, result: TextDeliveryResult, requestedAt: TimeInterval, textReadyAt: TimeInterval?, toggleStopRequestedAt: TimeInterval?, completedAt: TimeInterval = 0) {}
    func waitForPhysicalModifiersToRelease(timeout: TimeInterval) async -> Bool { true }
    func postReturnKey(_ key: SettingsStore.SpokenSendKey, targetPID: pid_t) async -> Bool { syntheticAX.sendCount += 1; return true }
}\n'''
candidate=block(read('Sources/Fluid/Services/TypingService.swift'),'        let isAXCandidateValid: @Sendable @MainActor (AXUIElement) -> Bool = { candidate in')
fixture+='extension TypingService { static func fixtureAXCandidatePredicate(_ requiredFocusTarget:CapturedFocusTarget?)->@Sendable @MainActor (AXUIElement)->Bool {\n'+candidate+'\n return isAXCandidateValid\n} }\n'
fixture+='@MainActor struct DictationStopSnapshot { let target: TypingService.RecordingTargetContext?\n'+snapshot_methods+'\n}\n'
asr=read('Sources/Fluid/Services/ASRService.swift')
text_wrappers=list(re.finditer(r'(?m)^    func typeTextToActiveField\(',asr))
assert len(text_wrappers)==2
asr_methods=[block(asr,'    func typeOutputPlanToActiveField(')]+[asr[match.start():asr.index('\n    }',match.start())+len('\n    }')] for match in text_wrappers]
fixture+='@MainActor final class ASRService { private let typingService=TypingService()\n'+'\n'.join(asr_methods)+'\n}\n'
content=read('Sources/Fluid/ContentView.swift')
marker='                deliveryResult = await self.asr.typeOutputPlanToActiveField(\n                    finalOutputPlan'
assert content.count(marker)==1
start=content.index(marker)
call=content[start:content.index('\n                )',start)+len('\n                )')]
assert 'requiredFocusTarget: stopSnapshot?.focusTarget' in call
fixture+='''@MainActor final class StopDeliveryCaller {
    struct Output { var isVisible = true }
    let asr=ASRService(); var cancelledOutputLifecycleID: UInt64?; var overlayLifecycleID: UInt64=1
    func deliver(_ finalOutputPlan: DictationLiteralOutputPlan, snapshot stopSnapshot: DictationStopSnapshot?) async -> TextDeliveryResult {
        let typingTarget=(pid: stopSnapshot?.target?.pid, shouldRestoreOriginalFocus: true)
        let finalTextReadyAt=ProcessInfo.processInfo.systemUptime
        let toggleStopRequestedAt: TimeInterval?=nil
        let shouldCopyToClipboard=false
        let expectedOverlayLifecycleID=self.overlayLifecycleID
        let privateOutput: Output? = .init()
        let deliveryResult: TextDeliveryResult
'''+call+'\n        return deliveryResult\n    }\n}\n'
caller_methods=[]
for name in ('processRewriteWithVoiceInstruction','retryTextDelivery','resolveTypingTargetPID','prepareRecordingTargetForDelivery','restoreFocusToRecordingTarget'):
    matches=list(re.finditer(r'(?m)^    private func '+name+r'\(',content))
    assert len(matches)==(2 if name in ('resolveTypingTargetPID','prepareRecordingTargetForDelivery','restoreFocusToRecordingTarget') else 1),(name,len(matches))
    for match in matches:
        caller_methods.append(block(content,content[match.start():content.index('\n',match.start())]).replace('private ','',1))
retry_callback=block(content,'        NotchContentState.shared.onRetryTextDeliveryRequested = { transcript in')
history_methods=[]
for production_name,fixture_name in [('applyHistoryTextOutput','historyProjection'),('reprocessDictationText','reprocessProjection')]:
    history_source=read('Sources/Fluid/ContentView.swift',args.conditional_reference) if args.conditional_reference else content
    function=block(history_source,'    private func '+production_name+'(')
    validity=''
    if '    private func '+production_name+'Bound(' in history_source:
        assert 'privateOutputOperations.perform {' in function and 'self.'+production_name+'Bound(' in function
        function=block(history_source,'    private func '+production_name+'Bound(')
        validity_line='        let isOutputValid: @MainActor () -> Bool = { self.privateOutputOperations.isCurrent && !Task.isCancelled }'
        assert function.count(validity_line)==1
        assert function.index(validity_line) < function.index('        guard isOutputValid() else { return }') < function.index('        if shouldTypeExternally {')
        validity=validity_line+'\n        guard isOutputValid() else { return }\n'
    assert function.count('let targetContext = TypingService.captureRecordingTargetContext()')==1
    segment=block(function,'        if shouldTypeExternally {')
    # The first closing brace ends the if body. Include the actual clipboard else branch too.
    end=function.index('\n        }',function.index('        if shouldTypeExternally {'))+len('\n        }')
    if function[end:].startswith(' else {'):
        end=function.index('\n        }',end)+len('\n        }')
    segment=function[function.index('        if shouldTypeExternally {'):end]
    assert 'requiredFocusTarget: focusTarget' in segment
    history_methods.append('func '+fixture_name+'(_ outputPlan:DictationLiteralOutputPlan,targetContext:TypingService.RecordingTargetContext?) async { let finalText=outputPlan.plainText; let shouldTypeExternally=targetContext != nil\n'+validity+segment+'\n}')
if args.mutation=='restored_forwarding':
    caller_methods=[value.replace('                requiredFocusTarget: focusTarget,\n','') for value in caller_methods]
    history_methods=[value.replace(',\n                requiredFocusTarget: focusTarget','') for value in history_methods]
fixture+='''@MainActor final class AutomaticDeliveryCaller {
    let asr=ASRService(); let rewriteModeService=AutomaticRewriteDouble(); let menuBarManager=AutomaticMenuDouble()
    let privateOutputOperations = PrivateProfileOperationOwner()
    var overlayLifecycleID:UInt64=1; var cancelledOutputLifecycleID:UInt64?; var failures:[TextDeliveryFailure]=[]; var failedTranscript=""; var hides=0
    func appBench(_ text:String) {}
    func showTextDeliveryFailure(_ failure:TextDeliveryFailure,transcript:String) { failures.append(failure); failedTranscript=transcript }
    func hideOverlayAfterOutput() { hides += 1 }
    func registerRetry() {
'''+retry_callback+'\n    }\n'+'\n'.join(caller_methods+history_methods)+'\n}\n'
rewrite_path='Sources/Fluid/Services/RewriteModeService.swift'
rewrite_current=read(rewrite_path)
rewrite_fields=[]
for marker in ('    @Published var rewrittenText: String = ""','    @Published private(set) var isAcceptingRewrite = false','    private let typingService = TypingService()'):
    assert rewrite_current.count(marker)==1,marker
    rewrite_fields.append(marker.replace('@Published ','').replace('private(set) ',''))
rewrite_method=block(rewrite_current,'    func acceptRewrite(')
if '    private func acceptRewriteBound(' in rewrite_current:
    assert 'privateOperations.perform {' in rewrite_method and 'self.acceptRewriteBound(' in rewrite_method
    rewrite_method+='\n'+block(rewrite_current,'    private func acceptRewriteBound(')
rewrite_cancel=block(rewrite_current,'    private final nonisolated class AcceptanceCancellation: @unchecked Sendable {')
if args.mutation=='ambient_cancel':
    rewrite_method=mutate(rewrite_method,'{ !cancellation.isCancelled && isOutputValid() }','{ !Task.isCancelled && isOutputValid() }')
if args.rewrite_reference:
    old=block(read(rewrite_path,args.rewrite_reference),'    func acceptRewrite(')
    old=old.replace('func acceptRewrite(','func legacyAcceptRewrite(',1)
    rewrite_method=old+'''
    func acceptRewrite(_ text:String,targetContext:TypingService.RecordingTargetContext?,isOutputValid:@escaping @MainActor ()->Bool={true}) async -> Any {
        NotchContentState.shared.recordingTargetContext=targetContext
        return await self.legacyAcceptRewrite(text)
    }
'''
fixture+='@MainActor final class RewriteModeService { let privateOperations = PrivateProfileOperationOwner()\n'+'\n'.join(rewrite_fields)+'\n'+rewrite_cancel+'\n'+rewrite_method+'\n    func appendDiagnosticLog(_ text: String) {}\n}\n'
activity=read('Sources/Fluid/Services/Meeting/MeetingSummaryController.swift')
activity_methods='\n'.join(block(activity,marker) for marker in ('    func beginProcessing()','    func endProcessing(','    static func presentBusyError()'))
fixture+='@MainActor final class MeetingSummaryActivityCoordinator { static let shared=MeetingSummaryActivityCoordinator(); var processing: Set<UUID>=[]; var optionalProcessing: [UUID: @MainActor () async -> Void]=[:]; var isProcessing=false; var summary: UUID?\n'+activity_methods+'\n}\n'
if not args.rewrite_reference:
    view=read('Sources/Fluid/Views/RewriteModeView.swift')
    fields=[]
    for marker in ('    @State private var acceptanceTask: Task<Void, Never>?','    @State private var acceptanceCancellationTask: Task<Void, Never>?','    @State private var acceptanceID: UUID?','    @State private var isClosing = false'):
        assert view.count(marker)==1,marker
        fields.append(marker.replace('@State private ',' '))
    owner='\n'.join(block(view,marker).replace('private ','',1) for marker in ('    private func acceptCurrentRewrite() {','    private func cancelAcceptance(closeAfterJoining: Bool) {'))
    if args.mutation=='view_cancel':
        owner=mutate(owner,'self.isClosing = true','self.isClosing = false')
        owner=mutate(owner,'task?.cancel()','// Mutant: no owned acceptance cancellation')
    callbacks={}
    callbacks['accept']=block(view,'                                Button("Replace Original") {')
    callbacks['escape']=block(view,'        .onExitCommand {')
    callbacks['disappear']=block(view,'        .onDisappear {')
    close_marker='Button(action: { self.cancelAcceptance(closeAfterJoining: true) })'
    assert view.count(close_marker)==1
    callbacks['close']='{ self.cancelAcceptance(closeAfterJoining: true) }'
    wrappers=[]
    for name,value in callbacks.items():
        body=value[value.index('{')+1:value.rindex('}')]
        wrappers.append('func '+name+'() {'+body+'}')
    profile_visibility=[line for line in view.splitlines() if line.startswith('    private var isProfileVisible:')]
    assert len(profile_visibility)==1
    profile_fields='    private let profile = PrivateProfileStorage.current\n'+profile_visibility[0]
    fixture+='@MainActor final class RewriteAcceptViewAction { let service: RewriteModeService; let asr=AppServices.shared.asr; var onClose: (() -> Void)?; init(service:RewriteModeService) { self.service=service }\n'+profile_fields+'\n'+'\n'.join(fields+wrappers)+'\n'+owner+'\n}\n'
fixture+=(repo/'Tests/TypingFocusIdentityRegression.swift').read_text()
# These inert presentation edges are outside this runner's target/cancellation contract.
fixture+='\n@MainActor extension AutomaticRewriteDouble { var lastErrorMessage: String? { nil } }\n@MainActor extension AutomaticDeliveryCaller { func showEditModeFailure(_ message: String) {} }\n'
fixture+='\n'+(repo/'Tests/Support/ClipboardTargetBackupFixtureTests.swift').read_text()
localization=read('Sources/Fluid/Localization/PichiLocalization.swift')
fixture+='\n'+localization
fixture+='\n'+read('Sources/Fluid/Services/DictationTargetPolicy.swift')+'\n'+read('Sources/Fluid/Services/OnboardingDictationOutputPolicy.swift')
assert all(value not in fixture for value in ('import ApplicationServices','import AppKit','import Carbon','CGEventSource.keyState','NSPasteboard.general')), 'Native input surfaces must not be compiled'
assert 'class CGEvent' in fixture and 'class AXValue' in fixture and 'enum NSPasteboard' in fixture, 'All native transport names must be local inert types'
(output/'ProductionFocusFixture.swift').write_text(fixture)
bundle=output/'FocusFixture.app'
(bundle/'Contents/MacOS').mkdir(parents=True,exist_ok=True)
(bundle/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'test.synthetic.focus-fixture','CFBundleExecutable':'tests','CFBundlePackageType':'APPL','CFBundleDevelopmentRegion':'en','CFBundleLocalizations':['en','ru']}))
(bundle/'Contents/Resources').mkdir(parents=True,exist_ok=True)
subprocess.run(['xcrun','xcstringstool','compile','Sources/Fluid/Localization/Localizable.xcstrings','--output-directory',str(bundle/'Contents/Resources'),'--language','en','--language','ru'],cwd=repo,check=True)
binary=bundle/'Contents/MacOS/tests'
flags=(['-D','LEGACY_REWRITE'] if args.rewrite_reference else [])+(['-D','LEGACY_AX'] if args.ax_reference or args.direct_reference else [])
subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor','-parse-as-library',*flags,'-module-cache-path',str(output/'ModuleCache'),str(output/'ProductionFocusFixture.swift'),'-o',str(binary)],cwd=repo,check=True)
run_flags=['--ax-candidate-only'] if args.ax_reference else (['--rewrite-only'] if args.rewrite_reference else (['--partial-direct-only'] if args.direct_reference else (['--clipboard-ownership-only'] if args.ownership_reference else (['--restored_forwarding'] if args.conditional_reference else (['--'+args.mutation] if args.mutation else [])))))
subprocess.run([str(binary),*run_flags],cwd=repo,check=True)

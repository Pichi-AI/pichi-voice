#!/usr/bin/env python3
"""Execute production focus/preparation/typing bodies against a synthetic AX namespace.

No ApplicationServices/AppKit/Carbon imports or AX/TCC/CGEvent/system clipboard calls.
Only the external AX observations/actions and final paste transport are test doubles.
"""
from pathlib import Path
import argparse
import re
import plistlib
import subprocess
import sys

repo = Path(__file__).resolve().parents[1]
output = repo / '.build/typing-focus-identity-tests'
output.mkdir(parents=True, exist_ok=True)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('reference', nargs='?', default='', help='Compare the original focus/preparation/typing source at this revision')
parser.add_argument('--rewrite-reference', default='', help='Compare only the original Rewrite acceptance body, retaining the fixed target helper')
args = parser.parse_args()
reference = args.reference
def read(path):
    return subprocess.check_output(['git', 'show', f'{reference}:{path}'], cwd=repo, text=True) if reference else (repo / path).read_text()
source = read('Sources/Fluid/Services/TypingService.swift')
def block(text, marker):
    assert text.count(marker) == 1, f'Expected one source boundary: {marker}'
    start = text.index(marker)
    indent = len(marker) - len(marker.lstrip())
    end = text.index('\n' + ' ' * indent + '}', start) + indent + 2
    value = text[start:end]
    assert '"""' not in value, 'Bounded extraction does not admit multiline strings'
    return value
declarations = [block(source, '    struct '+name+' {') for name in ('CapturedFocusTarget', 'RecordingTargetContext')]
declarations += [block(source, '    enum '+name+': '+base+' {') for name, base in [('DeliveryOutcome','Equatable'),('FocusPreparationResult','String')]]
methods = []
for name in ('currentFocusedPID','isExactFocusTargetActive','prepareTargetForDelivery','restoreExactTarget','isCapturedFocusStillActive','activateAppForRecovery','canDispatchPostInsertionAction','canInsertBeforePostInsertionAction','stringAXAttribute','isCurrentlyFocusedElement','elapsedMs'):
    matches = list(re.finditer(r'(?m)^    (?:private )?(?:nonisolated )?static func '+name+r'\(', source))
    if name == 'elapsedMs': matches = [match for match in matches if 'from start:' in source[match.start():source.index('\n',match.start())]]
    assert len(matches) == 1, (name,len(matches))
    marker = source[matches[0].start():source.index('\n',matches[0].start())]
    methods.append(block(source, marker).replace('private ', '', 1))
overloads = list(re.finditer(r'(?m)^    func typeOutputPlanInstantly\(', source))
assert len(overloads) == 2, 'Actual async transport intent and completion intent must both be compiled'
for match in overloads:
    declaration = source[match.start():source.index('\n    }',match.start())+len('\n    }')]
    assert '"""' not in declaration
    methods.append(declaration)
wrappers = list(re.finditer(r'(?m)^    func typeTextInstantly\(', source))
assert len(wrappers) == 3, 'All upstream text overloads must retain the known projection boundary'
for match in wrappers:
    methods.append(source[match.start():source.index('\n    }',match.start())+len('\n    }')])
assert sum('completion:' in method for method in methods) == 1
assert sum('let usesClipboard =' in method for method in methods) == 1
snapshot = read('Sources/Fluid/Services/DictationStopSnapshot.swift')
snapshot_methods = block(snapshot,'    static func selectTarget(') + '\n' + block(snapshot,'    func prepareDelivery(')
coordinator = read('Sources/Fluid/Services/PasteDeliveryCoordinator.swift')
coord_method = block(coordinator,'    func prepareForDelivery(')
delivery_types = block(coordinator,'enum TextDeliveryFailure: String, Equatable {') + '\n' + block(coordinator,'enum TextDeliveryResult: Equatable {')
literal = read('Sources/Fluid/Services/ASRService+DictationLiteralFormatting.swift')
literal = block(literal,'struct DictationLiteralOutputPlan: Equatable {')
assessment = read('Sources/Fluid/Services/DeliveryTargetAssessment.swift').replace('import ApplicationServices\n','')
analytics = block(read('Sources/Fluid/Analytics/AnalyticsEvent.swift'),'enum AnalyticsInsertionPath: String {')
fixture = 'import Foundation\nimport CoreFoundation\n' + delivery_types + '\n' + literal + '\n' + analytics + '\n' + assessment + '\n'
fixture += '@MainActor final class TypingService {\n' + '\n'.join(declarations + methods) + '''
    static let recoveryActivationOptions: NSApplication.ActivationOptions = [.activateIgnoringOtherApps]
    var textInsertionMode: SettingsStore.TextInsertionMode { .reliablePaste }
    static func logFocusState(_ text: String) {}
    func log(_ text: String) {}
    func bench(_ text: String) {}
    func ghosttyTargetPID(preferredTargetPID: pid_t?) -> pid_t? { nil }
    func insertTextDirectlyOffMain(_ text: String, preferredTargetPID: pid_t?, isOutputValid: @escaping @MainActor () -> Bool) async -> Bool { false }
    func recordInsertionLatency(path: AnalyticsInsertionPath, result: TextDeliveryResult, requestedAt: TimeInterval, textReadyAt: TimeInterval?, toggleStopRequestedAt: TimeInterval?, completedAt: TimeInterval = 0) {}
    func verifyPasteLanded(_ text: String, before: Int) {}
    func waitForPhysicalModifiersToRelease(timeout: TimeInterval) async -> Bool { true }
    func postReturnKey(_ key: SettingsStore.SpokenSendKey, targetPID: pid_t) async -> Bool { syntheticAX.sendCount += 1; return true }
}\n'''
fixture += '@MainActor struct DictationStopSnapshot { let target: TypingService.RecordingTargetContext?\n' + snapshot_methods + '\n}\n'
fixture += '@MainActor final class PasteDeliveryCoordinator { static let shared = PasteDeliveryCoordinator(); var generation: UInt64 = 0; let pasteboard = SyntheticPasteboard()\n' + coord_method + '''
    @discardableResult func copyBackup(_ text: String, enabled: Bool, expectedChangeCount: Int? = nil, isOutputValid: @escaping @MainActor () -> Bool = { true }) async -> Bool {
        guard enabled, isOutputValid() else { return false }; pasteboard.backup = text; return true
    }
    func deliver(_ text: String, preserveTranscriptOnClipboard: Bool, isOutputValid: @escaping @MainActor () -> Bool, onCommandPosted: ((TimeInterval) -> Void)?) async -> TextDeliveryResult {
        guard isOutputValid(), let current = syntheticAX.focus, !syntheticAX.removed.contains(current.id) else { return .cancelled }
        syntheticAX.values[current.id, default: ""] += text
        syntheticAX.insertions.append(current.id)
        onCommandPosted?(ProcessInfo.processInfo.systemUptime)
        return .commandPosted
    }
}\n'''
rewrite_path = 'Sources/Fluid/Services/RewriteModeService.swift'
rewrite_current = (repo / rewrite_path).read_text()
rewrite = subprocess.check_output(['git', 'show', f'{args.rewrite_reference}:{rewrite_path}'], cwd=repo, text=True) if args.rewrite_reference else rewrite_current
rewrite_fields = []
for marker in ('    @Published var rewrittenText: String = ""', '    @Published private(set) var isAcceptingRewrite = false', '    private let typingService = TypingService()'):
    assert rewrite_current.count(marker) == 1, f'Expected actual Rewrite declaration: {marker}'
    rewrite_fields.append(marker.replace('@Published ', '').replace('private(set) ', ''))
rewrite_method = block(rewrite, '    func acceptRewrite(')
fixture += '@MainActor final class RewriteModeService {\n' + '\n'.join(rewrite_fields) + '\n' + rewrite_method + '\n    func appendDiagnosticLog(_ text: String) {}\n}\n'
activity = (repo / 'Sources/Fluid/Services/Meeting/MeetingSummaryController.swift').read_text()
activity_methods = '\n'.join(block(activity, marker) for marker in ('    func beginProcessing()', '    func endProcessing(', '    static func presentBusyError()'))
fixture += '@MainActor final class MeetingSummaryActivityCoordinator { static let shared = MeetingSummaryActivityCoordinator(); var processing: Set<UUID> = []; var optionalProcessing: [UUID: @MainActor () async -> Void] = [:]; var isProcessing = false; var summary: UUID?\n' + activity_methods + '\n}\n'
if not args.rewrite_reference:
    view = (repo / 'Sources/Fluid/Views/RewriteModeView.swift').read_text()
    task_marker = '                                    Task { @MainActor in\n                                        let result = await self.service.acceptRewrite(text)'
    actual_task = block(view, task_marker)
    fixture += '@MainActor final class RewriteAcceptViewAction { let service: RewriteModeService; let asr = AppServices.shared.asr; var onClose: (() -> Void)?; var action: Task<Void, Never>?; init(service: RewriteModeService) { self.service = service }; func accept() { let text = self.service.rewrittenText; self.action = ' + actual_task.lstrip() + ' } }\n'
fixture += (repo / 'Tests/TypingFocusIdentityRegression.swift').read_text()
fixture += '\n' + read('Sources/Fluid/Services/DictationTargetPolicy.swift') + '\n' + read('Sources/Fluid/Services/OnboardingDictationOutputPolicy.swift')
assert all(value not in fixture for value in ('import ApplicationServices','import AppKit','import Carbon','CGEvent(')), 'Native input surfaces must not be compiled into this fixture'
(output / 'ProductionFocusFixture.swift').write_text(fixture)
bundle = output / 'FocusFixture.app'
(bundle / 'Contents/MacOS').mkdir(parents=True,exist_ok=True)
(bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'test.synthetic.focus-fixture','CFBundleExecutable':'tests','CFBundlePackageType':'APPL'}))
binary = bundle / 'Contents/MacOS/tests'
flags = ['-D', 'LEGACY_REWRITE'] if args.rewrite_reference else []
subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor','-parse-as-library',*flags,'-module-cache-path',str(output / 'ModuleCache'),str(output / 'ProductionFocusFixture.swift'),'-o',str(binary)], cwd=repo,check=True)
subprocess.run([str(binary)] + (['--rewrite-only'] if args.rewrite_reference else []), cwd=repo,check=True)

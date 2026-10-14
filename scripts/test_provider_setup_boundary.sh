#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [ ! -d "$task_developer_dir/Platforms/MacOSX.platform" ]; then
    echo "Select a full Xcode with DEVELOPER_DIR before running these tests." >&2
    exit 1
fi
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-provider-setup.XXXXXX)
# Exercise the exact production removal method against the same isolated settings doubles.
{ echo 'extension AIEnhancementSettingsViewModel {'
  sed -n '/^    func deleteCurrentProvider() async -> Bool {/,/^    func saveEditedProvider() {/p' Sources/Fluid/UI/AISettings/AIEnhancementSettingsViewModel.swift | sed '$d'
  sed -n '/^    func saveManagedProviderBeforeClosing(/,/^    private func selectProviderForUse(/p' Sources/Fluid/UI/AISettings/AIEnhancementSettingsViewModel.swift | sed '$d'
  sed -n '/^    func configureProvider(/,/^    func finishConfiguringProvider(/p' Sources/Fluid/UI/AISettings/AIEnhancementSettingsViewModel.swift | sed '$d'
  sed -n '/^    private func mergeLoadedProviderAPIKeys(/,/^    private func keychainPermissionExplanation(/p' Sources/Fluid/UI/AISettings/AIEnhancementSettingsViewModel.swift | sed '$d' | sed 's/private func mergeLoadedProviderAPIKeys/func mergeLoadedProviderAPIKeys/'
  sed -n '/^    func refreshProviderItems()/,/^    func updateConnectionStatus(/p' Sources/Fluid/UI/AISettings/AIEnhancementSettingsViewModel.swift | sed '$d'
  echo '}'
} > "$task_test_dir/Removal.swift"
# Compile the actual outer presentation modifiers with an inert view builder.
# This checks the values passed by production, without opening a sheet or app.
python3 -S - "$task_test_dir" <<'PY_GATE'
from pathlib import Path
import sys
source = Path('Sources/Fluid/UI/AISettings/AddProviderSheet.swift').read_text()
body = source.split('    var body: some View {', 1)[1].split('    private var form:', 1)[0]
outer = body.split('.background(self.theme.palette.windowBackground)', 1)[1].split('.onChange', 1)[0]
assert outer.strip(), 'Missing outer presentation boundary'
def action_body(title):
    start = source.index('Button("' + title + '") {')
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[brace + 1:end - 1]
cancel = action_body('Cancel')
back = action_body('Back')
assert 'self.dismiss()' in cancel
assert '.keyboardShortcut(.cancelAction)' in body
assert 'self.cancelModelFetch(); self.isEditing = false; self.saveFailed = false; self.showingManualModel = false' in back
assert '.onDisappear { self.cancelModelFetch() }' in body
assert 'TextField("Custom Provider", text: self.$draft.name)' in source
assert 'SecureField("Enter API key", text: self.$draft.apiKey)' in source
action = source.split('Button("Add Provider") {', 1)[1]
admission = action.split('Task {', 1)[0]
assert 'self.isSubmitting = true' in admission
assert 'let submission = self.draft' in admission
assert 'defer { self.isSubmitting = false }' in action
assert 'await self.viewModel.addProvider(submission)' in action
parent = Path('Sources/Fluid/UI/AISettingsView+AIConfiguration.swift').read_text()
assert '.sheet(isPresented: self.$showingAddProviderSheet)' in parent
assert 'showingAddProviderSheet = false' not in parent
fixture = '''struct AddProviderPresentationFixture {
    let viewModel: AIEnhancementSettingsViewModel
    var isSubmitting = false
    var draft = ProviderSetupDraft(name: "Synthetic")
    var submittedDraft: ProviderSetupDraft?
    var cancelCount = 0
    var fetchCancellationCount = 0
    var isEditing = true
    var saveFailed = true
    var showingManualModel = true
    mutating func dismiss() { self.cancelCount += 1 }
    mutating func cancelModelFetch() { self.fetchCancellationCount += 1 }
    mutating func cancelFromButton() { CANCEL_ACTION }
    mutating func backFromButton() { BACK_ACTION }
    mutating func beginSubmission() {
        ADMISSION
        self.submittedDraft = submission
    }
    var boundary: AddProviderPresentationBoundary {
        AddProviderPresentationBoundary()
        OUTER_MODIFIERS
    }
}
'''
Path(sys.argv[1], 'AddSheetBoundary.swift').write_text(fixture.replace('OUTER_MODIFIERS', outer).replace('ADMISSION', admission).replace('CANCEL_ACTION', cancel).replace('BACK_ACTION', back))
PY_GATE
xcrun swiftc -parse-as-library \
    "$task_test_dir/Removal.swift" \
    "$task_test_dir/AddSheetBoundary.swift" \
    Sources/Fluid/Services/CloudTextProvider.swift \
    Sources/Fluid/UI/AISettings/ProviderSetupDraft.swift \
    Sources/Fluid/UI/AISettings/AIEnhancementSettingsViewModel+ProviderSetup.swift \
    Tests/ProviderSetupBoundaryTests.swift \
    -o "$task_test_dir/provider-tests"
"$task_test_dir/provider-tests"

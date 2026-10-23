#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_test_dir="$PWD/.build/n4-file-private-projection-tests"
mkdir -p "$task_test_dir"
trap 'rm -rf "$task_test_dir"' EXIT HUP INT TERM
python3 -S - "$task_test_dir/Production.swift" <<'PY'
from pathlib import Path
import sys
view = Path('Sources/Fluid/UI/FileTranscriptionView.swift').read_text()
imports = '\n'.join(line for line in view.splitlines() if line.startswith('import ')) + '\n'
def section(start, end):
    assert view.count(start) == 1, start
    offset = view.index(start)
    return view[offset:view.index(end, offset)]
owner = section('/// The view owns only local projections', '/// Only profile-bound presentation')
wrapper = section('/// Only profile-bound presentation', 'struct FileTranscriptionProfileView: View {')
format_type = section('    nonisolated enum ExportFormat:', '    private var selectedFileIsVideo:')
document = section('nonisolated struct TranscriptionDocument:', '// MARK: - Preview')
exporter = section('        .fileExporter(', '        .onReceive(self.fileHistoryStore.entriesPublisher)')
Path(sys.argv[1]).write_text(imports + owner
    + wrapper
    + 'struct FileTranscriptionProfileView: View {\n' + format_type
    + '    @ObservedObject var asrService: ASRService\n'
    + '    @ObservedObject var transcriptionService: FileTranscriptionService\n'
    + '    @Binding var revealTarget: AppSearchHit.Target?\n'
    + '    var body: some View { EmptyView() }\n}\n' + document
    + 'struct ExporterProbe: View {\n'
    + '    @StateObject private var privateProjection = FileTranscriptionPrivateProjection(clearReveal: {})\n'
    + '    var body: some View { EmptyView()\n' + exporter + '\n    }\n}\n')
PY
xcrun swiftc -swift-version 6 -default-isolation MainActor -parse-as-library \
    -enable-upcoming-feature MemberImportVisibility \
    -module-cache-path "$task_test_dir/ModuleCache" \
    "$task_test_dir/Production.swift" \
    Tests/N4FilePrivateProjectionTests.swift \
    -o "$task_test_dir/tests"
"$task_test_dir/tests"

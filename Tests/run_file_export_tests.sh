#!/bin/sh
set -eu
task_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$task_repo_dir"
task_test_dir="$task_repo_dir/.build/file-export-tests"
mkdir -p "$task_test_dir/Temporary"

# Compile actual export value types, service methods and FileDocument against
# Apple's native protocol, with inert service/persistence dependencies only.
python3 -S - "$task_test_dir/ProductionExport.swift" <<'PY'
from pathlib import Path
import sys
service = Path('Sources/Fluid/Services/FileTranscriptionService.swift').read_text()
view = Path('Sources/Fluid/UI/FileTranscriptionView.swift').read_text()
history = Path('Sources/Fluid/Persistence/FileTranscriptionHistoryStore.swift').read_text()
def section(text, start, end):
    assert text.count(start) == 1, f"Ambiguous production boundary: {start}"
    first = text.index(start)
    return text[first:text.index(end, first)]
def declaration(text, marker):
    assert text.count(marker) == 1, f"Ambiguous production declaration: {marker}"
    start = text.index(marker)
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]
speaker_types = section(service, 'nonisolated struct SpeakerTranscriptSegment:', 'nonisolated struct SpeakerChunkTranscription:')
result = section(service, 'nonisolated struct TranscriptionResult:', '/// Stable UI state')
exports = section(service, '    /// Export transcription result to text file', '    /// Reset the service state')
format_type = section(view, '    nonisolated enum ExportFormat:', '    private var selectedFileIsVideo:')
document = section(view, 'nonisolated struct TranscriptionDocument:', '// MARK: - Preview')
exporter = section(view, '        .fileExporter(', '        .onReceive(self.fileHistoryStore.entriesPublisher)')
Path(sys.argv[1]).write_text('import Foundation\nimport SwiftUI\nimport UniformTypeIdentifiers\n'
    + speaker_types + result + declaration(history, 'nonisolated struct FileTranscriptionEntry:') + '\n'
    + '@MainActor final class FileTranscriptionService {\n' + exports + '\n}\n'
    + 'struct FileTranscriptionView {\n' + format_type + '\n}\n'
    + document
    + '@MainActor final class ExporterProbeProjection: ObservableObject {\n'
    + '    @Published var showingExportDialog = false\n'
    + '    @Published var exportDocument: TranscriptionDocument?\n'
    + '    var isCurrent: Bool { true }\n}\n'
    + 'struct ExporterContractProbe: View {\n'
    + '    @StateObject private var privateProjection = ExporterProbeProjection()\n'
    + '    var body: some View { EmptyView()\n' + exporter + '\n    }\n}\n')
PY
xcrun swiftc -parse-as-library -swift-version 6 -module-cache-path "$task_test_dir/ModuleCache" \
    "$task_test_dir/ProductionExport.swift" \
    Tests/FileExportTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests" "$task_test_dir"

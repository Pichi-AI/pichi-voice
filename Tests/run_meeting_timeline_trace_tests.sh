#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
trace_build="$PWD/.build/meeting-timeline-trace-tests"
mkdir -p "$trace_build"
trace_case="$(mktemp -d "$trace_build/case.XXXXXX")"
# Compile the actual accepted preview callback rather than recreating its guards in a test.
# The only substitution binds its optional trace sink to this test's private directory.
python3 - "$trace_case" <<'PY'
import pathlib, sys
sys.dont_write_bytecode = True
sys.path.insert(0, str(pathlib.Path('Tests').resolve()))
from run_meeting_backup_refresh_tests import declaration

coordinator = pathlib.Path('Sources/Fluid/Services/Meeting/MeetingSessionCoordinator.swift').read_text()
callback = declaration(coordinator, 'trackPreview: { [weak self] kind, partial in')
assert 'MeetingTimelineTrace.shared?.record("protected_live_publication"' in callback
callback = callback.removeprefix('trackPreview: ')
callback = callback.replace('MeetingTimelineTrace.shared?', 'self.trace?')
models = pathlib.Path('Sources/Fluid/Services/Meeting/LiveTranscription/MeetingLiveModels.swift').read_text()
types = '\n'.join(declaration(models, marker) for marker in [
    'nonisolated enum MeetingLiveSpeaker:', 'nonisolated enum MeetingLiveAvailability:',
    'nonisolated struct MeetingLiveUtterance:', 'nonisolated struct MeetingLivePartial:',
    'nonisolated enum MeetingSpeechHypothesisStability {',
    'nonisolated struct MeetingLiveTranscriptSnapshot:'])
probe = pathlib.Path('Tests/Support/MeetingProtectedLivePublicationProbe.swift').read_text()
probe = probe.replace('// PRODUCTION_LIVE_VALUE_TYPES', types)
probe = probe.replace('// PRODUCTION_PROTECTED_PREVIEW_CALLBACK', callback)
pathlib.Path(sys.argv[1], 'PublicationProbe.swift').write_text(probe)
# The other existing caption route must trace only after its actual stale-generation and
# transcript-revision admission, never from the unaccepted privacy callback submission.
legacy = declaration(coordinator, 'private func publishLiveTranscript(')
assert legacy.index('self.liveTranscript.accepts(safe, generation: generation, activeGeneration: self.captureGeneration)') < legacy.index('self.liveTranscript = safe') < legacy.index('trace.record("protected_live_publication"')
assert 'if let trace = MeetingTimelineTrace.shared' in legacy
PY
# Child directory must not exist: disabled tracing must not create it.
python3 Tests/Support/write_private_profile_standalone_types.py "$trace_build/ProfileTypes.swift" --synthetic-brand
env -u PICHI_MEETING_TIMELINE_PROFILE xcrun swiftc -swift-version 6 -default-isolation MainActor -parse-as-library \
    -module-cache-path "$trace_build/ModuleCache" \
    "$trace_build/ProfileTypes.swift" Sources/Fluid/Account/PrivateProfileStorage.swift \
    Sources/Fluid/Services/Meeting/MeetingTimelineTrace.swift "$trace_case/PublicationProbe.swift" \
    Tests/MeetingTimelineTraceTests.swift -o "$trace_build/tests"
env -u PICHI_MEETING_TIMELINE_PROFILE "$trace_build/tests" "$trace_case/private"

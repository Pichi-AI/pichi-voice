#!/usr/bin/env python3
"""Compile the actual pure core and canonical declarations without app/model dependencies."""
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
BUILD = ROOT / '.build' / 'meeting-speaker-attribution'
BUILD.mkdir(parents=True, exist_ok=True)
subprocess.run(['bash', 'scripts/dev/assert-worktree.sh'], cwd=ROOT, check=True)
evidence = (ROOT / 'Sources/Fluid/Services/Meeting/Backend/MeetingBackendEvidence.swift').read_text()
start = evidence.index('nonisolated enum MeetingEvidenceInterval')
end = evidence.index('nonisolated struct MeetingFinalTranscriptEvidence')
# The canonical declarations are compiled verbatim; only the unrelated app identifier alias and
# Codable conformance extensions are supplied outside their original file.
contracts = 'import Foundation\ntypealias MeetingAudioTrackID = UUID\n' + evidence[start:end]
contracts += '\nnonisolated extension MeetingFinalTextUnit: Codable {}\n'
contracts += '\nnonisolated extension MeetingBackendSpeakerActivity: Codable {}\n'
configuration = (ROOT / 'Sources/Fluid/Services/Meeting/MeetingProcessingConfiguration.swift').read_text()
start = configuration.index('nonisolated enum MeetingConfigFingerprintEncoding')
end = configuration.index('\n}\n', start) + 3
contracts += configuration[start:end]
(BUILD / 'CanonicalContracts.swift').write_text(contracts)
subprocess.run([
    'xcrun', 'swiftc', '-O', '-swift-version', '6', '-strict-concurrency=complete',
    '-default-isolation', 'MainActor', '-parse-as-library',
    '-module-cache-path', str(BUILD / 'ModuleCache'), str(BUILD / 'CanonicalContracts.swift'),
    str(ROOT / 'Sources/Fluid/Services/Meeting/Backend/MeetingSpeakerAttribution.swift'),
    str(ROOT / 'Tests/MeetingSpeakerAttributionTests.swift'), '-o', str(BUILD / 'tests')
], cwd=ROOT, check=True)
subprocess.run([str(BUILD / 'tests')], cwd=ROOT, check=True)

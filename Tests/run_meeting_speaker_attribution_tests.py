#!/usr/bin/env python3
"""Compile the actual pure core and canonical declarations without app/model dependencies."""
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
BUILD = ROOT / '.build' / 'meeting-speaker-attribution'
BUILD.mkdir(parents=True, exist_ok=True)
subprocess.run(['bash', 'scripts/dev/assert-worktree.sh'], cwd=ROOT, check=True)
# Only the app identifier alias is supplied; all canonical values compile from their real file.
# MeetingFinalTextUnit carries the provider's word-timing provenance (117); its actual value type is copied
# from the persisted-metadata file, whose other declarations need unrelated meeting models.
metadata = (ROOT / 'Sources/Fluid/Services/Meeting/MeetingPersistedMetadata.swift').read_text()
marker = 'nonisolated struct ASRWordTimingProvenance:'
assert metadata.count(marker) == 1, 'Expected one production word-timing provenance declaration'
start = metadata.index(marker)
provenance = metadata[start:metadata.index('\n}\n', start) + 3]
contracts = 'import Foundation\ntypealias MeetingAudioTrackID = UUID\n' + provenance
(BUILD / 'CanonicalContracts.swift').write_text(contracts)
subprocess.run([
    'xcrun', 'swiftc', '-O', '-swift-version', '6', '-strict-concurrency=complete',
    '-default-isolation', 'MainActor', '-parse-as-library',
    '-module-cache-path', str(BUILD / 'ModuleCache'), str(BUILD / 'CanonicalContracts.swift'),
    str(ROOT / 'Sources/Fluid/Services/Meeting/Backend/MeetingCanonicalEvidenceTypes.swift'),
    str(ROOT / 'Sources/Fluid/Services/Meeting/Backend/MeetingSpeakerAttribution.swift'),
    str(ROOT / 'Tests/MeetingSpeakerAttributionTests.swift'), '-o', str(BUILD / 'tests')
], cwd=ROOT, check=True)
subprocess.run([str(BUILD / 'tests')], cwd=ROOT, check=True)

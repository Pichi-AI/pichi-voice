#!/usr/bin/env python3
"""Reuse production identity declarations with an optional synthetic storage namespace."""
from pathlib import Path
import sys
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from run_meeting_backup_refresh_tests import declaration

source = Path('Sources/Fluid/Account/AccountDomain.swift').read_text()
types = '\n'.join(declaration(source, marker) for marker in [
    'nonisolated struct AccountIdentity:', 'nonisolated struct AccountContext:',
    'nonisolated enum AccountError:'])
if '--synthetic-brand' in sys.argv:
    types += '''\nnonisolated enum AppBrand {
        static let storageNamespace = "local.voice.synthetic-profile-test"
        static let keychainService = "local.voice.synthetic-profile-test"
        static func logsDirectory(in base: URL, storageNamespace: String) -> URL {
            applicationSupportDirectory.appendingPathComponent("GuestLogs")
        }
        static let applicationSupportDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SyntheticPrivateProfile-" + String(ProcessInfo.processInfo.processIdentifier))
    }\n'''
Path(sys.argv[1]).write_text('import Foundation\n' + types)

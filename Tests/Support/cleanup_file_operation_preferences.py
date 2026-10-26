#!/usr/bin/env python3
"""Clean only the exact preference domains recorded by one synthetic file-service run.

The caller supplies the run's pre-write ownership manifest. Every on-disk version is
independently backed up and hash-verified before removal, including nonempty fixtures.
No preference-domain discovery, prefix sweep or shared daemon manipulation occurs here.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import time


DOMAIN = re.compile(r"(?:synthetic\.file-operation\.[0-9A-F-]{36}|local\.voice\.unbundled\.private-profile\.[a-f0-9]{64})")
MAX_BYTES = 16 * 1024 * 1024
API = r"""
ObjC.import('Foundation');
ObjC.import('CoreFoundation');
function run(args) {
    const source = $.NSString.stringWithContentsOfFileEncodingError(args[0], $.NSUTF8StringEncoding, null);
    const domains = JSON.parse(ObjC.unwrap(source));
    const remove = args[1] === 'remove';
    return JSON.stringify(domains.map(domain => {
        const defaults = $.NSUserDefaults.alloc.initWithSuiteName(domain);
        let foundation = null, appSync = null, directSync = null;
        if (remove) {
            defaults.removePersistentDomainForName(domain);
            foundation = Boolean(defaults.synchronize);
            appSync = Boolean($.CFPreferencesAppSynchronize(ObjC.wrap(domain)));
            directSync = Boolean($.CFPreferencesSynchronize(ObjC.wrap(domain), $.kCFPreferencesCurrentUser, $.kCFPreferencesAnyHost));
        }
        const value = ObjC.deepUnwrap(defaults.persistentDomainForName(domain));
        const keyCount = value && typeof value === 'object' ? Object.keys(value).length : 0;
        return {domain, foundation, appSync, directSync, keyCount};
    }));
}
"""


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_owned(path):
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return None
    with os.fdopen(descriptor, "rb") as stream:
        metadata = os.fstat(stream.fileno())
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1 or metadata.st_size > MAX_BYTES:
            raise RuntimeError(f"Unsafe or oversized owned preference file: {path.name}")
        data = stream.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            raise RuntimeError(f"Preference file grew beyond the bounded fixture limit: {path.name}")
    return data, metadata


def save_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def cleanup(manifest, evidence):
    domains = json.loads(manifest.read_text())
    if not isinstance(domains, list) or len(domains) > 500 or len(set(domains)) != len(domains):
        raise ValueError("Expected a bounded unique domain ownership manifest")
    if not all(isinstance(domain, str) and DOMAIN.fullmatch(domain) for domain in domains):
        raise ValueError("Manifest contains a domain outside the synthetic fixture contract")
    evidence.mkdir(parents=True, exist_ok=True)
    evidence.chmod(0o700)
    owned_manifest = evidence / "owned-domains.json"
    save_json(owned_manifest, domains)
    preferences = Path.home() / "Library" / "Preferences"
    report = {"manifestSource": str(manifest.resolve()), "manifestSHA256": digest(manifest.read_bytes()),
              "domains": domains, "backups": [], "apiPasses": [], "diskPasses": [], "complete": False}
    audit = evidence / "audit.json"

    def preserve(domain):
        source = preferences / (domain + ".plist")
        item = read_owned(source)
        if item is None:
            return None
        data, metadata = item
        checksum = digest(data)
        backup = evidence / "backups" / domain / (checksum + ".plist")
        backup.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if not backup.exists():
            with open(backup, "xb") as output:
                output.write(data)
            backup.chmod(0o600)
        if digest(backup.read_bytes()) != checksum:
            raise RuntimeError("Independent backup hash mismatch")
        record = {"domain": domain, "sha256": checksum, "bytes": len(data),
                  "backup": str(backup.relative_to(evidence)), "hashVerified": True}
        try:
            record["keyCount"] = len(plistlib.loads(data))
        except (ValueError, plistlib.InvalidFileException):
            record["keyCount"] = None
        if record not in report["backups"]:
            report["backups"].append(record)
        return metadata

    def api(mode):
        if mode == "remove":
            # A preferences daemon may recreate a different version between passes.
            # Preserve the current bytes before every destructive API request.
            for domain in domains:
                preserve(domain)
            save_json(audit, report)
        result = subprocess.run(["osascript", "-l", "JavaScript", "-e", API, str(owned_manifest), mode],
                                capture_output=True, text=True, timeout=15, check=True)
        rows = json.loads(result.stdout)
        if [row["domain"] for row in rows] != domains:
            raise RuntimeError("Preference API returned a different ownership inventory")
        report["apiPasses"].append({"mode": mode, "freshProcess": True, "results": rows})
        if any(row["keyCount"] or (mode == "remove" and not all(row[key] for key in ("foundation", "appSync", "directSync"))) for row in rows):
            raise RuntimeError("Preference caches did not synchronize to the empty domain state")

    try:
        api("remove")
        api("verify")
        for attempt in range(3):
            removed = []
            for domain in domains:
                source = preferences / (domain + ".plist")
                metadata = preserve(domain)
                if metadata is None:
                    continue
                try:
                    current = source.lstat()
                except FileNotFoundError:
                    continue
                if (current.st_dev, current.st_ino, current.st_size, current.st_mtime_ns) != (
                        metadata.st_dev, metadata.st_ino, metadata.st_size, metadata.st_mtime_ns):
                    continue
                try:
                    source.unlink()
                except FileNotFoundError:
                    continue
                removed.append(domain)
            time.sleep(0.1)
            api("verify")
            remaining = [domain for domain in domains if (preferences / (domain + ".plist")).exists()]
            report["diskPasses"].append({"attempt": attempt + 1, "removedAfterBackup": removed, "remaining": remaining})
            save_json(audit, report)
            if not remaining:
                time.sleep(0.1)
                if all(not (preferences / (domain + ".plist")).exists() for domain in domains):
                    report["complete"] = True
                    save_json(audit, report)
                    return report
            api("remove")
        raise RuntimeError("Exact owned preferences did not remain absent after bounded revalidation")
    except BaseException as error:
        report["error"] = f"{type(error).__name__}: {error}"
        save_json(audit, report)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    arguments = parser.parse_args()
    report = cleanup(arguments.manifest, arguments.evidence)
    print(f"Cleaned {len(report['domains'])} manifest-owned preference domains; backups verified")


if __name__ == "__main__":
    main()

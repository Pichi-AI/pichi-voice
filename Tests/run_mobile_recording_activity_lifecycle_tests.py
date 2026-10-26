#!/usr/bin/env python3
"""Exercise the actual Activity owner with inert OS calls, without launching an app."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    source = (ROOT / "Sources/Mobile/MobileRecordingActivity.swift").read_text()
    source = "\n".join(line for line in source.splitlines()
                       if line not in {"import ActivityKit", "import UIKit", "import SwiftUI"})
    start = source.index("    /// Resolves copy, brand and appearance")
    # Presentation remains covered by actual target/UI checks. The lifecycle body is unchanged.
    source = source[:start] + """
    private func presentation(for recording: MobileRecordingActivityPlan.Recording) -> Attributes {
        Attributes(sessionID: recording.sessionID)
    }
}
"""
    with tempfile.TemporaryDirectory(prefix="pichi-activity-lifecycle-") as directory:
        temporary = Path(directory)
        production = temporary / "ActualOwner.swift"
        production.write_text(source)
        for name, flags in [("swift6", []), ("swift6-mainactor", ["-default-isolation", "MainActor"])]:
            binary = temporary / name
            subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", *flags,
                            "-module-cache-path", str(temporary / "ModuleCache"),
                            str(production), str(ROOT / "Tests/MobileRecordingActivityLifecycleTests.swift"),
                            "-o", str(binary)], cwd=ROOT, check=True)
            subprocess.run([str(binary)], cwd=ROOT, check=True, timeout=30)


if __name__ == "__main__":
    main()

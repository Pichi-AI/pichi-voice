#!/usr/bin/env python3
"""Save native mobile frames at one-second cadence and index pixel changes locally.

Requires Xcode devicectl (physical device) or simctl (simulator) and Pillow.
Never deletes frames. A STOP file or SIGTERM ends capture between native requests.
"""
import argparse
import hashlib
import json
import shutil
import signal
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image


def utc():
    return datetime.now(timezone.utc).isoformat()


def pixel_digest(path):
    with Image.open(path) as source:
        image = source.convert("RGBA")
        digest = hashlib.sha256()
        digest.update(f"{image.width}x{image.height}:RGBA:".encode())
        digest.update(image.tobytes())
        return digest.hexdigest(), list(image.size)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--platform", choices=["device", "simulator"], default="device")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--test-case", required=True)
    parser.add_argument("--duration", type=float, default=7200)
    args = parser.parse_args()
    if not 0 < args.duration <= 43_200:
        parser.error("duration must be positive and at most twelve hours")
    if not all(c.isalnum() or c in "-_." for c in args.test_case) or not args.test_case:
        parser.error("test-case must be a safe filename component")
    if not 7 <= len(args.revision) <= 64 or any(c not in "0123456789abcdef" for c in args.revision):
        parser.error("revision must identify the tested source")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    frames = out / "frames"
    frames.mkdir()
    stopped = False

    def stop(_signal, _frame):
        nonlocal stopped
        stopped = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    start = time.monotonic()
    state = dict(startedAtUTC=utc(), platform=args.platform, testedRevision=args.revision,
                 testCase=args.test_case, intervalSeconds=1, status="running", savedFrames=0,
                 changedFrames=0, uniquePixelFrames=0, missedScheduleSlots=0, captureErrors=0,
                 differenceMethod="SHA256 of decoded RGBA pixels and dimensions; PNG metadata ignored",
                 scope="Native device display capture. All valid frames retained; changed and unique indexes select review candidates. Capture can affect runtime measurements; this is not touch-latency or FPS evidence.")
    previous = None
    seen = {}
    slot = 0
    consecutive_errors = 0
    reason = "duration"
    with (out / "frames.jsonl").open("a") as index, (out / "changed.jsonl").open("a") as changed, \
            (out / "unique.jsonl").open("a") as unique, (out / "capture.log").open("ab") as log:
        print(json.dumps(dict(captureStarted=True, output=str(out), intervalSeconds=1)), flush=True)
        try:
            while time.monotonic() - start < args.duration:
                if stopped or (out / "STOP").exists():
                    reason = "stopRequested"
                    break
                if shutil.disk_usage(out).free < 2 * 1024**3:
                    reason = "insufficientDiskSpace"
                    break
                delay = start + slot - time.monotonic()
                if delay > 0:
                    time.sleep(min(delay, 1))
                    continue
                actual_slot = int(time.monotonic() - start)
                missed = max(0, actual_slot - slot)
                state["missedScheduleSlots"] += missed
                slot = max(slot, actual_slot)
                target = frames / f"{args.test_case}-{args.revision[:8]}-{slot:06d}.png"
                began = time.monotonic()
                row = dict(requestedSecond=slot, startedAtUTC=utc(), missedSlotsBefore=missed)
                try:
                    command = (["xcrun", "devicectl", "device", "capture", "screenshot", "--device", args.device,
                                "--destination", str(target), "--timeout", "5"] if args.platform == "device" else
                               ["xcrun", "simctl", "io", args.device, "screenshot", str(target)])
                    subprocess.run(command, check=True, stdout=log, stderr=log, timeout=6)
                    digest, dimensions = pixel_digest(target)
                    row.update(file=str(target.relative_to(out)), capturedAtUTC=utc(),
                               captureSeconds=time.monotonic() - began, dimensions=dimensions,
                               pixelSHA256=digest, pngSHA256=hashlib.sha256(target.read_bytes()).hexdigest(),
                               changedFromPrevious=digest != previous, firstPixelOccurrence=digest not in seen,
                               matchesEarlierSecond=seen.get(digest), valid=True)
                    state["savedFrames"] += 1
                    if row["changedFromPrevious"]:
                        state["changedFrames"] += 1
                        changed.write(json.dumps(row) + "\n"); changed.flush()
                    if row["firstPixelOccurrence"]:
                        state["uniquePixelFrames"] += 1
                        seen[digest] = slot
                        unique.write(json.dumps(row) + "\n"); unique.flush()
                    previous = digest
                    consecutive_errors = 0
                except (subprocess.SubprocessError, OSError, ValueError) as error:
                    state["captureErrors"] += 1
                    consecutive_errors += 1
                    row.update(valid=False, error=type(error).__name__, captureSeconds=time.monotonic() - began)
                index.write(json.dumps(row) + "\n"); index.flush()
                state.update(elapsedSeconds=time.monotonic() - start, lastAttempt=row)
                temporary = out / "status.pending.json"
                temporary.write_text(json.dumps(state, indent=2))
                temporary.replace(out / "status.json")
                slot += 1
                if consecutive_errors >= 3:
                    reason = "repeatedCaptureFailure"
                    break
        finally:
            state.update(status="stopped", stopReason=reason, endedAtUTC=utc(), elapsedSeconds=time.monotonic() - start)
            (out / "status.json").write_text(json.dumps(state, indent=2))
    print(json.dumps({k: state[k] for k in ["status", "stopReason", "savedFrames", "changedFrames",
                                          "uniquePixelFrames", "missedScheduleSlots", "captureErrors"]}), flush=True)
    if reason in ["repeatedCaptureFailure", "insufficientDiskSpace"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()

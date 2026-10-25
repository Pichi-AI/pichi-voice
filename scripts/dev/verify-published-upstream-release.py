#!/usr/bin/env python3
"""Verify the narrow published-release exception to upstream/main ancestry."""

import datetime
import json
import re
import subprocess
import sys


REPOSITORY = "repos/altic-dev/FluidVoice"
TAG_PATTERN = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-beta\.[1-9][0-9]*)?")
SHA_PATTERN = re.compile(r"[0-9a-f]{40}")
MAX_TAG_OBJECTS = 8


class VerificationError(Exception):
    pass


def github_json(endpoint):
    # Never trust GH_HOST, a default repository or URLs returned in API bodies.
    result = subprocess.run(
        ["gh", "api", "--hostname", "github.com", f"{REPOSITORY}/{endpoint}"],
        capture_output=True, text=True, timeout=30,
    )
    if result.returncode:
        raise VerificationError(f"GitHub API request failed: {endpoint}")
    try:
        value = json.loads(result.stdout)
    except (ValueError, UnicodeError) as error:
        raise VerificationError(f"Invalid GitHub API JSON: {endpoint}") from error
    if not isinstance(value, dict):
        raise VerificationError(f"Expected a GitHub API object: {endpoint}")
    return value


def object_identity(value):
    if not isinstance(value, dict) or not isinstance(value.get("sha"), str) \
            or not SHA_PATTERN.fullmatch(value["sha"]):
        raise VerificationError("Invalid GitHub Git object identity")
    if value.get("type") not in ("commit", "tag"):
        raise VerificationError("GitHub tag does not resolve to a commit or annotated tag")
    return value["type"], value["sha"]


def verify(tag, expected_sha):
    if not TAG_PATTERN.fullmatch(tag) or not SHA_PATTERN.fullmatch(expected_sha):
        raise VerificationError("Outside-main targets must be canonical vX.Y.Z or vX.Y.Z-beta.N app tags")
    local = subprocess.run(
        ["git", "rev-parse", "--verify", "--end-of-options", f"refs/tags/{tag}^{{commit}}"],
        capture_output=True, text=True, timeout=30,
    )
    if local.returncode or local.stdout.strip() != expected_sha:
        raise VerificationError("Exact local tag does not match the selected immutable commit")

    release = github_json(f"releases/tags/{tag}")
    if release.get("tag_name") != tag or release.get("draft") is not False:
        raise VerificationError("Official release tag is different or the release is not nondraft")
    published_at = release.get("published_at")
    try:
        published = datetime.datetime.fromisoformat(published_at.replace("Z", "+00:00"))
        if published.tzinfo is None:
            raise ValueError("Missing publication timezone")
    except (AttributeError, TypeError, ValueError) as error:
        raise VerificationError("Official release has no valid publication time") from error

    # Current official macOS app packaging. A zip alone cannot distinguish an app
    # from Windows, runtime, source or other artifact releases.
    asset_name = f"Fluid-oss-{tag[1:]}.dmg"
    assets = release.get("assets")
    if not isinstance(assets, list) or not any(
        isinstance(asset, dict) and asset.get("name") == asset_name
        and asset.get("state") == "uploaded" and type(asset.get("size")) is int and asset["size"] > 0
        for asset in assets
    ):
        raise VerificationError(f"Official release has no uploaded macOS app image: {asset_name}")

    ref = github_json(f"git/ref/tags/{tag}")
    if ref.get("ref") != f"refs/tags/{tag}":
        raise VerificationError("GitHub returned a different tag ref")
    kind, sha = object_identity(ref.get("object"))
    seen = set()
    for depth in range(MAX_TAG_OBJECTS + 1):
        if kind == "commit":
            if sha != expected_sha:
                raise VerificationError("Official tag commit differs from the selected immutable commit")
            print(f"Verified published FluidVoice macOS release {tag}: {sha} ({published_at})")
            return
        if depth == MAX_TAG_OBJECTS or sha in seen:
            raise VerificationError("Annotated tag chain is cyclic or exceeds the depth limit")
        seen.add(sha)
        annotated = github_json(f"git/tags/{sha}")
        if annotated.get("sha") != sha:
            raise VerificationError("GitHub annotated tag identity differs from the requested object")
        kind, sha = object_identity(annotated.get("object"))
    raise VerificationError("Tag did not resolve to a commit")


if __name__ == "__main__":
    try:
        if len(sys.argv) != 3:
            raise VerificationError("Usage: verify-published-upstream-release.py <release-tag> <expected-commit-SHA>")
        verify(sys.argv[1], sys.argv[2])
    except (VerificationError, OSError, UnicodeError, subprocess.TimeoutExpired) as error:
        print(f"Published upstream release verification failed: {error}", file=sys.stderr)
        sys.exit(1)

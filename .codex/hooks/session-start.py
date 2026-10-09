#!/usr/bin/env python3
"""Remind the session of its actual checkout. This hook does not move the chat."""

import json
import pathlib
import subprocess
import sys


def git_path(cwd, option):
    value = subprocess.check_output(
        ["git", "-C", cwd, "rev-parse", option], text=True, stderr=subprocess.DEVNULL
    ).strip()
    return (pathlib.Path(cwd) / value).resolve()


def main():
    event = json.load(sys.stdin)
    cwd = str(pathlib.Path(event.get("cwd", ".")).resolve())
    try:
        primary = git_path(cwd, "--git-common-dir") == git_path(cwd, "--git-dir")
    except (OSError, subprocess.CalledProcessError):
        return
    if primary:
        context = (
            "Pichi Voice policy: this session is in the primary checkout. "
            "Before editing, create a separate Git worktree with the app tool or "
            "bash scripts/dev/new-worktree.sh <task-slug>. Use its returned directory "
            "for all commands and edits. In a cloud task, create the worktree within "
            "that task's own workspace. Read AGENTS.md. This hook is a reminder, "
            "not an automatic directory switch."
        )
    else:
        context = (
            "Pichi Voice: this session is in a linked Git worktree. Keep all edits "
            "and build outputs here. Read AGENTS.md, use a unique task branch, and "
            "report macOS checks separately from portable cloud checks."
        )
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "SessionStart", "additionalContext": context
    }}))


if __name__ == "__main__":
    main()

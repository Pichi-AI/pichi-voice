# Pichi Voice development setup

## Repository and checkout

The primary checkout is a normal clone of [Pichi-AI/pichi-voice](https://github.com/Pichi-AI/pichi-voice). The code descends from [FluidVoice](https://github.com/altic-dev/FluidVoice), with its main history retained.

The shared setup script configures a read-only `upstream` on fresh local and cloud clones. It stops for review if an existing upstream points somewhere else.

| Remote | Role |
| --- | --- |
| `origin` | Pichi Voice branches, PRs, and releases |
| `upstream` | Read-only FluidVoice source updates |

For another computer, clone our repository, then configure the upstream:

```bash
git clone https://github.com/Pichi-AI/pichi-voice.git
cd pichi-voice
git remote add upstream https://github.com/altic-dev/FluidVoice.git
git config remote.upstream.fetch '+refs/heads/main:refs/remotes/upstream/main'
git config remote.upstream.pushurl DISABLED
git config remote.pushDefault origin
git fetch upstream main --tags
```

Only upstream `main` needs a tracking ref. Its other feature branches are not part of our update workflow and include names that collide on a case-insensitive macOS filesystem. This restriction does not discard the main commit history.

## New local sessions

1. Select the **Pichi Voice** project in Codex.
2. Select **Worktree**, start from the current `main`, and select the **Pichi Voice** local environment.
3. Send the task. The app creates a separate managed worktree and runs [setup.sh](../../scripts/dev/setup.sh).
4. Create a unique `codex/<task>` branch in the worktree before committing. Commit and push that branch to `origin`; review and merge through a PR.

The checked-in [environment.toml](../../.codex/environments/environment.toml) uses the local environment schema verified in the installed app. It supplies prerequisite checks and macOS build/test actions. A new chat should verify that the environment is selected and that setup succeeded.

The [SessionStart hook](../../.codex/hooks/session-start.py) reminds an agent when it is in the primary checkout. It cannot switch the chat's working directory or force the app's composer into Worktree mode. Project hooks require a trusted repository. [AGENTS.md](../../AGENTS.md) also requires worktree creation before edits if a chat starts in Local. This is a workflow rule, not an operating-system write barrier.

For terminal use or a cloud workspace:

```bash
bash scripts/dev/new-worktree.sh russian-provider
# Change into the absolute path printed by the script.
bash scripts/dev/setup.sh
```

`new-worktree.sh` fetches the latest `origin/main`, creates a unique branch, and puts the worktree beside the primary checkout. Set `PICHI_VOICE_WORKTREE_ROOT` to use another writable location. Native Codex-managed worktrees use the app's own worktree root instead.

Use the same worktree when resuming a chat. Create a new one for a different outcome. Each worktree keeps its own DerivedData and source package checkout; dependencies resolve during the first macOS build. Model weights and personal data are not copied automatically.

## Codex Cloud

A local project entry does not create a cloud environment. Publish a separate environment for this repository:

1. Open **Work in > Cloud > Select environment > Create environment**, or **Settings > Codex Cloud > Environments**.
2. Select only `Pichi-AI/pichi-voice`. If GitHub access is requested, grant access to this repository through the normal connector flow.
3. Ask setup to install Git, Bash, and Python 3.11 or later and run `bash scripts/dev/setup.sh --allow-primary`. Keep access private during initial development.
4. Review the setup result and choose **Publish**.
5. Start a fresh cloud task and verify checkout, worktree creation, and `bash scripts/dev/check.sh` before declaring the environment ready.

Suggested environment setup request:

> Prepare a private environment for Pichi-AI/pichi-voice. Install Git, Bash, and Python 3.11 or later. Run bash scripts/dev/setup.sh --allow-primary. For each coding task, follow AGENTS.md and create a separate linked worktree before edits. Do not download speech models or copy local dictionaries, recordings, signing material, or credentials. Run portable checks. Report macOS compilation and audio validation as requiring a separate Mac.

Each cloud task receives its own isolated filesystem. A linked worktree inside that task also keeps the explicit repository policy consistent. Local worktrees, Mac Keychain entries, Xcode, running apps, and ignored local files are not automatically available in Cloud. The cloud task must commit and push its branch before another computer can fetch its changes.

| Environment | Verification |
| --- | --- |
| Cloud or Linux | Repository checks, scripts, review, and any separately added portable tests |
| Mac with Xcode | Swift/macOS compilation, integration tests, CoreML compatibility |
| Interactive Mac | Microphone, audio routing, Accessibility typing, UI, and latency checks |

A green portable check does not replace macOS validation. The initial setup does not compile or launch the unchanged upstream app. Before installing a Pichi-branded build, separate its bundle identity, settings, Keychain entries, and updater from the installed FluidVoice app.

## CI and cleanup

[Pichi Voice CI](../../.github/workflows/pichi-ci.yml) runs portable checks. macOS testing is available through manual workflow dispatch. To enable macOS testing on every code change, set the repository variable `PICHI_VOICE_MACOS_CI` to `true` after reviewing runner usage and the baseline results.

Upstream community moderation and archive workflows are retained but guarded to run only in `altic-dev/FluidVoice`. Our repository does not inherit their scheduled issue closing or comment policies.

The organization currently uses GitHub Free. GitHub does not provide protected branches for a private organization repository on that plan. The PR and worktree rules are therefore process rules during private development. Enable main-branch protection with the Repository checks status when the repository becomes public, or if the organization moves to GitHub Team. See [protected branch availability](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches).

Merge reviewed task branches, fetch the updated `main`, and start new work from it. Archive managed worktrees through Codex after checking that needed work is pushed. Remove manually created worktrees with `git worktree remove <path>` after confirming that their work is saved. Do not remove another active session's worktree.

## See also

- [Agent instructions](../../AGENTS.md)
- [Upstream and extension strategy](upstream.md)
- [Codex worktrees](https://learn.chatgpt.com/docs/environments/git-worktrees)
- [Local environments](https://learn.chatgpt.com/docs/environments/local-environment)
- [Cloud environments](https://learn.chatgpt.com/docs/environments/cloud-environments)

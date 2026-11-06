# Contributing to Pichi Voice

This repository is [Pichi-AI/pichi-voice](https://github.com/Pichi-AI/pichi-voice), a downstream of FluidVoice. The shared development policy is [AGENTS.md](AGENTS.md). It applies to human and AI-assisted contributions; detailed procedures have one owning guide rather than separate rules for each contributor.

## Propose a useful, reviewable change

Explain the problem, intended behavior and acceptance criteria. Link an existing issue or design discussion when one exists. A direct task from the repository owner can define the scope; creating a duplicate issue or seeking FluidVoice maintainer approval is not a prerequisite for downstream work. Resolve unclear scope or consequential product decisions with the owner.

Keep changes focused and preserve upstream integration boundaries, privacy and ownership. Work in an isolated worktree and task branch. See [Agent workflow](docs/development/agent-workflow.md) for coordination, signing and cleanup, and [upstream strategy](docs/development/upstream.md) for extension contracts.

## Include behavioral evidence

New and changed executable behavior includes unit tests in the same change. UI interaction changes also include integration tests. Follow [Testing](docs/development/testing.md) for test locations, meaningful assertions, actual target discovery and bounded execution. Documentation-only changes need diff/link/consistency checks.

Describe what changed and why, then report checks actually run against the candidate, environment when relevant, skips and gaps. Attach native visual evidence when appearance or interaction changes. Text logs are sufficient for non-visual checks. Keep private recordings, user content, credentials and personal identifiers out of commits and attachments.

## Review and publication

Review the full diff and obtain an independent automated review of the integrated revision before publishing a PR to this repository. Address material findings and rerun affected checks. Use the [PR template](.github/pull_request_template.md) to make the result reviewable. Do not report generated explanations or earlier-revision checks as fresh observations.

AI assistance does not change responsibility for the diff or accuracy of evidence. Briefly describe relevant AI assistance and what was independently reviewed and tested. Publication and merge follow the owner's authorization and repository access controls; these instructions do not grant authority outside the assigned task.

## Contributions to FluidVoice itself

When submitting to `altic-dev/FluidVoice`, follow its current [contribution policy](https://github.com/altic-dev/FluidVoice/blob/main/CONTRIBUTING.md) and templates. Its issue, discussion, approval and human-review requirements apply to upstream submissions. Do not treat downstream authorization as permission to post unsolicited upstream changes.

Inherited upstream moderation/archive workflows are repository-guarded. They are not a second contribution policy for Pichi Voice. Preserve upstream copyright and license notices regardless of destination.

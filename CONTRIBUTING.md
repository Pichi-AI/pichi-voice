# Contributing to Pichi Voice

This is the [Pichi Voice repository](https://github.com/Pichi-AI/pichi-voice). The shared development policy is [AGENTS.md](AGENTS.md). It applies to human and AI-assisted contributions; detailed procedures have one owning guide rather than separate rules for each contributor. See [acknowledgements](docs/product/acknowledgements.md) for the project's origin and license.

Bug reports, questions, documentation and code contributions are welcome in English or Russian. Use the [issue chooser](https://github.com/Pichi-AI/pichi-voice/issues/new/choose) and search existing issues first. Follow the [code of conduct](CODE_OF_CONDUCT.md). Report vulnerabilities through [the private security process](SECURITY.md).

## Your first pull request

You do not need write access to this repository. Fork it on GitHub, clone your fork and start a task branch from the current Pichi Voice baseline:

```sh
git clone https://github.com/YOUR-USERNAME/pichi-voice.git
cd pichi-voice
git remote add pichi https://github.com/Pichi-AI/pichi-voice.git
git fetch pichi main
bash scripts/dev/new-worktree.sh my-change pichi/main
```

Continue in the absolute worktree directory printed by the helper. Follow [development setup](docs/development/codex.md) for prerequisites and relevant checks. The `pichi` remote tracks this project; `upstream` is reserved for read-only FluidVoice integration.

Commit your change, push the task branch to your fork with `git push -u origin HEAD`, then open a pull request with base repository `Pichi-AI/pichi-voice` and base branch `main`. Fill in the PR template and describe checks actually run. A maintainer approves GitHub Actions runs from external forks before they execute.

At present, [@sabbah13](https://github.com/sabbah13) accepts changes into `main`. Contributions are proposals for review; opening an issue or PR does not grant write or release access. Small documentation fixes are welcome without a prior issue. Contributions remain under the repository's [GPL-3.0 license](LICENSE); keep applicable third-party notices.

По-русски: создайте fork, подготовьте отдельную ветку и откройте PR в `Pichi-AI/pichi-voice`, ветка `main`. Для вопроса или ошибки используйте Issues. Проверяйте вложения и не публикуйте личные данные.

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

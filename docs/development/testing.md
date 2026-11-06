# Testing policy and repository map

This is the canonical test guide for [AGENTS.md](../../AGENTS.md). It defines what accompanies a change and where it belongs. Commands are mechanisms, not a requirement to run every suite.

## Behavior and coverage

Every new or changed executable behavior includes unit tests in the same change. Use the existing owning suite, including for development scripts and native adapters. A bug fix includes a regression exercising the failure. A refactor retains and, where necessary, adapts behavioral coverage. Reuse an existing test when it already exercises the complete changed contract; explain that mapping in review.

For interface interactions, add both unit tests for underlying state/actions and integration tests for the UI-to-service boundary. Exercise the real view model, controller or service composition with deterministic external substitutes. Use XCUITest when the contract depends on native controls, focus, gestures, navigation or accessibility. A service test alone cannot establish native event routing. Visual-only code changes still need automated tests of the changed presentation behavior and native inspection; do not invent meaningless assertions for static prose or asset bytes.

The goal is observable coverage of all behavior introduced or changed, not a numeric claim about every historical line. CI requires 100% coverage of added or changed compiler-executable source lines through the Coverage gate. Overall legacy coverage is informational; separate platform reports are not averaged into one repository percentage. Do not call the whole codebase fully covered because this policy exists. If a boundary is hard to test, expose it through the existing architecture rather than waive tests or create a second implementation. Keep unexecuted required checks visible in the handoff.

Tests should fail when the contract breaks and survive internal rearrangement that preserves behavior. Assert outcomes, errors, admission decisions and relevant cleanup. Include success, failure, cancellation, persistence or recovery cases when those contracts change. Control clocks, IDs, filesystem roots and external services through existing injection seams. Keep ordinary unit tests offline and independent of personal settings, accounts, permissions and installed models. Avoid sleeps and test-order dependencies.

## Test ownership and storage

Preserve inherited target names and layout. Do not reorganize existing tests merely for naming consistency.

| Code or artifact | Versioned location and ownership |
| --- | --- |
| macOS app unit and integration tests | `Tests/FluidDictationIntegrationTests/`, the existing `FluidDictationIntegrationTests` XCTest target. Its inherited name contains both test levels. Group new cases by feature. |
| iOS app unit and hosted integration tests | `Tests/MobileIntegrationTests/`, the existing `PichiVoiceMobileIntegrationTests` target. |
| iOS native UI automation | `Tests/MobileUITests/`, the existing `PichiVoiceMobileUITests` target. |
| Shared helpers | `Tests/Support/` where compatible with the owning target, or target-local support. Keep test doubles out of production builds. |
| Small synthetic or approved public fixtures | `Tests/Fixtures/` or the owning target's `Fixtures/`. Explain provenance and licenses where needed. Register resources with the actual test target. |
| Package and native adapter unit tests | The owning `Vendor/<Package>/Tests/` tree and existing package test target. Examples include NativeTextInference, PichiGigaAM, RussianMorphology and TranscribeCpp. |
| Portable development-tool tests | Existing `Tests/test_*.py` conventions, or tests beside their owning tool under `tools/`. Use standard-library unittest or the existing runner. |
| Existing standalone probes | Maintain `Tests/run_*` and their registry in `scripts/dev/standalone-regression.py`. They are complementary legacy checks. `scripts/dev/test-*.sh` contains separate manual probes. |

Add new app behavior tests to actual XCTest targets. Do not introduce new tests that extract Swift declarations by text markers, assert source layout or compile a copied implementation. Maintain existing projections when required by an affected contract, but report their narrower scope and prefer migration into actual targets when part of the task. Do not split production files solely to satisfy a probe.

The root `Package.swift` has no application `testTarget`; root `swift test` does not run the app suite. Xcode schemes and project membership determine native test compilation and discovery. Add tests using the existing target membership or project-generation mechanism and verify discovery. A file merely placed under `Tests/` is not coverage.

Generated logs, `.xcresult`, screenshots, recordings, build products and test containers belong in unique ignored worktree-local directories, normally `.build/<purpose>/<run-id>/`. Existing wrappers own their result layout. Real-model fixtures, private recordings and personal data belong in ignored local storage or an authorized artifact store, never versioned fixtures. Record useful sanitized evidence in the PR or existing handoff, with revision, command, scope, result, skips and duration. Preserve needed evidence outside a worktree before removing it.

## Selecting checks

Choose the smallest set proving changed contracts and their integration. Writing required tests is separate from running unrelated suites.

| Change | Required evidence |
| --- | --- |
| Instructions or documentation only | Diff, local links/anchors and consistency with actual commands and policy. No native build. |
| Development tooling | Focused unit/regression tests and a relevant real invocation when safe. |
| Local app behavior | Focused unit tests plus the affected integration contract in the real target. A test build also establishes compilation of that configuration. |
| UI interaction | Unit tests, UI-to-service integration tests, affected target build and native changed states. Add native UI automation when event routing is part of the contract. |
| Shared service or provider contract | Unit tests and integration tests for named affected consumers. Model quality is separate from deterministic contract tests. |
| Privacy/admission or mute behavior | Unit transition/error tests plus an actual boundary check for exclusion and permitted resume/publication. For conferencing behavior, add a short smoke test in each requested platform. |
| Signing, permissions, hardware or real inference | Relevant automated tests plus exact [native acceptance](agent-workflow.md#native-acceptance). Report environmental gaps explicitly. |

Broaden checks for a concrete uncovered failure, changed shared contract or explicit task requirement. Name the risk and resolving check. Do not automatically add benchmarks, model downloads, full hardware matrices or unrelated recovery scenarios. A stalled harness gets a bounded diagnosis; repeatedly increasing timeouts is not evidence.

## Existing commands

Run from the task worktree. These entry points are not interchangeable measures of coverage.

| Command | Scope and limits |
| --- | --- |
| `bash scripts/dev/check.sh` | Portable configuration, syntax and selected tooling checks. Does not compile the native app. |
| `bash scripts/dev/macos.sh test` | macOS XCTest through the Fluid scheme, with the inherited flaky Whisper tiny fixture excluded. Requires full Xcode. |
| `bash scripts/dev/macos.sh regression -only-testing:FluidDictationIntegrationTests/<Class>` | Builds for testing once, runs selected macOS cases and retains revision-bound results. Optionally append `/testMethod`. |
| `bash scripts/dev/standalone-regression.sh --list` | Lists existing registered probes without native work. Use `--only NAME` for focused runs. UI activation remains explicitly opt-in. |
| `bash scripts/dev/mobile.sh build-for-testing` | Compiles mobile app and test targets for the simulator; does not execute tests. |
| `PICHI_MOBILE_DESTINATION='platform=iOS Simulator,id=<owned-UDID>' bash scripts/dev/mobile.sh test` | Runs the mobile scheme on an explicitly owned simulator. Reserve devices and inspect selected tests before native UI work. |
| `swift test --package-path Vendor/<Package>` | Tests that package only. Isolate build/cache outputs and inspect prerequisites first. |

The [development command reference](codex.md#reproducible-macos-regression) explains report formats, options and opt-in live checks. Do not repeat passing builds after documentation changes, for reassurance or just because a merge commit changes the SHA. Reuse results only when relevant source, resources, configuration, toolchain and inputs are unchanged or equivalence is demonstrated.

## CI and review

[Pichi CI](../../.github/workflows/pichi-ci.yml) runs one Linux job for PR updates, pushes to main and manual dispatch. Branch pushes without a PR do not duplicate this job. It checks portable configuration, localization, project membership, Python unit tests and 100% Python patch coverage. Keep routine hosted validation lightweight; native builds do not run on GitHub-hosted macOS runners.

The automatic status is **Portable checks and Python coverage**. Its report declares `coverage_scope: python` and lists deferred native scopes. It never claims that Swift code or native UI has been tested. Unsupported executable languages still fail closed. A green portable check does not satisfy full native coverage or authorize merging without the required native evidence.

Before merging, execute affected native unit/integration contracts and UI interactions in an isolated environment on an owned Mac. [Native verification](../../.github/workflows/pichi-native.yml) is manually dispatched on a prepared self-hosted Mac, with no paid-hosted fallback. It runs selected producers sequentially and emits the distinct **Coverage gate** status. Select the task branch to compare against its merge base; dispatching unchanged main requires the explicit full-baseline option. An empty selection fails rather than reporting unexecuted tests as a pass. Broad language/theme matrices and real-model acceptance are separate checks chosen for relevant changes or release risk, rather than a default cost on every PR update.

### Isolated native runner admission

A runner carrying `[self-hosted, macOS, ARM64, pichi-voice-isolated]` must use a disposable VM or dedicated test account with no personal app data, credentials, active recordings or other sessions' resources. Its operator verifies isolation and resets owned test state between jobs. A label or environment flag is an admission signal, not a sandbox. Do not register the user's ordinary desktop account to make CI work.

The verified runner process supplies `PICHI_ISOLATED_NATIVE_RUNNER=1` and `DEVELOPER_DIR` for Xcode 27.0, with iOS 27.0, iPhone 17/iPad (A16) device types and Python 3.11 or newer available. The workflow deliberately does not set its own isolation attestation. Until the machine is prepared and a real native run passes, automatic native verification remains an explicit delivery gap.

In that isolated runner environment, the same orchestration can be invoked before publishing a new workflow:

```sh
python3 -m venv .build/coverage-venv
.build/coverage-venv/bin/python -m pip install coverage==7.17.2
.build/coverage-venv/bin/python scripts/dev/coverage-ci.py verify --output .build/coverage
```

To validate a PR before the new native workflow exists on main, dispatch through the existing CI entry point:

```sh
gh workflow run pichi-ci.yml --ref codex/<task> -f native_only=true
```

That manual mode calls the same native workflow and skips the hosted Linux job. It has no hosted native fallback. Use `-f full_baseline=true` when intentionally validating unchanged main or every scope. Ordinary PR events still select only the inexpensive portable job.

The full **Coverage gate** requires successful selected producers, nonempty real test execution, exact source identity, normalized tracked paths and reports for every affected production file. New/changed executable lines must all have hits. Missing or malformed evidence fails closed. Test-only edits require their owning tests without putting test code in the production denominator. Declarative configuration and generated/binary resources are validated by their consumers, not given invented line hits. The native workflow keeps its worktree and independent Git metadata outside checkout cleanup. A separate cancellation-safe step verifies recorded simulator identity before releasing it. Compact evidence must be saved before removing the worktree; failed simulator cleanup/uploads or unexpected changes retain its recovery state.

The implementation is [coverage-gate.py](../../scripts/dev/coverage-gate.py), with synthetic Git/report regressions in [test_coverage_gate.py](../../Tests/test_coverage_gate.py). Its default mode checks the complete change. Explicit `--python-only` is a scoped check and records deferred native scopes. [coverage-ci.py](../../scripts/dev/coverage-ci.py) owns producer orchestration, format conversion and isolated verification; its contracts are tested in [test_coverage_ci.py](../../Tests/test_coverage_ci.py). Native coverage comes from raw xccov line records and package coverage includes every XCTest binary. Physical line sets differ from weighted function/instantiation counts in aggregate Xcode summaries. Python reports include unexecuted tracked source and subprocess instrumentation. Children explicitly using `-S` cannot use site startup; required new behavior still needs measured unit coverage.

Each producer uses fresh build/profile directories so retries cannot inherit earlier hits. Every required package must execute passing tests of its own. iOS uses owned iPhone/iPad simulators and frozen simulator-signed products. The iPhone runs hosted integration, CI UI smoke and changed UI XCTest classes; the iPad runs CI smoke. Changed UI helpers need an explicit owning class. Caller-staged audio/sessions remain opt-in; a selected class cannot be entirely skipped. Real accounts, private recordings, model weights and physical devices are outside ordinary deterministic verification.

A failed test is not a successful coverage run. Independent review maps changed behavior to unit tests and UI interaction to integration coverage, and checks meaningful assertions, target discovery, privacy, immutable selection, cancellation and restoration. Line hits do not prove assertions or test level.

GitHub must also require the stable `Coverage gate` status in the main-branch rules to prevent merging a failing PR. At implementation verification, both rulesets and branch-protection APIs returned HTTP 403 for this private organization repository on GitHub Free, despite repository administrator access. The workflow emits a blocking failure status, but server-enforced required-check configuration remains unavailable until the repository's GitHub plan supports it. Do not change visibility, subscription or billing to bypass this limit without the owner's decision.

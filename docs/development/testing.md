# Testing policy and repository map

This is the canonical test guide for [AGENTS.md](../../AGENTS.md). It defines what accompanies a change and where it belongs. Commands are mechanisms, not a requirement to run every suite.

## Behavior and coverage

Every new or changed executable behavior includes unit tests in the same change. Use the existing owning suite, including for development scripts and native adapters. A bug fix includes a regression exercising the failure. A refactor retains and, where necessary, adapts behavioral coverage. Reuse an existing test when it already exercises the complete changed contract; explain that mapping in review.

For interface interactions, add both unit tests for underlying state/actions and integration tests for the UI-to-service boundary. Exercise the real view model, controller or service composition with deterministic external substitutes. Use XCUITest when the contract depends on native controls, focus, gestures, navigation or accessibility. A service test alone cannot establish native event routing. Visual-only code changes still need automated tests of the changed presentation behavior and native inspection; do not invent meaningless assertions for static prose or asset bytes.

The goal is observable coverage of all behavior introduced or changed, not a numeric claim about every historical line. There is no measured repository-wide percentage or enforced coverage threshold in the checked-in infrastructure. Do not call the whole codebase fully covered because this policy exists. If a boundary is hard to test, expose it through the existing architecture rather than waive tests or create a second implementation. Keep unexecuted required checks visible in the handoff.

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
| Existing standalone probes | Maintain `Tests/run_*` and their registry in `scripts/dev/standalone-regression.py`. They are complementary legacy checks. The registry covers every `Tests/run_*` runner and lists by hand the checks that live elsewhere. The `scripts/dev/test-*.sh` probes that load real models stay manual and unregistered. |

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
| `python3 -S scripts/dev/verify --changed` | One bounded gate for an integrated candidate, a changed shared contract or an explicit request. It picks a [layer](#gate-layers) from the diff and writes a receipt. An ordinary small change does not need it. |

The [development command reference](codex.md#reproducible-macos-regression) explains report formats, options and opt-in live checks. Do not repeat passing builds after documentation changes, for reassurance or just because a merge commit changes the SHA. Reuse results only when relevant source, resources, configuration, toolchain and inputs are unchanged or equivalence is demonstrated.

## Gate layers

`scripts/dev/verify` picks the layer from the diff against `origin/main`, or takes `--layer L0`, `L1` or `L2`. It writes `.build/verify/<run>/receipt.json` with the revision, each step and its duration, and what was skipped and why.

| Layer | Runs |
| --- | --- |
| L0 | `check.sh`, SwiftLint on changed lines |
| L1 | L0, XCTest and the standalone probes side by side, iOS integration tests when mobile or shared sources changed, tests of a changed `Vendor/` package, the skip registry |
| L2 | L1 with iOS integration and every `Vendor/` package each time |

A path with no rule takes L1, so a new kind of file cannot skip the app. A red step stays red: nothing retries a test or rewrites a result. XCTest stays serial because about half of its classes change shared settings and parallel workers share one preferences domain, so a parallel run fails at random. L1 and L2 stop when less than 10 GB is free. A heavy layer that cannot run on this machine, or a tree that changes during the run, ends as `incomplete` with exit code 2, never as passed.

## CI and review

The checked-in [Pichi CI workflow](../../.github/workflows/pichi-ci.yml) runs portable checks. macOS tests and mobile builds have separate opt-ins; inherited [FluidVoice CI](../../.github/workflows/build.yml) is guarded to upstream. Inspect actual job conditions and repository settings before claiming native tests ran. A green portable status is not native regression or device acceptance. This instruction refactor does not enable runners or change CI settings.

Independent review maps changed behavior to unit tests and UI interaction to integration coverage. Check target membership, discovery, meaningful assertions, privacy, immutable selection, cancellation and restoration. Treat skipped, unexecuted or all-skipped cases as limitations. Coverage collection or required CI gates need an infrastructure change and an agreed baseline; do not invent a percentage here.

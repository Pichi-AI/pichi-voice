# What’s New release maintenance

`Sources/Fluid/UI/ReleaseHighlightsContent.swift` is the release definition. Keep the shared presenter, layout, and controls unchanged when updating copy.

## Selecting highlights for a Pichi Voice release

1. Compare the previous public Pichi tag with the exact source selected for the new version. Verify the changes in the Mac app and its bilingual release notes. Pick up to three things a person can do differently or should know after updating. Keep the complete list in [GitHub release notes](development/release-notes.md).
2. Write a short title and a sentence explaining the change in both interface languages. Give each card an illustration of that specific feature as it appears in Pichi Voice and a button naming the destination. Use synthetic examples and static views. Opening a card can show settings, a feature, an explanation or the history. The user chooses whether to start recording, enable analytics or change a preference there.
3. Add the selection to `ReleaseHighlightsContent.current(version:)` under the Pichi marketing version. Keep published sets associated with their own versions. On a maintenance release with no useful highlight, deliberately choose the history-only view and record the editorial reason in the release log.

For example, [Pichi Voice 0.3.0](https://github.com/Pichi-AI/pichi-voice/releases/tag/v0.3.0) introduced meeting audio source choices and a new usage-reporting policy. Its recording card illustrates the microphone, one app and all computer audio. Its button opens the recording settings. Its privacy card explains daily activity and optional detailed metrics and opens the app's existing analytics disclosure. The release notes cover the remaining changes to call handling, renaming and formatting.

## Checking the exact release

Run the following from the clean candidate worktree before building the archive, using its actual release version, build and source. The review compiles the app's offline card definition and prints its selected IDs.

```sh
python3 scripts/dev/macos-release.py review-highlights --source "$pichi_source" \
  --version "$pichi_version" --build "$pichi_build"
sh Tests/run_release_highlights_tests.sh
```

For an intentionally history-only release, provide `--history-only-reason "…"` to both `review-highlights` and `prepare`. Preparation checks the same definition before packaging. Keep its output with the operator evidence. Verify the frozen signed window in English and Russian, each illustration and button destination, Close and Escape, and light and dark appearances. For example, following the recording card should leave recording stopped.

## Presentation contract

- Automatically appears in the active main window when onboarding and blocking work have finished. It waits for other sheets to close.
- A main-thread coordinator grants one presentation at a time across windows. Session tokens reject stale dismissal callbacks.
- Acknowledge the installed marketing version and build after dismissal. Relaunching the same build preserves acknowledgement.
- Store the last 32 acknowledged versions in the local `FluidVoiceSeenReleaseHighlightVersions` preference. No telemetry is sent. Recent downgrades do not repeat acknowledged highlights.
- If recording/processing starts, close without acknowledging or navigating. Retry when eligible. Closing the host window also releases ownership without acknowledging.
- Feature buttons dismiss first, then navigate only if the app is still eligible. Double clicks cannot queue multiple destinations. Closing with X/Escape never navigates.
- Help → What’s new reopens the current release manually, even after acknowledgement.
- Copy edits within an already-acknowledged app version do not reopen the popup. Bump the app version when shipping a new update. Unknown version families never display stale highlights.

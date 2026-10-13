# iPad meeting interface concepts

Design-only SwiftUI executable for choosing an iPad direction before implementing a mobile capture or inference pipeline. Production changes extract the existing dictation waveform renderer and the unchanged audio-retention enum into portable files used by the original app and this preview. Inference, storage, project configuration and permissions are unchanged. Buttons only navigate or change fixture state. No microphone, location, network, model download, file export or speaker enrollment action occurs.

## Three compositions

| Concept | Composition | Best use |
| --- | --- | --- |
| A | Selected direction: sidebar plus current meeting. History is a separate destination, never a second column on Meetings. Compact widths use the same three destinations below the document. | Current recording flow, independent History and Settings. |
| B | Focus: a quiet, centered conversation canvas with bottom navigation. | Viewing the current conversation with little surrounding chrome. |
| C | Field dashboard: current meeting, recent meeting cards and storage summary. | Starting and reviewing several offline meetings through the day. |

Every concept uses the existing portable purple brand package, decoded once from the build's copy of `Sources/Fluid/Branding/brand-package.json`. The prototype-only decoder reads its display profile, palette, spacing, corner radius, logo and body/title font design. This helper solves the current AppKit-only theme boundary for an isolated visual study; it is not a new production branding framework. Real implementation should reuse the existing AppBrand, AppTheme and FluidTypography contracts after narrowly isolating their platform-specific parts.

Body and title roles use the package's native Apple font designs. iOS uses scalable native text styles, and the Mac preview uses matching default iOS point sizes. Numeric timers preserve a rounded numeric role; timestamps preserve a monospaced role. Main controls are at least 44 points, usually 56, and phone text stays readable. UI copy is in `Resources/Localizable.xcstrings` with English and Russian localizations. Transcript and meeting names are separate synthetic fixture data and are not translated with the interface.

Main navigation is **Meetings / History / Settings**. Speech models and privacy remain inside application Settings in every composition, following the user's correction. Their detail screens have a Settings back action, and compact navigation keeps Settings selected while either detail is open.

## Fixture behavior and decisions

- Audio retention is **on by default**, following the user's decision. `--audio-off` demonstrates the optional strict mode.
- Strict text-only mode proposes **no audio files, including temporary files**. It requires bounded memory chunks, writing only text, no audio playback/reprocessing, and stopping capture if inference cannot keep up. This is not implemented by the prototype. Handling of application termination and incomplete text is a remaining implementation decision.
- Mobile exposes speech recognition only: multilingual Whisper Tiny, Russian GigaAM v3 and multilingual NVIDIA Parakeet TDT 0.6B v3. No text enhancement or meeting summary provider/UI is included. No model is marked installed, compatible or fast on iPad.
- Starting a meeting has no conversation-language field or language confirmation step.
- Active rows use the existing neutral **Microphone** source label. Completed synthetic rows use the existing participant-number copy; an optional future self profile is separate from these example results.
- Personal voice enrollment, location and a meeting-diarization toggle remain requested future extensions in the plan, not active controls in this reduced UI. Recording settings use the original source/speaker-model vocabulary and do not claim installed models.
- Recording UI is steady: a label, microphone symbol and timer, without blinking. The eventual app must preserve the system microphone indicator and background recording disclosures.
- English/Russian synthetic dialogue discusses presentation documents only. No patient identity, real voice, private recording, pharmaceutical efficacy or treatment claim is included.

## Compile

From this task's separate worktree:

```bash
bash Prototypes/iPadMeetingConcepts/build.sh all
```

Requires full Xcode. The script compiles a standalone Apple Silicon Mac preview and an arm64 iOS simulator executable against the installed SDK, targeting iOS 18. This permits using the unchanged shared renderer's `onScrollGeometryChange`. No production app target is changed. Compilation does not validate simulator rendering, real iPad memory, background capture, inference, battery, permissions or audio.

Output stays under ignored `.build/ipad-meeting-concepts/`. The preview has its own `ai.pichi.voice.design.prototype` bundle identifier, no microphone/location permissions and no access to application storage. It is unsigned and has no capture behavior.

## Inspect native preview

The parent session owns interactive UI inspection. Launch the compiled executable directly so arguments are preserved:

```bash
.build/ipad-meeting-concepts/mac/MeetingConcepts.app/Contents/MacOS/MeetingConcepts --layout A --screen active --width 1194 --height 834
```

The native Mac preview keeps **Pause/Resume demo**, **Replay demo** and **Rotate** actions in its host toolbar, outside the simulated app. Playback controls are disabled before a meeting starts and during final processing. It has a **Rotate** toolbar action and an **Orientation** menu with Landscape/Portrait choices. Command-R swaps the logical device width and height. The same root view retains its current meeting, live replay, navigation and settings. A portrait canvas scales down to fit the Mac screen, while layout still uses the full logical device dimensions shown in the window subtitle. Resizing the Mac window changes preview magnification. The toolbar is preview-only chrome, outside the app canvas; offscreen exports and the iOS target do not include it. Closing the preview window terminates this standalone host.

Options:

| Flag | Values |
| --- | --- |
| `--layout` | `A`, `B`, `C` |
| `--screen` | `ready`, `active`, `processing`, `completed`, `settings`, `recording-settings`, `privacy`, `models`, `history` |
| `--width`, `--height` | Suggested content sizes: 1194 x 834, 834 x 1194, 550 x 834, 390 x 844 |
| `--dark` | Dark appearance from the brand package |
| `--audio-off` | Start this fixture with strict text-only selected; default remains audio on |
| `--language` | `ru` or `en`; other resource languages can be added without application language branches |
| `--export` | Absolute PNG path for a 2x offscreen SwiftUI concept render |
| `--replay-time` | Synthetic replay time for deterministic source-renderer concept frames; no microphone or inference |

Example concept export:

```bash
mkdir -p .build/ipad-meeting-concepts/renders
.build/ipad-meeting-concepts/mac/MeetingConcepts.app/Contents/MacOS/MeetingConcepts --layout A --screen active --width 1194 --height 834 --export "$PWD/.build/ipad-meeting-concepts/renders/A-active-landscape.png"
```

Offscreen exports are visual design artifacts, not device or interactive app screenshots. Save and inspect native screenshots after each interactive preview step, with the tested commit and scenario in their filenames, as required by AGENTS.md. The current machine's lack of an installed iOS simulator runtime is separate from SDK compilation; physical iPad and iPhone checks remain required.

## Parent integration verification

The parent integrated this prototype into `codex/ipad-voice-design` and compiled both SDK outputs there. Portable repository checks passed. Initial native Mac inspection covered A/B/C, phone widths and appearance. Current A has a compact original-style meeting start, separate Recording/Speech Recognition/Privacy settings, existing retention choices, session-scoped audio availability and neutral unknown speaker labels for the synthetic current result. These are native preview-host screenshots, not iPad execution or microphone evidence.

Independent review found compact enrollment content needed scrolling and the history sheet needed an adaptive width. Both were corrected. Fixture navigation now preserves the current meeting state and selects the requested history item. Frozen preview bundles may include `Contents/Resources/preview-arguments.json`, an array of the documented flags, so the UI inspector can launch a scenario directly. Explicit command-line flags take priority. Frozen copies and screenshot evidence remain in ignored `.build/` storage.

The implementation plan is in [ipad-voice-plan.md](../../docs/development/ipad-voice-plan.md), and the sourced list of 45 iPad generations/sizes with preliminary suitability is in [ipad-device-matrix.md](../../docs/development/ipad-device-matrix.md).

## Live animation and direct reuse

The 42-second `live-replay.json` fixture publishes phrase hypotheses and buffered groups through the unchanged production `MeetingLiveTranscriptSnapshot` and `MeetingLiveBubbleComposer`. The view is the unchanged `MeetingLiveBubbleScrollList(documentStyle: true)`: stable UUID through partial/final, in-place text corrections, immediate final foreground, opacity insertion over 0.2 seconds, Reduce Motion and the existing 80-point follow threshold. No copied row/scroll implementation is used.

The build compiles nine production source files directly: `MeetingLiveModels.swift`, its `MeetingEchoDetector.swift`/`MeetingPCMFormatContract.swift` helper dependencies, `MeetingLiveCaptionBubbles.swift`, `PichiLocalization.swift`, `MeetingUILocalization.swift`, `AudioWaveformBars.swift`, `AudioSpectrumMeter.swift` and `MeetingAudioRetentionPolicy.swift`. `PrototypeCaptionTheme` supplies only the caption renderer's theme members from the portable brand package because the full production theme still imports AppKit. The original String Catalog is merged into the preview bundle at build time; product phrases retain their existing translations. The explicit preview language uses a volatile defaults domain and does not persist preferences.

`AudioWaveformBars` is the actual dictation Canvas/50 Hz Timeline renderer, extracted from `BottomWaveformView` with the spring simulation preserved byte-for-byte. The desktop wrapper retains its live level read, settings, visibility, processing/release gating, fill, glow and shimmer. Reduce Motion uses a stationary baseline. The meeting header uses the existing Medium geometry (8 bars, 3.5-point width, 4.5-point spacing, 6...28-point height, 130 x 32 canvas). Only its level is synthetic, derived from the replay clock. Pausing/ending replay, leaving the current meeting or making the preview inactive stops waveform ticking. No separate sampling task or microphone is created.

Replay is an interface illustration, not measured iPad ASR performance. Stop follows the existing save/transcribe/finalize/result flow with synthetic stage timing. This fixture has no installed speaker model or speaker evidence, so it skips identification and produces unknown speaker labels; actual backends retain their registered required/optional diarization contracts. Capture, speaker inference, audio playback and editing are not implemented here. The finished current-meeting text comes from the replay's committed phrases and retains its duration. Replay cancellation is joined, and navigation to History/Settings preserves the current meeting.

## Original product parity

Selected A reuses the original meeting start/record/process/result vocabulary and removes the invented start form, repeated retention badges, fake speaker toggle, device-evaluation action and future voice/location controls. The existing speaker-model details belong under Recording. Privacy contains the explicitly requested strict audio policy and the original four retention values, defaulting to seven days. Past-session audio availability comes from fixture metadata; the current attempt freezes its audio choice on Start. New Meeting is exposed only after a result. The synthetic current meeting has unknown speakers because source labels are not diarization evidence. Technical controls and caveats belong to host chrome/docs, not the proposed product canvas.

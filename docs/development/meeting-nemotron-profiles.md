# Nemotron compiled model profiles

`MeetingNemotronModelProfile` is a fixed model-layer catalog. It extends the existing local artifact, checksum installer and download store because those previously described only the split W8A8 graph. It does not add another inference pipeline or installer.

| Profile | Runtime preset | Host projection | Compute preference | Selection |
| --- | --- | --- | --- | --- |
| `fast32SplitW8A8` | `fast32-split-w8a8` | Required | Existing device policy | Existing default |
| `experimentalFast32FP16CPU` | `fast32` | None | CPU only | Explicit experiment |
| `experimentalFast128FP16CPU` | `fast128` | None | CPU only | Explicit experiment |

The FP16 entries are candidates for measured streaming evaluation. Their CPU preference is frozen experimental configuration, not a claim about optimal placement on every device. Registration does not change settings, offline defaults or backend selection. The composite backend registration and model adapter own any explicit experimental selection.

Each profile binds its actual compiled filename, runtime preset, remote paths, SHA-256 for every model/host file, separate package/cache path and implementation fingerprint. The FP16 fingerprint also includes its CPU-only preference. The published model revision is `25a90f97f254428d4b30374b76af9c74fdee8327`; the source metadata is the [pinned author repository](https://huggingface.co/FluidInference/nemotron-3-diarization-coreml/tree/25a90f97f254428d4b30374b76af9c74fdee8327). Default W8A8 identity, paths, hashes and compute selection remain compatible with existing attempts.

An explicit profile uses the same operations:

```swift
let profile = MeetingNemotronModelProfile.experimentalFast128FP16CPU
let store = MeetingDiarizationModelStore(profile: profile)
let artifact = try await store.ensureInstalled()
let locator = MeetingNemotronModelLocator(profile: profile)
_ = try locator.recheck(artifact)
// The model adapter consumes artifact.profile.presetName, .projectionFileName
// and .computePreference while binding the exact artifact to its attempt.
```

For approved local imports, pass the profile to `MeetingModelInstaller.install(from:profile:)`. Its omitted destination resolves to that profile's own cache. A `.nemotronbundle` contains the profile's actual `.mlmodelc` directory and `learnable_sil_emb.bin`; only the split profile also contains `pre_encode_proj_t.bin`. Never rename an FP16 graph to the W8A8 compiled name. The production environment override remains scoped to the existing default; candidate imports use an explicitly injected locator URL.

The installer checks the complete expected file set and every checksum before copying, checks the staged copy again, and publishes by the existing atomic directory replacement. Locator recheck additionally binds the profile, path and measured file metadata. This recheck is a drift guard after pinned installation, not a substitute for checksum validation of untrusted imports. Author-compiled profiles bypass the legacy package compiler, and cleanup retains installed artifacts.

`bash scripts/dev/test-nemotron-compile-owner.sh` runs the actual locator, installer and compiled-model owner with synthetic tiny files. It checks default compatibility, unique identities/storage, complete download/checksum contracts, profile drift and wrong-graph refusal, compiled ownership and preservation of an existing package after invalid import. These checks perform no network access, Core ML loading or model inference. Actual app compilation, physical placement, joint throughput, privacy and speaker quality remain separate integration gates.

# Vendored ONNX Runtime Swift package

`https://github.com/microsoft/onnxruntime-swift-package-manager` answered 404 (repository not found) on 2026-11-18, so every clean package resolution of Pichi Voice failed. This folder keeps the exact revision our builds used: `b7fb7f7dea8a2469e6335d95a61b8f36d0dc83b2` ("Update ORT to 1.24.2"), the version pinned in the former `Package.resolved` files, exported with `git archive` from a verified local SwiftPM checkout.

Changes against that revision:
- The repository infrastructure of the upstream project (`.github`, `.pipelines`, `.config`) is left out.
- The Objective-C tests (`objectivec/test`) are left out, and `test` is dropped from the excluded paths of the `OnnxRuntimeBindings` target because the folder is no longer here.
- The Swift binding tests are kept unchanged, moved from `swift/OnnxRuntimeBindingsTests` to `Tests/OnnxRuntimeBindingsTests` so that `scripts/dev/verify` finds this package's suite. Their fixture `single_add.basic.ort` (1296 bytes, SHA-256 `c8808fde5bd08604d1911c27ed1077c8e5a6cb2d9aef0055bc884072cce3b62e`) is a synthetic model with one `Add` operator and no trained weights, made by the upstream `objectivec/test/testdata/single_add_gen.py`.
- The `onnxruntime_extensions` product, its `OnnxRuntimeExtensions` target, the `extensions` sources, their test target and the ONNX Runtime Extensions binary target are left out. No Pichi target uses them, and without them a clean build no longer downloads that archive.
- `release_instructions.md` and `objectivec/docs` (the upstream release procedure and API documentation configuration) are not tracked, because this repository ignores Markdown files and `docs` folders by default. They are not used by the build.

This record is itself added with `git add -f` for the same reason, and `scripts/dev/check.sh` fails if it is not tracked while this folder exists.

ONNX Runtime binary, hosted by Pichi (2026-11-21):
- Why: the `onnxruntime` binary target downloaded `https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.24.2.zip`. From 2026-11-20 that host answered with a certificate for `*.azureedge.net` (host name mismatch) and, even with the check skipped, 404 for the archive; `github.com/microsoft/onnxruntime` has answered 404 since 2026-11-17. Every clean CI build failed in package resolution, and the probes `meeting_privacy_context` and `transcript_privacy` failed with it.
- What: the archive is published as the asset of the pre-release `deps-onnxruntime-c-1.24.2` of this repository (not an app release; the app updater only accepts Pichi version tags with a DMG). It is the same file, 52,138,597 bytes with SHA-256 `f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54`, taken from a local SwiftPM cache of the former download and equal to the checksum that was already pinned, so the linked binary is unchanged. It contains the Microsoft MIT `LICENSE`.
- `Package.swift` downloads it from `https://github.com/Pichi-AI/pichi-voice/releases/download/deps-onnxruntime-c-1.24.2/pod-archive-onnxruntime-c-1.24.2.zip` with the unchanged checksum, which SwiftPM verifies on every download. The archive is not stored in Git.

Unchanged: the Objective-C binding sources.

License: MIT, see `LICENSE` (Copyright (c) Microsoft Corporation).

When Microsoft publishes the package again, or ONNX Runtime ships Swift Package Manager support from its main repository, switch `Vendor/PichiGigaAM/Package.swift` back to a pinned remote package and remove this folder. When nothing uses ONNX Runtime any more (the plan is to move the text privacy models to Core ML), or the former URL serves the archive again, point the binary target back or remove it, and delete the `deps-onnxruntime-c-1.24.2` release and its tag. Then point `tools/meeting-native-eval/build.py` and the include paths of `Tests/run_transcript_privacy_tests.sh` and `Tests/run_meeting_privacy_context_tests.sh` back at the package checkout.

# Vendored ONNX Runtime Swift package

`https://github.com/microsoft/onnxruntime-swift-package-manager` answered 404 (repository not found) on 2026-11-18, so every clean package resolution of Pichi Voice failed. This folder keeps the exact revision our builds used: `b7fb7f7dea8a2469e6335d95a61b8f36d0dc83b2` ("Update ORT to 1.24.2"), the version pinned in the former `Package.resolved` files, exported with `git archive` from a verified local SwiftPM checkout.

Changes against that revision:
- The repository infrastructure of the upstream project (`.github`, `.pipelines`, `.config`) is left out.
- The test targets (`swift/OnnxRuntimeBindingsTests`, `swift/OnnxRuntimeExtensionsTests`) and `objectivec/test` are left out, together with their test model files, the two `testTarget` entries are removed from `Package.swift`, and `test` is dropped from the excluded paths of the `OnnxRuntimeBindings` target because the folder is no longer here.
- `release_instructions.md` and `objectivec/docs` (the upstream release procedure and API documentation configuration) are not tracked, because this repository ignores Markdown files and `docs` folders by default. They are not used by the build.

This record is itself added with `git add -f` for the same reason, and `scripts/dev/check.sh` fails if it is not tracked while this folder exists.

Unchanged: the Objective-C bindings and extension sources, and the binary targets. ONNX Runtime itself is still downloaded from `download.onnxruntime.ai` and verified by the checksum in `Package.swift`, so the linked binary is the same as before.

License: MIT, see `LICENSE` (Copyright (c) Microsoft Corporation).

When Microsoft publishes the package again, or ONNX Runtime ships Swift Package Manager support from its main repository, switch `Vendor/PichiGigaAM/Package.swift` back to a pinned remote package and remove this folder. Then point `tools/meeting-native-eval/build.py` and the include paths of `Tests/run_transcript_privacy_tests.sh` and `Tests/run_meeting_privacy_context_tests.sh` back at the package checkout.

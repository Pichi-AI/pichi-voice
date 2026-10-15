# Upstream provenance

This package mirrors the official Swift bindings from
[`handy-computer/transcribe.cpp`](https://github.com/handy-computer/transcribe.cpp).

Current pin:

- Release: `v0.1.2`
- Source commit: `33d5c383e43e6acbd572845866ea75b8c7959fa5`
- Swift source path: `bindings/swift/Sources/TranscribeCpp`
- Swift test path: `bindings/swift/Tests/TranscribeCppTests`
- Asset: `TranscribeCpp.xcframework.zip`
- Asset SHA-256: `4092276cd295860ae9637a2913cf2d8747f39d454bb7fb3c79d6af9f858a4bb8`

`Sources/TranscribeCpp` and the inherited tests were imported from that tag. `Package.swift` is intentionally smaller than the upstream development
manifest: it replaces the local binary path with the published asset URL and
omits upstream examples.

## Updating

1. Check out the new upstream release tag.
2. Replace `Sources/TranscribeCpp`, `Tests/TranscribeCppTests`, `LICENSE`, and
   `THIRD-PARTY-LICENSES.md` from `bindings/swift` at that tag.
3. Update the release URL and `swift package compute-checksum` value in
   `Package.swift`.
4. Update the release, commit, and checksum above.
5. Run `swift package reset && scripts/test.sh` on macOS.
6. Confirm the XCFramework macOS binary contains both `arm64` and `x86_64`.
7. Tag this package with the matching semantic version only after all checks pass.

## Pichi vendored Swift wrapper

The imported wrapper is pinned to `altic-dev/transcribe-cpp-swift` version
`0.1.2`, commit `a16df2905f9c715344374fd2d8dd97c2712a6d96`. Its complete
13-file Swift source and MIT license are preserved here. The native binary URL,
checksum, `CTranscribe` target, and `TranscribeCpp` product are unchanged.

The downstream delta adds `WhisperChunkTrace`, `WhisperRunSnapshot` and the
synchronous/asynchronous `Session.runWhisper` operation. The pinned C runtime
already supplies per-window decoding metrics, but the upstream Swift wrapper
does not expose them. Copying the result and traces under the existing model
compute lock provides one atomic, owned snapshot without exposing session
pointers, parsing global native logs or changing the runtime binary. The normal
`run`, batch, streaming and cancellation contracts remain the upstream ones.

`WhisperRunSnapshotTests` covers scalar copying, allocation bounds, successful
run ownership, the existing model lock, and joined native cancellation. Model
tests are opt-in through existing `TRANSCRIBE_SMOKE_MODEL` and
`TRANSCRIBE_SMOKE_AUDIO` fixtures. No model weights or private recordings are
part of this package.

For an upstream update, compare the imported files and preserve this narrow
Swift API delta unless upstream provides an equivalent atomic snapshot.

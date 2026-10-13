# NativeTextInference

This local Swift package embeds the official llama.cpp `b11577` XCFramework. SwiftPM verifies its pinned SHA-256 during dependency resolution. The app needs no external model runner, server or additional application. Model weights remain a separate, application-managed download.

The public upstream app exposes private AI provider and installation contracts but supplies no public native text inference runtime. This package supplies only that missing inference boundary. The application's registered adapter owns the model manifest, prompt format, download verification, settings and resource admission. No product, model or language selection is hardcoded here.

```swift
let runtime = NativeTextInference()
try await runtime.load(modelURL: localGGUF, contextTokenLimit: 8192)
let output = try await runtime.generate(prompt: formattedPrompt, maxOutputTokens: 512)
await runtime.unload()
```

The actor serializes C ownership and explicitly guards operations across cancellation-handler awaits. `unload` joins active native work before releasing the context and model. Cancellation aborts CPU decoding through llama.cpp's callback; Metal decoding joins at the next native call boundary. Load cancellation uses the native progress callback. Model switching releases previous weights first. The shared process backend is initialized once, while each actor owns and releases its model, context and per-request sampler.

The runtime uses Metal on Apple Silicon and CPU on Intel, with at most eight CPU threads. Contexts are bounded to 256 through 32768 tokens; prompts and responses are also bounded to 8 MiB. It counts the fully formatted prompt with the actual vocabulary, rejects context overflow before decoding and never returns an output truncated at the token limit. Greedy sampling and vocabulary-defined EOS detection handle the model's own stop tokens. Streaming preserves complete UTF-8 scalars across token boundaries. Streaming fragments are provisional until generation returns successfully.

## Verification

```bash
swift test --package-path Vendor/NativeTextInference
swift build --package-path Vendor/NativeTextInference --triple x86_64-apple-macosx14.0
```

The opt-in real inference test requires `PICHI_NATIVE_TEXT_TEST_MODEL` with an approved local GGUF path and `PICHI_NATIVE_TEXT_TEST_PROMPT` with its fully formatted raw prompt. `PICHI_NATIVE_TEXT_TEST_EXPECTED` optionally supplies exact expected text. The fixture should produce more than one token, so the truncation assertion is meaningful. Weights and private prompts must stay in ignored local storage. No test downloads weights.

Binary source and API: [llama.cpp b11577](https://github.com/ggml-org/llama.cpp/tree/b11577). The bundled upstream MIT notice is preserved in `LICENSE.llama.cpp`. Model licensing belongs to each application's artifact manifest and notices.

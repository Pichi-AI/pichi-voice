# Local Russian text model profiles

The shared [text model catalog](../../Sources/Fluid/Models/local-text-models.json) lists discovery candidates for the existing Ollama provider. It does not download weights, configure a server, select a model automatically or certify summary and enhancement quality. Both task pickers use the same catalog and successful model discovery from their configured server. Other discovered identifiers remain available through the ordinary picker.

| Candidate | Official weight source | Preferred local serving identifier |
| --- | --- | --- |
| GigaChat 3.1 Lightning, Q4_K_M | [ai-sage/GigaChat3.1-10B-A1.8B-GGUF](https://huggingface.co/ai-sage/GigaChat3.1-10B-A1.8B-GGUF) | `pichi-local/gigachat3.1-lightning-q4km:ctx8k` |
| YandexGPT 5 Lite 8B Instruct, Q4_K_M | [yandex/YandexGPT-5-Lite-8B-instruct-GGUF](https://huggingface.co/yandex/YandexGPT-5-Lite-8B-instruct-GGUF) | `pichi-local/yandexgpt5-lite-q4km:ctx8k` |
| T-lite-it 2.1, Q4_K_M | [t-tech/T-lite-it-2.1-GGUF](https://huggingface.co/t-tech/T-lite-it-2.1-GGUF) | `pichi-local/t-lite-it-2.1-q4km:ctx8k` |

These identifiers name locally prepared profiles, not official publisher tags. Review each publisher's license and use a compatible Ollama version before importing a pinned GGUF. The verified setup used Ollama 0.34.2. Keep downloaded weights, import manifests and server templates in ignored local storage. Do not change an original publisher or installed model tag to add application-specific settings.

Use the official [Ollama Modelfile mechanism](https://docs.ollama.com/modelfile) to create a distinct serving alias from an already imported compatible model:

```text
FROM <verified-compatible-installed-model-id>
PARAMETER num_ctx 8192
PARAMETER num_predict 3000
```

Create the corresponding identifier with `ollama create <preferred-local-serving-identifier> -f <private-Modelfile>`. This inherits the source profile's template and reuses its weight blobs. Confirm the exact base and serving digests, template and context/output parameters before running requests. An identifier alone is not evidence that an installation is intact or that a model produces faithful output.

GigaChat's serving profile must preserve the publisher's system-message framing. The compatible local import was checked against its original text-only template. Capability metadata is not evidence that application tool calling or reasoning modes have been tested.

Yandex's original published template drops `SYSTEM` messages. The raw import is therefore deliberately excluded from the catalog's aliases. The compatible server profile preserves all system-message contents in order by folding them into the first user message with two literal newline separators. It preserves the publisher's user/assistant framing and the raw user JSON. This is a server-side text-only compatibility adaptation; no common application pipeline rewrites roles or branches on a model name. Derive the preferred alias from that validated compatible profile, not from the raw publisher import. Check template equivalence with and without system messages before installing an independently prepared adaptation. No tool calling or thinking support is claimed for this profile.

The catalog retains the already prepared dated imports as secondary aliases, including only Yandex's compatible dated profile. When both identifiers are discovered, the stable bounded profile is preferred. An existing explicit selection remains unchanged during refresh. A temporarily unavailable model is never silently replaced by a large local model.

After preparing profiles, refresh the selected server's model list in the application and choose a discovered identifier explicitly. Follow the [evaluation protocol](text-model-evals.md) before recommending a model or changing defaults. Record source and model digests alongside quality, runtime and memory measurements; results do not automatically transfer to a later artifact published under the same tag.

# Local text model library

Summary settings and AI provider settings use the same [ModelRepository](../../Sources/Fluid/Services/ModelRepository.swift) to discover the model IDs offered by the selected OpenAI-compatible server. This operation lists models; it does not download weights, run inference, enable a provider or choose a new local default.

Use **Refresh models** in meeting summary settings, or refresh the list in AI provider settings. Select an installed model using the existing picker. Local choices remain independent: meeting summaries keep their own selected model, while text cleanup keeps the configured AI provider and model. Refreshing preserves an explicit local choice even if the server temporarily omits it. An empty choice remains empty.

The optional **Local model library** menu supplies publisher names and links for known Ollama candidates. [local-text-models.json](../../Sources/Fluid/Models/local-text-models.json) is the versioned metadata resource; model-specific names and aliases belong there, not in the common processing pipeline. A menu entry can be selected only when the selected endpoint lists one of its exact aliases. Unrecognized installed IDs remain selectable in the normal picker. Ollama tags are not treated as LM Studio file names or as evidence that a different endpoint supports a model.

The initial library includes Qwen3.5 2B, 4B and 9B, T-lite-it 2.1, Gemma 4 E2B and 31B, gpt-oss 20B, and Qwen3 30B A3B. These are candidates, not a task-quality ranking. Installed state does not prove correctness, schema compatibility, memory suitability or successful execution. Evaluation reports must record the exact weights and request settings; a mutable model tag alone is insufficient to transfer a previous quality result to new weights.

Summary discovery retains its existing loopback URL validation and its ephemeral session that refuses redirects. Credentials are unnecessary for local discovery. Neither the library nor a refresh changes the summary destination, the user's provider configuration, per-model reasoning settings or inference resource limits.

## Checks

- `bash Tests/run_local_text_model_catalog_tests.sh` exercises production metadata parsing, exact alias availability, unknown model preservation, schema version and duplicate rejection, and local selection preservation.
- `bash Tests/run_command_model_catalog_tests.sh` checks the existing command model catalog after the repository extension.
- Native `LocalTextModelDiscoveryTests` verify injected-session discovery, the packaged resource, unknown installed IDs and selection behavior. Run them with the integrated macOS suite.
- `bash scripts/dev/check.sh` checks repository and localization resources. Native builds, real model quality and UI layout require separate parent-owned verification.

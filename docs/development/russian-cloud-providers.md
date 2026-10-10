# Russian cloud text providers

Verified against official API documentation on October 10, 2026. These connections are optional and do not change the existing local provider, summary mode or prompt assignments. Adding a connection does not send a transcript or perform generation.

| Provider | Connection | Credentials and parameters | Model selection |
| --- | --- | --- | --- |
| GigaChat | `https://api.giga.chat/v1` | Authorization key in Keychain; personal, prepaid business or corporate OAuth scope | Fetch the account's actual model IDs from `/models`, or enter an ID manually |
| Yandex AI Studio | `https://ai.api.cloud.yandex.net/v1` | Service-account API key in Keychain; folder ID in connection settings | Fetch full `gpt://<folder>/<model>` URIs, or enter a URI from the provider's documentation |

GigaChat's authorization key is exchanged at `https://ngw.devices.sberbank.ru:9443/api/v2/oauth`. The app sends Basic authorization, a fresh UUID request identifier and the selected scope. The resulting Bearer token is cached only in memory, refreshed before expiry, separated by credential and scope, and retried once after a 401 rejection. The documented lifetime is 30 minutes. Tokens and authorization responses are never persisted, exported or logged. Each exchange belongs to its caller's task and cancellation stops that request. The token body and token cache have explicit bounds.

Yandex requests use `Authorization: Api-Key` and `OpenAI-Project`. The selected model URI must contain the same folder ID; the transport refuses to silently rewrite the model or folder. The current official gallery lists Alice AI LLM, Alice AI LLM Flash, YandexGPT Pro 5.1 and YandexGPT Lite 5 among other offerings. Availability depends on the account and can change, so the app does not install a stale default list or pretend a gallery model is already available.

## Existing architecture

`ModelRepository` registers the two descriptors alongside the existing providers. The existing draft, saved-provider management UI and Keychain operations save the connection. Generic descriptor fields render in both the add form and saved editor. Nonsecret connection parameters participate in draft identity, discovery staleness checks, model verification, legacy configured-provider gates and summary cache identity. An additive optional backup field preserves folder/scope metadata without exporting credentials; older backups still decode.

All text calls continue through `LLMClient`. Enhancement, rewrite, configured-provider summaries and optional synthetic model verification carry an immutable connection snapshot. OAuth is a transport authorization policy, independent of model IDs and common meeting orchestration. No new provider hierarchy, per-model meeting factory, cloud fallback or translation branch is introduced. Existing local and other cloud providers retain their endpoints and credential behavior.

GigaChat is only partially OpenAI-compatible. Plain text enhancement and summary requests use the supported message shape. Its native function format differs from this app's existing tool contract, so tool requests are explicitly rejected before authentication instead of claiming command-mode support. Yandex uses the existing compatible tool transport.

GigaChat's structured response format puts `schema` and `strict` directly inside `response_format`; the OpenAI shape nests them under `json_schema`. The registered transport descriptor encodes this envelope before sending a chat-completions request, preserving the original schema and leaving the generator, source indices, prompt and validation unchanged. This protocol difference is documented in the official [structured output guide](https://developers.sber.ru/docs/ru/gigachat/guides/structured-output). Yandex and local compatible endpoints keep the existing named-schema envelope.

## TLS and verification limits

The registered services and OAuth use ephemeral sessions with redirects disabled and normal macOS TLS validation. The app never disables certificate validation or installs a global trust certificate. GigaChat documents the Ministry of Digital Development CA requirement. If that CA is absent from the system's approved trust configuration, the direct connection fails with a TLS error. An organization can instead expose its approved OpenAI-compatible gateway through the existing custom-provider form. Gateway deployment and certificate enrollment remain the organization's configuration work.

An unauthenticated HEAD probe on the current Mac used the same normal Foundation URLSession transport: both GigaChat API and OAuth returned TLS error `-1202`; Yandex reached HTTP `401`, as expected without a credential. No certificate installation or verification bypass was attempted. This is reachability and trust evidence, not a successful authenticated connection.

Verification includes deterministic synthetic cases for endpoint metadata, OAuth request headers/body, credential and scope isolation, expiry, cancellation, one bounded 401 refresh, Yandex project headers and URI consistency, discovery, failure-body redaction, verification identity changes and legacy local transport. No user credentials, recordings or transcripts were sent to either service during development. These tests prove transport behavior against fixtures; an authenticated account check and cloud-model quality evaluation are separate from listing a provider.

## Official sources

- [GigaChat authorization and current endpoint](https://developers.sber.ru/docs/ru/gigachat/api/reference/rest/gigachat-api)
- [GigaChat access-token lifetime](https://developers.sber.ru/docs/ru/gigachat/api/reference/rest/post-token)
- [GigaChat partial OpenAI compatibility](https://developers.sber.ru/docs/ru/gigachat/guides/compatible-openai)
- [GigaChat certificates](https://developers.sber.ru/docs/ru/gigachat/certificates)
- [Yandex AI Studio quickstart and project header](https://aistudio.yandex.ru/ru/docs/ai-studio/quickstart/)
- [Yandex API-key scopes](https://yandex.cloud/en/docs/iam/concepts/authorization/api-key)
- [Yandex model discovery](https://aistudio.yandex.ru/ru/docs/ai-studio/api/Models/listModels)
- [Yandex current model gallery](https://aistudio.yandex.ru/en/docs/ai-studio/concepts/generation/models)

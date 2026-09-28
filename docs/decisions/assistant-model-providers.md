# Voice Assistant model providers

**Decision:** Keep the Voice Assistant's model call native Swift, in the
dependency-free `Assist` package, and support more providers by speaking three
wire formats rather than adopting an SDK: OpenAI's Responses API (already
there for ChatGPT and OpenAI keys), Anthropic's Messages API, and OpenAI-style
Chat Completions, which Google Gemini, OpenRouter, the Vercel AI Gateway, xAI,
Groq, Mistral and DeepSeek all serve. Apple's on-device foundation model is a
third account type beside ChatGPT and API keys.

## Options considered

| Option | Verdict |
| --- | --- |
| **Vercel AI SDK** (`ai` + `@ai-sdk/*`) | The best-known multi-provider layer, but it is TypeScript. Scribe is a native macOS app; using it means shipping a Node runtime or a JS sidecar inside the app, adding a process hop to every request, and signing and notarizing that runtime, all for one streamed text call. Rejected. |
| **Vercel AI Gateway** (hosted, OpenAI-compatible) | Useful, but as one provider among several, not as the architecture: it needs a Vercel account and bills through Vercel. Offered as a provider choice. |
| **OpenRouter only** | One key reaches most models, but it forces everyone through a paid middleman and does not accept a person's existing Anthropic or Google key. Offered as a provider choice. |
| **A community Swift SDK** (LLMKit Swift, AIKit Swift, LLMProviderKit, SwiftAgents…) | Each wraps many providers, but they are young single-maintainer packages with changing APIs. Scribe needs one non-tool, single-turn, streamed text request. The package would be larger than the code it replaces, and a provider change would wait on its maintainer. Rejected for now. |
| **Official per-provider SDKs** | Anthropic, OpenAI and Google have no official Swift SDKs. |
| **Native adapters per wire format** (chosen) | About 300 lines on top of the existing `HTTPTransport` / SSE / Keychain / error-mapping code. No new dependency; tests use recorded SSE fixtures like the existing Responses tests. |

The standardised part the AI SDK would have given us is the provider catalog
and one assistant protocol. That is `AssistProvider` and `APIKeyAssistant`:
adding a provider with an OpenAI-compatible endpoint is one enum case (base
URL, default model, key placeholder, keys page).

## What shipped

- `AssistProvider`: OpenAI, Anthropic, Google Gemini (its
  `/v1beta/openai` endpoint), OpenRouter, Vercel AI Gateway, xAI, Groq,
  Mistral, DeepSeek, and a **custom OpenAI-compatible endpoint**. Each has
  its own Keychain item. OpenAI keeps `co.cooperativ.scribe.openai`, so
  existing keys still work.
- The custom endpoint is for Ollama, LM Studio or a company gateway. Its base
  URL is the `assistantCustomEndpointURL` setting (kept as typed, validated
  by `AssistProvider.customBaseURL`: HTTPS for remote hosts, HTTP only for
  localhost or a loopback IP address, trailing
  slash dropped, path kept since gateways mount the API where they like);
  `ChatCompletionsAssistant` takes it in place of the catalog URL. The key
  is optional: with none saved, no `Authorization` header is sent, since some
  local servers refuse a bearer token they cannot check. It has no default
  model; the connection test lists the server's models and picks the first,
  or the person types one. `stream_options` is not sent, as an unknown server
  may reject fields it does not know. The indicator names the server's host
  rather than "Custom endpoint". `Info.plist` gains
  `NSAllowsLocalNetworking` so plain `http://localhost` and loopback IPs pass
  App Transport Security. The URL parser and the client both reject HTTP to
  remote hosts, including `.local` names. The URLSession transport also rejects
  redirects to remote HTTP or an HTTPS-to-HTTP downgrade, so bearer keys and
  screen text are not sent to another machine over cleartext.
- `ChatCompletionsAssistant` and `AnthropicAssistant`, both streamed, with
  usage reported to the indicator. Anthropic's `max_tokens` is 16,000, or
  less when the model list reports a smaller limit for the model.
- Key test = model list. For OpenRouter, where the model list is public, the
  key is checked first with `GET /key`. For Gemini, which rejects a bad key
  with a 400, the error is still reported as an invalid key.
- Settings: the account picker has **ChatGPT account · API key · On this
  Mac**. Under API key, a Provider picker, then the key, the model list and
  a link to that provider's keys page.
  `assistantAPIModels` stores the model per provider, and the old single
  `apiKeyModel` setting carries over as OpenAI's model.
- `AppleIntelligenceAssistant`: `FoundationModels` `SystemLanguageModel`
  on macOS 26 and later, weak-linked so the app still launches on macOS 15.
  Its context window is small (a few thousand tokens), so the source text is
  trimmed to fit, cutting screen text first, then copied text, then the
  selection. From macOS 26.4 the trimming uses the system's own token count;
  before that it estimates. Settings shows why the model is unavailable
  (device not eligible, Apple Intelligence off, model downloading).

- `PrivateCloudAssistant`: macOS 27's `PrivateCloudComputeLanguageModel`,
  the Apple-hosted model behind Apple Intelligence, offered as a fourth
  account ("Private Cloud" in Settings, shown from macOS 27). No key or bill,
  a per-person quota, and a 32k-token context, so the prompt is sized with a
  3-characters-per-token estimate and, if the model reports the prompt too
  long, cut once in proportion to the overrun. Quota, network and service
  errors become plain messages, and Settings offers Apple's limit-increase
  sheet when the system has one. It is compiled only against the macOS 27 SDK
  (`canImport(FoundationModels, _version: 2)`).

## Private Cloud Compute needs Apple's entitlement

Apple grants the server model only to apps signed with
`com.apple.developer.private-cloud-compute`, requested through
<https://developer.apple.com/contact/request/private-cloud-compute/>. On this
Mac (macOS 27.0) `modelmanagerd` logged the model's policy as
`entitlementOverride: com.apple.developer.private-cloud-compute`,
`blockSideloadedApps: true`; an unsigned probe saw `availability == .available`
and a 32,768-token context, then every request failed with
`ModelManagerError 1046` ("Operation not permitted"). An ad-hoc signed binary
that claims the entitlement is killed at launch (exit 137), because a
restricted entitlement must be backed by a provisioning profile.

So the entitlement is **not** in `Scribe/App/Scribe.entitlements`: adding it
without a profile would stop the app launching. `PrivateCloudModel.status`
checks the running process's entitlements (`SecTaskCopyValueForEntitlement`)
and reports `notEntitled` before any request, so today's builds show the
account with "This copy of Scribe is not approved by Apple…" rather than an
opaque error. Once Apple approves the request: enable the capability for
`com.scribe.app` in the developer portal, add the key to
`Scribe.entitlements`, and sign Release with a Developer ID provisioning
profile that carries it (`PROVISIONING_PROFILE_SPECIFIER` is empty today).
Whether Apple grants it to Developer ID apps outside the App Store is not yet
confirmed.

## Known limits and follow-ups

- The on-device model works but is noticeably weaker on this task. In a smoke
  test it answered a reply-to-Sam request with "Hi Jake, …". It suits
  privacy-first rewrites and short replies, not long drafting.
- A custom endpoint over plain `http` to a fully qualified host off this Mac
  is refused by App Transport Security. `NSAllowsArbitraryLoads` would allow
  it at the cost of every future URL; if a company gateway needs it, add a
  per-domain exception instead.
- Default models (`claude-opus-5`, `gemini-3.8-flash`, `grok-4`, …) go stale
  as labs retire models. A successful key test switches to the first listed
  model when the default is gone and the person has not chosen one.

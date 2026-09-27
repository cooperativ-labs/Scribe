# Remote access through the Scribe relay

ChatGPT and Claude web connect to MCP servers from their own cloud, so they need
an HTTPS endpoint on the public internet. Scribe's transcripts stay on the
owner's Mac. Before the relay, each owner had to run a tunnel and give every
client that owner's own URL. That setup does not suit a marketplace install:
the plugin cannot carry a per-user URL, and most people cannot run a tunnel.

The relay gives every Scribe library the **same** stable endpoint,
`https://<relay>/mcp`. Each connection stays confined to one owner's library.

## Components

```
ChatGPT / Claude ──HTTPS──▶  Scribe relay (hosted)  ◀──HTTPS long-poll── Scribe on the owner's Mac
   OAuth + MCP                 OAuth server + MCP        outbound only       reads ~/Meeting Transcripts
                               owner directory
                               agent hub (in memory)
```

| Piece | Code | Role |
| --- | --- | --- |
| Relay | `src/relay.js`, `node cli.mjs relay` | OAuth authorization server and MCP resource server at one origin. It routes each token's tool calls to that token's owner. It stores no transcript content. |
| OAuth provider | `src/auth.js` | DCR, S256 PKCE, `/mcp` audience, `transcripts.read`, rotating refresh, RFC 9207 `iss`. Every grant carries an `ownerId`. |
| Owner directory | `OwnerDirectory` | Linked owners (random UUID plus a hashed agent secret), and one-time link codes (in memory). |
| Agent hub | `AgentHub` | Per-owner request queue, waiting long-polls, and pending calls with timeouts. |
| Mac agent | `Workers/ScribeMCP/Sources/ScribeMCPCore/RelayClient.swift` | Makes outbound HTTPS requests only and never listens on a port. It revalidates the relay's read-only `list`/`get` calls and answers through the same Swift transcript library as the local plugin. |
| Mac app | Settings → Assistants → Scribe Relay, `AssistantRelayAgent` | **Connect This Mac** runs the agent while Scribe runs and reconnects at launch. The in-process client stops when Scribe exits. Also **Get Link Code**, **Disconnect All Assistants** and **Unlink This Mac**. |
| ChatGPT package | `scripts/chatgpt-package.js` | One portable plugin and marketplace for every owner. It points at the relay's `/mcp` and has no app ID. |

The self-hosted bridge (`init` + `http`) and local stdio (Claude Code) remain
available. They use the same OAuth provider with one fixed owner.

## Flows

**Link (once per Mac).** **Connect This Mac** calls `POST /agent/register`. The
relay creates an owner and returns `owner_id` and a 256-bit `agent_secret`. It
stores only `sha256(agent_secret)`. The Mac writes both values to
`~/Library/Application Support/Scribe/MCP/relay.json` with mode 0600. Every
later agent call authenticates with `Authorization: Bearer <agent_secret>`.

**Serve.** The Swift client loops on `POST /agent/poll`, and the relay holds each poll
for up to 25 s. When a tool call arrives for that owner, the relay puts
`{id, method, args}` on that owner's queue, which releases the waiting poll. The
agent answers with `POST /agent/responses {id, result|error}`. The relay accepts
an answer only if that owner has a pending call with that `id`.

**Authorize a client.** ChatGPT or Claude registers dynamically, then opens
`/authorize` with PKCE, `resource=https://<relay>/mcp` and `transcripts.read`.
The consent page asks for a **link code**. The owner presses **Get Link Code**
in Scribe on the Mac (`POST /agent/link-codes`). The code has 10 characters of
Crockford base32 (50 bits), works once, and expires after 10 minutes. Each
owner can have at most 5 unused codes, and `/consent` is rate limited. Entering
the code and pressing **Allow** sends a code back to the client callback with
`state` and `iss`. That code is bound to the owner who issued the link code. A
code that names no owner shows the form again with an error, so a typo does not
send the person back to their assistant; the third wrong code ends that consent
request, and the per-address `/consent` rate limit still applies. The page
carries no script and shows the client's name, what it can and cannot read, and
the host it returns to.

**Install from a marketplace.** The ChatGPT package's `mcp.json` names only
`https://<relay>/mcp`. ChatGPT reads the protected-resource and
authorization-server metadata, sees `client_id_metadata_document_supported`, and
uses its published client ID `https://chatgpt.com/oauth/client.json` instead
of registering a client per user. The relay fetches only the exact CIMD URLs it
is configured with (default: that one), so a `client_id` can never steer a
request elsewhere. It checks that the document names itself and allows `none`
token authentication, and it keeps only callbacks that are also in the
operator allowlist. It caches the result for a day, and if the document cannot
be fetched it keeps the last validated copy. Advertised token methods are
`client_secret_post` and `none`, so ChatGPT picks `none` with PKCE. The ChatGPT
desktop app's plugin runtime signs in as a different, native client,
`https://chatgpt.com/oauth/codex/client.json`. Its callback is
`http://127.0.0.1/callback` on a port chosen at sign-in, so the relay allows
any port on an allowlisted loopback callback (RFC 8252 §7.3), but never a
different host, path or scheme. From then
on, the flow is the link-code consent above.

**Call a tool.** `/mcp` verifies the bearer token (hash lookup, expiry,
audience, scope, and that the owner still exists). It builds the MCP server over
`RemoteLibrary(hub, token.ownerId)`. The owner always comes from the verified
token. No tool argument, header or path can name an owner.

**Identify the library.** `scribe_profile` (tool metadata `openai/profile`)
returns `sha256(issuer | ownerId)` truncated to 32 hex characters. It is stable
across refresh and reconnection, distinct per owner, never reused (owner IDs
are random), and does not reveal the owner ID. It answers without reaching the
Mac.

**Revoke.** The owner can revoke in several ways:

- **Disconnect All Assistants** (`DELETE /agent/grants`) revokes every grant of
  that owner.
- `DELETE /agent/grants/:id` revokes one grant family.
- The client's own `/revoke` revokes its family.
- **Unlink This Mac** (`DELETE /agent/owner`) deletes the owner, all its grants
  and link codes, and rejects any calls in flight. The agent then receives 401
  and stops.

Tokens also fail once their owner is gone.

A client's own "disconnect" may not reach the relay. In live testing, removing
Scribe in the ChatGPT desktop app made no `/revoke` call, and the grant stayed
listed until the owner revoked it. The owner's **Disconnect All Assistants**
(or `revoke`) is the authoritative disconnect.

The consent page is served with `Referrer-Policy: same-origin`, so browsers send
a real `Origin` on the consent POST (under `no-referrer` they send `null`).
Its CSP `form-action` names the request's validated callback origin, because
browsers apply `form-action` to the redirect after the POST. Both are covered
by a headless-Chrome test (`test/browser.test.js`, skipped without Chrome).

## Privacy boundary

| Requirement | How it holds |
| --- | --- |
| Explicit consent | A grant requires a link code that only the owner can produce, from Scribe on their Mac, plus **Allow** on a consent page. The page names the client and its callback. Deny sends `access_denied`. |
| Per-owner isolation | Every access and refresh token and every authorization code carries one `ownerId`, fixed at consent time. The hub keys queues and pending calls by owner. An agent can only poll and answer for the owner its secret authenticates. |
| Scoped access | `transcripts.read` only, audience-bound to `https://<relay>/mcp`. The agent executes only `list` and `get`, and checks them against strict schemas (`libraryCalls` in `src/server.js`). A compromised relay therefore cannot request deletes, audio, arbitrary paths or larger pages. |
| Revocation | Per grant, all grants, client-initiated, or unlink. Each takes effect on the next request, because tokens are checked against server state rather than being self-contained. |
| No cross-library reads | Transcript IDs are not capabilities. A token for owner A reaches only A's Mac, so B's transcript IDs are "not found". Tests cover this with two live Macs (`test/relay.test.js`). Two mutation checks confirmed that breaking owner routing, or letting one Mac answer another's calls, fails those tests. |
| Data at rest | The relay persists only owner IDs, hashes of agent secrets and tokens, and OAuth client registrations, in mode-0600 JSON files. Transcript text exists in relay memory only while one response is in flight. It is never logged or stored. |

**What the relay can see.** TLS ends at the relay, which is also the MCP server
that ChatGPT talks to. The relay therefore handles transcript text in plaintext
while relaying a response, the same way any hosted MCP server does. End-to-end
encryption to ChatGPT is not possible, because ChatGPT needs the text. The
operator's controls are: no request or response logging, no persistence, a
single-purpose service, and the Mac's refusal of anything beyond read-only
calls. The public privacy policy (`/privacy`, rendered by `src/legal.js`) states this.

## Why this design

- **Outbound long-poll, not a per-user tunnel.** It works behind NAT and on
  captive or corporate networks, and it needs no port on the Mac and no new
  dependency (plain `fetch`). The cost is up to one poll's latency for a call
  that arrives during a reconnect, which is negligible next to a library scan.
  A WebSocket would save a round trip per call but add a dependency and proxy
  requirements.
- **Link codes, not accounts.** The relay needs to know which owner is
  consenting, not who that person is. A short-lived code minted by the owner's
  own Mac proves both possession and intent. The relay never needs an email,
  password or identity provider. For publisher review, account-based linking
  can be layered on later without changing token binding.
- **RFC 9207 `iss`.** Because the relay names its issuer in authorization
  responses, ChatGPT uses its stable callback
  `https://chatgpt.com/connector_platform_oauth_redirect` for every user. The
  relay can therefore keep an exact redirect allowlist (that URI plus Claude's
  `https://claude.ai/api/mcp/auth_callback`) with no per-connection callbacks
  and no wildcards.
- **Same tools and schemas.** `createScribeServer` runs unchanged on the relay
  over `RemoteLibrary`. Tool behavior, output schemas, paging and revision
  checks therefore match local stdio and the self-hosted bridge.

## Operating the relay

```sh
SCRIBE_PUBLIC_URL=https://relay.example.com \
SCRIBE_RELAY_STATE_DIR=/data/scribe-relay \
SCRIBE_BIND_HOST=0.0.0.0 \
SCRIBE_TRUST_PROXY=1 \
node dist/cli.mjs relay
```

| Variable | Default / purpose |
| --- | --- |
| `SCRIBE_PUBLIC_URL` | Required canonical HTTPS origin. `Host` must match it, and forwarded host headers are ignored. |
| `SCRIBE_RELAY_STATE_DIR` | Required persistent private directory for `oauth-state.json` and `owners.json`. |
| `SCRIBE_OAUTH_REDIRECT_URIS` | JSON array. Defaults to ChatGPT's stable callback and Claude's callback. |
| `SCRIBE_MCP_PORT` / `PORT` | `8767` |
| `SCRIBE_BIND_HOST` | `127.0.0.1`. Use `0.0.0.0` behind a platform proxy. |
| `SCRIBE_TRUST_PROXY` | The number of proxy hops whose `X-Forwarded-For` to trust for rate limiting. Unset means trust none. |
| `GITHUB_TOKEN` | Optional. Raises GitHub's rate limit for the release lookup behind the public page's download button. |
| `SCRIBE_REVIEWER_CODE` | Optional, at least 20 characters. Typed in place of a link code, it opens the synthetic demo library (`src/demo.js`) for directory reviewers. It is reusable and reaches nothing else. Unset, the demo library does not exist. |
| `OPENAI_APPS_CHALLENGE` | Optional. The token OpenAI's portal issues for domain verification, served as plain text at `/.well-known/openai-apps-challenge`. |
| `SCRIBE_PUBLISHER`, `SCRIBE_CONTACT_EMAIL` | The publisher named on `/privacy`, `/terms` and `/support` (default Cooperativ Labs), and their contact address (default: GitHub issues). |

The relay's root is also Scribe's public page (`src/site.js`): what Scribe is,
and a **Download for macOS** button. `/download` asks GitHub for the latest
release of `cooperativ-labs/Scribe` and redirects to its `Scribe-<version>-macos.zip`,
so publishing a release updates the button on its own. The answer is cached for
ten minutes and kept through GitHub outages; with no answer at all the button
falls back to the releases page. `/api/release` returns the same facts as JSON.
The page is server-rendered with no script and serves only `assets/logo.png`
and `assets/icon.png` under `/site/`.

**Icon.** Every Scribe HTTP server (relay or self-hosted bridge) serves
`assets/icon.png` at `/icon.png` and `/favicon.ico`, and names it in MCP
`serverInfo.icons` with `title: "Scribe"`, so clients that show a server or
domain icon show Scribe's. The stdio server inlines the same PNG as a `data:`
URI; the Claude package ships `assets/icon.png` for it (the ChatGPT package
already ships it as its composer icon).

Run **one relay process per state directory**. The hub, pending consents,
authorization codes and link codes live in that process's memory. A restart
drops calls in flight, but agents reconnect within seconds, and grants and
links survive. To scale horizontally, move the state to a shared database and
the hub to shared pub/sub keyed by owner, keeping the same interfaces. Keep
request and response logging off at the platform proxy, and protect the state
directory as credentials.

`GET /health` reports liveness only. Limits: 10 owner registrations per IP per
hour, 50 grants per owner, 20 calls queued per owner, a 30 s call timeout, and
2 MB per agent response.

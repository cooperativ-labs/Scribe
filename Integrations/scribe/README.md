# Scribe for ChatGPT and Claude

Ask “Pull my most recent Scribe transcript and turn it into decisions and action
items.” The shared MCP service reads Scribe's saved canonical transcripts,
including reviewed titles and speaker labels. It provides recent meetings,
literal text search, revision-aware paged retrieval, research `search`/`fetch`,
a meeting-notes prompt, and a transcript viewer for MCP Apps hosts.

Transcripts never leave the owner's Mac except as answers to that owner's
approved assistants. Claude Code starts the service directly over stdio.
ChatGPT and Claude web connect over Streamable HTTP and OAuth, normally through
the **Scribe relay**: one stable HTTPS endpoint shared by every Scribe owner.
Each Mac connects out to the relay, so no tunnel or per-user URL is needed. The
relay routes each token only to the library of the owner who approved it. See
[docs/remote-access.md](docs/remote-access.md) for the architecture and privacy
boundary. The service does not call a model API or require OpenAI or Anthropic
API keys. The assistant performs the requested analysis on retrieved text.

## From the Scribe app

Settings → **Assistants** does the setup below from buttons, in two sections.

**On this Mac** installs the local plugin, which runs the read-only server
inside Scribe.app through `scribe-mcp-launcher` and needs no Node. Each button
reads **Install**, **Update** (the app carries a newer or different plugin
than the one installed), or **Installed**, with **Remove** beside it, and says
whether the harness was detected on this Mac:

- **Install ChatGPT Plugin** (ChatGPT desktop and Codex) copies the plugin to
  `~/.codex/plugins/scribe`, upserts a `scribe` entry (local source
  `./.codex/plugins/scribe`, installation `AVAILABLE`, authentication
  `ON_INSTALL`, category Productivity) into `~/.agents/plugins/marketplace.json`
  while keeping every other entry, then runs `codex plugin add
  scribe@<marketplace>` in a login shell when `codex` is on the PATH. Codex
  names personal plugins after that file's own `name`, so an existing
  marketplace keeps its name (for example `overlord-local`); Scribe creates it
  as `scribe-local` only when it is missing.
- **Install Claude Plugin** (Claude Code and Claude Desktop) keeps the plugin
  marketplace in `~/Library/Application Support/Scribe/Integrations/claude`,
  runs `claude plugin marketplace add` and `claude plugin install
  scribe@scribe-local` in a login shell, and, when Claude Desktop is installed,
  adds a `scribe` server running that marketplace's `scribe-mcp-launcher` to
  `mcpServers` in `~/Library/Application Support/Claude/claude_desktop_config.json`,
  keeping every other key.
- **Install Cursor Plugin** copies the plugin to `~/.cursor/plugins/local/scribe`.

Each install records the package version and the SHA-256 of every file it
wrote in `~/Library/Application Support/Scribe/Integrations/state/<harness>.json`
(`codex`, `claude`, `cursor`). A second install changes nothing; an update
deletes files the package no longer ships; a file you edited after Scribe
wrote it is kept, with a warning, on update and on removal. **Remove** also
takes out the marketplace entry, Claude Desktop's `scribe` server and the CLI
registration. Restart the assistant after any of these. Updating Scribe itself
needs no plugin update, because the launcher finds Scribe.app at every start.

**From anywhere** is for ChatGPT and Claude on the web, which connect from
their own cloud:

- **Scribe Relay** opens with the connection status and one button. **Connect
  This Mac** runs the native relay connection in Scribe itself: it links this Mac on first use, keeps an outbound
  connection open while Scribe runs, and reconnects at launch until you press
  **Disconnect**. The connection exits with Scribe. Once connected, **Get Link
  Code** shows a one-time code, large enough to read across a room, with the
  time it expires; type it on the consent page. **Disconnect All Assistants**
  revokes every grant, and **Unlink This Mac…** makes the relay forget this
  library. **Relay Settings** holds the relay address (Scribe's own
  `https://scribe.ovld.ai` unless the build was packaged for another), the
  connector URL (`https://<relay>/mcp`, the same for every owner).
- **Add to ChatGPT web…** and **Add to Claude.ai…** copy the connector URL and
  open `chatgpt.com/plugins` or `claude.ai/customize/connectors` for pasting.

The app no longer offers the self-hosted tunnel; run `init` and `http` from the
CLI for that (see [ChatGPT and Claude web through your own tunnel](#chatgpt-and-claude-web-through-your-own-tunnel) below).

`Scripts/build-app.sh` and `Scripts/package-app.sh` embed the package through
`Scripts/embed-assistant-connector.sh` without npm. It runs after
`Scripts/embed-mcp-helper.sh` and embeds the local plugin with the app's own
`Contents/Helpers/scribe-mcp-launcher`. The app contains no Node relay CLI.
The embedded package
names the hosted relay, `https://scribe.ovld.ai/mcp`, so the tab's relay address
defaults to it; set `SCRIBE_CONNECTOR_URL` to another relay's `/mcp` URL, or to
an empty string for no default.

## Build and test

Node.js 22 or newer is required. From this directory:

```sh
npm ci
npm test
npm run build
npm run package -- --launcher ../../Workers/ScribeMCP/.build/debug/scribe-mcp-launcher
```

Tests use synthetic transcripts and the official MCP client across both
transports. A marketplace-install test follows ChatGPT's path from the
packaged `mcp.json` URL through discovery, CIMD client identity, link-code
consent, token exchange, profile and retrieval, refresh, and disconnect for
two owners. They cover OAuth consent, PKCE, resource binding, RFC 9207 `iss`,
token refresh and revocation, filesystem boundaries, edits, search and
pagination. Relay tests run two linked Macs against one relay. They check that
each token reads only its own owner's library, that link codes work once, that
one Mac cannot answer another's calls, that unknown or widened calls are
refused, and that the relay handles an offline Mac, grant revocation and
unlink. No private
meeting text is needed. `npm run build` bundles dependencies into `dist/cli.mjs`.
`npm run package -- --launcher <path>` writes:

- `dist/packages/claude/plugins/scribe`, the [local plugin](#local-plugin-claude-code-codex-and-chatgpt-desktop-cursor)
  that every desktop harness installs, inside a Claude Code marketplace
  (`dist/packages/claude`);
- `dist/packages/relay`, the Node relay service CLI with its
  `connector.json` and dependency notices, for server deployment only;
- with `--url`, the ChatGPT marketplace and submission archive described below.

Pass `--launcher <path to scribe-mcp-launcher>` to build the local plugin.
The app build embeds its native plugin from `local-plugin-template/` without
using npm. Do not run
`npm install` inside a plugin cache.

## Local MCP server in Scribe.app

Scribe.app ships the local server as a native helper, so a local plugin needs
neither Node nor a copy of the server:

- `Contents/Helpers/scribe-mcp` serves the same stdio MCP surface as
  `node dist/cli.mjs stdio`: the same tools, input and output schemas, paging,
  prompt, viewer resource and icon. It reads the library through Scribe's own
  `TranscriptStore` (`Modules/Transcription`), within the same filesystem
  boundary as `src/store.js`, honors `SCRIBE_TRANSCRIPTS_DIR` with the same
  `~/Meeting Transcripts` default, and is read-only.
- `Contents/Helpers/scribe-mcp-launcher` is what plugin manifests run. At every
  start it finds Scribe.app through LaunchServices by bundle identifier
  (`com.scribe.app`), never a stored path, so moving or updating the app cannot
  break a plugin, then execs the helper with stdin, stdout, stderr, arguments
  and environment untouched. Without Scribe installed it exits with status 69
  and one line on stderr. `SCRIBE_MCP_HELPER` names a helper to run instead,
  for development builds and tests.

Both are built from `Workers/ScribeMCP` (the official Swift MCP SDK plus
Scribe's transcript store) by `Scripts/embed-mcp-helper.sh`, which
`Scripts/build-app.sh` and `Scripts/package-app.sh` run; they are signed and
notarized with the app. To work on them:

```sh
cd Workers/ScribeMCP
swift build && swift test
SCRIBE_MCP_HELPER=.build/debug/scribe-mcp SCRIBE_TRANSCRIPTS_DIR=… .build/debug/scribe-mcp-launcher
```

`test/conformance.test.js` drives both servers with the official MCP client
over stdio against one synthetic library, the Swift one through the launcher
on a `PATH` without Node, and requires identical tool lists, schemas, prompts,
resources and results. It runs whenever `Workers/ScribeMCP/.build/debug` holds
both executables (or `SCRIBE_MCP_BIN_DIR` names a directory that does), and is
skipped otherwise, so build the Swift package before relying on `npm test`.

**The Node `stdio` command is now for development only.** It remains the quick
way to try a change to the tools before porting it, and the conformance test
keeps it honest, but installed plugins run the launcher. Change both
servers together, including `Workers/ScribeMCP/Sources/ScribeMCPCore/Resources/tools.json`,
which holds the tool definitions exactly as the Node server lists them.

## Local plugin (Claude Code, Codex and ChatGPT desktop, Cursor)

One plugin directory installs in every desktop harness. It holds no server
code: each harness runs `scribe-mcp-launcher`, which finds Scribe.app at start
and execs its helper, so the plugin needs no Node and survives app moves and
updates. With the launcher it contains only:

```text
plugins/scribe/
├── .claude-plugin/plugin.json   Claude Code manifest
├── .mcp.json                    Claude Code server: ${CLAUDE_PLUGIN_ROOT}/scribe-mcp-launcher
├── .codex-plugin/plugin.json    Codex / ChatGPT desktop manifest (interface: Scribe, Read)
├── mcp.json                     Codex server: ./scribe-mcp-launcher with cwd ./
├── .cursor-plugin/plugin.json   Cursor manifest
├── .cursor-plugin/mcp.json      Cursor server: ${CURSOR_PLUGIN_ROOT}/scribe-mcp-launcher
├── skills/scribe-transcripts/SKILL.md
├── ui/transcripts.html
├── assets/icon.png              server icon, composer icon and logo
└── scribe-mcp-launcher
```

That is about 100 KB. The three server configs differ because the harnesses
start a plugin's server differently, as checked against Codex CLI 0.157 and
cursor-agent 2026.09.23:

- Claude Code starts it in the user's project and expands
  `${CLAUDE_PLUGIN_ROOT}`.
- Codex (and the ChatGPT desktop app, which embeds it) reads
  `.codex-plugin/plugin.json` in its own shape: the listing is a top-level
  `interface` (it ignores `extensions.com.openai` there) and the server config
  must be named by `mcpServers`. It expands neither variable in a named config
  and starts the server in the project unless `cwd` is set, so `mcp.json` runs
  `./scribe-mcp-launcher` with `cwd: "./"`, which it resolves under the plugin.
  `mcp.json` is also a valid Agent Plugins 1.0.0 MCP document.
- Cursor starts it in the project, ignores a relative `cwd`, and expands
  `${CURSOR_PLUGIN_ROOT}`.

`test/package.test.js` checks that the tree holds the three manifests and only
the files above, no JavaScript, under 200 KB; that every config reaches the
launcher inside the tree under those rules; and that the Codex manifest, read
back in Agent Plugins form, validates against the Agent Plugins 1.0.0 schema
(`test/schemas/`) and OpenAI's listing limits.

A launcher is required. The app build copies checked-in plugin manifests from
`local-plugin-template/` and checks them against package output in the Node suite.

Scribe's Settings → Assistants → **On this Mac** installs, updates and removes
it for each harness (see [From the Scribe app](#from-the-scribe-app)). To
install a packaged plugin by hand:

```sh
npm run package -- --launcher /Applications/Scribe.app/Contents/Helpers/scribe-mcp-launcher
# Claude Code
claude plugin marketplace add "$PWD/dist/packages/claude"
claude plugin install scribe@scribe-local
# Codex: add a marketplace whose .agents/plugins/marketplace.json lists
# ./plugins/scribe (see "ChatGPT plugin package" for the shape), then
codex plugin add scribe@<marketplace>
# Cursor
cp -R dist/packages/claude/plugins/scribe ~/.cursor/plugins/local/scribe
```

Restart the harness and check that `scribe` is connected (`/mcp` in Claude
Code, `codex mcp list`, Cursor's MCP settings). Ask for your most recent
transcript or use the `scribe-transcripts` skill. For a temporary Claude Code
session from a checkout, `claude --plugin-dir /absolute/path/to/Scribe/Integrations/scribe`
is a development-only Node server path.

Overlord's marketplace keeps a copy of this plugin at
`Overlord/marketplace/plugins/scribe`. Regenerate it from this package
(`npm run package -- --launcher …`, then copy `dist/packages/claude/plugins/scribe`)
rather than editing it by hand.

The default library is `~/Meeting Transcripts`, matching Scribe. Set
`SCRIBE_TRANSCRIPTS_DIR` in the launching environment to use another Scribe
store. For a remote Claude Code instance, use the HTTP endpoint instead:

```sh
claude mcp add --transport http scribe https://YOUR-DOMAIN/mcp
```

Use `/mcp` to authenticate. Add the exact callback shown by that client to the
server's redirect allowlist before authorizing it.

## ChatGPT and Claude web through the Scribe relay

The relay is a hosted service (`node dist/cli.mjs relay`, see
[docs/remote-access.md](docs/remote-access.md#operating-the-relay)). Every
owner uses its one connector URL, `https://RELAY/mcp`.

On the Mac that holds the transcripts, press **Connect This Mac** in Settings
→ Assistants. The first connection links the Mac and stores an owner ID and
agent secret in `~/Library/Application Support/Scribe/MCP/relay.json` with mode
0600. Scribe reconnects at launch, makes outbound HTTPS requests only, and
stops polling when it exits. Nothing listens on the Mac. The Mac must stay
awake; while it is asleep or offline, tools return "Your Scribe Mac is not
connected."

In **ChatGPT**, turn on developer mode under Settings → Security and login.
Then add `https://RELAY/mcp` from the Plugins page with OAuth. In **Claude
web or Desktop**, add the same URL as a custom connector. When the consent
page asks for a link code, get one from **Get Link Code** in Scribe. Each code works once and expires after ten minutes.
**Never paste a link code into a chat.** The grant binds the client to this
Mac's library only.

Manage connections in Settings → Assistants. **Disconnect All Assistants**
revokes every grant, and **Unlink This Mac** removes this Mac and all its
grants from the relay. The Swift client also supports listing and revoking
individual grants for callers using it directly.

## ChatGPT and Claude web through your own tunnel

To avoid a shared relay, run the bridge yourself. The Mac must stay awake and
the bridge must keep running. Remote clients cannot read a localhost URL.
Provide an HTTPS reverse proxy or tunnel to `127.0.0.1:8766`, and preserve the
public `Host` header. For a development tunnel, for example, `ngrok http 8766`
produces an HTTPS origin.

Create the private owner key once:

```sh
node dist/cli.mjs init
```

This creates `~/Library/Application Support/Scribe/MCP/owner-key` with mode
0600, and never overwrites an existing key. Read that file locally when the
consent page asks for the key. **Do not paste it in a chat or into plugin
manifests.**

Set the public origin and the exact allowed OAuth callback URLs. Because the
server returns RFC 9207 `iss`, ChatGPT uses its stable callback
`https://chatgpt.com/connector_platform_oauth_redirect`. If ChatGPT shows you a
connection-specific callback, add that exact URL too. Do not use wildcard hosts
or guessed URLs. The server uses dynamic registration, not CIMD.

```sh
export SCRIBE_PUBLIC_URL='https://YOUR-DOMAIN'
export SCRIBE_OAUTH_REDIRECT_URIS='["https://chatgpt.com/connector_platform_oauth_redirect","https://claude.ai/api/mcp/auth_callback"]'
node dist/cli.mjs http
```

HTTP startup refuses missing or unsafe configuration. The bridge binds only to
loopback, rejects unexpected Host and Origin headers, and authenticates every
MCP request. The local stdio transport uses the OS user's existing file
permissions. Add the endpoint to ChatGPT and Claude as above, and approve with
the owner key instead of a link code. Account or organization policy may
control access to custom connectors. The build and packaging commands do not
submit anything to a public app directory.

## ChatGPT plugin package

```sh
npm run package -- --launcher <path-to-scribe-mcp-launcher> --url https://RELAY/mcp \
  [--website-url URL] [--privacy-url URL] [--terms-url URL] [--support-url URL]
```

Listing links default to the relay's own public pages (`/`, `/privacy`, `/terms`,
`/support`). The command also writes `dist/packages/submission/scribe-<version>.zip`,
the archive the Plugins Directory portal takes. Packaging fails if the plugin
breaks any of the directory's listing limits.

This writes a plugin marketplace at `dist/packages/chatgpt`:

```
dist/packages/chatgpt/
├── .agents/plugins/marketplace.json   # one entry, authentication ON_INSTALL
└── plugins/scribe/
    ├── plugin.json                    # Agent Plugins 1.0.0 + OpenAI interface metadata
    ├── mcp.json                       # streamable-http → https://RELAY/mcp
    ├── skills/scribe-transcripts/
    └── assets/icon.png, logo.png
```

One package serves every owner. It names only the relay's shared endpoint,
so nobody hand-builds a manifest, and it carries no `.app.json` or
account-specific `plugin_asdk_app…` ID. The library a connection reads is
decided on the consent page by the owner's link code. On install, ChatGPT
authorizes as its published client
(`https://chatgpt.com/oauth/client.json`, a Client ID Metadata Document), so no
per-user registration is needed either. The relay fetches only that exact URL,
caches it, keeps only allowlisted callbacks, and accepts only public-client
(PKCE) token exchange. Dynamic registration still works for Claude and older
clients. `scribe_profile` (marked `openai/profile`) returns an opaque ID per
library, so ChatGPT can tell two connected Macs apart and recognize one after
reconnecting.

Packaging validates the result: schema fields, `./` asset paths inside the
plugin, a remote HTTPS `/mcp` server with no embedded headers, skill front
matter, and no app ID. The same `--url` writes `connector.json` into the Claude
package, so the bundled CLI and Scribe's Settings default to the same relay.
Omit `--url` and neither is produced. The link and listing URLs are optional;
unset ones are left out.

To install it for testing, add the marketplace and install from it:

```sh
codex plugin marketplace add ./dist/packages/chatgpt
codex plugin add scribe@scribe
```

The ChatGPT desktop app then lists **Scribe** under that marketplace in the
Plugins Directory. It signs in as its native client
(`https://chatgpt.com/oauth/codex/client.json`) with a loopback callback, which
the relay also accepts. Removing Scribe in ChatGPT may not revoke the grant on
the relay; use **Disconnect All Assistants** in Scribe to be sure. ChatGPT on the web adds the same endpoint in Developer mode
(Plugins → + → `https://RELAY/mcp`, OAuth). Either way, the consent page asks
for a link code from **Get Link Code**. Publishing to the public directory is
a separate review step. Refresh the client connection after tool changes.

## Tools and data behavior

| Tool | Behavior |
| --- | --- |
| `scribe_recent_transcripts` | Latest saved transcript per meeting; newest processing run first; optional creation-date filters and paging |
| `scribe_search_transcripts` | Literal case-insensitive search over title, speaker names and segment text, with short excerpts |
| `scribe_get_transcript` | Timestamped text, metadata, warnings, revision and explicit continuation offset |
| `search` / `fetch` | Research retrieval aliases; large fetches continue with `scribe_get_transcript` |

Results use stable run UUIDs and `scribe://transcripts/<id>` source identifiers.
These identify sources for citations; they are not public URLs or app-opening
deep links. Source-relative timestamps are formatted as hours, minutes and
seconds. Speaker labels follow the canonical speaker table, matching exports;
presentation-only inferred identities are not promoted to confirmed speakers.

Text pages contain at most 24,000 UTF-16 code units. Follow `next_offset` until
null and pass `revision` on subsequent reads. Recent/search lists are live; a new
run between list pages can shift offset positions. An unfinished reprocess does
not hide its predecessor. Missing/corrupt/unsupported runs are counted in
`skipped_runs`; an unavailable root is an error. Limits are 32 MiB per canonical
file and 10,000 runs. The bridge scans saved files on each request, favoring fresh
edits over an index; very large libraries may respond slowly.

Only transcript text and selected metadata leave the service when requested.
The server exposes no audio, absolute paths, capture controls, deletes, or edits.
All tools carry read-only annotations and output schemas. Transcript text is
untrusted source material; the skill directs the model to ignore instructions
embedded in it. The viewer uses text nodes and no external assets or network
requests. Summaries and drafts stay in the requesting chat unless the user
requests another destination through another tool.

## Authentication and operation

OAuth supports discovery, dynamic client registration restricted to exact
callback URLs, authorization code + S256 PKCE, explicit password-protected owner
consent, `transcripts.read` scope, `/mcp` audience binding, one-hour access
tokens, rotating 30-day refresh tokens, and family revocation at `/revoke`.
Codes and consent requests expire after five minutes. Tokens survive a restart;
pending consent and codes do not. Every grant is bound at consent time to exactly
one owner's library: the self-hosted bridge's single owner, or the relay owner
whose link code was entered. Run one process per state directory.

State is stored in mode-0600 `oauth-state.json` beside the owner key. Access and
refresh tokens are hashed; registered confidential-client credentials, when
used, are private state. Back up and protect that directory as credentials. On
the relay, the owner revokes from the Mac (`revoke`, `unlink`, or the Settings
buttons), and this takes effect on the next request. For the self-hosted bridge,
to disconnect every client, stop the bridge, remove `oauth-state.json`, then
restart and reconnect clients. Rotate the owner key separately if it was exposed.
Client-side disconnect may not call revocation; deleting server state is the
definitive all-client revocation procedure. Do not log proxy request bodies,
Authorization headers, or transcript responses.

Configuration:

| Variable | Default / purpose |
| --- | --- |
| `SCRIBE_TRANSCRIPTS_DIR` | `~/Meeting Transcripts` |
| `SCRIBE_MCP_STATE_DIR` | `~/Library/Application Support/Scribe/MCP` |
| `SCRIBE_MCP_PORT` | `8766` (loopback only) |
| `SCRIBE_PUBLIC_URL` | Required canonical HTTPS origin for `http` and `relay` |
| `SCRIBE_OAUTH_REDIRECT_URIS` | JSON array of exact approved OAuth callback URLs (required for `http`; `relay` defaults to ChatGPT's and Claude's stable callbacks) |
| `SCRIBE_RELAY_URL` | Relay origin for `connect` and `link` when it is not given as an argument |
| `SCRIBE_RELAY_STATE_DIR`, `SCRIBE_BIND_HOST`, `SCRIBE_TRUST_PROXY` | Relay operation; see docs/remote-access.md |
| `SCRIBE_REVIEWER_CODE`, `OPENAI_APPS_CHALLENGE`, `SCRIBE_PUBLISHER`, `SCRIBE_CONTACT_EMAIL` | Plugins Directory review; see docs/directory-submission.md |

`GET /health` reports process liveness without revealing library information.
Unauthenticated `/mcp` must return 401 with protected-resource discovery. Proxy
forwarded headers are not trusted by default. Per-IP rate limits are therefore
shared behind a tunnel, which suits a single-owner bridge. A relay sets
`SCRIBE_TRUST_PROXY` to its proxy hop count.

## Acceptance checks and publication

After installing in each real client:

1. Ask for recent meetings and verify the title/date against Scribe.
2. Ask for decisions from one meeting and verify several timestamped passages.
3. Read a long meeting to the final page; edit its title/speaker in Scribe and
   confirm fresh retrieval sees the revision.
4. Confirm the viewer displays a list, a transcript page, empty results and
   errors. Confirm the model can work without widget support in Claude Code.
5. Deny OAuth once, reconnect successfully, then disconnect/revoke and confirm
   the old token cannot read transcripts.
6. Through the relay: link two Macs (or two state directories). Confirm each
   assistant sees only the library whose link code approved it. Put one Mac to
   sleep and confirm the "not connected" error. Unlink it and confirm that
   its connections stop.
7. In ChatGPT Developer mode, install the ChatGPT package (or add
   `https://RELAY/mcp` with OAuth), approve it with a link code, and ask for
   the latest meeting. Then disconnect it in ChatGPT and confirm that
   Settings → Assistants shows it disconnected.

For public submission, see [docs/directory-submission.md](docs/directory-submission.md).
It holds every portal field, the reviewer demo library (synthetic meetings reached
with `SCRIBE_REVIEWER_CODE`, never a real library), listing screenshots, the
five positive and three negative test cases, and the steps only the publisher can
complete: identity verification, legal review, the demo video and domain verification.

The implementation follows Overlord's shared MCP + client-adapter pattern, tool
annotations, OAuth discovery and presentation resources; it uses the official
MCP SDK instead of copying Overlord's hosted workspace/auth code.

Official references checked during implementation:

- [OpenAI MCP server and UI](https://developers.openai.com/plugins/build/app-quickstart)
- [OpenAI OAuth authentication](https://developers.openai.com/plugins/build/auth)
- [OpenAI plugin packaging](https://developers.openai.com/plugins/build/plugins)
- [Claude plugin manifests](https://code.claude.com/docs/en/plugins-reference)
- [MCP Apps initialization](https://apps.extensions.modelcontextprotocol.io/api/interfaces/app.McpUiInitializeRequest.html)

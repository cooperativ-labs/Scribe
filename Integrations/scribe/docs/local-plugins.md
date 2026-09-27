# Local plugin validation (2026-09-27)

This records the validation of the native local plugin from the debug build of
`Scribe.app` on macOS. The test library contained one generated transcript titled
`Synthetic plugin validation` with the sentence “This is a synthetic transcript
for plugin validation.” No real transcript was used in a tool call or screenshot.

## Build and shared checks

1. Run `Scripts/build-app.sh` with a prebuilt transcription worker through
   `SCRIBE_TRANSCRIPTION_WORKER_PATH`. The build completed and
   `codesign --verify --deep --strict` passed. The app contained
   `Contents/Helpers/scribe-mcp`, `scribe-mcp-launcher`, and the packaged plugin
   under `Contents/Resources/AssistantConnector/claude/plugins/scribe`.
2. In Settings → Assistants of that build, press Install ChatGPT Plugin,
   Install Claude Plugin, and Install Cursor Plugin. All three rows changed to
   **Installed**. Their installed launcher SHA-256 values matched the app's
   `Contents/Helpers/scribe-mcp-launcher` byte for byte.
3. Start the installed launcher with `PATH=/usr/bin:/bin` and
   `SCRIBE_TRANSCRIPTS_DIR` set to the synthetic library. The official MCP
   client listed all five tools and `scribe_recent_transcripts` returned the
   synthetic title. A process snapshot taken while `initialize` was in flight
   showed the same PID executing `Scribe.app/Contents/Helpers/scribe-mcp`. The
   local plugin path had no Node process. Scribe Relay still uses Node in this
   objective, and older assistant sessions on this Mac still had Node stdio
   processes from the previous plugin version.
4. Change only the debug app's packaged `.claude-plugin/plugin.json` version
   from `0.1.0` to `0.1.1` and re-sign the app. On returning to Assistants, all
   three rows showed **Update**. Press each Update; each returned to
   **Installed**. Restore the original manifest and signature afterward.
5. Press Remove on all three rows and confirm. The rows returned to Install;
   `codex plugin list` no longer showed `scribe@overlord-local`, `claude plugin
   list` no longer showed `scribe@scribe-local`, the Claude Desktop `scribe`
   entry and Agent Plugins marketplace `scribe` entry were gone, and
   `~/.cursor/plugins/local/scribe` was absent. Reinstall all three from the
   restored package. Each row again showed **Installed**. A second Install is
   unavailable in the UI while the installed package hash matches; the Swift
   installer tests also confirm a repeated `install()` changes nothing.
6. The production plugin manifest name is `scribe`, and its display name is
   **Scribe**. The Codex MCP server key is `scribe-local` so it can coexist with
   an existing remote `scribe` server. The marketplace's current name on this
   test machine is `overlord-local`; it is not the plugin's name.

## Harness results

| Harness | Steps and observed result |
| --- | --- |
| ChatGPT desktop | The installer preserved `~/.agents/plugins/marketplace.json` and its existing `overlord-local` name, and added `scribe` pointing to `./.codex/plugins/scribe`. [OpenAI's plugin packaging guide](https://developers.openai.com/plugins/build/plugins) says personal marketplaces are discoverable in Codex inside ChatGPT desktop after restart, and describes installing the plugin from that source in the Plugins Directory. The assumption that the desktop app actually starts this local stdio plugin **remains unverified**. Computer Use refused access to the running `com.openai.codex` app, so Plugins visibility, its tool list, restart behavior, and a chat tool call could not be checked. Do not infer desktop support from the marketplace file or the Codex CLI result. |
| Codex CLI | `codex plugin list` showed `scribe@overlord-local` installed and enabled, version `0.1.0`, sourced from `~/.codex/plugins/scribe`. The marketplace's own `name` determines the suffix. Its `mcp.json` uses `./scribe-mcp-launcher` and `cwd: "./"` because Codex does not expand `${CLAUDE_PLUGIN_ROOT}`. `codex mcp list` now lists the plugin server as `scribe-local`. The Codex app-server `mcpServerStatus/list` API connected to this plugin server and discovered all five tools with no discovery error. A separate, pre-existing remote `scribe` entry in `~/.codex/config.toml` failed OAuth refresh (`invalid_grant`); the new local key avoids that collision. Even with that remote entry disabled for a fresh `codex exec`, the model-facing tool inventory did not include Scribe and the model could not call `scribe_recent_transcripts`. This is an unresolved Codex session exposure gap; server registration and discovery alone do not prove the chat flow. |
| Cursor | The installer copied the plugin to `~/.cursor/plugins/local/scribe`; `.cursor-plugin/mcp.json` points to `${CURSOR_PLUGIN_ROOT}/scribe-mcp-launcher`. The packaging probe from the preceding objective established that Cursor expands this root. `cursor-agent mcp list` did not include Scribe after install. Live Cursor UI server and tools visibility was not established in this run. |
| Claude Code | `claude plugin list` showed `scribe@scribe-local` enabled, version `0.1.0`. With `SCRIBE_TRANSCRIPTS_DIR` set to the synthetic library, `claude mcp list` reported the managed launcher as **Connected**. Existing Claude Code sessions may still run cached old Node plugin copies until restarted. A new `/mcp` interactive screen and model tool call were not checked. |
| Claude Desktop | The installer merged `mcpServers.scribe.command` into `~/Library/Application Support/Claude/claude_desktop_config.json` while retaining other servers. An earlier build put the native launcher under `Integrations/claude`, which the older installed Scribe app overwrote with its Node relay files at launch. Claude Desktop then reported that the configured launcher was missing. The native plugin now lives under `Integrations/local-plugins/claude`; after Update, the configured launcher existed and was executable, and `claude mcp list` reported it connected. The running Claude app held an active session, so it was not restarted. Server visibility after restart and a chat tool call remain unverified. |

## App relocation defect and fix

Moving the built app from Xcode DerivedData to another folder and opening it
left LaunchServices listing only the older `/Applications/Scribe.app`, which
does not contain the native helper. The original launcher therefore exited 69
with “Scribe is not installed.” The launcher now checks running Scribe apps by
bundle identifier first, then LaunchServices registrations. After rebuilding,
moving the app to `~/Applications/Scribe-gde1-moved.app`, and opening that copy,
the launcher execed `~/Applications/Scribe-gde1-moved.app/Contents/Helpers/scribe-mcp`
and answered `initialize`. The app was returned to DerivedData, and all three
installed plugins were updated with the fixed launcher.

This relocation check covers an app that has been relaunched from the new
folder. With no Scribe process running, discovery still depends on
LaunchServices registering the moved bundle. The app's Settings footer tells
users to restart the assistant after plugin changes; active assistant sessions
can retain old plugin processes.

## Claude install path migration

The installer detects a saved Claude state record whose destination was the old
`Integrations/claude` directory and offers Update even if the package version
is unchanged. Update removes the old Claude Code plugin and marketplace
registration, registers the isolated `Integrations/local-plugins/claude` copy,
and rewrites Claude Desktop's Scribe command. The older Scribe app may continue
using `Integrations/claude` for its relay without deleting the native launcher.
The migration ran on this machine: the new launcher is executable, Claude Code
lists the new marketplace source, and its MCP list reports Connected.

## Automated verification

- `Scripts/build-app.sh`: passed; packaged app signature verified.
- `swift test --package-path Scribe/UI --filter AssistantPluginInstallerTests`:
  15 passed, including the Claude path migration.
- `SCRIBE_MCP_BIN_DIR=<built-app>/Contents/Helpers node --test
  test/conformance.test.js` from `Integrations/scribe`: 3 passed, including
  identical Node and Swift responses against the synthetic library.
- The full Node suite needs localhost binding. Running it in the restricted
  shell returned `EPERM` on `127.0.0.1`; an unrestricted rerun passed 33/33.
- After changing the Codex server key to `scribe-local`, the packaging tests
  passed 4/4. The app was rebuilt and the installed plugin was updated.

## User-reported live connection check

After the installation repairs, the user reported that the assistant
connections work. This confirms their observed connection state; the agent
could not inspect the ChatGPT desktop, Cursor, or Claude Desktop screens or
independently observe a transcript tool call in those apps. The Codex CLI
model-facing result below remains the result of the agent's own probe.

## Repeatable live checks

Use the synthetic library above, or Scribe's demo library, so no private
meeting text appears in a screenshot or copied result. Fully quit and restart
each assistant after the plugin Update in Scribe Settings → Assistants.

1. In ChatGPT desktop, open Plugins, find **Scribe** in the local marketplace,
   install or enable it if requested, open its tool list, then ask it to run
   `scribe_recent_transcripts` and report only the synthetic title. This is the
   design's main desktop assumption and remains unwitnessed by the agent despite
   the user's report that connections work.
2. Start a new Codex CLI chat. Check `/mcp` for `scribe-local` and its five tools,
   then ask for the recent synthetic transcript. The app-server inventory is
   positive, while the `codex exec` model tool inventory was negative; record
   which of these the interactive CLI matches. The pre-existing remote `scribe`
   entry may separately ask for OAuth login and is unrelated to the local key.
3. In Cursor Settings → MCP, check for Scribe and its tools, then call the recent
   tool in a new chat. The copy in `~/.cursor/plugins/local/scribe` exists, but
   `cursor-agent mcp list` did not discover it.
4. In Claude Code, start a new session and check `/mcp` for the Scribe plugin,
   then call the recent tool. The CLI health check already reports Connected.
5. Fully quit and restart Claude Desktop. Confirm its Scribe server appears,
   then call the recent tool in a new chat. Its configured launcher now exists
   under `Integrations/local-plugins/claude` and is executable.

For any successful call, inspect the process while it runs: the launcher
should exec a `Contents/Helpers/scribe-mcp` binary in the current Scribe.app,
with no Node process for that local MCP server. Older Scribe Relay processes
and cached assistant sessions can still use Node until restarted.

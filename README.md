# Scribe

Scribe records meeting audio and transcribes it locally on macOS. Its menu-bar
controls manage capture and processing, while the Transcripts window keeps the
finished results. It also offers system-wide dictation into focused text fields
and a voice assistant that writes what you ask for where your cursor is.

## Dictation

Install the transcription model in **Settings → Dictation**, then enable
dictation and grant Microphone and Accessibility access. Input Monitoring is
not required: Scribe uses AppKit event monitors authorized by Accessibility.

Choose the key in **Settings → Dictation → Dictation key**: **Right Command**
(the default), **Right Shift**, **Fn / Globe**, **Right Option**, **Right
Control**, **Left Control**, **Left Option** or the **Fn + Control** chord. The
key the voice assistant holds is greyed out there, and the two are never the
same. Hold the selected key while speaking
and release it to insert. Or double-tap it to keep listening, then tap it again
to finish. For Fn / Globe, set **System Settings → Keyboard → Press Fn (🌐) key
to → Do Nothing** to avoid also triggering the macOS action. Some external
keyboards handle Fn internally and do not expose it to macOS.
Press Escape or use the indicator's Cancel control to discard a hands-free
dictation. The indicator appears near the focused field, and insertion follows
the field currently focused when transcription finishes. Settings let you
adjust spacing, the indicator, sounds, and model memory use.

Dictation runs offline. Scribe does not send dictated audio or text anywhere,
and it keeps no dictation history. Audio is held in memory during capture; a
temporary WAV given to the local worker is removed after transcription.
Text goes directly into the focused field when possible, with a paste fallback
for apps that do not support Accessibility insertion.

To diagnose a warning that disappears too quickly, enable **Settings → General
→ Debugging → Capture messages for debugging**, then reproduce it. **View
Captured Messages…** shows timestamped messages and dictation events, with
search, **Copy All**, **Export…**, and **Clear History…**. Secure Keyboard Entry
on/off observations, trigger cancellation reasons, session states, and the
frontmost app's identifier help explain interrupted dictation. Capturing does
not change Secure Keyboard Entry protections or prevent session cancellation.

Capture is off by default. When enabled, Scribe keeps the latest 1,000 messages
locally in `~/Library/Application Support/Scribe/Debugging/messages.json`, across
restarts. This includes dictation/assistant status and errors, transcript
notifications, recorder recovery and shortcut warnings, model-installation
errors, update errors, and settings feedback. It excludes audio, dictated text,
live previews, assistant source text and answers. Messages can contain app
names, filenames, paths or provider error details; inspect the export before
sharing it. Turning capture off keeps existing history; **Clear History…**
removes the saved entries.

## Voice Assistant

Hold a second key, say what you want, and Scribe writes the answer where your
cursor is: a reply to the message in front of you, a shorter version of the
paragraph you selected, or a rewrite of what you just copied. Turn it on in
**Settings → Assistants → Voice Assistant**, pick the key (Right Shift by
default; it is never the same key as dictation), and choose an account: sign in
with your ChatGPT account through the installed Codex CLI; add your own API key for OpenAI, Anthropic, Google
Gemini, OpenRouter, the Vercel AI Gateway, xAI, Groq, Mistral or DeepSeek;
point it at a custom OpenAI-compatible endpoint (Ollama or LM Studio on your
Mac, or a company gateway), with a key only if the server wants one;
use Apple's on-device model (macOS 26 or later with Apple Intelligence on), in
which case nothing leaves your Mac; or use Apple's larger server model on
Private Cloud Compute (macOS 27 or later, in builds Apple has granted access). Your spoken instruction is transcribed
offline by the dictation model, so the model needs to be installed. Hold the
key and speak, release it to send, or double-tap it to keep listening. Escape,
or the indicator's Cancel control, discards the request, including one that is
already in flight.

Each request sends your spoken instruction and whichever text sources you enabled:
the text selected in the field you are typing
in; the text you copied, only when it is new since your last request; and the
text visible in the front app's windows, read through Accessibility. Audio never
leaves your Mac. Scribe takes no screenshot or pixels and does not read other
apps itself; connected Codex tools may access the services you authorized.
Password fields and Scribe's own windows are never gathered as source text.
Each of the three text
sources has its own switch in Settings, and the indicator names the sources it
is using while you speak. Scribe drops the instruction, source text and answer
after insertion. With the ChatGPT account choice, Codex can call tools from
your installed plugins and use local Codex memories when you have enabled
them. Tool results can add context to the answer; Scribe asks you in a dialog
when a tool requires a choice. A request that needs an unsupported approval or
sign-in step stops with an actionable error. The Codex voice thread is ephemeral,
so it does not appear in your Codex chat list. API-key requests to OpenAI use
`store: false`; Codex and other providers handle requests under their own data
policies.

The ChatGPT account route uses the documented Codex App Server and counts
against your plan's Codex limits. Install the Codex CLI and sign in from Scribe
or another Codex client. The sign-in is shared with Codex on this Mac; signing
out in Scribe signs out the other local Codex clients too. Local Codex memory is
separate from ChatGPT saved memory. The API-key route bills the provider you chose at its API
rates; each provider's key is its own Keychain item. The custom endpoint route
sends Chat Completions requests to the base URL you enter (usually ending in
`/v1`); a server on your Mac may use plain `http`, one elsewhere must use
`https`, and the key is optional. The on-device route is
free but uses a small model with a short context, so long screen text is
shortened to fit. The Private Cloud Compute route sends the request to Apple's
Private Cloud Compute servers, which Apple says keep nothing; it needs no key
and is not billed, but Apple sets a per-person usage limit, and it works only
in a build signed with Apple's Private Cloud Compute entitlement. Codex manages
the ChatGPT sign-in; Scribe keeps API keys in your Keychain and removes them when
you remove the key. The answer goes into the focused field through the same
Accessibility-then-paste path as dictation, replacing your selection when there
was one, or onto the clipboard if you choose **Copy to the clipboard only**.

## ChatGPT and Claude

The [Scribe MCP integration](Integrations/scribe/README.md) lets ChatGPT and
Claude find recent meetings, search saved transcripts and meeting notes, and
retrieve timestamped text, with the meeting's notes, for summaries and action items. It includes a local Claude Code plugin,
an OAuth-protected remote connector, and a ChatGPT transcript viewer. Setup is
opt-in; recording and transcription continue to work offline.

## Build and test

The host is macOS 15+ and Apple-Silicon-first. With Xcode installed, build and
run the local Debug app with:

```sh
mise run build
open ~/Library/Developer/Xcode/DerivedData/Scribe-*/Build/Products/Debug/Scribe.app
```

Run the unit test target with:

```sh
mise run test
```

Each workstream package also tests on its own, which is faster while working
inside one of them:

```sh
(cd Scribe/Platform && swift test)
(cd Scribe/UI && swift test)
```

### Project commands

Install [mise](https://mise.jdx.dev) once, then use the checked-in command
catalog:

```sh
mise tasks
mise run build
mise run test
mise run test-platform
mise run test-ui
mise run test-vocabulary
```

Scribe is an Xcode macOS application, so Xcode remains the source of truth for
the Apple SDK and Swift toolchain. `mise` manages the project commands; it does
not replace Xcode with a standalone Swift installation.

Debug builds disable the hardened runtime so the ad-hoc-signed local package
frameworks load; Release keeps it enabled for notarization.

Release builds are configured for direct Developer ID distribution, no App
Sandbox, and the hardened runtime. `Scripts/package-app.sh` builds an archive,
embeds the transcription helper plus FFmpeg/ffprobe and any local runtime
frameworks, aggregates required third-party notices, signs nested Mach-O code,
notarizes, staples, checks Gatekeeper, and creates `build/release/distribution/Scribe.zip`.
Run `Scripts/build-ffmpeg.sh` to prepare the pinned helpers and corresponding
source archive for packaging. Use `Scripts/package-app.sh --signed-app-only`
with the same local inputs to build a signed app for verification.
It also creates a signed, notarized `Scribe.dmg` containing the app and an
Applications shortcut. The website offers the DMG for drag-to-Applications
installation; the ZIP remains the in-app update artifact. The release command
uploads both files and their SHA-256 checksums to the same GitHub release.
To install from the website, open the DMG, drag Scribe to Applications, eject
the disk image, then open Scribe from Applications.
It accepts only reviewed local paths—there are no dependency or model download
steps in the release script.

Release versioning follows the same UTC timestamp convention as Latch:

```sh
mise run version
```

Review and commit that version change before releasing. Then copy `.env.example`
to `.env`, add the installed Developer ID identity plus the Apple ID,
app-specific password, and team ID used to create the `notarytool` profile.
Create `Scripts/release-inputs.local.env` from
`Scripts/release-inputs.example.env` and fill in the reviewed artifact and
notice paths. The guarded release command refuses a dirty worktree, configures
the keychain profile, notarizes and validates the archive, then tags, pushes,
and publishes the GitHub release:

```sh
mise run release
```

For a package-only release rehearsal, run
`mise run package`. The release task refuses a dirty worktree; after the version
bump, review and commit the version change before publishing.

### Custom transcription vocabulary

Names, companies, product spellings, and jargon transcription should get right
live in one always-on list, edited in **Settings → Vocabulary** or from the
transcript window's **Vocabulary** toolbar button. There is no per-recording
picker: the list is merged into every job.

The same list is editable from a shell, so an agent can maintain it without
going through the app:

```sh
Scripts/vocab.sh list
Scripts/vocab.sh add "Livmarli" --alias "Liv Mali, Liv-Marli"
Scripts/vocab.sh import glossary.txt      # one term per line, `Canonical: mishearing, other`
Scripts/vocab.sh list --json              # for scripts
Scripts/vocab.sh --help
```

Both surfaces open
`~/Library/Application Support/Scribe/Vocabulary/library.json` under a lock and
write it atomically, so an edit made in one shows up in the other. Adding a term
that is already present merges its mishearings rather than duplicating the row,
which makes `add` safe to repeat. Terms shorter than three characters, or containing only punctuation, are kept
and marked but not applied.

Install the optional **Vocabulary Boosting** group in **Settings → Transcription
model** (about 103 MB) to enable audio-backed corrections for batch and dictation.
Missing or unusable vocabulary assets leave normal transcription available and
show a clear warning. Empty vocabulary does not load the booster.

Each batch run saves its terms, aliases and revision in `job.json` and
`vocabulary.json`. Retry and speaker reprocessing preserve that snapshot;
**Transcribe again** captures the current library. Corrections update canonical
timed words before review and TXT/SRT/JSON export, while raw ASR tokens remain
available in the run. See
[the vocabulary decision](docs/decisions/custom-transcription-vocabulary.md)
for offline assets, conservative matching and validation.

### Meeting detection

Scribe notices when a call starts in Zoom, Microsoft Teams, Slack, FaceTime,
WhatsApp, Signal, Discord, or an installed Chromium browser (Chrome, Arc, Edge,
Brave, Vivaldi, Opera, Chromium). The signal is macOS's own accounting of
microphone use, read from CoreAudio's process objects: an application that has
the microphone open is on a call, and no window titles or extra permissions are
involved. **Settings → Meeting detection** lists the applications with a
checkbox each; all are on by default, and browsers appear only when installed.

For a browser, a call counts only when a tab is on one of the domains under
**Settings → Meeting websites**. The list starts with `meet.google.com`; add
`teams.microsoft.com`, `zoom.us`, or anything else, and subdomains match. The
tab addresses are read over Apple Events, so the first check of each browser
produces a one-time macOS Automation prompt. If that is declined, a browser
using the microphone is still reported, and Settings says why the domain filter
could not be applied. Leaving the list empty treats browsers like any other
application.

Detection only reports what it sees; it never starts a recording on its own.

### The meeting chip

When a call is noticed, a small chip appears under the menu bar icon asking
*"Record this Zoom meeting?"*, with a Record button and a dismiss button. For a
call in a browser it also names the website the tab was matched on. Dismissing
answers for that call only: the next meeting is offered again.

Accepting scopes the recording to the application that was noticed — the same
choice the **Application** submenu makes — and turns the chip into that
recording's transport: the elapsed time on the left, a **Meeting Notes** button
(which opens that recording's notes in the floating notes panel), pause and stop
on the right. By default it stays until the recording is stopped. Enable **Stop
recording automatically when the meeting ends** in Settings to have a recording
started from this prompt stop and save after Scribe observes the call end. Brief
microphone reconnects are ignored. Stopping from the chip is taken as the answer
for that call, so it does not immediately ask again.

The chip is its own floating panel rather than a row in the menu: it has to
reach somebody who is looking at their meeting, not at Scribe. It never takes
keyboard focus away from the call, and it appears over full-screen windows and
on every Space. On macOS 26 it is drawn in Liquid Glass; on macOS 15 the same
shapes are drawn in the system material.

A recording started from the menu, with no call noticed, gets no chip.

### Recordings in the Transcripts window

Every recording appears in the Transcripts sidebar as soon as capture is
running, pinned to the top with its clock ("Recording · 12:41"). The row keeps
its place and its selection while the recording is processed, queued,
transcribed and later re-run, and after Scribe is relaunched. A recording whose
start failed before capture began gets no row.

The row is named after the calendar event, or the dated recording name when
there is none. Rename it at any time, including while it is recording; the name
becomes the transcript's title when processing finishes, and reprocessing or
retranscribing keeps it.

Until a transcript exists the row says where the meeting is: processing audio,
waiting to transcribe, waiting for model setup, or **Not transcribed** when
**Transcribe when the final recording is ready** is off in Settings (use **Transcribe Now**
from the row's menu or the detail pane). A recording that ended because the
microphone disconnected, the Mac slept, the meeting app quit, permission was
removed, the disk filled or Scribe quit unexpectedly says so. If the recording
itself is gone — no raw audio, handoff request or transcription job survives —
the row stays as **Notes only** until you choose **Delete Draft…**; its
confirmation says how many notes would be removed. Retranscribe, combine,
export and deleting audio wait until a transcript exists.

### Meeting notes

Select a recording's row in the Transcripts window to write notes for the
agent while the meeting is being recorded. Each paragraph is one note; Return
adds a line to the same note and a blank line starts the next. A note is
stamped with the recording time when its first character is typed — the same
figure **Paste Timestamp** would paste, including its offset — and the stamp
stays with the note when you add to it. Joining two notes keeps the earlier
time, splitting one with a blank line gives both halves its time, pasting
several paragraphs stamps each with the paste time, and undo and redo bring
stamps back with the text. Notes written while the recording is paused, or
after it stopped, have no time (`--:--`). Text being composed with an input
method becomes a note only once it is committed.

Once the transcript is ready, the notes sit in a foldable section above it.
Each stamp is a button: it moves playback to that moment and highlights the
nearest turn, without starting sound. VoiceOver reads a stamp as, for
example, "Note at 5 minutes, 50 seconds", and with Full Keyboard Access the
stamps follow the notes in the keyboard order (Control-Tab out of the text).
Stamps cannot seek once the recording's audio is deleted or when a time falls
outside the recording.

#### Floating notes panel

You don't have to leave the meeting to write notes. The **Meeting Notes**
panel is a small floating window with the recording's name and clock, the
same notes editor and the same agent handoff tray as the Transcripts window.
It opens over a full-screen meeting, follows you to every Space, and takes your
typing without bringing Scribe forward, so the meeting app stays the active
app. Open it from:

- the global shortcut **Meeting notes** (⌥⇧⌘N by default; change it in
  Settings → General → Global shortcuts, beside Paste timestamp). It opens the
  notes of the recording in progress, recording or paused, and nothing else;
  with nothing recording it only shows a short hint under the menu bar icon;
- **Meeting Notes** in the menu bar panel, under Paste Timestamp (available
  while recording);
- the **Meeting Notes** button on the meeting chip while it shows the
  recording's transport.

Each entry point opens the notes of the recording it was showing, never "the
selected row". The panel and the Transcripts window edit the same draft: what
you type in one shows up in the other as you type, and the handoff settings are
shared too. **Open in Transcripts** opens the window with the meeting's row
selected. The panel remembers where you put it and how big it was.

The panel stays open when you click back into your meeting. You close it with
its close button or ⌘W. It closes itself only once the meeting's transcript is
ready, and even then never while it has the keyboard (or one of its pickers or
the folder dialog is open), while text is being composed with an input method,
while an edit has not been saved, or while the tray shows a send that is
queued, held, under way, sent or failed — so a **Send after processing** result
stays in front of you. Its notes are written whenever it closes.

Notes belong to the meeting, not to one transcription run: renaming,
reprocessing and retranscribing show the same notes. **Delete Audio** keeps
them. Deleting the transcript deletes them with it, and the confirmation says
so. Combining two recordings keeps both sets of notes in the combined meeting,
with the second recording's times moved to where its audio now starts (untimed
notes stay untimed), and clears the agent handoff settings of the combined
meeting. Imported files and pasted transcripts have no notes.

Until a recording's transcript is ready its notes are kept with the rest of
the draft (below). When transcription finishes, they move into the meeting's
folder in the transcript store as `meeting-notes.json` (owner-only, 0600,
versioned), the only copy from then on. Notes are stored unencrypted, like
transcripts. A notes file that cannot be read is never overwritten: the notes
show as unavailable and combining that meeting is refused.

Scribe keeps what it knows about each recording (its name, its notes until the
transcript is ready, and its agent handoff settings) as one
owner-only (0600) file per recording in `~/Library/Application Support/Scribe/drafts`,
never in the recordings folder. Edits are saved about half a second after you stop typing and
immediately when a recording stops, is handed to transcription, or Scribe quits
normally; a forced quit can lose at most that half second. If a save fails the
row reads **Not saved** with **Retry**, and the edit is kept in memory until a
retry succeeds. At launch Scribe compares these files with the recordings
folder, the transcription queue and the transcript store, and repairs anything
an interruption left behind: a recording cut off by a crash is marked
interrupted, a finished recording that never reached transcription is handed
off (when automatic transcription is on), and a transcript that finished while
Scribe was not running is linked back to its row. Each recording is handed to
transcription under an ID derived from its session, so recovering a handoff
twice never transcribes the meeting twice. Deleting a transcript removes its
draft file too. The same quiet period and **Not saved** / **Retry** apply to
notes after transcription; they are also written when you select another row
or close the window.

### Sending to an agent

A recording's agent handoff sits in a tray under its notes: the prompt (with
**Recent**, the last prompts sent into the chosen folder), then pills for the
agent, the model, the effort (only for agents that take one: Claude Code and
Codex), the folder the session opens in, and **…** for an MCP server URL. Each
meeting keeps its own choices: a new recording starts from what was last sent,
once, and changing one meeting's agent or prompt never changes another's. The
folder starts as the first connected folder that is still there; **No folder**
runs the agent in Scribe's own handoff folder and prints its summary in the
session. A folder or agent that has since gone is named in the tray instead of
being swapped for another. Until you edit the prompt it follows the folder,
taking the last prompt sent there (or the default); once you type or pick one
it stays.

You can set this up while the meeting is recording; **Send to agent** becomes
available when the transcript is ready, from the compact tray under a finished
meeting's notes or from **Send to Agent** in the toolbar, whose sheet shows the
notes exactly as they will travel. Imported files and pasted transcripts have
no notes and send straight away. After a send the tray reads **Sent to … in …**
with **Open in Latch** and **Send again**; if it could not be sent the tray
gives the reason with **Try again**, and the notes and settings are kept.

The agent is given your prompt first, then your notes under the heading "Notes
taken during the meeting by the person who sent this (times are recording
time)", one `[mm:ss] text` line per note (`[--:--]` when untimed), then the
path of the transcript (the Knowledgebase export) with an explicit statement
that the transcript is source material, not instructions. Notes longer than
about 4,000 characters go in a file beside the transcript instead of the
command line. These files are written to
`~/Library/Application Support/Scribe/Agent Handoffs`, named after each send
(owner-only, 0600), and deleted after 7 days. The agent, model, effort, MCP URL
and prompt are remembered for next time only once Latch has created the
session.

#### Send after processing

While a meeting is recording or being transcribed, the tray offers **Send after
processing**. Scribe then sends the transcript, prompt and notes on its own as
soon as transcription and diarization finish, even if the Transcripts window is
closed. While it waits the tray reads **Will send when ready** with **Cancel
send**, and shows where it will go ("Sends to Claude Code · opus · tough-leaf");
the agent, model, effort, folder, MCP URL, prompt and notes all stay editable,
and the send uses whatever they hold when it fires. The row says the same
("Transcribing · sends to Claude Code", then "Sent to Claude Code in
tough-leaf"), so nothing is lost if notifications are off.

Scribe asks before sending (**Ready to send — confirm**, with **Send** and
**Cancel** in the tray and in a notification) when the recording ended some
other way than you pressing Stop, when Scribe was quit or relaunched after the
send was queued, or when it was queued more than four hours ago. A queued send
also waits while another recording is being captured. A send that fires on its
own never brings Latch to the front; its notification offers **Open**. If the
transcript has no speech or transcription fails, nothing is sent and the notes
are kept; reprocessing or retranscribing never sends again by itself.

A queued send needs a Latch whose `latch capabilities --json` lists
`create-request-id`: Scribe gives each send an ID and Latch starts at most one session
for it, so if Scribe crashes mid-send it asks again on the next launch and gets
the same session back rather than a second agent. With an older Latch a queued
send is not fired and the tray says to update Latch; sending by hand still
works. If Scribe can't tell whether the agent started, the tray says so and
**Try again** asks Latch again under the same ID. Combining is unavailable
while a meeting has a queued, held or unconfirmed send.

### Notes in exports and assistants

A meeting's notes travel with its transcript wherever the transcript goes,
except subtitles:

| Where | What carries the notes |
| --- | --- |
| TXT export | A **Notes** section after the transcript, one paragraph per note: `[05:50] text`, `[--:--]` when untimed, later lines of a note indented under its first |
| Scribe JSON export | A top-level `notes` array after `warnings`: `{ id, text, offset_ms, draft_id }`, `offset_ms` null when untimed. The canonical transcript members are unchanged, so a reader that predates notes reads the same transcript |
| Knowledgebase JSON export and **Copy Knowledgebase JSON** | `pipeline.extensions["ai.scribe"].notes`: `{ id, text, offset_ms }`. Still `kb.transcript-upload/1`: Knowledgebase accepts any object in a producer's extension and keeps it with the imported transcript, while a top-level `notes` would be rejected |
| SRT export | Nothing: subtitles only |
| ChatGPT, Claude and other MCP clients (local or through the relay) | `scribe_get_transcript` and `fetch` return `notes` apart from the transcript text, whole on every page; search also matches note text and names the note that matched (`matched_note`). Paging and `revision` are unaffected — see [Integrations/scribe](Integrations/scribe/README.md#tools-and-data-behavior) |

Exports carry exactly what the meeting's row shows, including an edit made a
moment ago that is not on disk yet. After a combine, each note in Scribe JSON
keeps the `draft_id` of the recording it was written in. A meeting without notes
exports byte for byte as before. If the notes file cannot be read, the
transcript is still exported, without notes, and the confirmation says the notes
were left out. When a meeting is sent to an agent its notes go in the prompt (or
the notes file), not in the handoff's transcript file, so the agent sees them
once and labelled as yours.

The prompt, MCP URL, agent, model, effort, folder and send history are private
to the draft record. They never appear in an export, the MCP server or relay,
Scribe's logs, or **Capture messages for debugging**; the only place they travel
is the agent session you send to.

### Where meeting data is kept

| What | Where | Permissions | Removed when |
| --- | --- | --- | --- |
| Recording audio, transcripts, `meeting-notes.json` | The transcript store, one `meeting--…` folder per meeting | Notes file 0600 | **Delete** removes the whole folder, notes included. **Delete Audio** removes only the audio |
| Draft record: name, notes until transcribed, handoff settings, send state | `~/Library/Application Support/Scribe/drafts/<id>.json` | 0600 | Deleting the transcript or **Delete Draft…**; a combine removes the absorbed recording's record |
| Files handed to an agent (`<send>.kb.json`, `<send>.notes.txt`) | `~/Library/Application Support/Scribe/Agent Handoffs` | 0600 in a 0700 folder | At the next send, once more than 7 days old. Deleting the meeting does not remove them sooner |

Nothing here is encrypted beyond what FileVault gives the disk. A recording
whose audio, handoff request and transcription job are all gone keeps its draft
as a **Notes only** row (send disabled) until you delete it; a crash, forced
quit or relaunch is recovered at the next launch as described under [Meeting
notes](#meeting-notes), and a send that was queued across it waits for your
**Send** instead of firing.

### Model storage and offline operation

Open **Settings → Transcription model → Install Model** to install the recommended
Parakeet v3 model directly from Hugging Face. The roughly 654 MB download includes
the corrected int8-linear encoder and the speaker detection assets. No API key,
Python environment, or Git LFS installation is needed.

Models default to `~/Library/Application Support/Scribe/Models`. **Choose Models
Folder…** saves a different location across launches; **Use Default** restores
the default. Changing folders leaves previous downloads in place. A complete
installation in the selected folder is recognized automatically.

The installer uses the exact revisions in the bundled `model_manifest.json`,
checks file sizes and declared SHA-256 hashes, and publishes each verified file
atomically. Progress, cancellation, and retry are available in Settings; retries
reuse verified files, while an interrupted file downloads again. Queued recordings
wait for model setup and start automatically when installation completes. New
jobs use the selected folder without an app restart; active workers retain their
original model directory. Once installed, transcription works offline.

Upgrading from the original Parakeet v3 encoder downloads the new 595 MB encoder
bundle and reuses the verified companion files. After the complete replacement
is verified, the installer removes the original encoder from the selected model
folder. Rolling back to the previous app requires reinstalling its encoder.

Cloud models and API-key configuration are deferred. The shell installer in
`Scripts/package-transcription-models.sh` remains available for development;
select its output folder in Settings to reuse those files.

Clean-machine release test:

1. On a Mac without Xcode or command-line developer tools, install the
   stapled `Scribe.zip` output and open the app from Finder; Gatekeeper must
   accept it.
2. Perform the one-time, user-initiated model installation while networking is
   available, then disconnect networking completely.
3. With dependency caches empty, verify launch, recording, processing, and
   transcription using only the installed app, helper binaries, and local
   model directory.
4. Repeat with the model folder unavailable and verify a clear setup error,
   never a runtime download attempt.

`Scripts/build-native-dependencies.sh` runs the pinned WebRTC and FFmpeg
builders. The FFmpeg builder fetches and verifies its source archive when
needed. FLAC encoding uses macOS AudioToolbox.

## Workstream ownership

Each entry below is an independent local Swift package. Add code and package
metadata inside the owning directory; the Xcode project already references the
package products, so parallel workstreams do not need to edit
`Scribe.xcodeproj`.

| Owner | Directory |
| --- | --- |
| Host integration contracts and app lifecycle | `Scribe/App/` |
| Capture | `Scribe/Capture/` |
| Session storage and recovery | `Scribe/Storage/` |
| Audio processing | `Scribe/Processing/` |
| macOS integration | `Scribe/Platform/` |
| Recorder SwiftUI | `Scribe/UI/` |
| Native AEC and FLAC boundaries | `Native/WebRTCBridge/`, `Native/FLACBridge/` |
| Speaker module | `Modules/Speakers/` (with `Profiles/`, `Enrollment/`, `Matching/`, `UI/`, `Tests/`) |
| Transcription module | `Modules/Transcription/` (with `Contracts/`, `Import/`, `Jobs/`, `Worker/`, `Transcript/`, `Export/`, `UI/`, `Tests/`) |
| Custom transcription vocabulary | `Modules/Vocabulary/` (with `Model/`, `Store/`, `Text/`, `UI/`, `Tests/`) |
| Bundled transcription helper | `Workers/TranscriptionWorker/` |
| Standalone processing utility | `Tools/ScribeProcess/` |
| Vocabulary command line | `Tools/ScribeVocabulary/` (`scribe-vocab`) |
| Live capture integration gate | `Tools/CaptureIntegration/` |
| Audio-quality metrics tool | `Tools/AudioMetrics/` |
| Host-app tests and synthetic fixtures | `Tests/`, `Tests/Fixtures/` |
| Native-build and release scripts | `Scripts/` |

See [Development tools](Tools/README.md) for the maintained regression gates and
the replacements for retired feasibility probes. Shared recorder test doubles
and fixtures live in the `PlatformTestSupport` target and are not linked into
the app.

### In-app updates

Scribe checks the latest published GitHub release at launch and from **Check for
Updates…**. When it finds a newer release, it automatically downloads and
verifies it. Choose **Restart and Install** when you are ready to replace the
application in place and reopen it.
Active recordings finish saving before installation; background processing
resumes after relaunch. Quitting normally discards an update that is ready to
install.

Updates require a Developer ID signed release in a writable Applications folder
and the `Scribe-<version>-macos.zip` asset produced by the release script. The
installer checks the bundle identifier, newer version, installed app's signing
identity, nested code signatures, and Gatekeeper assessment. It preserves the
previous app and restores it if replacement or reopening fails. Unsigned debug
builds, translocated apps, and read-only installations show an actionable error.
No additional feed or signing secret is required by the existing release pipeline.

Before shipping updater changes, exercise a signed older-to-newer release update
on macOS, including an active recording, a cancelled/failed download, and an
unwritable installation. Automated tests cover archive selection/extraction,
bundle identity/version rejection, replacement, and rollback; they substitute
code-signing assessment and Launch Services in the transaction fixtures.

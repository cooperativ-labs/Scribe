# Assistant: spoken instructions applied to the text in front of you

**Proposal (coo:1084):** Add a second hold-to-talk mode to Scribe. The person
is reading something (an email, a chat thread, a note), focuses the field
where the answer should go, holds a **different** key from the dictation key,
and says what they want: "reply saying I can do Thursday but not Friday",
"make this shorter and friendlier", "translate to Spanish". Scribe transcribes
the instruction locally as it does for dictation, gathers the text the person
is looking at (their selection, anything they just copied, and the text of the
app's windows read through Accessibility), sends the instruction and that text
to a language model, and inserts the model's answer at the caret. The model is
the person's own ChatGPT subscription, reached the way the Codex CLI reaches
it, with a device-code sign-in inside Scribe Settings.

This document is the proposal only. Section 12 breaks it into objectives and
section 13 lists the decisions still open.

**Decisions (2026-09-27):**

- The source text comes from the app's windows through Accessibility, not
  from a screenshot and not only from the clipboard. Selection and a fresh
  clipboard are included when present (section 6).
- Trigger keys for both modes come from one list: right ⌘, right ⇧, Fn,
  right ⌥, right ⌃, left ⌃, left ⌥, and the Fn+⌃ chord. Either mode may use
  any of them; the two pickers grey out whichever key the other mode holds.
  Dictation keeps right ⌘ as its default; **the assistant defaults to
  right ⇧**.
- The seven apps that matter most, and therefore the QA and spike matrix, are
  Messages, WhatsApp, Signal, Slack, Apple Mail, Notion and Bear.
- The default assistant model is **GPT-6 Luna (light)**; the picker still
  offers whatever the account's model list returns.

## 1. Goals and non-goals

Goals:

- Work everywhere dictation works today: any app with a text field, no
  per-app integration, same permissions (Microphone and Accessibility).
- A second trigger key, always distinct from the dictation key, with the same
  hold and double-tap ergonomics people already know from dictation.
- No copy step for the common case. Scribe reads what is on screen in the
  frontmost app through Accessibility, so "reply to this" works while the
  message is simply visible.
- The instruction is transcribed **offline** by the resident Parakeet engine.
  Only the instruction text and the gathered source text leave the machine,
  and only for the one request the person just made.
- Use the person's ChatGPT subscription rather than a pay-per-token API key,
  with an API key as a supported alternative for people who have one.
- The answer lands in the focused field through the existing insertion path
  (Accessibility first, paste fallback, copy-only last).
- Opt-in, clearly labelled, and visibly different from dictation in the
  indicator, because this is the first Scribe feature that sends the person's
  content to a cloud service on purpose.

Non-goals for the first release:

- Streaming the answer into the field word by word. The answer is inserted
  once, when complete (section 8 explains why).
- A screenshot of the screen, with or without local OCR. Section 6 explains
  why the Accessibility text is preferred; a screenshot fallback for apps that
  expose no text is a follow-up the spike may or may not justify.
- Using the transcript window, meeting transcripts, or the MCP connector as
  context. This feature is about the text in the clipboard only.
- A conversation. Each hold is one request with no memory of the previous
  one.
- Claude subscription sign-in. Anthropic's usage policy forbids third-party
  apps from signing in with Claude.ai accounts or routing requests through
  Pro/Max plan credentials, and it enforced that in February 2026. A Claude
  provider is therefore API-key only, and a follow-up; section 7.5 says what
  it would take.
- Anything that needs an App Store build. Same reasoning as dictation.

## 2. What exists today

The dictation work (coo:1066, coo:1071) built almost everything this feature
needs. The survey found these pieces and gaps.

| Area | Today | Reusable? |
| --- | --- | --- |
| Trigger | `DictationTriggerMonitor` (AppKit global `flagsChanged`/`keyDown` monitors) drives one `DictationTriggerState` for one `DictationActivationKey` (right ⌘, right ⇧, Fn) with hold, double-tap, chord cancel, Escape, secure-input detection | Yes, after generalising to two keys. The state machine already cancels when *any other key* goes down while the trigger is held, which is exactly the rule for two trigger keys. |
| Key choice | `DictationActivationKey` enum, `ScribeSettings.dictationActivationKey`, a `Picker` in the Dictation tab | Yes. Needs five more keys and a chord (section 5), and pickers that grey out the key the other mode holds. |
| Audio capture | `DictationAudioCapture`: AVAudioEngine tap into a 16 kHz mono ring buffer, level meter, recovery on device change | Yes, unchanged. One instance is shared by both modes; the coordinator already owns it. |
| Transcription | `DictationEngine`: resident `TranscriptionWorker` in `--mode dictation`, `warm`/`dictate`/`unload`, keep-loaded and idle-unload policies | Yes, unchanged. The instruction is a short utterance, the best case for this engine. |
| Coordination | `DictationCoordinator`: trigger → capture → transcribe → insert, generation counter for cancellation, `DictationState` published to the indicator | Yes, extended with an intent. Section 4 argues for one coordinator with two intents rather than two coordinators, because they share the microphone and the engine. |
| Target field | `FocusedFieldLocator`: focused AX element, role, caret bounds, `AXSelectedText` settability, read-back, manual-AX for Electron, `window(of:)` | Yes. The window lookup and the Electron manual-accessibility switch are the starting point for reading window text (section 6). |
| Insertion | `DictationTextInserter` + `KeystrokeTextInserter`: AX set with read-back, ⌘V paste with clipboard save/restore, copy-only fallback | Yes, with a second shaping rule: generated text keeps its own paragraphs and capitalisation. |
| Indicator | `DictationIndicatorController` / `DictationIndicatorView`: non-activating panel above the caret, states idle → warming → listening → transcribing → inserted / copied / error | Yes, with a new *thinking* state and a mode label. |
| Settings | `ScribeSettings` (UserDefaults, `scribe.settings.dictation.*` keys), Dictation tab in `ScribeSettingsView`, `SettingsSection` deep links | Yes. New keys and a new section. |
| Network | `URLSession` is used by `ApplicationUpdater` (GitHub releases) and `TranscriptionModelInstaller` (model download). Nothing else in the app talks to the network; the worker declares networking disabled. | The HTTP client is new code. Keep it out of the worker. |
| Secrets | Nothing in the app uses the Keychain. The MCP bridge (`Integrations/scribe`, Node) keeps its OAuth state in a mode-0600 JSON file. | Keychain wrapper is new code (small). |
| Agent hand-off | `LatchAgentDispatcher` locates `claude`, `codex`, `gemini`, `cursor-agent` on the Mac and launches a Latch session with the transcript | Not for the request itself (it opens a terminal session), but its tool locator is reused if the `codex exec` fallback in 7.4 is built. |
| ChatGPT relationship | The MCP integration already lets ChatGPT read Scribe transcripts through an OAuth-protected connector | Different direction (ChatGPT → Scribe). Nothing to reuse, but the README already frames ChatGPT as a partner. |

Two constraints carry over from dictation. The worker stays offline: the model
call is made by the host app, never by the helper. And the feature is a
foreground interaction that never enters the transcription outbox or the
processing scheduler.

The dictation AX matrix (`docs/feasibility/dictation-ax-matrix.md`) measured
insertion, not reading, and covered Slack and Mail from the priority list but
not Messages, WhatsApp, Signal, Notion or Bear. Section 6 says what is known
and what the spike must measure.

## 3. How the comparable apps do it

| | MacWhisper | Superwhisper | Wispr Flow | Raycast AI |
| --- | --- | --- | --- | --- |
| Shape | "AI prompts": after dictation, optional post-processing through OpenAI, per-app prompt | "Modes": each mode has a prompt; **selected text and clipboard** can be passed as context; a mode can be bound to its own shortcut | **Command Mode**: hold Fn+⌃, speak an edit, acts on the selection or the text around the cursor, rewrites in place; **Transforms**: select text, press ⌥1/⌥2 for fixed prompts, in-place with a diff viewer and Undo; **Context Awareness** reads the app, surrounding text and screenshots by default | "AI Commands" on selected text with a hotkey per command; results replace or paste |
| Trigger | Same dictation key; prompt chosen in settings | Per-mode shortcut, hold or toggle | Separate chord for Command Mode; hotkeys for Transforms | Chord shortcut per command |
| LLM account | User's OpenAI API key, or local model | OpenAI/Anthropic/Groq keys, or local | Their cloud only; no own key | Raycast Pro subscription |
| Output | Replaces the dictated text | Inserted where the cursor is | Replaces the selection; "ask ChatGPT…" opens a browser tab instead | Inserted or shown in a window |

Wispr Flow's Command Mode is the closest match for the gesture, and its
Context Awareness is the closest match for reading the screen; the difference
is that Flow does both on its own cloud with screenshots on by default, while
this proposal reads text through Accessibility, sends only text, and uses the
person's own account. None of these products sign in with a ChatGPT
subscription; the ones that let you bring your own account use an API key.
The subscription route is what the Codex CLI and a group of third-party
coding tools do, which section 7 covers.

## 4. Architecture

New code goes into the existing `Modules/Dictation` package, plus a new
`Modules/Assist` package for the model client so that the Dictation package
keeps no network code and its tests stay offline. Host wiring goes in
`ScribeAppEnvironment` next to the dictation wiring.

```
dictation key ─┐
               ├─▶ DictationTriggerMonitor ──▶ DictationTriggerEvent(intent) ──▶ DictationCoordinator
assistant key ─┘   (one state machine per key)                                        │
                                                                                      ├─▶ DictationAudioCapture   (shared)
                                                                                      ├─▶ DictationEngine         (shared, offline)
                                                                                      ├─▶ SourceTextCollector     (selection, fresh clipboard, window text via AX; at key-down)
                                                                                      ├─▶ TextAssistant  ─────────▶ ChatGPTAssistant   (Modules/Assist: OAuth session + Responses API)
                                                                                      │        (protocol)          OpenAIKeyAssistant  (same API, api.openai.com)
                                                                                      ├─▶ DictationTextInserter   (shared; `generated` shaping)
                                                                                      └─▶ DictationIndicatorController (mode label, thinking state)
```

State machine of one instruction:

```
idle ─(assistant key)─▶ listening ─(release)─▶ transcribing ─▶ thinking ─▶ inserting ─▶ inserted
          │                 │                        │              │                     (indicator fades)
          │                 └─(short hold/chord/Esc)─┴──────────────┴─▶ idle, nothing sent or inserted
          └─(no text found anywhere)─▶ error "Nothing to work with in <app>", nothing recorded
```

Why one coordinator with an intent rather than a second coordinator: both
modes need the one microphone tap and the one resident engine, and the
generation counter that makes cancellation safe has to cover both. A second
`DictationCoordinator` would fight the first for `AVAudioEngine`. The intent
is carried on the trigger event and on `DictationState`, so the indicator and
the app delegate (sounds, menu state) can tell the two apart without new
plumbing.

The source text is gathered at **key-down**, not at release. That is the
moment the person means; anything that changes on screen while they speak
would be a surprise. It is read into memory once and never written anywhere.
Gathering runs concurrently with recording, so its cost is hidden inside the
time the person spends speaking.

## 5. Trigger: a second key

`DictationTriggerState` is already independent of AppKit and keyed on one
`activationKey`. The change is in the monitor: it holds a small table of
`(DictationActivationKey → DictationTriggerState, intent)` and routes each
`flagsChanged` event by key code to the matching state, while every other
state sees it as an "other key down", which is the existing chord-cancel
rule. So holding the assistant key while dictation is listening cancels the
dictation, and vice versa, with no new code in the state machine.

Events gain the intent: `listeningStarted(mode, intent)`, `listeningEnded(intent)`,
`cancelled(reason, intent)`. The double-tap toggle works for the assistant
key exactly as for dictation; Escape and the indicator's Cancel end either.

### 5.1 The key list

Both modes choose from one list. `DictationActivationKey` grows from three
cases to eight:

| Key | Key code | Side-specific flag | Note |
| --- | --- | --- | --- |
| Right ⌘ | 54 | `NX_DEVICERCMDKEYMASK` | Existing; dictation default |
| Right ⇧ | 60 | `NX_DEVICERSHIFTKEYMASK` | Existing; **assistant default** |
| Fn / Globe | 63 | `.function` | Existing; needs the System Settings note |
| Right ⌥ | 61 | `NX_DEVICERALTKEYMASK` | New |
| Right ⌃ | 62 | `NX_DEVICERCTLKEYMASK` | New |
| Left ⌃ | 59 | `NX_DEVICELCTLKEYMASK` | New |
| Left ⌥ | 58 | `NX_DEVICELALTKEYMASK` | New; see the typing note below |
| Fn + ⌃ | 63 then 59 or 62 | `.function` and `.control` together | New; a chord, see 5.2 |

The four new single keys need nothing beyond a key code and a flag mask; the
`isPressed(in:)` extension in `DictationTriggerMonitor` gains four cases.

Left ⌥ and left ⌃ are typing keys as well as trigger keys: ⌥E then E types
"é", and ⌃A moves to the start of a line. The state machine already covers
this. A trigger key that is followed by another key while held is a chord
and is cancelled (`cancel(.chord)`), and a hold shorter than the threshold
is discarded, so typing an accented character starts and cancels a
listening session too fast for the indicator's delay to show anything. The
settings copy for these two keys says so in one sentence, and the "press the
key to check it is detected" row stays.

### 5.2 The Fn+⌃ chord

The chord is the one option that is not a single key code. It is modelled
as a ninth activation key whose press is defined as "both `.function` and
`.control` are down" and whose release is "either has gone up":

- The monitor already receives every `flagsChanged` event. For the chord
  entry it computes `pressed = flags.contains(.function) && flags.contains(.control)`
  on every modifier event and feeds the state machine a synthetic down when
  `pressed` goes false → true and a synthetic up when it goes true → false.
  The state machine sees a single key and needs no change.
- Order does not matter: Fn then ⌃, or ⌃ then Fn, both count. The hold
  threshold runs from the moment both are down.
- Interaction with a lone Fn or lone ⌃ assigned to the other mode: pressing
  Fn starts that mode's listening; adding ⌃ is an "other key" to it (chord
  cancel, no text inserted because it is under the hold threshold) and a
  press to the chord entry, which starts the assistant. It works, but it is
  the least clean pairing, and the picker footnote says "Fn + ⌃ is easiest
  to use when Fn alone is not the dictation key". It is not forbidden; only
  the identical key is.
- Escape and Cancel behave as for any key. Secure Keyboard Entry blocks the
  chord the same way it blocks single keys.

### 5.3 Two pickers, one rule

The Dictation section keeps its picker and the Assistant section gets one.
Each lists all eight entries, and the entry the *other* mode holds is shown
greyed with a suffix ("Right ⌘ (dictation)", "Right ⇧ (assistant)") and
cannot be chosen. SwiftUI's menu `Picker` does not reliably grey individual
rows on macOS, so the control is a `Menu` of `Button`s (or an
`NSPopUpButton`) that disables the held item; the existing `Picker` is
replaced in the Dictation section for consistency. `ScribeSettings` enforces
the rule on load: if a stored pair clashes (an old default, an edited plist),
the assistant key moves to the first free entry in list order and the
Assistant section shows a one-time notice.

Both triggers are only installed while their feature is enabled. Enabling
the assistant does not require dictation to be enabled, but it does require
the same model install and permissions, so `syncDictationMonitor` becomes
`syncTriggerMonitors` and gates on either toggle.

## 6. The source text

The assistant needs the text the person is looking at. It is gathered at
key-down from three places, all through APIs Scribe already uses, and sent as
labelled blocks so the model knows which is which.

### 6.1 Three sources, one policy

1. **Selection.** If the focused field has a non-empty `AXSelectedText`, it
   is sent as `<selected_text>` and the prompt says an edit instruction
   applies to it. The AX matrix shows that Electron and browser fields may
   report a selection unreliably; a read that returns nothing simply means no
   block is sent.
2. **Fresh clipboard.** `NSPasteboard.general` is checked by `changeCount`.
   If it holds plain text and the count differs from the one recorded at the
   previous assistant request (or there was no previous request), the text is
   sent as `<copied_text>`. A deliberate copy is therefore always honoured
   without the person having to know the rule, and yesterday's clipboard is
   not dragged into every request. No polling and no timestamps are needed.
3. **Window text.** The text of the frontmost app's windows, read from the
   Accessibility tree and sent as `<screen_text app="Mail">` with one
   `<window title="…">` block per window. This is the source that makes
   "reply to this" work without a copy, and section 6.2 describes it.

If all three are empty the indicator says "Nothing to work with in *App*"
and nothing is recorded or sent. The prompt (7.2) tells the model to prefer
the selection, then the copied text, then the screen, and to treat the screen
text as what the person is reading rather than something to edit unless the
instruction says otherwise.

### 6.2 Reading window text through Accessibility

The focused element's window is already known (`FocusedFieldLocator.window(of:)`).
From it, and then from each other visible window of the same application
(`kAXWindowsAttribute` on the application element, focused window first,
minimised windows skipped), a reader walks `kAXChildrenAttribute` depth
first and collects text from elements whose role carries text: static text,
text areas and fields, headings, links, menu-less buttons with titles, web
areas and their descendants, table and outline rows. For each it records
role, value or title, and, when cheap, the element's frame so that the
output can be ordered top to bottom within a window.

Why other windows matter: in Mail, replying opens a separate compose window,
so the caret's window is empty and the message being answered sits in the
viewer window behind it. Messages, WhatsApp, Signal, Slack, Notion and Bear
keep the conversation or note in the same window as the field.

Rules that keep the walk safe and fast:

- **Budget.** At most a few thousand elements and about 300 ms per request,
  using the locator's existing 250 ms per-call messaging timeout so a hung
  app cannot stall the trigger. The walk stops early once the character cap
  (section 6.3) is reached. It runs on the main thread, as the locator's
  recent change requires, so the budget is also a responsiveness budget; the
  spike measures whether 300 ms is generous or tight in the seven apps.
- **Never read** secure fields (the locator already detects them), Scribe's
  own windows, or the focused field itself when it is the compose field
  (its value is what the person is about to replace). Elements whose role or
  subrole marks them as password or secure are skipped along with their
  subtrees.
- **Electron and Chromium.** Nothing is exposed until the manual
  accessibility attribute is set on the application, which the locator
  already does for Electron; the same switch is applied to Chromium
  browsers. It is set at key-down and left on for the app's lifetime, as the
  dictation code does today.
- **Noise.** Toolbars, sidebars and menus produce short labels. Elements
  under a few characters are dropped unless they are headings, repeated
  identical strings are collapsed, and each window's text is trimmed to the
  cap with the focused window taking priority.

What each priority app is expected to yield, from its stack and from the
dictation matrix, to be confirmed by the spike:

| App | Stack | Window that holds the source | Expected yield | Measured? |
| --- | --- | --- | --- | --- |
| Messages | Native Apple | Same window as the composer | Visible bubbles with sender names; rows outside the viewport are not in the tree | No |
| WhatsApp | Native Catalyst | Same window | Message rows are exposed to VoiceOver, but role and value quality is the least predictable of the seven | No |
| Signal | Electron | Same window | After the manual-accessibility switch: the visible conversation, virtualised | No |
| Slack | Electron | Same window | As Signal; the composer tree was measured, the message list was not | Composer only |
| Apple Mail | WebKit viewer, separate compose window | The viewer window behind the compose window | The whole message body regardless of scroll, quoted history included | Compose only |
| Notion | Electron | Same window | Page blocks as text; most of a page | No |
| Bear | Native custom editor | Same window | The whole note from one `AXValue` | No |

The follow-ups if the spike finds an app that exposes nothing useful are a
per-app adapter through Apple Events (Mail's scripting dictionary returns the
selected message in full, and Scribe already holds the entitlement) and a
screenshot with on-device OCR through the Vision framework. Neither is in
this release unless the spike says one of the seven needs it.

### 6.3 Size

The three blocks together are capped at a configurable size (default
40,000 characters, roughly 10,000 tokens), selection first, copied text
second, screen text last and trimmed from the least relevant window. The
model is told when a block was truncated. Dictation-length instructions plus
a long thread are well inside any current model's context.

The clipboard is never modified by reading it. Insertion still saves and
restores it on the paste fallback, as today.

## 7. The model call

### 7.1 Provider shape

```swift
public protocol TextAssistant: Sendable {
    var displayName: String { get }
    func respond(to request: AssistRequest) async throws -> AssistResponse
}

public struct AssistRequest: Sendable {
    public var instruction: String            // transcribed utterance
    public var selectedText: String?          // AXSelectedText of the focused field
    public var copiedText: String?            // clipboard, only when it changed since the last request
    public var screenText: [WindowText]       // per visible window of the frontmost app, focused first
    public var truncated: Bool
    public var applicationName: String?       // frontmost app, e.g. "Mail"
    public var locale: String                 // for the reply language default
}
```

`AssistResponse` carries the text to insert and, for the indicator, the model
name and a usage line. The coordinator only knows this protocol; the account
type and the HTTP details live in `Modules/Assist`.

### 7.2 Prompt

One fixed system prompt, editable under an "Advanced" disclosure for people
who want a house style:

> You are a writing assistant working inside a text field in the app
> *{application}*. The user has spoken an instruction. You are given, when
> available, the text they selected, text they just copied, and the text
> visible in the app's windows. Prefer the selection, then the copied text,
> then the screen; treat the screen text as what the user is reading, not as
> something to edit, unless the instruction says otherwise. Do exactly what
> the instruction asks and return **only the text to insert**: no preamble,
> no explanation, no code fences unless the user asked for code, no quoting
> of the original unless asked. If the instruction asks for a reply, write
> the reply in the user's voice, in the language of the instruction, without
> a subject line. If the instruction is not about any of the text, still
> answer it.

Then the input blocks, delimited so the model cannot mistake one for another
and omitted when empty:

```
<selected_text>
…
</selected_text>

<copied_text>
…
</copied_text>

<screen_text app="Mail" truncated="false">
<window title="Re: Thursday" focused="true">
…
</window>
<window title="Inbox – 1,204 messages">
…
</window>
</screen_text>

<instruction>
…transcript…
</instruction>
```

The application name matters more than it looks: "reply to this" in Mail and
in Slack want different registers. It comes from
`NSWorkspace.shared.frontmostApplication?.localizedName`, which the
coordinator already reads.

### 7.3 ChatGPT subscription through the Codex sign-in (the subscription route)

This is the part of the proposal that needs a feasibility spike before it is
committed to, because it rests on OpenAI tolerating it rather than documenting
it. The mechanism, as the Codex CLI (`codex-rs/login`) implements it:

- **Sign-in.** OAuth 2.0 authorization code with PKCE against
  `https://auth.openai.com/oauth/authorize` and `/oauth/token`, with Codex's
  public client id (`app_EMoamEEZ73f0CkXaXp7hrann`, a constant in
  `codex-rs/login/src/auth/manager.rs`), scopes `openid profile email
  offline_access api.connectors.read api.connectors.invoke`, and a loopback
  redirect on `http://127.0.0.1:1455/auth/callback`. There is also a
  **device-code** variant (`codex login --device-auth`, present in the
  0.157.1 build on this Mac, documented as beta): the client POSTs to
  `auth.openai.com/api/accounts/deviceauth/usercode` and receives a
  `device_auth_id` and a short `user_code`; the person enters the code at an
  OpenAI page in any browser; the client polls `…/deviceauth/token` at the
  interval the server gives, for up to fifteen minutes, until it receives an
  authorization code and PKCE pair, which it exchanges at `/oauth/token`
  with the redirect `auth.openai.com/deviceauth/callback`. The device flow
  is what Scribe should show: it needs no local HTTP listener, works from a
  menu-bar app, and reads as a deliberate, revocable pairing.
- **Tokens.** The exchange returns an `id_token`, an `access_token` (a JWT)
  and a `refresh_token`. The `id_token` carries an
  `https://api.openai.com/auth` claim with `chatgpt_account_id` and
  `chatgpt_plan_type`. Codex stores all three plus the account id in
  `~/.codex/auth.json` and refreshes (`grant_type=refresh_token`, refresh
  tokens rotate) when the access token's `exp` is within five minutes or the
  last refresh is more than eight days old; `refresh_token_expired`,
  `refresh_token_reused` and `refresh_token_invalidated` mean sign in again.
  The source pins no absolute access-token lifetime, so Scribe refreshes on
  the same rule rather than on an assumed TTL.
- **Request.** `POST https://chatgpt.com/backend-api/codex/responses` with
  `Authorization: Bearer <access_token>`, `chatgpt-account-id: <account id>`,
  an `originator` header, `Accept: text/event-stream`, and a Responses-API
  body: `model`, `instructions`, `input` items, and the two values the
  backend insists on, `store: false` and `stream: true`. Current Codex has
  moved its primary transport to WebSockets (`OpenAI-Beta:
  responses_websockets=2026-02-06`) and keeps SSE as a fallback, so the SSE
  path is the one to build and the one most likely to drift. Only the
  ChatGPT-login models are accepted: at the time of writing the GPT-6
  family (Astra, Sol, Luna), GPT-5.5 (retiring 2026-10-14) and GPT-5.4 Mini,
  varying by plan; the `gpt-5` / `gpt-5-codex` names are already gone, which
  is why the model list must come from the provider at runtime rather than
  be hard-coded. Usage counts against the plan's Codex limits (a rolling
  five-hour window and a weekly cap, shared with Codex and ChatGPT Work),
  and exhaustion comes back as a 429 with a reset time.
- **The catch: `originator`.** Codex sends `originator: codex_cli_rs`. The
  backend is reported (pi issue #1828, March 2026) to return 403 for any
  value outside a server-side allowlist said to contain `codex_cli_rs`,
  `codex_vscode`, `codex_sdk_ts` and names beginning with `Codex`. That list
  is not in the open-source client and cannot be verified except by trying.
  Every third-party tool that uses this route today (OpenCode, pi, Cline,
  OpenClaw, the `SignInWithCodex` Swift package) passes by identifying as a
  Codex client.

What Scribe would build:

- `ChatGPTSession` (actor): `beginDeviceSignIn()` returns the user code and
  verification URL for the settings sheet, then polls; `accessToken()`
  refreshes on Codex's rule (within five minutes of `exp`, or eight days
  since the last refresh); `signOut()` deletes the Keychain items.
  Tokens go in the **Keychain** (`kSecClassGenericPassword`, service
  `co.cooperativ.scribe.chatgpt`), never in UserDefaults and never in
  `~/.codex/auth.json`, which belongs to Codex. The account id and plan are
  cached in settings for display.
- `ResponsesClient`: one method that streams a Responses request and
  concatenates `response.output_text.delta` events into the final text. The
  same client serves the API-key provider with a different base URL and no
  account header, so it is written once.
- `ChatGPTAssistant: TextAssistant` glues them and maps errors: 401 → sign in
  again; 429 → "ChatGPT usage limit reached, resets at …"; 403 (the
  `originator` gate, or a plan without Codex) → "Not available for this
  account". A model-list endpoint call at sign-in fills the picker and is
  cached; a stale cached model gets a clear "no longer offered" error rather
  than a silent fallback.
- `pmanot/SignInWithCodex` (Swift 6, macOS 14+, MIT) already implements the
  browser flow, Keychain storage, refresh, model discovery and the streamed
  `backend-api/codex` call. It is small and experimental (its own README
  warns that accounts "can be rate-limited, flagged, or banned"), so it is a
  reference to read rather than a dependency to add, but it proves the whole
  path in Swift.

Why the device flow rather than reading Codex's own `auth.json`: sharing a
credential file with another program is fragile (Codex rotates and rewrites
it, and a refresh from Scribe could invalidate Codex's copy or the reverse),
it forces the person to install and log in to Codex first, and it makes
Scribe's behaviour depend on a file format OpenAI can change without notice.
A device-code pairing that Scribe owns is the same amount of code and is
honest about what is happening.

Where OpenAI stands, as far as it can be read today:

- Nothing in the Codex repository or the Codex docs licenses or forbids
  non-Codex clients; the docs describe only "ChatGPT sign-in" and "API key".
- The OpenAI Terms of Use forbid circumventing "rate limits or restrictions"
  and "protective measures". Whether identifying as a Codex client to pass an
  originator gate is such a circumvention is an open question nobody has
  tested.
- The Codex lead at OpenAI said publicly in May 2026 that about ten percent
  of Codex production traffic comes through the pi and OpenCode harnesses,
  and that people "can use your ChatGPT account in a flourishing set of
  other tools"; OpenAI's Codex-for-open-source page names OpenCode, Cline,
  pi and OpenClaw approvingly. That is tolerance stated in public, not a
  licence, and it can change.
- A February 2026 feature request for an official "bill my ChatGPT plan"
  option for third-party apps is open with no commitment. "Sign in with
  ChatGPT" for third parties is an identity flow only.
- No evidence was found of OpenAI blocking any of these tools by client id.
  The only enforcement observed is the originator 403.

Anthropic, for contrast, wrote the opposite rule into its Claude Code legal
page and enforced it in February 2026, which is why a Claude subscription
route is off the table entirely.

What the spike has to establish (objective 1 in section 12):

1. That the device-code endpoints accept a request from a non-Codex client
   and return the documented token shape.
2. Which `originator` values the Responses endpoint accepts, in this order:
   an honest `scribe`; a `Codex`-prefixed value that still names Scribe (the
   reported allowlist accepts the prefix); and, last, the verbatim Codex
   value. Only the first two are values Scribe could ship without the PM
   deciding otherwise (question 1 in section 13).
3. Whether a plain "rewrite this" request with no tools is accepted on the
   Codex path, and the latency to first token and to completion for a
   typical email reply on the tester's plan.
4. The exact 429 body, the model-list response, and whether the SSE
   fallback is still served. The findings decide whether 7.3 ships as the
   default, ships behind a "use my ChatGPT sign-in (experimental, unofficial)"
   label, or is dropped in favour of 7.4.

### 7.4 Alternatives and fallbacks

| Route | Auth work | Cost to the person | Latency | Terms | Verdict |
| --- | --- | --- | --- | --- | --- |
| **7.3 Codex device sign-in** | Device flow + Keychain + refresh (~400 lines) | Included in ChatGPT Free/Plus/Pro/Business | ~1–3 s to first token | Undocumented for third parties; publicly tolerated for coding harnesses; gated by `originator` | Primary, pending the spike and question 1 |
| **OpenAI API key** | Paste key into settings, Keychain | Pay per token (a reply costs well under a cent on `gpt-5-mini`) | Same | Fully supported | Ship alongside 7.3 from day one; it is the same client with a different base URL |
| **`codex exec` subprocess** | None: reuses whatever `codex login` did | Included | ~3–6 s (process start, agent loop) | Codex's own client makes the call with its own originator, so unarguable | The clean subscription route if 7.3 is refused or feels wrong; reuses `AgentToolLocator`; needs `codex` installed and signed in |
| **Anthropic API key** | Same shape as OpenAI | Pay per token | Same | Fully supported; the subscription sign-in is explicitly forbidden | Follow-up, see 7.5 |
| **Local model (Apple Foundation Models, MLX)** | None | Free | 2–10 s on Apple Silicon, quality well below | Fully offline | Follow-up; the `TextAssistant` protocol leaves room |

The recommendation is to build the API-key provider unconditionally, run the
spike, and then build 7.3 as an opt-in path labelled "experimental,
unofficial" if the spike passes with an originator the PM is willing to send.
If it does not, `codex exec` is the subscription route: slower, and it needs
the Codex CLI installed, but it is Codex itself making the call.

### 7.5 Adding a second provider later

Because the coordinator only sees `TextAssistant`, another provider is a new
type in `Modules/Assist` plus a row in the picker. Anthropic's Messages API
is a one-file client behind an API key. A Claude subscription sign-in is not
an option: Anthropic's Claude Code legal page says third parties may not
offer Claude.ai login or route requests through Pro/Max credentials, and
OpenCode removed exactly that in February 2026 after legal requests.

## 8. Insertion

The answer goes through `DictationTextInserter` with a second shaping rule.
`DictationTextShaper.shape` was written for a dictated sentence: it may
capitalise the first letter after a full stop and add a leading space. A
generated reply is often several paragraphs and must keep its own line breaks
and its own capitalisation, so the inserter gets an
`insertGenerated(_:)` entry point that trims outer whitespace, applies the
leading-space rule only when the field's preceding character is not
whitespace and the text is a single line, and otherwise inserts verbatim.
Multi-line text works on both paths today: `AXSelectedText` accepts newlines
and the paste fallback pastes them.

Insertion is **once, at completion**, not streamed. Streaming partial text
through AX means many `AXSelectedText` writes, each of which the Electron
matrix shows may silently fail, and the paste fallback cannot append to a
paste it already made. The person is told the model is working (section 9)
and the answer appears in one piece, typically a second or two after they
release the key.

When the person had a selection, insertion **replaces** it, on both paths:
setting `AXSelectedText` replaces the selected range, and a posted ⌘V
replaces the selection in every app. So "make this shorter" edits in place
with no extra rule, and "reply to this" with nothing selected inserts at the
caret.

The target field is captured at key-down and re-checked before insertion, as
dictation does; if the person moved away the text still follows focus and the
indicator says so.

## 9. The indicator

The same panel, with a mode label so the two gestures never look alike:

| State | Dictation today | Assistant |
| --- | --- | --- |
| listening | level meter | level meter plus **"Assistant"** and a one-line hint naming the sources: "Using your selection", "Using copied text and what is on screen in Mail", or "Using what is on screen in Slack" |
| transcribing | "Transcribing…" | "Transcribing…" |
| thinking (new) | — | "Asking ChatGPT…" with the model name; Cancel control stays live and aborts the request |
| inserted | "Inserted" (app name if focus moved) | same |
| error | message | message; 429 shows the reset time; 401 offers "Sign in" which deep-links to the settings section |

Escape during *thinking* cancels the HTTP task through the existing
generation counter; nothing is inserted. The start and stop sounds are
reused; a third short cue on *inserted* is optional and off by default.

## 10. Settings

A new **Assistant** section in the Dictation tab (it shares the model,
permissions and microphone rows) with its own `SettingsSection.assistant`
deep link:

- **Enable Assistant** toggle, off by default, with the sentence: "Sends the
  instruction you speak, your selection or copied text, and the text visible
  in the front app's windows to the account below. Audio never leaves your
  Mac, and nothing is kept."
- **Assistant key** picker from the list in 5.1, greying out the dictation
  key, with the detection hint row. The Dictation section's picker gains the
  same list and greys out the assistant key.
- **Account**: a segmented choice of *ChatGPT account* / *OpenAI API key*.
  ChatGPT shows *Sign in…* which opens a sheet with the user code, a *Copy
  code* button and *Open openai.com*; on success it shows the email or plan
  and *Sign out*. API key shows a secure field and a *Test* button.
- **Model** picker filled from the provider's model list at sign-in (for
  ChatGPT, whatever the plan offers: the GPT-6 family, GPT-5.5, GPT-5.4
  Mini at the time of writing), defaulting to **GPT-6 Luna (light)** when
  the list contains it and to the first listed model otherwise.
- **Result**: *Insert into the focused field* (default) / *Copy to clipboard
  only*.
- **Sources**: three toggles, all on by default: *Selection*, *Copied text*,
  *Text on screen*. Turning off *Text on screen* returns the feature to the
  copy-first behaviour for people who want the narrower exposure.
- **Advanced** disclosure: system prompt editor with *Reset*, source size
  cap.

`ScribeSettings` gains `scribe.settings.assistant.*` keys for the enable flag,
key, provider choice, model, result mode, cap and prompt. Tokens and the API
key are Keychain-only; settings hold nothing secret.

## 11. Permissions and privacy

No new macOS permissions: the trigger and insertion use the Accessibility
grant, the microphone grant already exists, and outbound HTTPS needs nothing
under the hardened runtime without a sandbox. `Scribe.entitlements` is
unchanged.

What changes is the README's promise. Today it says dictation "does not send
dictated audio or text anywhere". That stays true for dictation. The
Assistant section of the README and the settings sentence say exactly what
is sent (the instruction, the selection, copied text when it is new, and the
text visible in the front app's windows, per request), where (the chosen
account), and what is not (audio never; pixels never; other apps never;
nothing stored; `store: false` on every request so OpenAI's API does not
retain it either, subject to their policy for subscription traffic). The
indicator's mode label and its source hint are part of that promise: a
person can always see which gesture they made and what it read.

Reading window text widens what leaves the machine compared with a copied
paragraph: an inbox list, a sidebar of other conversations. The mitigations
are that only the frontmost app is read, secure fields and their subtrees
are never read, the *Text on screen* toggle turns it off, and the source
hint names it every time. Wispr Flow reads the screen and takes screenshots
by default on its own cloud; Scribe reads text only, on the person's own
account, and says so.

Secure Keyboard Entry blocks both triggers alike, and the existing handling
covers it. The Keychain items are per-user and are removed on *Sign out*.

## 12. Objectives

Proposed objectives for this mission, in order. Each is one agent prompt.

1. **Feasibility spike, two halves** (harness only, in `Tools/`, like
   `docs/feasibility/*`). *Sign-in*: a throwaway Swift command that runs the
   device-code flow against OpenAI's endpoints, stores nothing, and makes one
   Responses request with a thread-sized prompt. Record: whether the flow
   works from a non-Codex client, which `originator` values are accepted
   (honest, `Codex`-prefixed, verbatim), whether SSE is still served, the
   model-list response, latency to first token and completion on the
   tester's plan, and the exact 429 shape. *Window text*: a read-only probe
   that, for each of Messages, WhatsApp, Signal, Slack, Mail, Notion and
   Bear, walks the front app's window trees and records character yield per
   window, element count, wall time, whether the reply case finds the source
   (Mail's viewer window behind the compose window), and whether the
   selection reads; it logs counts and timings, never contents. Output:
   `docs/feasibility/chatgpt-signin.md` and
   `docs/feasibility/assistant-window-text.md`, with a go / label / no-go
   for 7.3 and a per-app verdict for 6.2. The API-key path is exercised by the same harness
   so objective 3 has a known-good request body either way.
2. **Second trigger and settings**: the five new keys and the Fn+⌃ chord in
   `DictationActivationKey` and the monitor's flag handling;
   `DictationTriggerMonitor` routing two keys to two `DictationTriggerState`s
   with intent-tagged events and synthetic-event tests (hold, double-tap,
   cross-key chord cancel, the chord's synthetic down/up in both orders,
   Escape); `ScribeSettings` assistant keys with the distinct-key rule and
   load-time normalisation; the two greying pickers; the Assistant section
   with the key picker and detection row; `syncTriggerMonitors` in
   `ScribeAppEnvironment`. Everything else in the section is disabled until
   objective 3.
3. **`Modules/Assist`**: `TextAssistant`, `AssistRequest`, the prompt builder
   with tests; `ResponsesClient` with a streaming parser tested against
   recorded SSE fixtures; `KeychainStore`; `OpenAIKeyAssistant`; and, if
   objective 1 said go, `ChatGPTSession` (device flow, refresh, sign-out) and
   `ChatGPTAssistant`. The account rows and model picker in Settings, with
   the sign-in sheet.
4. **Sources, coordinator, insertion and indicator**: `SourceTextCollector`
   with the selection read, the clipboard `changeCount` rule and the
   Accessibility window reader (budget, skip rules, Electron switch, noise
   trimming, cap) with tests against a fake AX client; intent on
   `DictationTriggerEvent` and `DictationState`; gathering at key-down
   concurrent with capture; the *thinking* state and cancellation of the
   in-flight request; `insertGenerated` shaping with tests; indicator mode
   label, source hint and states; error mapping (401 → Sign in link, 429 →
   reset time); sounds.
5. **Polish and QA**: README section, settings copy, an end-to-end pass over
   the seven priority apps (Messages, WhatsApp, Signal, Slack, Mail, Notion,
   Bear) with a reply from screen text, an edit of a selection, and a rewrite
   of copied text in each; packaging and notarisation check; `codex exec`
   fallback only if objective 1 turned 7.3 down.

Follow-ups outside this mission: a screenshot-with-local-OCR source for apps
that expose no text; a Mail adapter through Apple Events for full threads; a
diff-and-undo preview when a selection is replaced (Wispr Flow's Transforms
have one); a Claude API-key provider; a local model provider; named
instruction presets ("Reply", "Shorten") on their own keys; the last answer
kept for one "redo with a different instruction".

## 13. Questions for the PM

1. **Terms risk on the ChatGPT sign-in.** Are you comfortable shipping a
   subscription route that OpenAI tolerates for coding harnesses in public
   statements but has not licensed, and, specifically, if the spike shows
   the backend only accepts a Codex `originator`, are you willing for Scribe
   to send one? The proposal builds the API-key provider alongside it either
   way, so the answer changes the default, the label and the wording, not
   the architecture; a "no" keeps `codex exec` as the subscription route.
2. **Where the answer goes**: inserted at the caret, replacing any
   selection (proposed), or offered in a preview panel with *Insert* / *Copy*
   / *Retry* first? The preview is safer for long replies and for in-place
   edits but adds a click to every use; it could be an option rather than
   the default.
3. **Window text on by default?** The proposal says yes, with a toggle,
   because the reply case is the point of the feature. The alternative is off
   by default with a first-use prompt that explains what will be read.

## 14. Risks

| Risk | Mitigation |
| --- | --- |
| OpenAI rejects non-Codex clients on the ChatGPT path, now or later, or changes the transport again | Spike first; API-key provider ships alongside; `codex exec` as the subscription fallback; the error path says "not available for this account" rather than failing quietly; the model list is fetched, not hard-coded |
| A person's ChatGPT account is flagged for third-party use | The route is opt-in, labelled unofficial, and the settings copy says so in one sentence; nothing is sent unless they hold the key |
| Plan usage limits are shared with the person's Codex work | 429 surfaces the reset time; the default model is the light GPT-6 variant |
| Two nearby modifier keys are confused | Distinct indicator label and hint; different start sound pitch is a cheap option |
| The front app's windows show something private (an inbox list, another conversation) | Only the frontmost app is read; secure fields are skipped; the listening hint names the sources; the *Text on screen* toggle; a short hold cancels without sending |
| Window walks are slow or empty in one of the seven apps | Spike measures each; the 300 ms budget bounds the cost; the other two sources still work; Apple Events and OCR fallbacks are scoped as follow-ups |
| A stale clipboard is sent by mistake | Only a clipboard that changed since the last assistant request is included |
| Left ⌥ or left ⌃ as a trigger interferes with typing | Existing chord-cancel and short-hold rules; footnote in the picker; detection row |
| Long answers fail AX insertion in Electron fields | Existing read-back and paste fallback; copy-only result as a last resort, reported in the indicator |
| A request hangs | 60 s timeout; Escape cancels; the generation counter discards late results |
| Token refresh races with Codex's own refresh | Scribe holds its own tokens from its own sign-in and never touches `~/.codex` |

## Sources

- Codex CLI login and device auth: `codex login --device-auth` (codex-cli 0.157.1, `codex login --help` on this Mac); https://learn.chatgpt.com/docs/auth ; https://learn.chatgpt.com/docs/cli/reference
- Codex login crate (browser flow, device flow, refresh, storage, JWT claims): https://github.com/openai/codex/tree/main/codex-rs/login/src ; client id and refresh rules in `auth/manager.rs`; device flow in `device_code_auth.rs`
- Codex backend base URL and transport: `codex-rs/model-provider-info/src/lib.rs`, `codex-rs/core/src/client.rs` in the same repository
- ChatGPT-login models and retirements: https://learn.chatgpt.com/docs/models ; plan limits: https://learn.chatgpt.com/docs/pricing
- Originator gating report: https://github.com/badlogic/pi-mono/issues/1828
- OpenAI public statements on third-party harnesses: https://x.com/thsottiaux/status/2058071172361998482 ; https://developers.openai.com/community/codex-for-oss ; open request for an official plan-billing option: https://github.com/openai/codex/issues/10974
- OpenAI Terms of Use: https://openai.com/policies/row-terms-of-use/
- Third-party implementations: https://github.com/pmanot/SignInWithCodex (Swift) ; https://github.com/numman-ali/opencode-openai-codex-auth ; https://github.com/vec4me/openai-codex-auth
- Anthropic's position on third-party use of Claude subscriptions: https://code.claude.com/docs/en/legal-and-compliance ; https://www.theregister.com/2026/02/20/anthropic_clarifies_ban_third_party_claude_access/
- Superwhisper modes with selected text and clipboard context: https://superwhisper.com/docs/modes
- Wispr Flow Command Mode: https://docs.wisprflow.ai/articles/4816967992-how-to-use-command-mode ; Transforms: https://docs.wisprflow.ai/articles/8068950331-how-to-use-transforms-beta ; Context Awareness: https://docs.wisprflow.ai/articles/4678293671-feature-context-awareness ; shortcuts: https://docs.wisprflow.ai/articles/2612050838-supported-unsupported-keyboard-hotkey-shortcuts
- Electron accessibility switch: https://www.electronjs.org/docs/latest/tutorial/accessibility ; Chromium on-demand accessibility: https://chromium.googlesource.com/chromium/src/+/HEAD/docs/accessibility/overview.md
- MacWhisper AI prompts: https://docs.macwhisper.com/article/14-how-to-use-the-dictation-feature
- OpenAI Responses API: https://platform.openai.com/docs/api-reference/responses
- Dictation proposal and feasibility reports in this repository: `docs/proposals/dictation.md`, `docs/feasibility/dictation-trigger.md`, `docs/feasibility/dictation-ax-matrix.md`

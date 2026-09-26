# System-wide dictation

> Implementation update (coo:1071): dictation uses AppKit event monitors and
> requires Microphone and Accessibility only. The conditional Input Monitoring
> fallback discussed below was not adopted; its throwaway probes were retired.

**Proposal (coo:1066):** Add a dictation mode to Scribe. The person holds or
double-taps the right ⌘ key in any app, speaks, and the transcribed text
lands in the field they were typing in. A small indicator
appears above that field while Scribe listens and transcribes. Transcription
reuses Scribe's existing offline Parakeet engine, kept resident so an
utterance comes back in well under a second. Everything is built on macOS
mechanisms that already exist: AppKit event monitors, the Accessibility API,
CoreGraphics event posting, AVAudioEngine, and a non-activating `NSPanel`.

This document is the proposal only. Section 13 breaks it into objectives.

**Decisions (2026-09-25):**

- The trigger is the right ⌘ key only. Holding it is push-to-talk; a double
  tap holds the mic open until the next tap. Both are always on. Other keys
  and chord shortcuts are deferred.
- No dictation history in this release. Audio and text are discarded after
  insertion.
- The model stays loaded while dictation is enabled (see 7.1 for what that
  costs), with an idle-unload option.
- If the trigger monitor turns out to need Input Monitoring, accept the second
  permission prompt rather than change the design.

## 1. Goals and non-goals

Goals:

- Work in every app that has a text field, including browsers and Electron
  apps, without any per-app integration.
- Two activation styles on the same key, both always available: **hold to
  talk** (press, speak, release) and **double-tap to hold the mic open, tap
  again to finish**.
- A dedicated **Dictation** settings tab for enabling the feature, its
  permissions, and the insertion, indicator and model options.
- An indicator anchored above the caret of the field being dictated into, so
  the person knows where the text will go.
- Fully offline, like the rest of Scribe. No audio leaves the machine.
- Latency that feels instant: text appears within about half a second of the
  release for a normal sentence.

Non-goals for the first release:

- Live word-by-word text while speaking (section 13 lists it as a follow-up).
- AI rewriting of the dictated text (MacWhisper's "prompts"). Scribe's agent
  hand-off infrastructure could power this later.
- Voice commands ("new line", "delete that").
- Choosing a different trigger key or a chord shortcut. Right ⌘ is the only
  trigger in this release; section 13 lists the rest as follow-ups.
- App Store distribution. Dictation needs Accessibility and event posting,
  which the App Sandbox forbids. MacWhisper ships dictation only in its direct
  download for the same reason. Scribe already distributes directly with
  Developer ID and notarization (`Scripts/package-app.sh`), so nothing changes.

## 2. What exists today

The survey of the repository found these reusable pieces and gaps.

| Area | Today | Reusable? |
| --- | --- | --- |
| ASR engine | Parakeet TDT 0.6B v3 (Core ML) via FluidAudio 0.15.7, inside the `TranscriptionWorker` helper process | Yes. Same model, same worker binary, new long-lived session mode. |
| Worker lifecycle | One process per job, models loaded per call, shut down after (`WorkerStageRunner.finish`, `ParakeetAdapter.transcribe`) | Needs a resident mode. Load time per call is the whole latency budget. |
| Audio capture | ScreenCaptureKit + `AVCaptureSession` writing to disk through `SessionStore` | Not suitable. Dictation needs an in-memory, low-latency mic tap. |
| Global shortcuts | Carbon `RegisterEventHotKey`, key-down only, lone modifiers rejected (`HotkeyService.swift:45`) | Keep for chord shortcuts. Cannot express "right ⌘ held" or a double-tap. |
| Shortcut UI | `ShortcutRecorderField` + `ShortcutCaptureModel` (local `NSEvent` monitor) | Not needed while right ⌘ is the only trigger. |
| Text insertion | `KeystrokeTextInserter`: clipboard + posted ⌘V, waits for modifier release, asks for post-event access (`TimestampInserter.swift`) | Yes, as the paste fallback. Needs clipboard save/restore and an Accessibility-first path. |
| Floating panel | `MeetingChipController`: borderless non-activating `NSPanel`, `.statusBar` level, all Spaces, glass capsule | Yes. Direct template for the indicator. |
| Settings | `ScribeSettingsView` tabs (General / Recording / Transcription), `ScribeSettings` + UserDefaults, `SettingsSection` deep links | Yes. Add a `.dictation` tab and section. |
| Permissions | `PermissionService` models Screen Recording and Microphone with revocation polling | Extend with an Accessibility pane. |
| Model install | `TranscriptionModelInstaller`; jobs wait for `.installed` | Dictation gates on the same state. |

Two facts shape the design. First, the worker already declares no networking,
no runtime downloads, and no telemetry (`Workers/TranscriptionWorker/PROTOCOL.md`),
and dictation must keep that promise. Second, the manifest benchmark reports
about 0.28 s to transcribe 12.4 s of audio once models are loaded, with a peak
of about 465 MB. That is fast enough for dictation only if the model stays
loaded between utterances.

## 3. How the comparable apps do it

| | MacWhisper Pro | Wispr Flow | Superwhisper |
| --- | --- | --- | --- |
| Trigger | Configurable hotkey; toggle or push-to-talk mode; commonly a lone modifier such as right ⌥ | Hold Fn by default; Fn+Space or **double-tap the trigger** for hands-free | Configurable; hold or toggle |
| Indicator | Floating dictation window | Small pill with "moving white bars" while recording; expands when it hears speech | Recording window with waveform, mode, Stop and Cancel; position options: **at the cursor**, screen edge, or notch; mini mode |
| Insertion | Into "whatever textbox you had open" | Inserted on release after formatting | Inserted; can capture selected text and clipboard as context |
| Engine | Local Whisper family; optional ChatGPT post-processing with per-app prompts | Cloud | Local models; live text with compatible models |
| Distribution | Direct download only (not App Store) for dictation | Direct | App Store and direct |
| Known issues | — | Secure Keyboard Entry blocks Fn+Space and Escape but not hold-to-talk; no on-screen warning | Static waveform means mic not working |

Open-source push-to-talk tools (whisper-hotkey, mac-dictate, SimpleWhisper)
converge on the same recipe: hold right ⌘ or Fn, record, transcribe locally,
paste. Two published implementation notes are worth adopting directly:

- The insertion design in the quoth project: set `AXSelectedText` on the
  focused element, **read it back** because Chromium and Electron fields report
  success without inserting, fall back to paste only when the value provably
  did not change, never read back secure fields, and use a 250 ms AX messaging
  timeout so a hung app cannot stall dictation.
- The caret-location approach: `AXFocusedUIElement` → `AXSelectedTextRange` →
  `AXBoundsForRange` gives the caret rectangle in native fields; Electron and
  browser surfaces often return a focused text element but no usable bounds,
  so fall back to the element's `AXFrame`, then the window, then the screen.
- Firekeeper's argument for `NSEvent` `flagsChanged` monitors over a
  `CGEventTap`: an observing monitor cannot swallow keystrokes if it misbehaves
  and does not need a second permission prompt. It cross-checks
  `CGEventSource.keyState` to tell press from release when the twin modifier
  is also down.

## 4. Architecture

New code lives in a `Dictation` local package (`Modules/Dictation`) plus a
small `dictate` extension to the worker. The host wiring goes in
`ScribeAppEnvironment`, next to the existing hotkey and recording setup.

```
right ⌘ down/up ──▶ DictationTriggerMonitor ──▶ DictationCoordinator (actor, main-actor facade)
                    (NSEvent flagsChanged,           │
                     state machine)                  ├─▶ DictationAudioCapture   (AVAudioEngine tap, 16 kHz mono ring buffer)
                                                     ├─▶ DictationEngine         (resident TranscriptionWorker, "dictate" op)
                                                     ├─▶ FocusedFieldLocator     (AX: focused element, caret bounds)
                                                     ├─▶ DictationTextInserter   (AX set + read-back → paste fallback → clipboard only)
                                                     └─▶ DictationIndicatorController (NSPanel above the caret)
```

State machine of one dictation:

```
idle ─(trigger)─▶ listening ─(trigger end)─▶ transcribing ─▶ inserting ─▶ done (indicator fades)
                      │                             │              │
                      └─(cancel / chord / <0.3 s)───┴──────────────┴─▶ idle, nothing inserted
```

The coordinator captures the target field at the moment listening starts,
because that is when the person's attention is on it and when the indicator
must appear. Insertion goes to the field that is focused when transcription
finishes; if focus moved, the text still follows the person, and the indicator
notes it. Dictation never touches `TranscriptionCoordinator`, the outbox, or
the processing scheduler: it is a foreground interaction, not a background
job, and must not be paused by an active recording.

## 5. Trigger detection

### 5.1 Lone modifier keys

Carbon hotkeys cannot see a modifier pressed on its own, so the trigger uses
`NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)`. Each event
carries `keyCode`, which distinguishes the two keys of each pair. Only right
⌘ (54) is used in this release, but the monitor is written against the
keycode so the others cost nothing later:

| Key | keyCode |
| --- | --- |
| Left ⌘ / Right ⌘ | 55 / 54 |
| Left ⌥ / Right ⌥ | 58 / 61 |
| Left ⌃ / Right ⌃ | 59 / 62 |
| Left ⇧ / Right ⇧ | 56 / 60 |
| Fn / 🌐 | 63 |

Press versus release is normally clear from `modifierFlags`, but not when the
twin key is also held (right ⌘ up while left ⌘ stays down leaves the command
flag set). `CGEventSource.keyState(.combinedSessionState, key:)` for the
specific keycode resolves it, the same call `KeystrokeTextInserter` already
uses for flag polling.

A global monitor is observe-only: it cannot consume the key, so the modifier
still reaches the target app. That is correct. A lone modifier press does
nothing in any app, and a chord such as right-⌘C must keep working.

**Permission.** Apple documents that global key monitors need the app to be
trusted for Accessibility, which dictation needs anyway for insertion. The
first objective verifies on macOS 27 that a `flagsChanged` monitor delivers
with Accessibility alone. If it does not, the decision is to accept a second
prompt: use a listen-only `CGEventTap` on `flagsChanged` (and `keyDown`, for
chord cancellation) with `CGRequestListenEventAccess`, isolated behind the
same `DictationTriggerMonitor` interface, and add an Input Monitoring row to
the settings tab. A listen-only tap cannot swallow keystrokes, which removes
the main hazard of event taps.

### 5.2 Hold to talk

```
down ─▶ start audio immediately (no lost first syllable)
      ─▶ after 250 ms still down: show indicator, play start tick
up   ─▶ stop audio
      ─▶ if held < 300 ms, or another key was pressed during the hold,
         or the VAD saw no speech: discard silently
      ─▶ else transcribe and insert
```

Chords are the main hazard: right-⌘C must not dictate. Three layers handle it.
A key-down during the hold cancels (if the spike shows key-down monitoring is
available under the same permission). Short holds are discarded. Finally, the
FluidAudio VAD (Silero, already in the pinned package) rejects audio with no
speech, so a 400 ms chord produces nothing even if the other layers miss it.
The indicator is delayed by 250 ms so chords never flash it.

### 5.3 Double-tap to hold the mic open, tap to finish

```
tap = down then up within 300 ms, no other key in between
two taps within 400 ms ─▶ listening (indicator shows immediately)
next tap ─▶ stop, transcribe, insert
Escape, or click ✕ on the indicator ─▶ discard
```

In this mode listening has a ceiling (default 5 minutes) and an optional
silence auto-stop (off by default), both in settings under "Advanced". A
single tap while idle does nothing, so the key still works as a modifier.

Wispr Flow supports hold and double-tap together on the same key, and the
state machine above handles both at once with no ambiguity: a hold longer
than 300 ms is a hold; two short taps open the mic. Both are always on; there
is no mode picker.

### 5.4 Why right ⌘ and what is deferred

Right ⌘ has no system binding, so nothing in macOS competes with it, and it
is the key MacWhisper users and the open-source push-to-talk tools converge
on. Fn/🌐 and double-tap ⌃ are bound to Apple's own emoji picker and
Dictation, and Caps Lock toggles, so all of those would need extra settings
notes and conflict handling. Other modifier keys and chord shortcuts (the
existing `ShortcutRecorderField` plus `kEventHotKeyReleased` in
`CarbonHotKeyRegistrar` would give chords hold-to-talk) are follow-ups in
section 13.

- **Secure Keyboard Entry** (Terminal option, password fields, 1Password)
  blocks global monitors. Scribe polls `IsSecureEventInputEnabled()` when a
  trigger is expected and none arrives, and shows "Dictation is paused while
  Secure Keyboard Entry is on" in the menu bar item and the settings tab.
  Wispr Flow gives no warning here; that is an easy place to be better.

## 6. Audio capture

`DictationAudioCapture` installs a tap on `AVAudioEngine.inputNode`, converts
to 16 kHz mono Float32 with `AVAudioConverter`, and appends to a bounded
in-memory ring buffer (5 minutes at 16 kHz is about 19 MB). It also feeds an
RMS level to the indicator. Nothing is written to disk except the short
16 kHz WAV handed to the worker (7.1), which is deleted after transcription.

It uses the system default input device, honoring the microphone Scribe's
Recording tab selects if one is set. `AVAudioEngineConfigurationChange`
restarts the engine on device changes and after sleep.

Running alongside a Scribe meeting recording is allowed: `AVAudioEngine` and
`AVCaptureSession` can share the device. Dictated audio is not added to the
meeting. Scribe's `MeetingDetector` matches only catalog bundle ids, so its own
mic use does not trigger a recording offer.

The macOS microphone indicator in the menu bar lights whenever the engine
runs. To keep it honest, the engine starts on trigger and stops on release;
it is not left running between dictations.

## 7. Transcription engine

### 7.1 Recommended: resident Parakeet in the worker

Extend the worker protocol (v2) with a persistent session:

- Launch with `--mode dictation`. The worker loads the ASR models once and
  keeps a single `AsrManager` alive. No diarization or embedding models load.
- `dictate` request: `{ "audioPath": "<16 kHz wav in the run dir>", "language": "auto" | "<bcp47>" }`
  → `stage_result` with `text` and token timings. A short WAV write is
  microseconds and keeps the existing path-based protocol and its 1 MiB record
  cap. In-memory `AsrManager.transcribe(AVAudioPCMBuffer, decoderState:)` is
  the call the worker makes.
- `warm` (load models, answer when ready) and `unload`.

The host keeps this worker alive while dictation is enabled. "Resident"
means the Core ML model weights stay loaded in the worker's memory between
dictations instead of being read from disk and compiled on every use. Loading
takes seconds; a loaded model answers in a fraction of a second. The cost is
that the worker holds about 465 MB of RAM the whole time dictation is on,
the same amount a batch transcription uses while it runs, and macOS may
compress or swap it when memory is tight. The settings tab offers **keep
loaded while dictation is on** (default) or **unload after 10 minutes idle**,
which trades a few seconds of warm-up on the first dictation after a break
for a smaller footprint. Warm load happens at launch when dictation is
enabled, and the indicator shows a "Warming up" state if a trigger arrives
first. The existing comment in `WorkerStageRunner` that a resident model
"would compete with a recording for memory" still holds for batch jobs, so
the batch worker keeps its per-job lifecycle; only the dictation worker
stays up.

Why this and not an in-process engine: crash isolation, memory accounting,
and the fact that all model-loading code, manifests, checksums, and the
no-network guarantees already live in the worker.

Parakeet TDT v3 emits punctuation and capitalization and covers 25 European
languages, so no separate punctuation model is needed. The custom vocabulary
work in `docs/decisions/custom-transcription-vocabulary.md` applies unchanged
once it lands, which matters for dictating names and product terms.

### 7.2 Alternative: Apple `DictationTranscriber`

macOS 26 added the `Speech` framework's `SpeechAnalyzer` with a
`DictationTranscriber` module (`.shortDictation`, `.progressiveShortDictation`
presets, punctuation and emoji options, volatile results). It runs on device
with a system-managed model, needs no download flow, and would give live
partial text for free. It is a real option, but not the recommendation:

- Scribe's deployment target is macOS 15, so it could only be an availability-
  gated path.
- It is not "our transcription technology"; accuracy, vocabulary boosting, and
  behavior would diverge from the transcripts Scribe produces elsewhere.
- It needs its own authorization and usage string.

It fits well as a later fallback for locales Parakeet v3 does not cover, or
for machines where the model download has not been run.

### 7.3 Streaming Parakeet EOU

FluidAudio 0.15.7 also ships `StreamingAsrManager` with the 120M
Parakeet-realtime-EOU models (160/320/1280 ms chunks) and end-of-utterance
detection. This is the path to live text in the indicator (section 13 follow-ups). It is
a smaller, less accurate model, so it should show provisional text while the
0.6B model produces the final insertion.

## 8. Text insertion

`DictationTextInserter` conforms to the existing `TextInserting` protocol and
tries, in order:

1. **Accessibility, direct.** `AXUIElementCreateSystemWide()` →
   `kAXFocusedUIElementAttribute`. Skip if the element's subrole is
   `AXSecureTextField`. Check `AXUIElementIsAttributeSettable(kAXSelectedTextAttribute)`.
   Record the value length and `AXSelectedTextRange`, set `AXSelectedText` to
   the dictated text, then **read back** up to three times over 150 ms and
   accept only if the value grew by the inserted length or the selection moved
   past it. Use `AXUIElementSetMessagingTimeout` of 250 ms on the element.
   This path leaves the clipboard untouched, which also avoids waking clipboard
   managers.
2. **Paste fallback.** Only if read-back proves the value did not change. Save
   the current pasteboard contents (all types), write the text with the
   `org.nspasteboard.TransientType` marker so clipboard managers ignore it,
   post ⌘V exactly as `KeystrokeTextInserter` does (including its wait for all
   modifiers to be up, which matters because the trigger key is itself a
   modifier), then restore the saved contents after 300 ms if `changeCount`
   shows nobody else wrote in between. Terminal, some Java apps, and
   remote-desktop clients need this path.
3. **Clipboard only.** If event posting is refused, leave the text on the
   clipboard and have the indicator say "Copied. Press ⌘V to insert." This is
   the current timestamp behavior.

The clipboard save/restore should be lifted into `KeystrokeTextInserter` so
the timestamp shortcut benefits too.

Text shaping before insertion, each a setting:

- Leading space when the character before the caret is not whitespace or a
  line start. The AX path can read that character (`AXStringForRange` on the
  range before the selection); the paste path assumes a space is needed
  unless the field is empty.
- Trailing space (off by default; on makes chained dictations flow).
- Capitalize the first letter when following sentence-ending punctuation.
- Trim Parakeet's occasional trailing whitespace and drop outputs that are
  only punctuation.

## 9. The indicator

A `DictationIndicatorController` built exactly like `MeetingChipController`:
borderless `.nonactivatingPanel`, `.statusBar` level, `canJoinAllSpaces` and
`fullScreenAuxiliary`, glass capsule, `orderFrontRegardless`. Non-activating
is essential: focus must stay in the field being dictated into.

**Placement.** At listening start, `FocusedFieldLocator` computes an anchor:

1. Caret: focused element → `AXSelectedTextRange` → `AXBoundsForRange`
   (parameterized). A zero-length range yields the caret rectangle. Place the
   capsule 8 pt above the caret line, left edge aligned to the caret x.
2. Field: the focused element's `AXFrame`. Place the capsule above the field's
   top edge, left aligned.
3. Window: the focused window's frame. Bottom center of the window.
4. Screen: bottom center of the screen with the mouse, above the Dock.

AX coordinates are top-left origin; convert with the primary screen height
and clamp inside the visible frame of the target screen. The anchor is locked
for the whole dictation; the capsule does not chase the caret while typing,
which avoids jitter and makes the read-back window quiet. AX lookups run off
the main actor with a 250 ms timeout so a slow app never delays the capsule.

**States.**

| State | Look |
| --- | --- |
| Listening | Mic glyph plus 5 level bars driven by the RMS meter, subtle pulse |
| Transcribing | Bars collapse into a shimmer; text "Transcribing…" only if it exceeds 800 ms |
| Inserted | Checkmark for 600 ms, then fade out |
| Copied | "Copied. Press ⌘V" for 3 s |
| Warming up | "Loading model…" |
| Error | One line, with a "Settings" link, 4 s |

While the mic is held open by a double tap, the capsule has a ✕ (Escape does
the same) and a Stop button. During a hold it has neither. An optional start/stop tick uses `NSSound`
system sounds, off by default. The menu bar icon shows a mic state while
listening, and the status menu gains a "Dictation: On / Off" item and a
"Dictation Settings…" item.

Settings offer indicator position **Near the text cursor** (default), **Bottom
of the screen**, or **Off**.

## 10. Settings tab

Add `SettingsTab.dictation` to `ScribeSettingsView` and
`SettingsSection.dictation` for deep links, persisted through `ScribeSettings`
under `scribe.settings.dictation.*`.

```
Dictation
├─ Enable dictation                                 [toggle]
│   Requires Microphone and Accessibility access.
│   ● Microphone: Allowed   ● Accessibility: Not allowed  [Open System Settings]
│   ● Input Monitoring: … (row shown only if the spike shows it is required)
│   ● Transcription model: Installed / [Download…]  (reuses TranscriptionModelSettingsView state)
├─ How it works (static text with key glyphs)
│   Hold right ⌘ and speak; release to insert.
│   Double-tap right ⌘ to keep listening; tap again to insert. Esc cancels.
├─ Insertion
│   [✓] Add a space before dictated text when needed
│   [ ] Add a space after dictated text
│   [✓] Restore the clipboard after pasting (used only when direct insertion is unavailable)
├─ Indicator
│   Position       [Near the text cursor ▾]
│   [ ] Play a sound when listening starts and stops
├─ Language        [Automatic ▾]   (Parakeet v3 locales)
└─ Advanced
    Keep model loaded   (•) While dictation is on  ( ) Unload after 10 minutes idle
    Double-tap speed    [400 ms slider]     Hold threshold [300 ms]
    Maximum dictation   [5 min]             [ ] Stop after 3 s of silence (mic held open)
```

Enabling the toggle triggers the permission flow: `AXIsProcessTrustedWithOptions`
with the prompt option, then polling like `PermissionService` does for the
other panes. The first-run `ScribePermissionsView` gains an optional
"Dictation" row so people who enable it during onboarding get one flow.

## 11. Permissions and privacy

| Need | Mechanism | Prompt |
| --- | --- | --- |
| Hear the trigger key | `NSEvent` global `flagsChanged` monitor | Accessibility (verify in the spike) |
| Insert text | AX `AXSelectedText`; `CGEvent` ⌘V fallback | Accessibility (same pane as today's `CGRequestPostEventAccess`) |
| Read caret position | AX parameterized attributes | Accessibility |
| Microphone | `AVAudioEngine` | Microphone (already requested) |
| Input Monitoring | Only if the spike shows the monitor needs it; then a listen-only `CGEventTap` | Input Monitoring (accepted as a second prompt) |

Add `.accessibility` to `SystemSettingsPane` with the
`x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`
deep link, and model it in `PermissionService` with `AXIsProcessTrusted()`
polling so revocation mid-session is reported the way microphone loss is.
No new entitlement is needed; the hardened runtime does not restrict AX or
event posting, and the app is not sandboxed.

Privacy rules: audio stays in memory and is dropped after insertion (the
worker's temporary WAV is deleted with it); the dictated text is never logged
and never stored; secure fields are never read; nothing leaves the machine
(the worker's no-network declaration covers the new mode). There is no
dictation history in this release.

## 12. Edge cases

- **No text field focused** (Finder desktop, a canvas): AX finds no settable
  element, paste posts ⌘V into whatever is frontmost. To avoid surprising
  pastes, if the focused element has no text role at all, go straight to
  "Copied" instead of posting ⌘V.
- **Focus changes between press and release**: insert where focus is now; the
  indicator was anchored at the original field, so it shows "Inserted in
  <App>" for that case.
- **Model not installed**: the toggle stays off with a Download button; a
  trigger shows the "Loading model" error state pointing at settings.
- **Empty or hallucinated output**: VAD gate before transcription; drop
  results that are only punctuation or under two characters.
- **Very long hold** (key stuck, sat on the keyboard): cap at the maximum
  dictation length and stop.
- **Twin modifier held** (left ⌘ down while right ⌘ tapped): keyState check
  in 5.1.
- **Karabiner or remapped keys**: the monitor sees keycode 54 only if the
  remap still delivers it. People who remap right ⌘ cannot use dictation until
  the key-choice follow-up ships; the settings tab says so if no trigger has
  ever been seen.
- **Multiple displays and full-screen apps**: panel collection behavior from
  the meeting chip; anchor clamped to the screen holding the caret.
- **Recording active**: dictation runs; the batch scheduler is not involved.
  If memory pressure is reported, the dictation worker unloads and reloads on
  the next trigger.
- **Sleep/wake, device unplugged**: engine restarts on configuration change;
  an in-flight dictation is discarded with an error state.
- **Swift 6 concurrency**: `NSEvent` monitor callbacks arrive on the main
  thread; the coordinator is `@MainActor` with the engine and locator as
  actors, matching `LiveRecordingCoordinator` / `RecordingCoordinator`.

## 13. Objectives

Proposed objectives for this mission, in order. Each is one agent prompt and
each is added to the mission in Overlord.

1. **Feasibility spike** (harness only, like `docs/feasibility/*`): confirm a
   global `flagsChanged` monitor works with Accessibility alone on macOS 27
   and reports right-⌘ (keycode 54) press and release, including with left ⌘
   held; if not, confirm a listen-only `CGEventTap` does with Input
   Monitoring. Measure resident Parakeet warm-load time and per-utterance
   latency for 3 s, 10 s and 30 s clips. Measure `AXBoundsForRange` and
   `AXSelectedText` success across TextEdit, Notes, Mail, Safari, Chrome,
   Slack, VS Code, Xcode, Terminal and a Java app. Output:
   `docs/feasibility/dictation-trigger.md`, `dictation-latency.md`,
   `dictation-ax-matrix.md`.
2. **Trigger monitor, settings and permissions**: `Modules/Dictation` package
   with `DictationTriggerMonitor` (hold and double-tap on right ⌘, chord
   cancel, twin-modifier check, secure-input detection) and synthetic-event
   unit tests; `ScribeSettings` dictation keys; the Dictation tab with
   permission rows; Accessibility (and Input Monitoring if required) in
   `PermissionService` and `SystemSettingsPane`.
3. **Resident engine**: worker protocol v2 `--mode dictation` with `warm`,
   `dictate` and `unload`; `DictationAudioCapture` (AVAudioEngine ring
   buffer); `DictationCoordinator` orchestrating trigger → capture →
   transcribe with the keep-loaded and idle-unload policies; VAD gate.
4. **Insertion**: `FocusedFieldLocator` and `DictationTextInserter` (AX with
   read-back, paste fallback, clipboard save and restore, smart spacing,
   secure-field rule); lift clipboard restore into `KeystrokeTextInserter`.
5. **Indicator**: `DictationIndicatorController` with caret anchoring, the
   state set in section 9, level meter, stop and cancel; menu bar item and
   icon state; wiring in `ScribeAppEnvironment`.
6. **Polish and QA**: onboarding row, sounds, secure-input warning, README
   and user docs, an end-to-end pass over the app matrix from the spike,
   packaging and notarization check.

Follow-ups outside this mission: choosing another trigger key or a chord
shortcut (`ShortcutRecorderField` plus `kEventHotKeyReleased`); live partial
text with the streaming EOU model; AI cleanup prompts via the agent hand-off;
voice commands; Apple `DictationTranscriber` as an alternate engine for
uncovered locales; a dictation history.

## 14. Risks

| Risk | Mitigation |
| --- | --- |
| Global monitors turn out to need Input Monitoring on macOS 27 | Spike first; listen-only `CGEventTap` behind the same interface and a second permission prompt, which is accepted |
| Electron and Chromium fields lie about AX insertion | Read-back verification; paste fallback; the QA matrix |
| 465 MB resident model on 8 GB machines | Idle unload policy; memory-pressure unload; recording still takes priority for batch jobs |
| Right-⌘ chords start listening | Delayed indicator, short-hold discard, VAD gate, key-down cancel |
| Latency feels slow on long utterances | Sounds and indicator states; streaming EOU follow-up |
| Secure Keyboard Entry silently blocks the trigger | Detect and say so |
| Right ⌘ remapped by Karabiner or similar | Settings tab notes when no trigger has been seen; key choice is a follow-up |

## 15. Questions asked and answered

The first draft asked five questions. The answers (2026-09-25) are recorded
in the Decisions block at the top: right ⌘ only with hold and double-tap both
on; no dictation history; keep the model loaded while dictation is on, with
idle unload as an option; accept an Input Monitoring prompt if the spike
shows it is required; chord shortcuts deferred.

## Sources

- MacWhisper dictation: https://docs.macwhisper.com/article/14-how-to-use-the-dictation-feature and https://www.nik.tw/post/how-to-setup-macwhisper-so-you-can-talk-to-your-computer-for-free/
- Wispr Flow shortcuts and modes: https://docs.wisprflow.ai/articles/2612050838-supported-unsupported-keyboard-hotkey-shortcuts ; first dictation: https://docs.wisprflow.ai/articles/6409258247-starting-your-first-dictation ; Secure Keyboard Entry: https://docs.wisprflow.ai/articles/8841649969-fix-flow-shortcuts-blocked-by-macos-secure-keyboard-entry-secure-event-input
- Superwhisper recording window: https://superwhisper.com/docs/get-started/interface-rec-window
- AX insertion with read-back and paste fallback: https://github.com/ryan-stoffel/quoth/issues/41
- Locating the caret with AX: https://dev.to/ahab_indieseek/how-to-locate-the-input-position-on-macos-and-what-it-took-to-get-it-right-3n5d
- `flagsChanged` monitor versus `CGEventTap`: https://www.creativeworksofknowledge.com/en/cwk-quests/firekeeper-quest/the-latency-war/flagschanged-not-tap/
- Open-source push-to-talk references: https://github.com/vovlov/whisper-hotkey , https://github.com/mwgo/SimpleWhisper
- Apple `DictationTranscriber` presets and options: read from the macOS 27 SDK `Speech.swiftinterface`; overview at https://developer.apple.com/videos/play/wwdc2025/277/
- `kAXBoundsForRangeParameterizedAttribute`: https://developer.apple.com/documentation/applicationservices/kaxboundsforrangeparameterizedattribute

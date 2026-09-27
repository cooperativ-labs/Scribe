# Voice Assistant QA matrix (seven apps, macOS 27)

Objective 5 of `docs/proposals/assistant.md` section 12. Run on 2026-09-27
against the working-tree build with `Tools/AssistantFeasibility` (`assistant-qa`),
a throwaway Swift command that is not part of the Xcode project. Companion to
`assistant-window-text.md`, which measured what the windows yield; this report
records what the shipped code does with it in each of the seven priority apps.

## Method

The harness runs the production code rather than a copy of it: it links
`Modules/Dictation` and calls the same `SourceTextCollector` and
`DictationTextInserter` the coordinator calls, with a stub `TextAssistant` in
place of the model so the pass needs neither an account nor a spoken
instruction. That isolates the three things the objective asks about (which
sources were found, which insertion path was used, wrong-window and empty-yield
cases) from the two that need the person (transcription of the instruction and
the model's answer), which are covered by the spoken pass below.

For each app it asks LaunchServices to bring the app forward (a command-line
process cannot activate another app on this macOS), resolves the focused
element through the same `SystemFocusedFieldAXClient` the app uses, focuses a
composer through Accessibility when the focused element is not a text field,
then runs the three cases:

1. **Reply from screen text, nothing selected.** `collect` with no clipboard,
   then `insertGenerated` of a fixed token, read back through `AXValue` (or a
   descendant's value for a web area whose root value stays empty, as Mail's
   does), then removed.
2. **In-place edit of a selection.** A seed sentence is inserted the same way,
   selected with ⇧⌘← as a person would, `collect` runs (the selection must
   read), then `insertGenerated` of a second token must replace the selection:
   the token present and the seed gone.
3. **Rewrite of freshly copied text.** The harness sets the clipboard,
   `ClipboardFreshness` must call it new, `collect` must return it, and after the
   insertion (whose paste path changes and restores the clipboard) the freshness
   rule must not call the same clipboard new again.

For Mail the harness opens a reply to the selected message with ⌘R so the
compose window is in front of the viewer, and closes it afterwards with ⌘W and
the sheet's *Delete*. Everything inserted is removed with ⌘Z, or through a
selected-range delete where undo does not reach it, and anything left behind is
reported. The log carries roles, counts, paths and timings, never the text read
or, beyond the harness's own tokens, inserted.

The per-app rows below are filled from that log. The **spoken pass** column is
the person's own run of the same three cases with the real key, transcription
and model, on their ChatGPT account, in the built app.

## Observed matrix

Run at 20:52–21:20 on 2026-09-27 with all seven apps open on the person's own
conversations, pages and notes. Every app came forward and every field focused
on the first try except Notion, whose home page needed a click into a block
(the harness clicks the first text area when the focused element is not a text
field, as a person would). Gather times are the `collect` wall time including
the window walk; insert times run from `insertGenerated` to the read-back.

| App | Focused element | Reply: sources found (gather) | Insert path (time) | Edit: selection read → replaced | Copied: found → freshness after insert | Wrong window or empty yield | Spoken pass |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Messages | `AXTextField`, value unreadable while empty, selection reads | screen: focused window 672 chars (224 ms) | paste (667 ms first, ~330 ms after); `AXSelectedText` not settable | ✓ 29 chars → ✓ replaced | ✓ 104 chars → not new again | none | ✓ all three |
| WhatsApp | `AXTextArea`, value unreadable while empty, selection reads | screen: 1,974 chars (278 ms) | paste (350–480 ms); not settable | ✓ 29 → ✓ | ✓ → ✓ | none; one walk hit the 300 ms budget (`truncated`) | ✓ all three |
| Signal | `AXTextArea`, value reads, selection reads | screen: 5,202 chars (121 ms) | paste (490 ms): `AXSelectedText` settable but the direct write is a no-op, read-back sends it to paste | ✓ 30 → ✓ | ✓ → ✓ | none | ✓ all three |
| Slack | `AXTextArea` (plain composer) or `AXComboBox` (composer with a draft) | screen: 1,655–1,786 chars (43–63 ms) | paste (520 ms); settable but a no-op, as for Signal | ✓ 29 → ✓ in the text-area state; in the combobox state ⇧⌘← read 0 chars and ⌘Z did not undo the paste (the harness removed its text through AX) | ✓ → ✓ | in the combobox state the composer reported a 9-char selection with nothing chosen by the harness (a draft's own selection, seen by the window-text spike hours earlier too) | ✓ all three |
| Apple Mail | `AXWebArea` (reply body), value 0, selection range unreadable | focused compose window 642 chars **and the viewer behind it 5,913–8,976 chars** (309 ms, budget hit) | paste (360 ms); the token lands in a descendant, root value stays empty | first run: **selection not found** (`AXSelectedText` and the range both unreadable) though paste replaced it; after the fix below: ✓ 29 chars through `AXSelectedTextMarkerRange` → ✓ replaced | ✓ → ✓ | none: the reply case reads the message being answered from the viewer window | not run (harness only) |
| Notion | `AXTextArea` block (`AXApplicationGroup` subrole) once a page is open; nothing focusable on the home page | screen: 2,007–2,810 chars (60–350 ms) | paste (470–560 ms); settable but a no-op | first run: `AXSelectedText` unreadable on a 118-char block; after the fix: ✓ 29 chars → ✓ replaced | ✓ → ✓ | home page: `collect` yields text but there is no field to insert into (the indicator would say "Nothing to work with" only if the yield were empty; here it copies the answer instead) | ✓ all three |
| Bear | `AXTextArea` note body, value reads, selection reads, settable | screen: 297–391 chars (308–318 ms, budget hit: the sidebar and note list are walked last) | **Accessibility** (15–60 ms), the only app of the seven on the direct path | ✓ 69 chars (the seed plus the line it joined) → ✓ | ✓ → ✓ | none | not run (harness only) |

Across the seven: `ClipboardFreshness` called the harness's clipboard new
exactly once per case, the paste path restored the copied sample every time,
and the hint read "Using your selection / copied text / what is on screen in
App" as section 9 specifies. Nothing was left in any field; the Mail reply
draft was discarded through the close sheet's *Don't Save*.

## What the pass found and what changed

1. **Mail's selection was invisible to the collector.** WebKit's web area
   answers neither `AXSelectedText` nor `AXSelectedTextRange` (the dictation
   matrix saw the same), so an in-place edit in a Mail reply would have sent the
   instruction with no `selected_text` block while the paste still replaced the
   selection: the model would have answered blind and the person would have
   lost their selection. A probe showed the selection is exposed through the
   text-marker attributes (`AXSelectedTextMarkerRange` then
   `AXStringForTextMarkerRange`), which Chromium fields answer as well.
   `SystemFocusedFieldAXClient.selectedText(of:)` now tries `AXSelectedText`,
   then `AXSelectedTextRange` with `AXStringForRange`, then the marker range,
   and `SourceTextCollector` reads through it. Mail then found the 29-char
   selection and Notion's non-empty block did too. The protocol default keeps
   the fake client in the tests unchanged.
2. **Slack's combobox composer** (the state it takes with a draft) can report a
   selection the person did not just make. It is the composer's own state, not
   a stale read, and the person sees it highlighted, so it is left as is; the
   listening hint names "your selection" whenever one is sent.
3. **Notion's home page** has no field; the answer goes to the clipboard with
   "Copied. Press ⌘V", which is the existing rule for a non-text focus.
4. **Budget.** Mail and Bear hit the 300 ms window budget, as the window-text
   spike predicted; the reply source was still complete in Mail's case because
   the focused window takes only half the budget when another window follows.

## Spoken pass

Run by the person at 21:05–21:35 on the working-tree build, signed in with
their own ChatGPT account, with the real key, transcription and model:

- **Sign-in.** The device-code card showed the code; *Copy*, the OpenAI page
  and the poll all worked; the pane then showed the plan and account, and the
  model list loaded. The list offered `gpt-6-luna` (shown as "GPT-6-Luna") and
  no separate "light" entry, so the default rule chose `gpt-6-luna`.
- **The route is open.** The first Responses request on
  `chatgpt.com/backend-api/codex` with the verbatim `codex_cli_rs` originator
  and Scribe's own User-Agent returned an answer, which was inserted. The
  honest and Codex-prefixed originator values were not tried in this run
  (the sign-in spike never ran them either); the constant stays verbatim with
  that note, and the `codex exec` fallback stays out.
- **Apps.** All three cases worked, spoken, in Messages, WhatsApp, Signal,
  Slack and Notion, and in Overlord as an extra Electron app. Mail and Bear
  were covered by the harness only; their insertion paths and sources are the
  rows above.
- **Sign in link and 401 state.** Before signing in, the held key showed
  "Sign in to ChatGPT to use Voice Assistant." with the *Sign in* link, and the
  link opened the Voice Assistant pane. A real 401 was not provoked.

Two things the live run hit that are not the assistant's code:

1. **The development build's helper aborted at launch**
   ("unable to find bundle named TranscriptionWorker_TranscriptionWorkerSupport"),
   so the first spoken request failed before any HTTP call. `Scripts/build-app.sh`
   copied the worker executable without its SwiftPM resource bundle, which
   `Scripts/package-app.sh` does copy; the script now copies it too.
2. **Accessibility and Microphone read as denied** for the Debug build although
   System Settings showed Scribe on: tccd logged "Failed to match existing code
   requirement", the rows being bound to the release build's signature.
   `tccutil reset Accessibility com.scribe.app` (and Microphone) and a re-grant
   fixed it. Re-signing the Debug build also made the Keychain ask before each
   token read; `ChatGPTSession` now reads the item once per launch and keeps
   the tokens in the actor (`testTheKeychainIsReadOncePerLaunch`), so the
   worst case is one prompt per launch, and the notarised app, whose Developer
   ID requirement is stable across updates, never prompts.

## Error paths and the Sign in link

- **401.** `ChatGPTAssistant` maps a 401 to `AssistError.signInRequired` after
  one refresh attempt (`testAssistantRefreshesOnceOn401ThenSucceeds`,
  `testAssistantReportsSignInAfterASecond401`), the three terminal refresh
  codes sign out (`testEachTerminalRefreshCodeSignsOut`), and the coordinator
  turns it into `DictationState.signInRequired` with the message "Sign in to
  ChatGPT again to use Voice Assistant." (`testErrorsMapToIndicatorStates`).
  The indicator shows that message with a *Sign in* link that calls
  `openAssistantSettings`, which `AppDelegate` routes to
  `settingsFocus.request(.assistant)`; `SettingsTab(containing:)` maps
  `.assistant` to the Assistants tab (`testAssistantSectionOpensTheAssistantsTab`)
  and the tab selects the Voice Assistant segment before scrolling. The same
  state is shown, with the same link, when the key is held with no account set
  up ("Sign in to ChatGPT to use Voice Assistant."). The link itself was not
  clicked in this run: the release build was running as the person's own
  instance and the harness pass does not go through the indicator. It is the
  first step of the spoken pass, before signing in, together with a real 401
  after a sign-out from another device if the person wants one.
- **429.** The ChatGPT backend's body (`Fixtures/chatgpt-429.json`) and the
  API's (`Fixtures/api-429.json`) are parsed for the reset time, with the
  `x-codex-primary-reset-after-seconds` and `retry-after` headers as the
  fallback, into `usageLimitReached(resetsAt:)`, shown as "ChatGPT usage limit
  reached. It resets at 3:45 PM." (or "…on Tue at 3:45 PM" when it is not
  today). A live 429 needs a plan at its limit and was not provoked.
- **403** shows "Voice Assistant is not available for this ChatGPT account."
  This is also the state a closed route would produce; see below.

## Entitlements

`Scribe/App/Scribe.entitlements` needs no change: the trigger and insertion use
the Accessibility grant, the microphone entitlement already exists for
dictation, outbound HTTPS needs nothing under the hardened runtime without the
App Sandbox, and the Keychain items under `co.cooperativ.scribe.chatgpt` and
`co.cooperativ.scribe.openai` are ordinary generic-password items that need no
keychain-access-groups entitlement outside the sandbox. Confirmed by reading
the file and the notarised build below, which launched and stored and read a
Keychain item.

## Packaging and notarisation

`mise run package` with `Scripts/release-inputs.local.env`, run at 16:40 on
2026-09-27 from the working tree with the assistant code in it:

- The Release archive built, the helpers, FFmpeg dylibs and `scribe-mcp` were
  embedded and signed, and the app was signed with the Developer ID identity
  under the hardened runtime with the unchanged entitlements: `codesign
  --verify --deep --strict` reported "valid on disk" and "satisfies its
  Designated Requirement". Nothing the assistant added (Keychain items,
  outbound HTTPS, the second trigger key) needed an entitlement.
- Notarisation did not complete: `notarytool submit` stopped with "No Keychain
  password item found for profile: scribe-notary". The profile is the one that
  produced `dist/Scribe-0.2609271346.0-macos.zip` at 15:51 the same day, so the
  item exists; notarytool keeps it in the data-protection keychain, which is
  unreadable while the screen is locked, as it was during this run.
- Repeated at 20:58 with the screen unlocked: the same build was submitted,
  `notarytool` reported "status: Accepted", `stapler staple` and `stapler
  validate` passed ("The staple and validate action worked!"), and the
  notarized archive was written to `build/release/distribution/Scribe.zip`.
  `dist/` was not touched; that is `mise run release`'s job.

## The `codex exec` fallback

Section 7.4's `codex exec` fallback was to be added only if OpenAI's route was
found closed. The spoken pass answered it: the first request on the person's
ChatGPT account went through with the verbatim originator, so the fallback is
left out. "Voice Assistant is not available for this ChatGPT account." on
every request after a successful sign-in would be the sign to revisit it.

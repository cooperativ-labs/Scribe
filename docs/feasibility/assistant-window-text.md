# Assistant window-text feasibility (Accessibility, macOS 27)

Spike for `docs/proposals/assistant.md` section 6.2, objective 1 of section 12.
Run on 2026-09-27 with `Tools/AssistantFeasibility` (`window-text-probe`), a
throwaway Swift command that is not part of the Xcode project. Companion to
`dictation-ax-matrix.md`, which measured the focused field; this report measures
what the rest of the front app's windows yield as source text.

## Method

The probe is a plain command-line process run from a shell that already holds
Accessibility trust (`AXIsProcessTrusted()` true). For each app it asks
LaunchServices to bring the app forward (a command-line process cannot activate
another app itself on this macOS), waits 1.5 s, then:

1. Resolves the focused element through the system-wide element, falling back to
   the application element, and rejects it if it belongs to another process.
   Records its role, subrole, whether `AXValue` and `AXSelectedText` read, and the
   selected range length. Counts only; never contents.
2. Resolves the focused element's window (`kAXWindowAttribute`), then the app's
   other windows (`kAXWindowsAttribute`), skipping minimised ones, focused window
   first.
3. Walks each window's `kAXChildrenAttribute` depth first with a 250 ms messaging
   timeout per element, reading role, subrole, value, title, description and
   children in **one** `AXUIElementCopyMultipleAttributeValues` call per element.
   Text is taken from static text, text areas and fields, headings, links,
   buttons, web areas, cells and rows; the focused field's own value is skipped;
   secure fields and their subtrees are skipped; menus and scroll bars are
   skipped; strings under 4 characters are dropped unless headings; identical
   strings are counted once ("filtered chars").
4. Records the element count and filtered characters at the moment the section
   6.2 budget (4,000 elements or 300 ms) is crossed, then keeps walking to a hard
   cap (15,000 elements or 4 s) so the report can say whether the budget is
   tight. Tables, outlines and lists are cut to their first 40 rows and walked
   after their siblings.
5. For Electron apps sets `AXManualAccessibility` on the application element and
   polls the focused window every 100 ms (up to 2.5 s) until a text-bearing
   element appears.

Passes 1 and 2 ran before the person had opened content; passes 3 and 4 are the
measurements below. Pass 5 measured Bear with a note that contains text; pass 6 measured Signal with
a conversation open and Mail with a reply window in front of the viewer.

## Three things the reader must handle that the proposal did not anticipate

- **The application element as a "window".** When WhatsApp, Slack or Bear had no
  window open, `kAXWindowsAttribute` returned an array whose single entry was the
  application element itself, and its children contained the application element
  again. A naive walk looped 15,000 elements deep in 3 s. The reader must drop
  any listed window equal to the application element, skip `AXApplication` below
  the root, and keep a visited set.
- **One round trip per attribute is too slow for WebKit and AppKit tables.**
  With six separate `AXUIElementCopyAttributeValue` calls per element, Mail's
  viewer walked 360 elements in 4 s and Bear's window 427 elements in 4 s. Reading
  the six attributes in one `AXUIElementCopyMultipleAttributeValues` call cut Mail
  to 538 elements in 2.2 s and Bear to 251 elements in 0.6 s. The production
  reader should use the batched call.
- **List rows dominate.** Mail's message list exposed 34,325 rows through
  `kAXChildrenAttribute` and Bear's note list 946. Capping each table, outline or
  list at 40 rows and walking lists after their siblings is what makes the
  message body reachable inside the budget. `kAXVisibleRowsAttribute` is the
  better production choice where a table supports it.

## Observed matrix

Budget column: elements / filtered chars at the moment 300 ms or 4,000 elements
was crossed, or "not reached" when the whole walk finished inside the budget.

| App | Stack | Focused element | Selection reads | Windows walked | Elements | Filtered chars | Largest text | Walk time | At budget | Verdict for 6.2 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Messages | Native | `AXTextField` (composer), value unreadable when empty, `AXSelectedText` reads (0) | ✓ | 1 | 34 | 791 | 268 (`AXStaticText`) | 33–84 ms | not reached | **Go.** Visible bubbles with sender names; only the rows on screen are in the tree, as expected. |
| WhatsApp | Native (Catalyst) | `AXTextArea` (composer), value unreadable when empty, `AXSelectedText` reads (0) | ✓ | 1 | 92 | 1,589 | 106 (`AXStaticText`) | 157–214 ms | not reached | **Go, but slow per element** (about 2 ms each even batched). Message rows come through as static text with four headings. |
| Signal | Electron | `AXTextArea` (composer), value reads (8 chars), `AXSelectedText` reads (0) | ✓ | 1 | 175–609 | 133–2,320 | 235 (`AXStaticText`) | 43–52 ms | not reached | **Go.** With a conversation open (pass 6) the visible messages read as static text; the tree appears about 180 ms after the manual-accessibility switch. |
| Slack | Electron | Pass 3: a toggle button; pass 4: `AXComboBox` with 15-char value, 9 chars selected | ✓ (9 chars) | 1 | 334–666 | 875–2,468 | 205 (`AXStaticText`) | 30–91 ms | not reached | **Go.** The message list yields the visible conversation; tree ready 170 ms after the switch. |
| Apple Mail | WebKit viewer, separate compose window | `AXWebArea` (viewer in pass 3; reply body in pass 6), root `AXValue` empty as in the dictation matrix | range unreadable on the web area | 2–3 | 83 + 530 + 55 | 940 + 12,481 + 27 (pass 6) | 1,001 (`AXStaticText`) | 21 ms + 2,035 ms + 130 ms | 264 / 8,221 at 312 ms (viewer) | **Go with the row cap.** Reply case confirmed: the focused compose window yields only its own quoted text (940 chars) and the message being answered sits in the viewer window behind it (12,481 chars, 8,221 of them inside the 300 ms budget). |
| Notion | Electron | Pass 3: `AXButton` on the home page; pass 4: none reported while a page was open | not measured | 1 | 107–1,206 | 513–3,184 | 332 (`AXTextArea`) | 19–107 ms | not reached | **Go.** Page blocks are text areas; most of a page reads in about 100 ms once the tree is exposed (150 ms after the switch). |
| Bear | Native custom editor | `AXTextArea` (note body) when a note is open; `AXTable` (note list) when none is | ✓ (0 in an empty note) | 1 (+ a small dialog) | 251–280 | 347–424 | 39 (`AXTextArea`, the note body of a short note) | 577–746 ms | 184–192 / 266–271 at 303 ms | **Go.** The note body reads as one `AXValue` from the window walk (pass 5, note with text, body not focused); the sidebar and note list are the noise and the cost. |

Per-element cost after batching, from the walks above: Slack 0.09 ms, Notion
0.09 ms, Signal 0.25 ms, Messages 1–2.5 ms, WhatsApp 1.7 ms, Bear 2.3–2.7 ms,
Mail 4 ms. The Electron apps are an order of magnitude cheaper to walk than the
native ones because Chromium serves the whole tree from a cache once it is built.

## What this means for section 6.2

- **Budget.** 300 ms is generous for Messages, WhatsApp, Signal, Slack and Notion
  (all finish inside it) and tight but workable for Mail and Bear, where the
  content area is reached first only if lists are walked last and capped. Keep
  300 ms and 4,000 elements; add the batched attribute read, the row cap and the
  lists-last ordering to the rules.
- **Skip rules.** No secure fields were met in the seven apps; the rule is cheap
  and stays. Add: drop any window equal to the application element, skip
  `AXApplication` below the root, keep a visited set, and skip `AXMenu`,
  `AXMenuBar` and `AXScrollBar` subtrees.
- **Electron switch.** Setting `AXManualAccessibility` returned success in
  Signal, Slack and Notion, and each tree exposed text within 150–180 ms. A fixed
  400 ms wait is not enough on the first request in every case (pass 2 saw only
  opaque groups in Signal and Notion); poll for a text-bearing element instead,
  up to about 2 s, as the locator already does for the focused field.
- **Noise.** Dropping strings under 4 characters and repeats removed 5–60 % of
  raw characters (Notion the most: 8,548 raw to 3,184 filtered).
- **Selection.** `AXSelectedText` read in Messages, WhatsApp, Signal, Slack and Bear; it
  is unreadable on Mail's web area and on Slack's toggle button, so the reader
  must treat an unreadable selection as "no selection" rather than an error.
- **Other windows.** Mail is the only app of the seven with a second content
  window. In the reply case the mechanism (walk `kAXWindowsAttribute` after the
  focused window) found the viewer behind the compose window and read the
  message being answered from it; the compose window itself contributed only the
  quoted text. A third Mail window (an older empty compose window) cost 130 ms
  and yielded nothing, so the per-window budget should be split with the focused
  window and the largest non-focused window taking priority. Bear's second window
  was a small dialog and yielded nothing, which is the right outcome.
- **Focus resolution.** The system-wide focused element resolved in every app
  once it was frontmost (0–56 ms); the app-element fallback was not needed in
  these passes. Twice an app reported not frontmost after activation (Notion in
  pass 4, Bear in pass 5) yet its window still walked normally, so the reader
  should key on the pid it was asked about rather than on `frontmostApplication`.

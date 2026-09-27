# Plugins Directory submission

Everything needed to submit Scribe to OpenAI's public Plugins Directory, in the
order the submission portal asks for it. Rules checked against OpenAI's
[submission guide](https://developers.openai.com/plugins/deploy/submission),
[MCP server review requirements](https://developers.openai.com/plugins/deploy/app-review),
[plugin guidelines](https://developers.openai.com/plugins/app-guidelines) and
[submission checks](https://developers.openai.com/plugins/deploy/submission-errors)
as of 27 September 2026.

## What only a person can do

These steps need an account owner, a legal decision, or a recording. Everything
else is built, deployed and tested.

| # | Step | Where | Blocks |
|---|------|-------|--------|
| 1 | Verify the publisher identity **Cooperativ Labs** (business, or individual if there is no registered entity) in the OpenAI Platform. The name must match the listing's developer name, the website and the privacy and terms pages. If the verified name differs, set `SCRIBE_PUBLISHER` on the relay and rebuild the package with the same name in `PUBLISHER` (scripts/chatgpt-package.js). | platform.openai.com → Settings → Organization → Verification | Opening the submission form |
| 2 | Give the submitting user the **Apps Management** write role (`api.apps.write`, `api.apps.read`). | platform.openai.com → Settings → Roles | Creating the draft |
| 3 | Choose the contact address and set it on the relay: `railway variables --set SCRIBE_CONTACT_EMAIL=<address> --service relay`. Until it is set, the pages send people to GitHub issues, which is weak for privacy requests. | Railway | Review (the listing needs a real support contact) |
| 4 | Have someone qualified review /privacy and /terms. They describe exactly what the code does, but are not written by a lawyer: governing law, the liability cap and entity details are decisions for the publisher. Edit `src/legal.js` and redeploy. | scribe.ovld.ai/privacy, /terms | Your own risk sign-off |
| 5 | Paste the domain-verification token from the MCP tab into the relay: `railway variables --set OPENAI_APPS_CHALLENGE=<token> --service relay` (this redeploys), then press Verify. | Portal → MCP tab | Submission |
| 6 | Record the demo video (next section) and host it at a public URL (YouTube unlisted, Loom, etc.). | Any video host | Submission |
| 7 | Read the reviewer code and paste it into the portal's credentials field: `railway variables --service relay --kv \| grep SCRIBE_REVIEWER_CODE`. Do not commit it: the repository is public. | Portal → MCP / Testing tab | Review |
| 8 | Press **Scan Tools**, paste the annotation justifications below, fill in the remaining tabs, accept the policy attestations, and submit. After approval, choose when to publish. | Portal | — |

## Info tab

| Field | Value |
|-------|-------|
| Plugin name | Scribe |
| Short description (≤30) | Summarize your Scribe meetings |
| Long description | As `longDescription` in the packaged plugin.json (built by `npm run package -- --url https://scribe.ovld.ai/mcp`). |
| Developer identity | Cooperativ Labs (verified; step 1) |
| Category | Productivity |
| Logo | `assets/logo.png` (512×512 PNG). Composer icon: `assets/icon.png` (128×128). |
| Website | https://scribe.ovld.ai/ |
| Support | https://scribe.ovld.ai/support |
| Privacy policy | https://scribe.ovld.ai/privacy |
| Terms | https://scribe.ovld.ai/terms |
| Demo recording | The video from step 6 |

## MCP tab

| Field | Value |
|-------|-------|
| Server URL type | Universal |
| MCP server URL | `https://scribe.ovld.ai/mcp` |
| Authentication | OAuth 2.1 with PKCE. Discovery at `/.well-known/oauth-protected-resource` and `/.well-known/oauth-authorization-server`. ChatGPT identifies itself with its Client ID Metadata Document (`https://chatgpt.com/oauth/client.json`); dynamic registration also works. Scope `transcripts.read`. |
| Reviewer credentials | On the Scribe consent page, type the reviewer code in the **Scribe link code** field and press Allow transcript access. It opens a demo library of five fictional meetings. It is reusable, needs no Mac, no MFA, no email or SMS, and works from any network. |
| Content Security Policy | The transcript widget fetches nothing: connect domains none, resource domains none, frame domains none. |
| Domain verification | Challenge base URL `https://scribe.ovld.ai`. The relay serves the token at `/.well-known/openai-apps-challenge` as plain text (step 5). |

The MCP origin (`https://scribe.ovld.ai`) cannot change between versions, so keep
this domain for the life of the listing.

### Tool annotations and justifications

Every tool has `readOnlyHint: true`, `destructiveHint: false`, `openWorldHint: false` (and `idempotentHint: true`).

| Tool | Justification |
|------|---------------|
| `scribe_recent_transcripts` | Read-only: lists meeting metadata (title, date, duration, speakers) from the connected user's own Scribe library and changes nothing. Not destructive: it has no write path. Closed world: it reads one private library bounded by the OAuth grant, never the public internet. |
| `scribe_search_transcripts` | Read-only: literal text search over the connected library, returning matching meetings with a short excerpt. No state changes, no side effects. Closed world: bounded to the one library the user approved. |
| `scribe_get_transcript` | Read-only: returns one transcript's text with speaker labels and timestamps, paged. Cannot edit or delete. Closed world: the user's own library only; transcript IDs from any other library return "not found". |
| `search` | Read-only research alias of search, returning IDs, titles and `scribe://` URIs. Same bounds as above. |
| `fetch` | Read-only research alias of `scribe_get_transcript`. Same bounds as above. |
| `scribe_profile` | Read-only: returns an opaque, stable identifier for the connected library, so ChatGPT can tell two connected Scribe libraries apart (`openai/profile`). Contains no personal data. |

Data minimization: results carry meeting data only (titles, dates, durations,
language, speaker names, excerpts, transcript text). They never include owner or
account IDs, tokens, file paths, audio, or request/trace IDs. `processed_at` and
`revision` are kept on purpose: the assistant needs them to page through long
transcripts consistently, and ordering by processing time is disclosed in the
tool description. Everything returned is disclosed in the privacy policy.

## Skills tab

Upload the skill bundle from the submission archive
(`dist/packages/submission/scribe-0.1.0.zip`, built by the package command). It
holds one skill, `scribe-transcripts`, which tells the assistant when to list,
search and page through transcripts, and to cite titles and timestamps.

## Prompts tab

1. Summarize my most recent Scribe meeting with decisions and action items.
2. Search my Scribe transcripts for what we decided about the launch date.
3. List the action items and owners from my Scribe meetings this week.

Screenshots (706 px wide, one per prompt, in order) are in `docs/listing/`:
`1-recent-meeting.png`, `2-search-launch-date.png`, `3-this-weeks-meetings.png`.
They show the transcript widget rendering the demo library's real tool output.

## Testing tab

All cases use the reviewer demo library. Its dates are relative to today, so
"this week" and "most recent" hold for as long as the review runs. The same
cases run at the tool level in `test/directory.test.js`.

### Positive cases

**P1.** *Summarize my most recent Scribe meeting with decisions and action items.*
- Expected behavior: `scribe_recent_transcripts` (limit 1), then `scribe_get_transcript` for "Q4 launch planning" (one page, `next_offset` null).
- Expected result: the decisions are that launch moves to the second Tuesday of next month and that pricing changes wait until after launch (about 02:44). Action items: Tom Okafor merges the payment retry fix by Friday; Priya Raman delivers the menu editor empty state by Monday; Maya Chen sends release notes to Luis Ortega by Wednesday of next week; Luis writes support macros; staged rollout, and Tom owns the rollout switch (about 04:01). Timestamps are cited.
- Account: reviewer demo library.

**P2.** *Search my Scribe transcripts for what we decided about the launch date.*
- Expected behavior: `scribe_search_transcripts` (for example query "launch date" or "launch"), then `scribe_get_transcript` for "Q4 launch planning".
- Expected result: the launch moved to the second Tuesday of next month, not the first, to give time for the payment retry fix and a week for support. Cites Maya Chen at about 01:58 and 02:44. It may note that "Support team sync" mentions the date only in passing.
- Account: reviewer demo library.

**P3.** *List the action items and owners from my Scribe meetings this week.*
- Expected behavior: `scribe_recent_transcripts` with `after` about seven days ago, then `scribe_get_transcript` for each of the three meetings.
- Expected result: grouped by meeting. From Q4 launch planning, as in P1. From the Weekly design review, Priya updates the spec today and tags Sam Whitaker. From the Lakeside Bakery interview, Maya emails Hannah Lee the pilot sign-up tomorrow. Older meetings (budget review, support sync) are excluded.
- Account: reviewer demo library.

**P4.** *What did Hannah from Lakeside Bakery say was her biggest problem?*
- Expected behavior: `scribe_search_transcripts` ("Hannah" or "Lakeside"), then `scribe_get_transcript` for "Customer interview: Lakeside Bakery".
- Expected result: when the Wi-Fi drops, the tablet stops taking orders and customers wait while she restarts the router (about 00:31). It may also mention croissants selling out while still orderable, and small order numbers on receipts.
- Account: reviewer demo library.

**P5.** *What did we decide in the design review about receipts?*
- Expected behavior: `scribe_search_transcripts` ("receipt" or "design review"), then `scribe_get_transcript` for "Weekly design review".
- Expected result: receipts put the order number at the top in large type, and item names are truncated at forty characters because thermal printers cut off wider lines. The full name stays in the app. Cites about 01:19–02:01.
- Account: reviewer demo library.

### Negative cases

**N1.** *Delete the budget review transcript from Scribe.*
- Expected behavior: no tool call changes anything. The assistant says the Scribe connection is read-only and that transcripts can be deleted in the Scribe app on the Mac.
- Rationale: the plugin exposes no write or delete tool by design. Deletion stays with the owner in Scribe.

**N2.** *Play me the audio recording of the customer interview.*
- Expected behavior: the assistant explains that Scribe shares transcripts only, not audio, and offers to summarize or quote the Lakeside Bakery transcript instead.
- Rationale: audio never leaves the Mac. No tool returns recordings or file paths.

**N3.** *Search every Scribe user's meetings for mentions of Lakeside Bakery.*
- Expected behavior: the assistant searches only the connected library, or explains that it can see only the library the user connected. It never claims access to other users' transcripts.
- Rationale: each OAuth grant is bound to one library. No tool input can name another library, and IDs from another library return "not found".

## Global tab

All countries and regions where ChatGPT plugins are offered. Scribe itself needs
macOS 15 or later on Apple silicon, and Parakeet's languages are European, but
nothing in the plugin is regional.

## Submit tab: release notes

> Initial submission of Scribe 0.1.0. Scribe for Mac records and transcribes meetings on the user's Mac. This plugin lets ChatGPT list, search and read those transcripts, read-only, through the Scribe relay at scribe.ovld.ai: the Mac connects out to the relay, and each OAuth connection is bound to the one library whose owner approved it with a one-time link code from the Scribe app.
>
> For review, no Mac is needed: on the consent page, type the reviewer code (in the credentials field) where it asks for a Scribe link code. It opens a demo library of five fictional meetings, with dates relative to today, and can be reused on every surface. Tools: scribe_recent_transcripts, scribe_search_transcripts, scribe_get_transcript, search, fetch, scribe_profile, all read-only. No audio, no write actions.

## Rebuilding the package

```bash
cd Integrations/scribe
npm run package -- --url https://scribe.ovld.ai/mcp
# dist/packages/chatgpt: marketplace + plugin, for Developer Mode installs
# dist/packages/submission/scribe-0.1.0.zip: the archive the portal takes
```

Packaging fails if the plugin breaks any of the directory's limits: names and
short description up to 30 characters, at most 3 unique starter prompts of up to 128
characters, all four listing URLs over HTTPS, a supported category, square PNG
logos of 48–4096 px, and brand-color contrast. Bump `VERSION` in
scripts/chatgpt-package.js for every resubmission; the MCP origin must stay the same.

## Operating the demo library

- `SCRIBE_REVIEWER_CODE` on the relay turns it on (at least 20 characters). Unset, the demo library does not exist.
- The code reaches only the synthetic meetings in `src/demo.js`. Its owner ID is not a UUID, so no Mac can register as it. It cannot be used as a Mac's agent secret, and a real link code never reaches it.
- It is reusable, and up to 2,000 demo connections can be live at once (30-day refresh tokens). Changing the variable stops new demo connections, but existing ones keep reading the synthetic library. To end them all, unset the variable: every demo token then fails. Either way nothing real is exposed, so this matters only if the code leaks and fills the demo slots.
- Edit the meetings in `src/demo.js`. The submission's expected results quote them, and `test/directory.test.js` fails if the two drift apart.

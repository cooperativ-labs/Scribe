// The browser pages of the OAuth consent step: the request itself, and the pages a
// failed or expired request ends on. They carry no script (the CSP forbids it) and
// use the same tokens as the Scribe site and the Mac app, in light and dark.
import { ICON_PATH } from './brand.js';

export const escape = value => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const LOOPBACK = ['127.0.0.1', 'localhost', '[::1]'];

// Where the browser goes after the decision, named the way a person recognizes it.
export function destination(redirectUri) {
  const url = new URL(redirectUri);
  return LOOPBACK.includes(url.hostname) ? 'the app on this computer' : url.hostname;
}

const STYLE = `
:root { color-scheme: light dark;
  --ground: #F5F5F7; --panel: #FFFFFF; --text: #1D1D1F; --secondary: #6E6E73; --hairline: rgba(0,0,0,.12);
  --fill: rgba(29,29,31,.06); --accent: #007AFF; --accent-text: #FFFFFF; --field: #FFFFFF; --ring: rgba(0,122,255,.28);
  --good: #248A3D; --no: #C93400; --shadow: 0 1px 2px rgba(0,0,0,.04), 0 12px 32px rgba(0,0,0,.08); }
@media (prefers-color-scheme: dark) { :root {
  --ground: #15112A; --panel: #1E1938; --text: #F5F5F7; --secondary: rgba(245,245,247,.62); --hairline: rgba(255,255,255,.12);
  --fill: rgba(245,245,247,.07); --accent: #0A84FF; --field: #262046; --ring: rgba(10,132,255,.36);
  --good: #30D158; --no: #FF9F0A; --shadow: 0 12px 40px rgba(0,0,0,.4); } }
* { box-sizing: border-box; }
body { margin: 0; min-height: 100vh; display: grid; place-items: center; padding: 32px 16px; background: var(--ground); color: var(--text);
  font: 14.5px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", system-ui, sans-serif; -webkit-font-smoothing: antialiased; }
main { width: 100%; max-width: 440px; background: var(--panel); border: .5px solid var(--hairline); border-radius: 20px; padding: 32px 28px 24px; box-shadow: var(--shadow); }
.pair { display: flex; align-items: center; justify-content: center; gap: 12px; margin-bottom: 22px; }
.pair img, .pair .client { width: 52px; height: 52px; border-radius: 12px; }
.pair .client { display: grid; place-items: center; background: var(--fill); border: .5px solid var(--hairline); font-size: 22px; font-weight: 600; color: var(--secondary); }
.pair .link { display: flex; gap: 4px; } .pair .link i { width: 4px; height: 4px; border-radius: 50%; background: var(--hairline); }
.solo { display: block; width: 56px; height: 56px; border-radius: 13px; margin: 0 auto 20px; }
h1 { font: 600 21px/1.25 -apple-system, BlinkMacSystemFont, "SF Pro Display", "Helvetica Neue", system-ui, sans-serif; letter-spacing: -.015em; text-align: center; margin: 0 0 6px; text-wrap: balance; }
.lede { text-align: center; color: var(--secondary); margin: 0 0 22px; text-wrap: balance; }
ul.scope { list-style: none; margin: 0 0 22px; padding: 4px 14px; background: var(--fill); border-radius: 12px; font-size: 13.5px; }
ul.scope li { display: grid; grid-template-columns: 18px 1fr; gap: 10px; padding: 8px 0; }
ul.scope li + li { border-top: .5px solid var(--hairline); }
ul.scope svg { width: 16px; height: 16px; margin-top: 2px; }
.yes svg { color: var(--good); } .no svg { color: var(--no); }
label.code { display: block; font-size: 13px; font-weight: 600; margin-bottom: 6px; }
input[name=link_code], input[name=owner_key] { display: block; width: 100%; font: 500 22px/1.2 ui-monospace, "SF Mono", Menlo, monospace; letter-spacing: .12em; text-align: center; text-transform: uppercase;
  padding: 12px 14px; color: var(--text); background: var(--field); border: .5px solid var(--hairline); border-radius: 10px; outline: none; }
input[name=owner_key] { font-size: 16px; letter-spacing: normal; text-transform: none; text-align: left; }
.error { font-size: 13px; color: var(--no); background: var(--fill); border-radius: 10px; padding: 9px 12px; margin: 0 0 14px; }
input[aria-invalid=true] { border-color: var(--no); }
input:focus { border-color: var(--accent); box-shadow: 0 0 0 3px var(--ring); }
input::placeholder { color: var(--secondary); opacity: .5; }
.hint { font-size: 12.5px; color: var(--secondary); margin: 8px 0 0; }
details { margin: 14px 0 0; font-size: 13px; }
summary { cursor: pointer; color: var(--accent); width: fit-content; }
details ol { margin: 8px 0 0; padding-left: 20px; color: var(--secondary); } details li { margin: 4px 0; } details strong { color: var(--text); font-weight: 600; }
.actions { display: flex; flex-direction: column; gap: 8px; margin-top: 24px; }
button { font: inherit; font-size: 15px; font-weight: 600; line-height: 1; padding: 13px 18px; border-radius: 999px; border: 0; cursor: pointer; text-align: center; text-decoration: none; }
button.allow { background: var(--accent); color: var(--accent-text); }
button.deny { background: transparent; color: var(--secondary); font-weight: 500; }
button:hover { filter: brightness(1.06); } button.deny:hover { color: var(--text); }
button:focus-visible, summary:focus-visible { outline: 2px solid var(--accent); outline-offset: 3px; }
.return { text-align: center; font-size: 12px; color: var(--secondary); margin: 14px 0 0; overflow-wrap: anywhere; }
`;

const check = '<svg viewBox="0 0 16 16" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" d="m3.5 8.5 3 3 6-7"/></svg>';
const cross = '<svg viewBox="0 0 16 16" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" d="m4.5 4.5 7 7m0-7-7 7"/></svg>';

function page(title, body) {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark"><meta name="robots" content="noindex"><title>${escape(title)}</title>
<link rel="icon" href="${ICON_PATH}" type="image/png"><style>${STYLE}</style></head><body><main>${body}</main></body></html>`;
}

// `relay` asks for a one-time link code from the Mac; a self-hosted bridge asks for its owner key.
export function consentPage({ clientName, redirectUri, request, relay, error }) {
  const client = clientName || 'An MCP client';
  const initial = [...client.trim()][0]?.toUpperCase() ?? '?';
  const alert = error ? `<p class="error" id="consent-error" role="alert">${escape(error)}</p>` : '';
  const invalid = error ? ' aria-invalid="true" aria-describedby="consent-error"' : '';
  const credential = relay
    ? `${alert}<label class="code" for="link_code">Link code from Scribe</label>
<input id="link_code" name="link_code" placeholder="XXXXX-XXXXX" autocomplete="one-time-code" autocapitalize="characters" autocorrect="off" spellcheck="false" maxlength="64" required autofocus${invalid}>
<p class="hint">On your Mac, open Scribe → Settings → Assistants and press <strong>Get Link Code</strong>. A code works once, for ten minutes.</p>
<details><summary>No link code yet?</summary><ol>
<li>Open Scribe on the Mac that holds your transcripts.</li>
<li>In <strong>Settings → Assistants</strong>, press <strong>Connect This Mac</strong>. Keep the Mac awake while assistants use it.</li>
<li>Press <strong>Get Link Code</strong> and type the code here. Never paste it into a chat.</li></ol></details>`
    : `${alert}<label class="code" for="owner_key">Scribe owner key</label>
<input id="owner_key" type="password" name="owner_key" autocomplete="off" required autofocus${invalid}>
<p class="hint">Scribe created this key the first time its server ran. Enter it only on this page, never in a chat.</p>`;
  return page('Connect Scribe', `<div class="pair" aria-hidden="true"><span class="client">${escape(initial)}</span><span class="link"><i></i><i></i><i></i></span><img src="${ICON_PATH}" alt=""></div>
<h1>Connect ${escape(client)} to Scribe</h1>
<p class="lede">${escape(client)} is asking to read the transcripts in your Scribe library.</p>
<ul class="scope">
<li class="yes">${check}<span>Read transcript text, titles, speaker names and timestamps</span></li>
<li class="no">${cross}<span>No recording audio, and no changes to your library</span></li>
<li class="yes">${check}<span>Disconnect whenever you like from Scribe → Settings → Assistants</span></li>
</ul>
<form method="post" action="/consent"><input type="hidden" name="request" value="${escape(request)}">${credential}
<div class="actions"><button class="allow" name="decision" value="allow">Allow access</button><button class="deny" name="decision" value="deny" formnovalidate>Deny</button></div></form>
<p class="return" title="${escape(redirectUri)}">Afterwards you return to ${escape(destination(redirectUri))}.</p>`);
}

// Where a consent attempt ends when it cannot continue: say what happened and what to do next.
export function consentProblemPage(heading, detail) {
  return page(heading, `<img class="solo" src="${ICON_PATH}" alt="Scribe"><h1>${escape(heading)}</h1><p class="lede">${escape(detail)}</p>`);
}

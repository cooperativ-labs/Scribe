// Scribe's public privacy policy, terms of use and support page, served by the
// relay (scribe.ovld.ai) beside the download page. OpenAI's Plugins Directory
// requires all three at public HTTPS URLs that match the publisher, and reviewers
// compare them with what the relay actually does, so every claim here describes
// the code: relay.js (what the relay stores), auth.js (tokens and their lifetimes),
// agent.js (the Mac's outbound connection) and demo.js (the reviewer library).
//
// The publisher name and contact address come from the operator's configuration
// (SCRIBE_PUBLISHER, SCRIBE_CONTACT_EMAIL), so the pages always name the verified
// identity the listing was submitted under.

import express from 'express';

export const LEGAL_EFFECTIVE = '28 September 2026';
const REPO = 'https://github.com/cooperativ-labs/Scribe';
const escape = value => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

export function legalConfig({ host = 'scribe.ovld.ai', publisher = process.env.SCRIBE_PUBLISHER || 'Cooperativ Labs', contactEmail = process.env.SCRIBE_CONTACT_EMAIL } = {}) {
  if (contactEmail !== undefined && !/^[^\s@<>"]+@[^\s@<>"]+\.[^\s@<>"]+$/.test(contactEmail)) throw new Error('SCRIBE_CONTACT_EMAIL must be an email address.');
  return { host, publisher, contactEmail };
}

export function createLegalRouter(options = {}) {
  const config = legalConfig(options);
  const router = express.Router();
  const page = render => (_req, res) => {
    res.set({ 'Cache-Control': 'public, max-age=300', 'Content-Security-Policy': "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'" });
    res.type('html').send(render(config));
  };
  router.get('/privacy', page(renderPrivacy));
  router.get('/terms', page(renderTerms));
  router.get('/support', page(renderSupport));
  return router;
}

const contact = ({ contactEmail }, subject) => contactEmail
  ? `email <a href="mailto:${escape(contactEmail)}?subject=${encodeURIComponent(subject)}">${escape(contactEmail)}</a>`
  : `open an issue at <a href="${REPO}/issues">github.com/cooperativ-labs/Scribe/issues</a> (please leave personal details out of the public issue and ask for a private channel)`;

function shell({ title, description, heading, body }) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>${escape(title)}</title>
<meta name="description" content="${escape(description)}">
<meta name="color-scheme" content="light dark">
<link rel="icon" href="/site/icon.png" type="image/png">
<style>
:root { color-scheme: light dark; --ground: #F5F5F7; --panel: #FFFFFF; --text: #1D1D1F; --secondary: #6E6E73; --hairline: rgba(0, 0, 0, 0.12); --accent: #007AFF; }
@media (prefers-color-scheme: dark) { :root { --ground: #15112A; --panel: #1E1938; --text: #F5F5F7; --secondary: rgba(245, 245, 247, 0.62); --hairline: rgba(255, 255, 255, 0.12); --accent: #0A84FF; } }
* { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; }
body { margin: 0; background: var(--ground); color: var(--text); font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", system-ui, sans-serif; font-size: 15px; line-height: 1.6; -webkit-font-smoothing: antialiased; }
a { color: var(--accent); }
a:focus-visible { outline: 2px solid var(--accent); outline-offset: 3px; border-radius: 4px; }
.wrap { max-width: 760px; margin: 0 auto; padding-inline: 24px; }
.top { display: flex; align-items: center; gap: 10px; padding-block: 22px 0; }
.top img { width: 28px; height: 28px; }
.top a.name { font-weight: 600; color: inherit; text-decoration: none; }
.top nav { margin-left: auto; display: flex; gap: 18px; font-size: 13px; }
.top nav a { color: var(--secondary); text-decoration: none; }
.top nav a:hover, .top nav a[aria-current] { color: var(--text); }
main { padding-block: 48px 72px; }
h1 { font-size: 34px; line-height: 1.15; letter-spacing: -0.02em; font-weight: 600; margin: 0 0 8px; }
.meta { color: var(--secondary); font-size: 13px; margin: 0 0 32px; }
.summary { background: var(--panel); border: 0.5px solid var(--hairline); border-radius: 12px; padding: 16px 20px; margin: 0 0 36px; }
.summary p { margin: 0; }
.summary ul { margin: 8px 0 0; padding-left: 20px; }
h2 { font-size: 19px; letter-spacing: -0.012em; font-weight: 600; margin: 36px 0 8px; }
h3 { font-size: 15px; font-weight: 600; margin: 20px 0 4px; }
p, li { max-width: 68ch; }
ul { padding-left: 22px; }
li + li { margin-top: 4px; }
table { border-collapse: collapse; width: 100%; font-size: 14px; margin: 12px 0; }
th, td { text-align: left; vertical-align: top; padding: 8px 10px 8px 0; border-bottom: 0.5px solid var(--hairline); }
th { font-weight: 600; }
.scroll { overflow-x: auto; }
footer { border-top: 0.5px solid var(--hairline); padding-block: 20px 40px; display: flex; flex-wrap: wrap; gap: 8px 20px; font-size: 12.5px; color: var(--secondary); }
footer a { color: inherit; text-decoration: none; }
footer a:hover { color: var(--text); text-decoration: underline; }
@media (max-width: 560px) { h1 { font-size: 28px; } main { padding-top: 32px; } }
</style>
</head>
<body>
<div class="wrap">
  <header class="top">
    <img src="/site/mark.png" alt="" width="28" height="28">
    <a class="name" href="/">Scribe</a>
    <nav aria-label="Legal">
      <a href="/privacy"${heading === 'privacy' ? ' aria-current="page"' : ''}>Privacy</a>
      <a href="/terms"${heading === 'terms' ? ' aria-current="page"' : ''}>Terms</a>
      <a href="/support"${heading === 'support' ? ' aria-current="page"' : ''}>Support</a>
    </nav>
  </header>
  <main>
${body}
  </main>
  <footer>
    <a href="/">Scribe for Mac</a>
    <a href="/privacy">Privacy policy</a>
    <a href="/terms">Terms of use</a>
    <a href="/support">Support</a>
    <a href="${REPO}">Source on GitHub</a>
  </footer>
</div>
</body>
</html>
`;
}

export function renderPrivacy(config) {
  const { publisher } = config;
  return shell({ title: 'Scribe Privacy Policy', heading: 'privacy', description: 'How Scribe, the Scribe relay and the Scribe plugin for ChatGPT handle your data.', body: `
    <h1>Privacy policy</h1>
    <p class="meta">Effective ${LEGAL_EFFECTIVE}. Published by ${escape(publisher)}.</p>
    <div class="summary">
      <p><strong>In short.</strong></p>
      <ul>
        <li>Scribe records and transcribes on your Mac. Your recordings and transcripts are stored there, not on our servers.</li>
        <li>If you connect an AI assistant such as ChatGPT, transcript text passes through the Scribe relay only while it answers that assistant's request. The relay does not store or log it.</li>
        <li>The relay keeps a small amount of account data needed to route requests: random identifiers, hashed secrets and connection times. It has no names, emails or passwords.</li>
        <li>You can disconnect any assistant, or unlink your Mac entirely, from Scribe → Settings → Assistants.</li>
      </ul>
    </div>

    <h2>Who this covers</h2>
    <p>This policy covers the Scribe app for macOS, the Scribe relay service at <strong>${escape(config.host)}</strong>, and the Scribe plugin for ChatGPT and Codex (together, "Scribe"). ${escape(publisher)} ("we") publishes Scribe and operates the relay. For questions about this policy, ${contact(config, 'Scribe privacy')}.</p>

    <h2>The Scribe app on your Mac</h2>
    <p>Scribe records meetings only when you press Record, and transcribes them on your Mac with local speech models. Recordings, transcripts, speaker names you assign, and settings are stored in folders on your Mac that you control. We do not receive them. Dictation audio is held in memory and discarded once the text is inserted.</p>
    <p>The Voice Assistant is optional and off until you turn it on. When you hold its key, Scribe transcribes your spoken instruction on your Mac and sends it with the source text you enabled: selected text, recently copied text, and text visible in the front app's windows. With ChatGPT selected, Scribe sends the text to the local Codex App Server. Codex uses its managed ChatGPT sign-in, can use enabled local memories and connected tools, and returns the answer for Scribe to insert. Those tools can read information from connected services under your Codex and service permissions; some calls ask you to choose an action in Scribe. Other account choices send the text to the model provider whose API key you added, to the OpenAI-compatible endpoint you entered, or to Apple's models. Voice Assistant requests do not pass through the Scribe relay and we do not receive them. API-key requests to OpenAI are sent with storage turned off; Codex and other providers handle data under their own policies. Apple's on-device model keeps the request on your Mac. Apple Private Cloud Compute sends it to Apple, which says it does not retain the request or make it accessible to Apple. Scribe does not send audio, screenshots or password-field contents, and drops its request and answer after insertion. Codex manages its own ChatGPT credential; Scribe stores API keys in your Mac's Keychain.</p>
    <p>The app contacts the internet to download its speech models from Hugging Face when you first set it up; after that it transcribes with the network off. The download button on this site fetches the app from GitHub. Those services see your IP address under their own privacy policies. The app has no analytics or advertising trackers.</p>

    <h2>Connecting an assistant through the relay</h2>
    <p>Connecting an assistant is optional. When you choose <em>Connect This Mac</em>, your Mac opens an outbound connection to the relay; nothing on your Mac accepts incoming connections. When you then connect an assistant, you approve it on the relay's consent page by typing a one-time link code that Scribe shows on your Mac. That code ties the connection to your library and no other.</p>
    <h3>What the relay stores</h3>
    <div class="scroll"><table>
      <thead><tr><th>Data</th><th>Purpose</th><th>Kept until</th></tr></thead>
      <tbody>
        <tr><td>A random library ID, a hash of your Mac's secret, and when it was linked</td><td>Recognize your Mac and route requests to it</td><td>You unlink the Mac</td></tr>
        <tr><td>Hashes of access and refresh tokens, with the assistant's client ID, your library ID and the time you approved it</td><td>Let the connection you approved keep working, and list it for you in Scribe</td><td>Access tokens: 1 hour. Refresh tokens: 30 days without use, or until you disconnect</td></tr>
        <tr><td>Assistant registration details (client name, client ID and callback address)</td><td>Complete sign-in for that assistant</td><td>Unused registrations are removed after 7 days once space is needed</td></tr>
        <tr><td>Link codes (hashed) and pending consent requests</td><td>Approve a new connection</td><td>Memory only; 10 minutes (codes) or 5 minutes (requests), or first use</td></tr>
      </tbody>
    </table></div>
    <h3>What passes through without being stored</h3>
    <p>When an assistant asks for a list of meetings, a search, or a transcript, the relay forwards that request to your Mac and passes the answer back. The answer can include meeting titles, dates, durations, language, speaker names, short excerpts and transcript text with timestamps. The relay holds it in memory only for the few seconds this takes, and does not write it to disk or to logs. Audio never leaves your Mac, and assistants cannot change or delete anything.</p>
    <h3>Technical data</h3>
    <p>To protect the service from abuse, the relay counts requests per IP address in memory for up to one hour. Our hosting provider (Railway) and network provider (Cloudflare) process IP addresses and request metadata, such as time, path and status, to deliver and secure the service, and may keep standard server logs under their own retention policies. The relay itself does not write request logs.</p>

    <h2>How we use data, and who receives it</h2>
    <ul>
      <li><strong>To provide Scribe.</strong> We use the data above only to route requests between the assistants you approve and your Mac, to show you your connections, and to keep the service secure.</li>
      <li><strong>The assistants you connect.</strong> Transcript data goes to the assistant you approved, such as ChatGPT from OpenAI, which handles it under its own privacy policy and your settings there.</li>
      <li><strong>Service providers.</strong> Railway (hosting) and Cloudflare (DNS and network) process data on our behalf to run the relay.</li>
      <li><strong>Legal reasons.</strong> We disclose data if the law requires it. The relay does not hold your transcripts, so we cannot disclose them.</li>
    </ul>
    <p>We do not sell personal data, use it for advertising, or use your transcripts to train models.</p>

    <h2>Your controls</h2>
    <ul>
      <li><strong>Disconnect an assistant:</strong> Scribe → Settings → Assistants lists each connection with its own Disconnect button. Disconnect All revokes every one.</li>
      <li><strong>Unlink your Mac:</strong> Unlink This Mac makes the relay forget your library, its connections and any request in flight.</li>
      <li><strong>Stop sharing temporarily:</strong> quit Scribe or turn off Connect This Mac. Assistants then get an error saying your Mac is not connected.</li>
      <li><strong>Delete transcripts:</strong> delete them in Scribe or in Finder. They are removed from the only place they are stored.</li>
      <li><strong>Requests:</strong> to ask about, correct or delete data we hold, ${contact(config, 'Scribe data request')}. Because the relay has no names or emails, you may need to tell us your connection details from Scribe so we can find the right records.</li>
    </ul>

    <h2>Other people in your recordings</h2>
    <p>Transcripts contain what other people said. Scribe asks before each recording, but you are responsible for telling participants and getting any consent the law requires where you and they are, before you record or share a transcript with an assistant.</p>

    <h2>Reviewer demo library</h2>
    <p>For app-directory review, the relay can serve a demo library of fictional meetings to anyone with a reviewer code. It contains no real people or recordings, and a demo connection cannot reach any real library.</p>

    <h2>Security</h2>
    <p>All connections to the relay use HTTPS. Secrets and tokens are stored only as SHA-256 hashes. Each token is bound to one library, and the relay sends a token's requests only to that library's Mac, which checks every request again before reading anything. No system is perfectly secure; tell us about any vulnerability you find through the contact above.</p>

    <h2>Children</h2>
    <p>Scribe is not directed at children under 13, and we do not knowingly collect their data.</p>

    <h2>International transfers</h2>
    <p>The relay runs in a Railway data center in the European Union (Netherlands). Our providers may process data in other countries under their own safeguards.</p>

    <h2>Changes</h2>
    <p>We will post changes to this page and update the effective date. If a change materially affects how we handle your data, we will say so on this page before it takes effect.</p>
` });
}

export function renderTerms(config) {
  const { publisher } = config;
  return shell({ title: 'Scribe Terms of Use', heading: 'terms', description: 'Terms for using Scribe, the Scribe relay and the Scribe plugin for ChatGPT.', body: `
    <h1>Terms of use</h1>
    <p class="meta">Effective ${LEGAL_EFFECTIVE}. Published by ${escape(publisher)}.</p>
    <p>These terms apply to the Scribe app for macOS, the Scribe relay at ${escape(config.host)}, and the Scribe plugin for ChatGPT and Codex (together, "Scribe"), provided by ${escape(publisher)} ("we"). By using Scribe you agree to them. If you do not agree, do not use Scribe.</p>

    <h2>What Scribe is</h2>
    <p>Scribe records and transcribes meetings on your Mac. The relay and plugin let AI assistants you approve read your transcripts, read-only, while your Mac is connected. Scribe is provided free of charge. The app's source code is available on GitHub; any license published there governs the code itself, and these terms govern the service.</p>

    <h2>Your responsibilities</h2>
    <ul>
      <li><strong>Recording consent.</strong> Laws on recording conversations differ by place, and some require every participant's consent. You are responsible for informing participants and obtaining any consent required before you record, transcribe or share a conversation.</li>
      <li><strong>Lawful use.</strong> Do not use Scribe to record people secretly, to harass or surveil anyone, or for any purpose that breaks the law or another person's rights.</li>
      <li><strong>Your connections.</strong> Keep link codes private and approve only assistants you trust. Anyone you give a link code to can connect to your library until you disconnect them.</li>
      <li><strong>The service.</strong> Do not attack, overload, probe or attempt to get around the relay's security or limits, or try to access a library that is not yours.</li>
    </ul>

    <h2>Your content</h2>
    <p>Your recordings and transcripts belong to you. We do not claim any rights to them. The relay passes transcript data between your Mac and the assistants you approve only to provide the service, as described in the <a href="/privacy">privacy policy</a>.</p>

    <h2>Third-party assistants</h2>
    <p>ChatGPT and other assistants are provided by their own companies under their own terms. We do not control what an assistant does with transcript data you let it read, or the accuracy of summaries it writes. Check important details against the transcript.</p>

    <h2>Accuracy</h2>
    <p>Automatic transcription and speaker identification make mistakes. Do not rely on Scribe for anything where an error could cause harm without checking the recording.</p>

    <h2>Availability and changes</h2>
    <p>We may change, suspend or stop the relay or plugin at any time, and may limit or end access for anyone who breaks these terms. The app keeps working on your Mac without the relay.</p>

    <h2>Disclaimer</h2>
    <p>Scribe is provided "as is" and "as available", without warranties of any kind, express or implied, including merchantability, fitness for a particular purpose and non-infringement, to the extent the law allows.</p>

    <h2>Limitation of liability</h2>
    <p>To the extent the law allows, ${escape(publisher)} is not liable for any indirect, incidental, special, consequential or punitive damages, or for lost data, profits or revenue, arising from your use of Scribe. Our total liability for any claim about Scribe is limited to 100 US dollars. Nothing in these terms limits liability that cannot be limited by law.</p>

    <h2>Changes to these terms</h2>
    <p>We will post changes here and update the effective date. Continuing to use Scribe after a change means you accept it.</p>

    <h2>Contact</h2>
    <p>For questions about these terms, ${contact(config, 'Scribe terms')}.</p>
` });
}

export function renderSupport(config) {
  return shell({ title: 'Scribe Support', heading: 'support', description: 'Get help connecting ChatGPT and other assistants to Scribe.', body: `
    <h1>Support</h1>
    <p class="meta">Help with Scribe and the Scribe plugin for ChatGPT.</p>
    <div class="summary"><p>To reach us, ${contact(config, 'Scribe support')}. We usually reply within two business days.</p></div>

    <h2>Connect ChatGPT to Scribe</h2>
    <ol>
      <li>Install Scribe on the Mac that holds your transcripts (<a href="/download">download</a>).</li>
      <li>In Scribe → Settings → Assistants, under <strong>From anywhere</strong>, press <strong>Connect This Mac</strong>.</li>
      <li>In ChatGPT, add the Scribe plugin from the Plugins Directory and choose Connect.</li>
      <li>On the Scribe consent page, type the link code from Scribe → Settings → Assistants → <strong>Get Link Code</strong>, then press Allow transcript access.</li>
      <li>Ask ChatGPT something like "Summarize my most recent Scribe meeting".</li>
    </ol>

    <h2>Common problems</h2>
    <h3>"Your Scribe Mac is not connected"</h3>
    <p>Scribe must be open, with Connect This Mac turned on, on a Mac that is awake and online. Open Scribe and try again.</p>
    <h3>"Invalid or expired link code"</h3>
    <p>A link code works once and expires after ten minutes. Get a new one in Scribe and start connecting again from ChatGPT.</p>
    <h3>A meeting is missing</h3>
    <p>Only finished transcripts are available. A meeting that is still processing appears once Scribe finishes it.</p>

    <h2>Disconnect</h2>
    <p>In Scribe → Settings → Assistants, press Disconnect next to a connection, or Disconnect All. Unlink This Mac also makes the relay forget your library. Removing the plugin in ChatGPT stops ChatGPT from using it; disconnecting in Scribe also revokes its access on our side.</p>

    <h2>Privacy and security</h2>
    <p>Read the <a href="/privacy">privacy policy</a> for what the relay stores and what passes through it. To report a security issue, ${contact(config, 'Scribe security')}.</p>
` });
}

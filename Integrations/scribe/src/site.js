// The public page at the relay's root: what Scribe is, and one button that
// downloads the newest notarized macOS build.
//
// The relay serves it because scribe.ovld.ai is the relay's origin, and the
// relay's own routes (/mcp, /authorize, /agent, …) never use the root. The page
// is rendered on the server with no script, so the version under the button is
// right at first paint and the page needs nothing but its own inline styles.
//
// `/download` asks GitHub for the latest release and redirects to its macOS
// disk image (`Scribe-<version>-macos.dmg`). Older ZIP-only releases remain
// available as a fallback. The answer is cached for ten
// minutes; if GitHub cannot be reached the last good answer is kept, and with
// none the button falls back to the releases page.

import express from 'express';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const DEFAULT_RELEASE_REPO = 'cooperativ-labs/Scribe';
const MAC_DISK_IMAGE = /-macos\.dmg$/i;
const MAC_ARCHIVE = /-macos\.zip$/i;
const SITE_FILES = new Set(['mark.png', 'logo.png', 'icon.png']);

/// The parts of a GitHub release the page shows, or null without a macOS download.
export function releaseFromGitHub(json) {
  const assets = Array.isArray(json?.assets) ? json.assets : [];
  const uploaded = asset => (asset.state ?? 'uploaded') === 'uploaded';
  const download = assets.find(asset => MAC_DISK_IMAGE.test(asset?.name ?? '') && uploaded(asset))
    ?? assets.find(asset => MAC_ARCHIVE.test(asset?.name ?? '') && uploaded(asset));
  if (!download || typeof json.tag_name !== 'string') return null;
  const checksum = assets.find(asset => asset?.name === `${download.name}.sha256` && uploaded(asset));
  return {
    tag: json.tag_name,
    version: json.tag_name.replace(/^v/, ''),
    publishedAt: json.published_at ?? null,
    name: download.name,
    format: MAC_DISK_IMAGE.test(download.name) ? 'dmg' : 'zip',
    size: Number.isFinite(download.size) ? download.size : null,
    url: download.browser_download_url,
    checksumURL: checksum?.browser_download_url ?? null,
    notesURL: json.html_url ?? null,
  };
}

/// The newest release, asked of GitHub at most once per `ttlMs` and remembered
/// through outages. Unauthenticated GitHub allows 60 requests an hour per
/// address, which one request per ten minutes stays well inside; GITHUB_TOKEN
/// raises the limit when set.
export class ReleaseSource {
  constructor({ repo = DEFAULT_RELEASE_REPO, fetch = globalThis.fetch, ttlMs = 10 * 60_000, retryMs = 60_000, token = process.env.GITHUB_TOKEN, now = Date.now, timeoutMs = 5000 } = {}) {
    Object.assign(this, { repo, fetch, ttlMs, retryMs, token, now, timeoutMs });
    this.cached = null; this.expires = 0; this.pending = null;
  }

  get releasesURL() { return `https://github.com/${this.repo}/releases`; }
  get latestURL() { return `${this.releasesURL}/latest`; }

  async latest() {
    if (this.now() < this.expires) return this.cached;
    this.pending ??= this.#refresh().finally(() => { this.pending = null; });
    return this.pending;
  }

  async #refresh() {
    const release = await this.#fetchLatest();
    if (release) this.cached = release;
    this.expires = this.now() + (release ? this.ttlMs : this.retryMs);
    return this.cached;
  }

  async #fetchLatest() {
    try {
      const headers = { Accept: 'application/vnd.github+json', 'User-Agent': 'scribe-site', 'X-GitHub-Api-Version': '2022-11-28' };
      if (this.token) headers.Authorization = `Bearer ${this.token}`;
      const response = await this.fetch(`https://api.github.com/repos/${this.repo}/releases/latest`, { headers, signal: AbortSignal.timeout(this.timeoutMs) });
      if (!response.ok) return null;
      return releaseFromGitHub(await response.json());
    } catch {
      return null;
    }
  }
}

export function createSiteRouter(options = {}) {
  const releases = options.releases ?? new ReleaseSource(options);
  const assetsDir = options.assetsDir ?? fileURLToPath(new URL('../assets/', import.meta.url));
  const router = express.Router();
  router.get('/', async (_req, res) => {
    const release = await releases.latest();
    res.set({ 'Cache-Control': 'public, max-age=300', 'Content-Security-Policy': "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'" });
    res.type('html').send(renderSite({ release, releases }));
  });
  router.get('/download', async (_req, res) => {
    const release = await releases.latest();
    res.redirect(302, release?.url ?? releases.latestURL);
  });
  router.get('/api/release', async (_req, res) => {
    const release = await releases.latest();
    res.set('Cache-Control', 'public, max-age=300');
    res.json(release ? { ...release, download: '/download' } : { release: null, download: '/download', releases: releases.latestURL });
  });
  router.get('/site/:file', (req, res, next) => {
    if (!SITE_FILES.has(req.params.file)) return next();
    res.set('Cache-Control', 'public, max-age=86400');
    res.sendFile(path.join(assetsDir, req.params.file), { cacheControl: false }, error => { if (error && !res.headersSent) next(error.status === 404 ? undefined : error); });
  });
  return router;
}

const escape = value => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const megabytes = bytes => `${(bytes / 1_000_000).toFixed(bytes >= 100_000_000 ? 0 : 1)} MB`;
const shortDate = iso => { const date = new Date(iso); return Number.isNaN(date.valueOf()) ? null : date.toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric', timeZone: 'UTC' }); };

/// The page as HTML. `release` may be null when GitHub has not answered yet.
export function renderSite({ release, releases }) {
  const releasesURL = releases?.releasesURL ?? `https://github.com/${DEFAULT_RELEASE_REPO}/releases`;
  const repoURL = releasesURL.replace(/\/releases$/, '');
  const versionLine = release
    ? `Version ${escape(release.version)}${release.publishedAt && shortDate(release.publishedAt) ? `, released ${escape(shortDate(release.publishedAt))}` : ''}${release.size ? `. ${escape(megabytes(release.size))} ${release.format}` : ''}, notarized by Apple.`
    : 'The newest notarized build from GitHub.';
  const notesURL = release?.notesURL ?? releasesURL;
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Scribe for Mac</title>
<meta name="description" content="Scribe records and transcribes meetings on your Mac. Dictate into any app, or use Voice Assistant with ChatGPT, your own model provider, or Apple's models.">
<meta name="color-scheme" content="light dark">
<meta property="og:title" content="Scribe for Mac">
<meta property="og:description" content="Meetings and dictation stay on your Mac. Choose where optional Voice Assistant requests go.">
<meta property="og:image" content="/site/logo.png">
<link rel="icon" href="/site/icon.png" type="image/png">
<link rel="apple-touch-icon" href="/site/logo.png">
<style>
:root {
  color-scheme: light dark;
  --ground: #F5F5F7;
  --panel: #FFFFFF;
  --text: #1D1D1F;
  --secondary: #6E6E73;
  --hairline: rgba(0, 0, 0, 0.12);
  --neutral-fill: rgba(29, 29, 31, 0.06);
  --accent: #007AFF;
  --accent-text: #FFFFFF;
  --playing-fill: rgba(0, 122, 255, 0.10);
  --glass: rgba(255, 255, 255, 0.62);
  --glass-edge: rgba(0, 0, 0, 0.08);
  --glass-shadow: 0 4px 14px rgba(0, 0, 0, 0.12);
  --blue: #007AFF; --teal: #30B0C7; --orange: #FF9500; --purple: #AF52DE;
  --uncertain: #FF9500;
  --field: #FFFFFF;
}
@media (prefers-color-scheme: dark) {
  :root {
    --ground: #15112A;
    --panel: #1E1938;
    --text: #F5F5F7;
    --secondary: rgba(245, 245, 247, 0.62);
    --hairline: rgba(255, 255, 255, 0.12);
    --neutral-fill: rgba(245, 245, 247, 0.07);
    --accent: #0A84FF;
    --playing-fill: rgba(10, 132, 255, 0.14);
    --glass: rgba(46, 39, 82, 0.55);
    --glass-edge: rgba(255, 255, 255, 0.18);
    --glass-shadow: 0 4px 16px rgba(0, 0, 0, 0.32);
    --blue: #0A84FF; --teal: #40CBE0; --orange: #FF9F0A; --purple: #BF5AF2;
    --uncertain: #FF9F0A;
    --field: #262046;
  }
}
* { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; }
body {
  margin: 0;
  background: var(--ground);
  color: var(--text);
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", system-ui, sans-serif;
  font-size: 14.5px;
  line-height: 1.55;
  -webkit-font-smoothing: antialiased;
}
a { color: inherit; }
a:focus-visible, .button:focus-visible { outline: 2px solid var(--accent); outline-offset: 3px; border-radius: 6px; }
.wrap { max-width: 1040px; margin: 0 auto; padding-inline: 24px; }
.top { display: flex; align-items: center; gap: 10px; padding-block: 22px 0; }
.top img { width: 32px; height: 32px; margin-left: -3px; }
.top .name { font-weight: 600; font-size: 15px; letter-spacing: -0.01em; }
.top nav { margin-left: auto; display: flex; gap: 20px; font-size: 13px; color: var(--secondary); }
.top nav a { text-decoration: none; }
.top nav a:hover { color: var(--text); }
.hero { display: grid; grid-template-columns: minmax(0, 5fr) minmax(0, 6fr); gap: 48px; align-items: center; padding-block: 72px 88px; }
h1 { font-size: 44px; line-height: 1.08; letter-spacing: -0.022em; font-weight: 600; margin: 0 0 18px; text-wrap: balance; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Helvetica Neue", system-ui, sans-serif; }
.lede { font-size: 17px; line-height: 1.5; color: var(--secondary); margin: 0 0 30px; max-width: 34em; }
.button { display: inline-flex; align-items: center; gap: 9px; background: var(--accent); color: var(--accent-text); text-decoration: none; font-weight: 600; font-size: 15px; padding: 12px 20px 12px 16px; border-radius: 999px; }
.button svg { width: 16px; height: 16px; }
.button:hover { filter: brightness(1.06); }
.version { margin: 14px 0 0; font-size: 12.5px; color: var(--secondary); max-width: 34em; }
.version a { color: var(--secondary); }
.requires { margin: 4px 0 0; font-size: 12.5px; color: var(--secondary); }

/* The Transcripts window, drawn with the app's own tokens: flat rows, a 52px
   timecode column, capsule chips, the accent only on the playing row, and one
   glass capsule floating over the content. */
.panel { background: var(--panel); border: 0.5px solid var(--hairline); border-radius: 14px; padding: 16px 14px 18px; position: relative; overflow: hidden; }
.panel .head { display: flex; align-items: baseline; flex-wrap: wrap; gap: 6px 10px; padding: 0 8px 12px; }
.panel .head .title { font-size: 15px; font-weight: 600; letter-spacing: -0.01em; margin-right: 4px; }
.chip { display: inline-flex; align-items: center; gap: 5px; font-size: 12px; font-weight: 500; line-height: 1; padding: 5px 8px; border-radius: 999px; color: var(--secondary); background: var(--neutral-fill); white-space: nowrap; }
.chip .dot { width: 9px; height: 9px; border-radius: 50%; }
.turns { display: flex; flex-direction: column; gap: 2px; margin: 0; padding: 0; list-style: none; }
.turn { display: grid; grid-template-columns: 52px minmax(0, 1fr); gap: 0 4px; padding: 8px 12px 8px 8px; border-radius: 10px; position: relative; }
.turn .tc { font-size: 12px; color: var(--secondary); font-variant-numeric: tabular-nums; padding-top: 3px; }
.turn .who { display: flex; align-items: center; gap: 6px; font-size: 13px; font-weight: 600; margin-bottom: 1px; }
.turn .who .dot { width: 9px; height: 9px; border-radius: 50%; }
.turn .who .flag { width: 7px; height: 7px; border-radius: 50%; background: var(--uncertain); }
.turn p { margin: 0; max-width: 66ch; }
.turn.playing { background: var(--playing-fill); }
.turn.playing::before { content: ""; position: absolute; left: 0; top: 8px; bottom: 8px; width: 3px; border-radius: 2px; background: var(--accent); }
.glass { background: var(--glass); -webkit-backdrop-filter: blur(20px) saturate(1.6); backdrop-filter: blur(20px) saturate(1.6); border: 0.5px solid var(--glass-edge); box-shadow: var(--glass-shadow); }
.transport { position: absolute; left: 50%; bottom: 14px; transform: translateX(-50%); display: flex; align-items: center; gap: 12px; padding: 8px 14px 8px 10px; border-radius: 999px; font-size: 12px; font-variant-numeric: tabular-nums; color: var(--text); }
.transport .play { width: 26px; height: 26px; border-radius: 50%; background: var(--accent); display: grid; place-items: center; }
.transport .play svg { width: 11px; height: 11px; fill: var(--accent-text); margin-left: 1px; }
.transport .bar { width: 120px; height: 3px; border-radius: 2px; background: var(--hairline); position: relative; }
.transport .bar::after { content: ""; position: absolute; inset: 0 auto 0 0; width: 31%; border-radius: 2px; background: var(--accent); }
.transport .speed { color: var(--secondary); }
.panel .fade { position: absolute; left: 0; right: 0; bottom: 0; height: 64px; background: linear-gradient(to bottom, transparent, var(--panel)); pointer-events: none; }

.features { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 40px 36px; padding-block: 0 84px; border-top: 0.5px solid var(--hairline); padding-top: 56px; }
.feature h2 { font-size: 19px; line-height: 1.25; letter-spacing: -0.015em; font-weight: 600; margin: 0 0 8px; text-wrap: balance; }
.feature p { margin: 0; color: var(--secondary); max-width: 38em; }
.feature p + p { margin-top: 8px; }
.figure { height: 112px; display: flex; align-items: center; margin-bottom: 20px; }

/* The meeting chip: the floating panel that offers to record a call. */
.meeting { display: inline-flex; align-items: center; gap: 12px; padding: 8px 8px 8px 12px; border-radius: 999px; font-size: 13px; }
.meeting img { width: 20px; height: 20px; }
.meeting .record { background: var(--accent); color: var(--accent-text); font-weight: 600; font-size: 12px; padding: 6px 12px; border-radius: 999px; }
.meeting .close { width: 22px; height: 22px; border-radius: 50%; background: var(--neutral-fill); display: grid; place-items: center; color: var(--secondary); font-size: 12px; line-height: 1; }

/* A focused field mid-dictation, with the indicator beside it. */
.field { width: 100%; max-width: 300px; background: var(--field); border: 0.5px solid var(--hairline); border-radius: 8px; padding: 9px 12px; font-size: 13.5px; position: relative; box-shadow: 0 0 0 3px rgba(0, 122, 255, 0.22); }
.field .caret, .assist .caret { display: inline-block; width: 1.5px; height: 1em; background: var(--accent); vertical-align: -0.15em; margin-left: 1px; }
.field .indicator { position: absolute; right: -10px; top: -18px; display: inline-flex; align-items: center; gap: 6px; padding: 5px 10px 5px 8px; border-radius: 999px; font-size: 11.5px; font-weight: 500; }
.field .indicator .wave { display: inline-flex; align-items: center; gap: 2px; height: 12px; }
.field .indicator .wave i { display: block; width: 2px; border-radius: 1px; background: var(--accent); }
.keys { display: inline-flex; gap: 8px; margin-top: 12px; }
.key { font-size: 11.5px; font-weight: 500; color: var(--secondary); border: 0.5px solid var(--hairline); border-bottom-width: 1.5px; border-radius: 6px; padding: 3px 7px; background: var(--panel); }

/* A question put to an assistant, and where it can be asked. */
.ask { display: flex; flex-direction: column; gap: 10px; }
.ask .q { background: var(--neutral-fill); border-radius: 14px 14px 14px 4px; padding: 9px 13px; font-size: 13.5px; max-width: 300px; }
.ask .hosts { display: flex; gap: 6px; flex-wrap: wrap; }

/* The open models the pipeline runs, in the order audio passes through them. */
/* The Voice Assistant: the message on screen, the reply field it writes into,
   and the indicator while the request is out. */
.assist { border-top: 0.5px solid var(--hairline); padding-block: 56px 84px; display: grid; grid-template-columns: minmax(0, 5fr) minmax(0, 6fr); gap: 40px 48px; align-items: center; }
.assist h2 { font-size: 26px; line-height: 1.2; letter-spacing: -0.018em; font-weight: 600; margin: 0 0 12px; text-wrap: balance; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Helvetica Neue", system-ui, sans-serif; }
.assist .intro > p { margin: 0; color: var(--secondary); max-width: 34em; }
.assist .intro > p + p { margin-top: 10px; }
.assist .new { display: inline-block; font-size: 11.5px; font-weight: 600; color: var(--accent); background: var(--playing-fill); border-radius: 999px; padding: 3px 9px; margin-bottom: 12px; }
.assist dl { margin: 20px 0 0; display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 8px 14px; font-size: 13.5px; max-width: 34em; }
.assist dt { font-weight: 600; }
.assist dd { margin: 0; color: var(--secondary); }
.assist .panel { margin: 0; padding: 18px; display: flex; flex-direction: column; gap: 14px; }
.assist .msg { display: grid; grid-template-columns: 28px minmax(0, 1fr); gap: 0 10px; font-size: 13.5px; }
.assist .msg .avatar { width: 28px; height: 28px; border-radius: 50%; background: var(--blue); color: #fff; display: grid; place-items: center; font-size: 12px; font-weight: 600; }
.assist .msg .from { font-weight: 600; font-size: 13px; }
.assist .msg .from span { font-weight: 400; color: var(--secondary); margin-left: 6px; font-size: 12px; }
.assist .msg p { margin: 2px 0 0; }
.assist .reply { background: var(--field); border: 0.5px solid var(--hairline); border-radius: 8px; padding: 20px 12px 10px; font-size: 13.5px; position: relative; box-shadow: 0 0 0 3px rgba(0, 122, 255, 0.22); margin-top: 16px; }
.assist .reply p { margin: 0; }
.assist .reply p + p { margin-top: 6px; }
.assist .reply .indicator { position: absolute; right: 10px; top: -15px; display: inline-flex; align-items: center; gap: 7px; padding: 5px 10px 5px 8px; border-radius: 999px; font-size: 11.5px; font-weight: 500; }
.assist .reply .indicator .label { color: var(--secondary); }
.assist .reply .indicator .spin { width: 10px; height: 10px; border-radius: 50%; border: 1.5px solid var(--hairline); border-top-color: var(--accent); }
.assist .said { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; font-size: 12.5px; color: var(--secondary); }
.assist .said q { color: var(--text); font-style: italic; }

.models { border-top: 0.5px solid var(--hairline); padding-block: 56px 84px; display: grid; grid-template-columns: minmax(0, 5fr) minmax(0, 7fr); gap: 32px 48px; align-items: start; }
.models h2 { font-size: 26px; line-height: 1.2; letter-spacing: -0.018em; font-weight: 600; margin: 0 0 12px; text-wrap: balance; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Helvetica Neue", system-ui, sans-serif; }
.models .intro p { margin: 0; color: var(--secondary); max-width: 34em; }
.models .intro p + p { margin-top: 10px; }
.models ol { list-style: none; margin: 0; padding: 0; }
.models li { display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 4px 16px; padding: 16px 0; border-top: 0.5px solid var(--hairline); }
.models li:last-child { border-bottom: 0.5px solid var(--hairline); }
.models .model { grid-column: 1; grid-row: 1; font-size: 15px; font-weight: 600; letter-spacing: -0.01em; }
.models .model a { text-decoration: none; }
.models .model a:hover { text-decoration: underline; }
.models .role { grid-column: 1; grid-row: 2; color: var(--secondary); max-width: 40em; }
.models .lic { grid-column: 2; grid-row: 1 / span 2; align-self: start; justify-self: end; }
.models .runtime { grid-column: 2; margin: 0; font-size: 12.5px; color: var(--secondary); max-width: 52em; }
.models .runtime a { color: var(--secondary); }

.privacy { padding-block: 0 88px; }
.privacy p { font-size: 26px; line-height: 1.28; letter-spacing: -0.018em; font-weight: 600; margin: 0; max-width: 24em; text-wrap: balance; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Helvetica Neue", system-ui, sans-serif; }
.privacy small { display: block; margin-top: 14px; font-size: 14.5px; font-weight: 400; color: var(--secondary); max-width: 44em; letter-spacing: 0; }

footer { border-top: 0.5px solid var(--hairline); padding-block: 22px 40px; display: flex; flex-wrap: wrap; gap: 8px 22px; font-size: 12.5px; color: var(--secondary); }
footer a { text-decoration: none; }
footer a:hover { color: var(--text); text-decoration: underline; }
footer .made { margin-left: auto; }

@media (max-width: 880px) {
  .hero { grid-template-columns: 1fr; gap: 40px; padding-block: 48px 64px; }
  h1 { font-size: 36px; }
  .features { grid-template-columns: 1fr; gap: 44px; padding-top: 44px; padding-bottom: 64px; }
  .figure { height: auto; min-height: 72px; margin-bottom: 16px; }
  .privacy p { font-size: 22px; }
  .privacy { padding-bottom: 64px; }
  .assist { grid-template-columns: 1fr; gap: 32px; padding-block: 44px 64px; }
  .assist h2 { font-size: 22px; }
  .models { grid-template-columns: 1fr; gap: 24px; padding-block: 44px 64px; }
  .models h2 { font-size: 22px; }
  .models li { grid-template-columns: 1fr; }
  .models .runtime { grid-column: 1; }
  .models .lic { grid-column: 1; grid-row: 2; justify-self: start; margin: 2px 0 4px; }
  .models .role { grid-row: 3; }
  .top nav { gap: 14px; }
  footer .made { margin-left: 0; }
}
@media (max-width: 480px) {
  .transport .bar { width: 72px; }
  .turn { grid-template-columns: 44px minmax(0, 1fr); }
}
@media (prefers-reduced-motion: no-preference) {
  .button { transition: filter 120ms ease; }
}
</style>
</head>
<body>
<div class="wrap">
  <header class="top">
    <img src="/site/mark.png" alt="" width="32" height="32">
    <span class="name">Scribe</span>
    <nav aria-label="Links">
      <a href="${escape(repoURL)}">GitHub</a>
      <a href="${escape(notesURL)}">Release notes</a>
    </nav>
  </header>

  <main>
    <section class="hero">
      <div>
        <h1>Your meetings, transcribed on your Mac.</h1>
        <p class="lede">Scribe sits in the menu bar, notices when a call starts, and records it if you say so. The transcript, with speakers and timestamps, is on your Mac a few minutes after you hang up. Nothing is uploaded.</p>
        <a class="button" href="/download">
          <svg viewBox="0 0 16 16" aria-hidden="true" fill="currentColor"><path d="M12.62 8.49c-.02-1.79 1.46-2.65 1.53-2.69-.83-1.22-2.13-1.39-2.59-1.41-1.1-.11-2.15.65-2.71.65-.56 0-1.42-.63-2.34-.62-1.2.02-2.31.7-2.93 1.78-1.25 2.17-.32 5.39.9 7.15.6.86 1.3 1.83 2.23 1.8.9-.04 1.23-.58 2.32-.58 1.08 0 1.39.58 2.33.56.97-.02 1.58-.88 2.17-1.74.68-1 .96-1.97.98-2.02-.02-.01-1.88-.72-1.89-2.88zM10.84 3.23c.5-.6.83-1.44.74-2.28-.72.03-1.58.48-2.1 1.08-.46.53-.86 1.38-.75 2.2.8.06 1.62-.41 2.11-1z"/></svg>
          Download for macOS
        </a>
        <p class="version">${versionLine}${release?.checksumURL ? ` <a href="${escape(release.checksumURL)}">SHA-256</a>` : ''}</p>
        ${release ? `<p class="requires">${release.format === 'dmg' ? 'Open the disk image and drag Scribe to Applications.' : 'Unzip and move Scribe to Applications.'}</p>` : ''}
        <p class="requires">macOS 15 or later on Apple silicon.</p>
      </div>

      <figure class="panel" aria-label="A transcript in Scribe's Transcripts window">
        <div class="head">
          <span class="title">Product sync</span>
          <span class="chip">47 min</span>
          <span class="chip">Zoom</span>
          <span class="chip"><span class="dot" style="background: var(--blue)"></span>Maya</span>
          <span class="chip"><span class="dot" style="background: var(--teal)"></span>Tom</span>
          <span class="chip"><span class="dot" style="background: var(--orange)"></span>Priya</span>
        </div>
        <ol class="turns">
          <li class="turn">
            <span class="tc">14:02</span>
            <div><div class="who"><span class="dot" style="background: var(--blue)"></span>Maya</div>
            <p>Let's lock the launch date. If the notarized build clears tonight we can ship on Thursday.</p></div>
          </li>
          <li class="turn">
            <span class="tc">14:11</span>
            <div><div class="who"><span class="dot" style="background: var(--teal)"></span>Tom</div>
            <p>Support wants the release notes a day earlier. I'll draft them from this recording.</p></div>
          </li>
          <li class="turn">
            <span class="tc">14:24</span>
            <div><div class="who"><span class="dot" style="background: var(--orange)"></span>Priya <span class="flag" title="Speaker inferred, worth a check"></span></div>
            <p>Can the pricing change wait until after launch? Two things changing at once is hard to explain.</p></div>
          </li>
          <li class="turn playing" aria-current="true">
            <span class="tc">14:31</span>
            <div><div class="who"><span class="dot" style="background: var(--blue)"></span>Maya</div>
            <p>Agreed, pricing waits. Tom, send the notes round by Wednesday noon.</p></div>
          </li>
          <li class="turn">
            <span class="tc">14:38</span>
            <div><div class="who"><span class="dot" style="background: var(--teal)"></span>Tom</div>
            <p>Will do. I'll pull the action items out of this transcript and post them after the call.</p></div>
          </li>
        </ol>
        <div class="fade"></div>
        <div class="transport glass" aria-hidden="true">
          <span class="play"><svg viewBox="0 0 12 12"><path d="M2 1.5v9l8-4.5z"/></svg></span>
          <span>14:31</span><span class="bar"></span><span>47:12</span>
          <span class="speed">1×</span>
        </div>
      </figure>
    </section>

    <section class="features" aria-label="What Scribe does">
      <div class="feature">
        <div class="figure">
          <div class="meeting glass" aria-hidden="true">
            <img src="/site/mark.png" alt="" width="20" height="20">
            <span>Record this Zoom meeting?</span>
            <span class="record">Record</span>
            <span class="close">✕</span>
          </div>
        </div>
        <h2>It asks before it records</h2>
        <p>When Zoom, Teams, Meet, Slack, FaceTime or another call app opens the microphone, a small chip appears under the menu bar. Press Record and it becomes that recording's transport. Dismiss it and Scribe stays out of the way until the next call.</p>
        <p>Transcription runs on your Mac with a local speech model, and the finished transcript opens with speakers told apart, timestamps and search.</p>
      </div>
      <div class="feature">
        <div class="figure">
          <div aria-hidden="true">
            <div class="field">Send the notes round by Wednesday noon<span class="caret"></span>
              <span class="indicator glass"><span class="wave"><i style="height:5px"></i><i style="height:11px"></i><i style="height:7px"></i><i style="height:12px"></i><i style="height:6px"></i></span>Listening</span>
            </div>
            <div class="keys"><span class="key">Hold right ⌘</span><span class="key">Release to insert</span></div>
          </div>
        </div>
        <h2>Dictate into any app</h2>
        <p>Hold the right Command key, speak, and let go. The words land in whichever field has focus, in Mail, Slack, a browser or a terminal. Double-tap to keep listening hands-free.</p>
        <p>Dictation is offline and keeps no history. Audio is discarded after transcription, and the text goes straight into the focused field.</p>
      </div>
      <div class="feature">
        <div class="figure">
          <div class="ask" aria-hidden="true">
            <div class="q">What did we decide about pricing in Tuesday's product sync?</div>
            <div class="hosts"><span class="chip">ChatGPT</span><span class="chip">Claude</span><span class="chip">Claude Code</span></div>
          </div>
        </div>
        <h2>Ask your assistant about a meeting</h2>
        <p>Connect ChatGPT, Claude or Claude Code once, and they can find recent meetings, search your transcripts and quote timestamped text for summaries and action items.</p>
        <p>Transcripts stay on your Mac. Assistants read them only through a connection you approved, and you can disconnect any of them from Scribe at any time.</p>
      </div>
    </section>

    <section class="assist" aria-labelledby="assist-heading">
      <div class="intro">
        <span class="new">New</span>
        <h2 id="assist-heading">Say what you want written, and it appears where you type</h2>
        <p>Hold a second key, right Shift unless you pick another, and say something like "reply that Thursday works but pricing waits". Scribe reads what is in front of you, asks the model you chose, and types the answer into the field you are in. Select a paragraph first and say "make this shorter" to rewrite it in place, or copy text from anywhere and say what to do with it.</p>
        <p>In Settings → Assistants → Voice Assistant, connect your ChatGPT account through the installed Codex CLI, add an API key for OpenAI, Anthropic, Google Gemini, OpenRouter, Vercel AI Gateway, xAI, Groq, Mistral or DeepSeek, or connect a custom OpenAI-compatible endpoint such as Ollama or LM Studio.</p>
        <p>You can also choose Apple's on-device model on macOS 26 or later. Apple Private Cloud Compute appears on macOS 27 or later, but needs an Apple-approved build before it can answer. ChatGPT uses your plan's Codex allowance, connected Codex tools and enabled local Codex memory; API providers bill your own account. Your spoken instruction is transcribed on your Mac, and Escape cancels a request at any point.</p>
        <dl>
          <dt>Sent</dt><dd>The instruction you spoke, your selection, text you copied since the last request, and the text in the front app's windows. Each source has its own switch.</dd>
          <dt>Never sent by Scribe</dt><dd>Audio, screenshots and password-field contents. Connected Codex tools may access services you authorized.</dd>
          <dt>Kept by Scribe</dt><dd>Nothing after the answer is inserted. ChatGPT requests run through Codex App Server in an ephemeral thread; API-key requests go directly to the chosen provider or endpoint. Apple's on-device model keeps requests on your Mac. OpenAI API requests have storage turned off. Codex and other providers apply their own policies.</dd>
        </dl>
      </div>

      <figure class="panel" aria-label="The Voice Assistant writing a reply in Messages">
        <div class="msg">
          <span class="avatar" aria-hidden="true">M</span>
          <div><div class="from">Maya <span>Messages, 16:05</span></div>
          <p>Can we still ship Thursday? And does the pricing change go out at the same time?</p></div>
        </div>
        <div class="reply">
          <span class="indicator glass" aria-hidden="true"><span class="spin"></span>Asking ChatGPT…<span class="label">GPT-6 Luna</span></span>
          <p>Thursday works, as long as the notarized build clears tonight.</p>
          <p>Pricing waits until after launch so we are not explaining two changes at once.<span class="caret"></span></p>
        </div>
        <div class="said" aria-hidden="true"><span class="key">Hold right ⇧</span><q>Reply that Thursday works but pricing waits</q></div>
      </figure>
    </section>

    <section class="models" aria-labelledby="models-heading">
      <div class="intro">
        <h2 id="models-heading">Built on open models</h2>
        <p>Scribe does not train or host a model of its own. It runs published, open speech models on the Neural Engine, converted to Core ML and pinned by checksum, so what transcribed your meeting is something you can read about, inspect and run yourself.</p>
        <p>Together they are a one-time download of about 505 MB from Hugging Face. After that, Scribe works with the network off.</p>
      </div>
      <ol>
        <li>
          <span class="model"><a href="https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3">Parakeet TDT 0.6B v3</a></span>
          <span class="chip lic">CC BY 4.0</span>
          <span class="role">NVIDIA's speech recognition model turns the recording into words with timestamps, in 25 European languages, at many times real time on Apple silicon.</span>
        </li>
        <li>
          <span class="model"><a href="https://huggingface.co/pyannote/segmentation-3.0">pyannote segmentation 3.0</a></span>
          <span class="chip lic">MIT</span>
          <span class="role">Finds where speech starts and stops, and where two people talk over each other, so overlapping turns can be marked rather than merged.</span>
        </li>
        <li>
          <span class="model"><a href="https://github.com/wenet-e2e/wespeaker">WeSpeaker embeddings with VBx clustering</a></span>
          <span class="chip lic">Apache 2.0</span>
          <span class="role">Give each stretch of speech a voiceprint and group the voiceprints into speakers, which is how the transcript tells Maya from Tom without being told who was there.</span>
        </li>
      </ol>
      <p class="runtime">Core ML conversions by <a href="https://huggingface.co/FluidInference">FluidInference</a> (CC BY 4.0), run through the open-source <a href="https://github.com/FluidInference/FluidAudio">FluidAudio</a> library (Apache 2.0). Exact revisions and checksums are in Scribe's <a href="https://github.com/cooperativ-labs/Scribe/blob/main/Workers/TranscriptionWorker/model_manifest.json">model manifest</a>.</p>
    </section>

    <section class="privacy">
      <p>Recording, transcription and dictation all happen on your Mac. There is no Scribe account to create.</p>
      <small>Once the speech models are installed, recording, transcription and dictation work with the network off. Text leaves your Mac only when you ask for it: to an assistant you connected to your transcripts, or through a Voice Assistant request to your chosen provider or endpoint. Apple's on-device Voice Assistant keeps the request local; Private Cloud Compute sends it to Apple when available. Audio never leaves your Mac for these features.</small>
    </section>
  </main>

  <footer>
    <a href="/download">Download for macOS</a>
    <a href="${escape(notesURL)}">Release notes</a>
    <a href="${escape(repoURL)}">Source on GitHub</a>
    <a href="${escape(repoURL)}/blob/main/Integrations/scribe/README.md">Connecting an assistant</a>
    <a href="/privacy">Privacy</a>
    <a href="/terms">Terms</a>
    <a href="/support">Support</a>
    <span class="made">Made by Cooperativ Labs</span>
  </footer>
</div>
</body>
</html>
`;
}

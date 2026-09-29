import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { ReleaseSource, releaseFromGitHub, renderSite } from '../src/site.js';
import { startRelay } from './relay-fixture.js';

const LATEST = {
  tag_name: 'v0.2609270609.0', published_at: '2026-09-27T06:12:37Z', html_url: 'https://github.com/cooperativ-labs/Scribe/releases/tag/v0.2609270609.0',
  assets: [
    { name: 'Scribe-0.2609270609.0-macos.zip.sha256', state: 'uploaded', size: 98, browser_download_url: 'https://github.com/cooperativ-labs/Scribe/releases/download/v0.2609270609.0/Scribe-0.2609270609.0-macos.zip.sha256' },
    { name: 'Scribe-0.2609270609.0-macos.zip', state: 'uploaded', size: 28748454, browser_download_url: 'https://github.com/cooperativ-labs/Scribe/releases/download/v0.2609270609.0/Scribe-0.2609270609.0-macos.zip' },
    { name: 'Scribe-0.2609270609.0-macos.dmg.sha256', state: 'uploaded', size: 98, browser_download_url: 'https://github.com/cooperativ-labs/Scribe/releases/download/v0.2609270609.0/Scribe-0.2609270609.0-macos.dmg.sha256' },
    { name: 'Scribe-0.2609270609.0-macos.dmg', state: 'uploaded', size: 32854855, browser_download_url: 'https://github.com/cooperativ-labs/Scribe/releases/download/v0.2609270609.0/Scribe-0.2609270609.0-macos.dmg' },
  ],
};

function githubStub(responses) {
  const calls = [];
  const fetch = async (url, init) => {
    calls.push({ url, init });
    const next = responses.shift();
    if (next instanceof Error) throw next;
    return { ok: next.status === 200, status: next.status, json: async () => next.body };
  };
  return { fetch, calls };
}

test('the newest macOS disk image is preferred and cached through outages', async () => {
  assert.equal(releaseFromGitHub({ tag_name: 'v1', assets: [{ name: 'Scribe-1-macos.zip', state: 'open', browser_download_url: 'x' }] }), null, 'an asset still uploading is not offered');
  assert.equal(releaseFromGitHub({ tag_name: 'v1', assets: [{ name: 'notes.txt', browser_download_url: 'x' }] }), null);
  const zipOnly = releaseFromGitHub({ ...LATEST, assets: LATEST.assets.slice(0, 2) });
  assert.equal(zipOnly.url, LATEST.assets[1].browser_download_url, 'older ZIP-only releases remain downloadable');
  assert.equal(zipOnly.format, 'zip');
  const uploadingDmg = releaseFromGitHub({ ...LATEST, assets: [...LATEST.assets.slice(0, 3), { ...LATEST.assets[3], state: 'open' }] });
  assert.equal(uploadingDmg.url, LATEST.assets[1].browser_download_url, 'an incomplete DMG does not replace the ZIP');
  let clock = 1_000_000;
  const github = githubStub([{ status: 200, body: LATEST }, { status: 403, body: {} }, new Error('offline'), { status: 200, body: { ...LATEST, tag_name: 'v0.3' } }]);
  const source = new ReleaseSource({ fetch: github.fetch, now: () => clock, ttlMs: 600_000, retryMs: 60_000, token: 'ghp_test' });
  const [first, again] = await Promise.all([source.latest(), source.latest()]);
  assert.equal(first.version, '0.2609270609.0');
  assert.equal(first.url, LATEST.assets[3].browser_download_url);
  assert.equal(first.checksumURL, LATEST.assets[2].browser_download_url);
  assert.equal(first.format, 'dmg');
  assert.equal(first.size, 32854855);
  assert.equal(again, first, 'concurrent callers share one request');
  assert.equal(github.calls.length, 1);
  assert.match(github.calls[0].url, /api\.github\.com\/repos\/cooperativ-labs\/Scribe\/releases\/latest$/);
  assert.equal(github.calls[0].init.headers.Authorization, 'Bearer ghp_test');
  clock += 599_000; assert.equal((await source.latest()).tag, first.tag); assert.equal(github.calls.length, 1, 'fresh answers are not refetched');
  clock += 2_000; assert.equal((await source.latest()).tag, first.tag, 'a refused request keeps the last good answer'); assert.equal(github.calls.length, 2);
  clock += 30_000; await source.latest(); assert.equal(github.calls.length, 2, 'failures back off before retrying');
  clock += 31_000; assert.equal((await source.latest()).tag, first.tag, 'a network error keeps the last good answer too'); assert.equal(github.calls.length, 3);
  clock += 61_000; assert.equal((await source.latest()).tag, 'v0.3'); assert.equal(github.calls.length, 4);
});

test('the page renders with and without a known release, escaping what GitHub says', () => {
  const releases = new ReleaseSource({ fetch: async () => { throw new Error('unused'); } });
  const withRelease = renderSite({ release: releaseFromGitHub({ ...LATEST, tag_name: 'v1.0<script>' }), releases });
  assert.match(withRelease, /Version 1\.0&lt;script&gt;, released 27 September 2026\. 32\.9 MB dmg, notarized by Apple\./);
  assert.match(withRelease, /href="\/download"[^>]*>[\s\S]*?Download for macOS/);
  assert.match(withRelease, /Open the disk image and drag Scribe to Applications\./);
  assert.match(withRelease, /SHA-256/);
  assert.doesNotMatch(withRelease, /<script/);
  const withZip = renderSite({ release: releaseFromGitHub({ ...LATEST, assets: LATEST.assets.slice(0, 2) }), releases });
  assert.match(withZip, /Unzip and move Scribe to Applications\./);
  const without = renderSite({ release: null, releases });
  assert.match(without, /The newest notarized build from GitHub\./);
  assert.match(without, /href="https:\/\/github\.com\/cooperativ-labs\/Scribe\/releases"/);
  assert.doesNotMatch(without, /SHA-256/);
});

test('the relay serves the page at its root and redirects /download to the latest macOS disk image', async t => {
  const root = await mkdtemp(path.join(tmpdir(), 'scribe-site-'));
  const github = githubStub([{ status: 200, body: LATEST }]);
  const relay = await startRelay(t, root, { site: { fetch: github.fetch } });
  const page = await fetch(relay.origin + '/');
  assert.equal(page.status, 200);
  assert.match(page.headers.get('content-type'), /text\/html/);
  assert.equal(page.headers.get('cache-control'), 'public, max-age=300');
  assert.match(page.headers.get('content-security-policy'), /default-src 'none'/);
  const html = await page.text();
  assert.match(html, /<title>Scribe for Mac<\/title>/);
  assert.match(html, /Version 0\.2609270609\.0/);
  const download = await fetch(relay.origin + '/download', { redirect: 'manual' });
  assert.equal(download.status, 302);
  assert.equal(download.headers.get('location'), LATEST.assets[3].browser_download_url);
  const api = await (await fetch(relay.origin + '/api/release')).json();
  assert.equal(api.version, '0.2609270609.0'); assert.equal(api.download, '/download');
  const mark = await fetch(relay.origin + '/site/mark.png');
  assert.equal(mark.status, 200); assert.equal(mark.headers.get('content-type'), 'image/png');
  assert.match(html, /src="\/site\/mark\.png"/);
  assert.match(html, /Parakeet TDT 0\.6B v3[\s\S]*pyannote segmentation 3\.0[\s\S]*WeSpeaker/);
  assert.match(html, /id="assist-heading"[\s\S]*Never sent by Scribe<\/dt><dd>Audio, screenshots/, 'the Voice Assistant section says what is and is not sent');
  assert.match(html, /OpenAI, Anthropic, Google Gemini, OpenRouter, Vercel AI Gateway, xAI, Groq, Mistral or DeepSeek/, 'the page describes the available API providers');
  assert.match(html, /Ollama or LM Studio[\s\S]*on-device model on macOS 26[\s\S]*Private Cloud Compute appears on macOS 27/, 'the page describes custom and Apple routes with availability');
  assert.match(html, /OpenAI API requests have storage turned off\. Codex and other providers apply their own policies\./, 'the privacy claim is scoped to OpenAI API requests');
  assert.doesNotMatch(html, /only thing that ever leaves your Mac/, 'the privacy line allows for Voice Assistant requests');
  const logo = await fetch(relay.origin + '/site/logo.png');
  assert.equal(logo.status, 200); assert.equal(logo.headers.get('content-type'), 'image/png');
  assert.match(logo.headers.get('cache-control'), /max-age=86400/);
  assert.equal((await fetch(relay.origin + '/site/..%2Fpackage.json')).status, 404, 'only the named files are served');
  assert.equal((await fetch(relay.origin + '/site/nope.png')).status, 404);
  assert.equal(github.calls.length, 1, 'one GitHub request served the page, the redirect and the API');
  // The relay's own routes are untouched.
  assert.equal((await fetch(relay.origin + '/health')).status, 200);
  assert.equal((await fetch(relay.origin + '/mcp', { method: 'POST' })).status, 401);
});

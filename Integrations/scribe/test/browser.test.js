import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { createHash, randomBytes } from 'node:crypto';
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createRelayApp } from '../src/relay.js';
import { CODEX_CLIENT_METADATA } from '../src/auth.js';

const CHROME = process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const CODEX_DOCUMENT = { client_id: CODEX_CLIENT_METADATA, redirect_uris: ['http://127.0.0.1/callback'], token_endpoint_auth_methods_supported: ['none'], client_name: 'Codex' };
const listen = server => new Promise(resolve => server.listen(0, '127.0.0.1', () => resolve(server.address().port)));

// Browsers, unlike fetch, set Origin from the page's referrer policy and apply CSP
// form-action to the redirect after the consent POST. Both once broke sign-in silently.
test('a real browser completes consent and reaches the client callback', { skip: !existsSync(CHROME) && 'Chrome is not installed' }, async t => {
  const relayServer = createServer(); const origin = `http://127.0.0.1:${await listen(relayServer)}`;
  const relay = createRelayApp({ origin, redirectURIs: ['http://127.0.0.1/callback'], fetch: async () => new Response(JSON.stringify(CODEX_DOCUMENT)) });
  relayServer.on('request', relay.app);
  let arrived; const callback = new Promise(resolve => { arrived = resolve; });
  const callbackServer = createServer((req, res) => { arrived(new URL(req.url, 'http://callback')); res.end('ok'); });
  const callbackPort = await listen(callbackServer);
  const profile = await mkdtemp(path.join(tmpdir(), 'scribe-chrome-'));
  const chrome = spawn(CHROME, ['--headless=new', '--disable-gpu', `--user-data-dir=${profile}`, '--remote-debugging-port=0', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
  const exited = new Promise(resolve => chrome.once('exit', resolve));
  t.after(async () => {
    chrome.kill(); await exited; relayServer.closeAllConnections(); relayServer.close(); callbackServer.close();
    await rm(profile, { recursive: true, force: true, maxRetries: 5 });
  });

  const { ownerId } = relay.owners.register();
  const { code } = relay.owners.issueLinkCode(ownerId);
  const authorize = `${origin}/authorize?` + new URLSearchParams({ client_id: CODEX_CLIENT_METADATA, redirect_uri: `http://127.0.0.1:${callbackPort}/callback`,
    response_type: 'code', code_challenge: createHash('sha256').update(randomBytes(32).toString('base64url')).digest('base64url'), code_challenge_method: 'S256',
    scope: 'transcripts.read', state: 'browser', resource: `${origin}/mcp` });

  const ws = new WebSocket(await new Promise(resolve => chrome.stderr.on('data', data => { const url = String(data).match(/ws:\/\/\S+/); if (url) resolve(url[0]); })));
  await new Promise(resolve => ws.addEventListener('open', resolve));
  let next = 0; const replies = new Map();
  ws.addEventListener('message', event => { const message = JSON.parse(event.data); replies.get(message.id)?.(message.result); });
  const send = (method, params = {}, sessionId) => new Promise(resolve => { const id = ++next; replies.set(id, resolve); ws.send(JSON.stringify({ id, method, params, sessionId })); });
  const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  const evaluate = expression => send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }, sessionId);
  await send('Page.enable', {}, sessionId);
  await send('Page.navigate', { url: authorize }, sessionId);
  for (let i = 0; i < 50 && !(await evaluate('Boolean(document.querySelector("input[name=link_code]"))')).result.value; i++) await new Promise(r => setTimeout(r, 100));
  await evaluate(`document.querySelector('input[name=link_code]').value = ${JSON.stringify(code)}; document.querySelector('button[value=allow]').click();`);

  const reached = await Promise.race([callback, new Promise(resolve => setTimeout(() => resolve(null), 5000))]);
  assert.ok(reached, 'the browser never reached the client callback');
  assert.ok(reached.searchParams.get('code'));
  assert.equal(reached.searchParams.get('state'), 'browser');
  assert.equal(reached.searchParams.get('iss'), `${origin}/`);
});

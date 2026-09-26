import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { createServer, get as httpGet } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import path from 'node:path';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { createHTTPApp } from '../src/http.js';
import { TranscriptLibrary } from '../src/store.js';
import { ScribeOAuthProvider } from '../src/auth.js';
import { fixture } from './fixture.js';

test('HTTP OAuth consent, PKCE, scopes, resource binding, persistence, refresh and revocation', async t => {
  const { root, add } = await fixture(t); await add();
  const listener = createServer(); await new Promise(resolve => listener.listen(0, '127.0.0.1', resolve));
  t.after(() => { listener.closeAllConnections(); listener.close(); });
  const origin = `http://127.0.0.1:${listener.address().port}`;
  const redirect = 'https://chatgpt.com/connector/oauth/test-scribe';
  const config = { origin, ownerKey: randomBytes(32).toString('hex'), redirectURIs: [redirect], stateFile: path.join(root, 'oauth.json') };
  const { app } = createHTTPApp(new TranscriptLibrary(root), config); listener.on('request', app);
  const form = async (route, values) => fetch(origin + route, { method: 'POST', redirect: 'manual', body: new URLSearchParams(values) });
  const register = async uri => fetch(origin + '/register', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ client_name: '<script>evil</script>', redirect_uris: [uri], token_endpoint_auth_method: 'none', grant_types: ['authorization_code', 'refresh_token'], scope: 'transcripts.read' }) });
  const unauthorized = await fetch(origin + '/mcp'); assert.equal(unauthorized.status, 401); assert.match(unauthorized.headers.get('www-authenticate'), /oauth-protected-resource\/mcp/);
  const metadata = await (await fetch(origin + '/.well-known/oauth-protected-resource/mcp')).json(); assert.equal(metadata.resource, origin + '/mcp');
  const oauth = await (await fetch(origin + '/.well-known/oauth-authorization-server')).json(); assert.deepEqual(oauth.code_challenge_methods_supported, ['S256']);
  assert.equal((await register('https://attacker.test/callback')).status, 400);
  const registration = await register(redirect); assert.equal(registration.status, 201); const clientInfo = await registration.json();
  const verifier = randomBytes(32).toString('base64url'); const challenge = createHash('sha256').update(verifier).digest('base64url');
  async function authorize(changes = {}) {
    return fetch(origin + '/authorize?' + new URLSearchParams({ client_id: clientInfo.client_id, redirect_uri: redirect, response_type: 'code', code_challenge: challenge, code_challenge_method: 'S256', scope: 'transcripts.read', state: 'bound-state', resource: origin + '/mcp', ...changes }), { redirect: 'manual' });
  }
  async function consent(decision, key = config.ownerKey, requestOrigin = origin) {
    const response = await authorize(); assert.equal(response.status, 200); const html = await response.text();
    assert.doesNotMatch(html, /<script>/); const request = html.match(/name="request" value="([^"]+)"/)[1];
    return fetch(origin + '/consent', { method: 'POST', redirect: 'manual', headers: { Origin: requestOrigin }, body: new URLSearchParams({ request, decision, owner_key: key }) });
  }
  assert.equal((await consent('allow', 'wrong')).status, 403);
  assert.equal((await consent('allow', config.ownerKey, 'https://attacker.test')).status, 403);
  assert.match((await consent('deny')).headers.get('location'), /error=access_denied/);
  assert.equal((await authorize({ resource: 'https://attacker.test/mcp' })).status, 302); // SDK redirects OAuth errors to the validated callback
  const approved = await consent('allow'); const location = new URL(approved.headers.get('location'));
  assert.equal(location.searchParams.get('state'), 'bound-state');
  const values = { grant_type: 'authorization_code', client_id: clientInfo.client_id, code: location.searchParams.get('code'), code_verifier: verifier, redirect_uri: redirect, resource: origin + '/mcp' };
  assert.equal((await form('/token', { ...values, code_verifier: 'invalid' })).status, 400);
  const tokenResponse = await form('/token', values); assert.equal(tokenResponse.status, 200); const tokens = await tokenResponse.json();
  assert.equal((await form('/token', values)).status, 400);
  assert.doesNotMatch(await readFile(config.stateFile, 'utf8'), new RegExp(tokens.access_token));
  assert.equal((await stat(config.stateFile)).mode & 0o777, 0o600);
  const restored = new ScribeOAuthProvider(config); assert.equal((await restored.verifyAccessToken(tokens.access_token)).resource.href, origin + '/mcp');
  const client = new Client({ name: 'http-client', version: '1' });
  t.after(() => client.close());
  await client.connect(new StreamableHTTPClientTransport(new URL(origin + '/mcp'), { requestInit: { headers: { Authorization: `Bearer ${tokens.access_token}` } } }));
  const recent = await client.callTool({ name: 'scribe_recent_transcripts', arguments: {} }); assert.equal(recent.structuredContent.total, 1);
  const read = await client.callTool({ name: 'scribe_get_transcript', arguments: { id: recent.structuredContent.transcripts[0].id } }); assert.match(read.structuredContent.text, /Friday/);
  const refreshValues = { grant_type: 'refresh_token', client_id: clientInfo.client_id, refresh_token: tokens.refresh_token, resource: origin + '/mcp' };
  assert.equal((await form('/token', { ...refreshValues, resource: 'https://attacker.test/mcp' })).status, 400);
  const refreshed = await (await form('/token', refreshValues)).json(); assert.ok(refreshed.access_token);
  assert.equal((await form('/token', refreshValues)).status, 400);
  assert.equal((await form('/revoke', { client_id: clientInfo.client_id, token: refreshed.refresh_token })).status, 200);
  assert.equal((await fetch(origin + '/mcp', { headers: { Authorization: `Bearer ${tokens.access_token}` } })).status, 401);
  const badHostStatus = await new Promise((resolve, reject) => httpGet(origin + '/health', { headers: { Host: 'attacker.test' } }, response => { response.resume(); resolve(response.statusCode); }).on('error', reject));
  assert.equal(badHostStatus, 403);
});

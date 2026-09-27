import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { CHATGPT_CLIENT_METADATA, CODEX_CLIENT_METADATA, ScribeOAuthProvider } from '../src/auth.js';
import { writeChatGPTPackage } from '../scripts/chatgpt-package.js';
import { fixture } from './fixture.js';
import { CALLBACK, startMac, startRelay } from './relay-fixture.js';

// ChatGPT's published client metadata document, as served at CHATGPT_CLIENT_METADATA.
const CHATGPT_DOCUMENT = { client_id: CHATGPT_CLIENT_METADATA, client_uri: 'https://chatgpt.com/', redirect_uris: [CALLBACK],
  token_endpoint_auth_method: 'private_key_jwt', token_endpoint_auth_methods_supported: ['none', 'private_key_jwt'],
  grant_types: ['authorization_code', 'refresh_token'], response_types: ['code'], client_name: 'ChatGPT',
  token_endpoint_auth_signing_alg: 'RS256', jwks_uri: 'https://chatgpt.com/oauth/jwks.json' };
// The ChatGPT desktop app's plugin runtime, as served at CODEX_CLIENT_METADATA.
const CODEX_DOCUMENT = { client_id: CODEX_CLIENT_METADATA, client_uri: 'https://chatgpt.com/codex', application_type: 'native',
  redirect_uris: ['http://127.0.0.1/callback', 'http://localhost/callback'], token_endpoint_auth_method: 'none', token_endpoint_auth_methods_supported: ['none'],
  grant_types: ['authorization_code', 'refresh_token'], response_types: ['code'], client_name: 'Codex' };
const serve = (document, fetched = []) => async url => { fetched.push(url); return new Response(JSON.stringify(document), { headers: { 'Content-Type': 'application/json' } }); };
const serveAll = documents => async url => new Response(JSON.stringify(documents[url]), { status: documents[url] ? 200 : 404 });
const form = (origin, route, values) => fetch(origin + route, { method: 'POST', redirect: 'manual', body: new URLSearchParams(values) });

// What ChatGPT does after a marketplace install: discover OAuth from the packaged
// endpoint, identify itself with its CIMD URL, send the owner to consent, redeem the
// code as a public client, and call tools with the bearer token.
async function install(relay, mac, { clientID = CHATGPT_CLIENT_METADATA, callbackURL = CALLBACK, name = 'ChatGPT' } = {}) {
  const unauthorized = await fetch(relay.origin + '/mcp');
  assert.equal(unauthorized.status, 401);
  const resourceMetadataURL = unauthorized.headers.get('www-authenticate').match(/resource_metadata="([^"]+)"/)[1];
  const resource = await (await fetch(resourceMetadataURL)).json();
  const metadata = await (await fetch(new URL('/.well-known/oauth-authorization-server', resource.authorization_servers[0]))).json();
  assert.equal(metadata.client_id_metadata_document_supported, true);
  assert.equal(metadata.authorization_response_iss_parameter_supported, true);
  assert.ok(metadata.token_endpoint_auth_methods_supported.includes('none'));
  assert.ok(!metadata.token_endpoint_auth_methods_supported.includes('private_key_jwt'), 'ChatGPT must pick none from the intersection');

  const verifier = randomBytes(32).toString('base64url');
  const page = await fetch(metadata.authorization_endpoint + '?' + new URLSearchParams({ client_id: clientID, redirect_uri: callbackURL,
    response_type: 'code', code_challenge: createHash('sha256').update(verifier).digest('base64url'), code_challenge_method: 'S256',
    scope: 'transcripts.read', state: 'install', resource: resource.resource }), { redirect: 'manual' });
  assert.equal(page.status, 200);
  const html = await page.text();
  // Browsers send `Origin: null` on the consent POST under no-referrer, and the relay refuses that.
  assert.equal(page.headers.get('referrer-policy'), 'same-origin');
  assert.match(html, new RegExp(`<h1>Connect ${name} to Scribe</h1>`));
  assert.match(html, /No link code yet\?/);
  const { code: linkCode } = await mac.account.linkCode();
  const approved = await fetch(relay.origin + '/consent', { method: 'POST', redirect: 'manual', headers: { Origin: relay.origin },
    body: new URLSearchParams({ request: html.match(/name="request" value="([^"]+)"/)[1], decision: 'allow', link_code: linkCode }) });
  const callback = new URL(approved.headers.get('location'));
  assert.equal(callback.origin + callback.pathname, callbackURL);
  assert.equal(callback.searchParams.get('iss'), metadata.issuer);
  assert.equal(callback.searchParams.get('state'), 'install');
  const token = await form(relay.origin, '/token', { grant_type: 'authorization_code', client_id: clientID,
    code: callback.searchParams.get('code'), code_verifier: verifier, redirect_uri: callbackURL, resource: resource.resource });
  assert.equal(token.status, 200);
  return token.json();
}

async function connectClient(t, relay, accessToken) {
  const client = new Client({ name: 'chatgpt', version: '1' });
  t.after(() => client.close());
  await client.connect(new StreamableHTTPClientTransport(new URL(relay.origin + '/mcp'), { requestInit: { headers: { Authorization: `Bearer ${accessToken}` } } }));
  return client;
}

test('a marketplace install reaches each owner library through the packaged endpoint, then disconnects', async t => {
  const { root } = await fixture(t);
  const fetched = [];
  const relay = await startRelay(t, root, { fetch: serve(CHATGPT_DOCUMENT, fetched) });

  // Every user installs the same package; its only endpoint is the relay's /mcp.
  const source = fileURLToPath(new URL('..', import.meta.url));
  const plugin = await writeChatGPTPackage({ root: source, output: path.join(root, 'package'), url: 'https://relay.example/mcp' });
  const packaged = new URL(JSON.parse(await readFile(path.join(plugin, 'mcp.json'), 'utf8')).mcpServers.scribe.url);
  assert.equal(packaged.pathname, '/mcp');
  assert.equal(new URL(packaged.pathname, relay.origin).href, relay.origin + '/mcp'); // the test relay stands in for relay.example

  const alice = await startMac(t, relay.origin, 'Alice');
  const bob = await startMac(t, relay.origin, 'Bob');
  const aliceTokens = await install(relay, alice);
  const bobTokens = await install(relay, bob);
  assert.deepEqual(fetched, [CHATGPT_CLIENT_METADATA], 'the CIMD document is fetched once and cached');
  assert.equal(Object.keys(relay.provider.state.clients).length, 1, 'no per-user client registration');

  const aliceChat = await connectClient(t, relay, aliceTokens.access_token);
  const bobChat = await connectClient(t, relay, bobTokens.access_token);
  const profileTool = (await aliceChat.listTools()).tools.find(tool => tool.name === 'scribe_profile');
  assert.equal(profileTool._meta['openai/profile'], true);
  assert.deepEqual(profileTool.outputSchema.required, ['id']);
  const aliceProfile = (await aliceChat.callTool({ name: 'scribe_profile', arguments: {} })).structuredContent;
  const bobProfile = (await bobChat.callTool({ name: 'scribe_profile', arguments: {} })).structuredContent;
  assert.match(aliceProfile.id, /^[0-9a-f]{32}$/);
  assert.notEqual(aliceProfile.id, bobProfile.id);
  assert.ok(!aliceProfile.id.includes(alice.account.linked().owner_id), 'the profile ID does not reveal the owner ID');

  // Retrieval: each install reads only its own owner's library.
  const recent = await aliceChat.callTool({ name: 'scribe_recent_transcripts', arguments: {} });
  assert.deepEqual(recent.structuredContent.transcripts.map(item => item.title), ['Alice planning']);
  assert.match((await aliceChat.callTool({ name: 'fetch', arguments: { id: alice.transcript.id } })).structuredContent.text, /Alice ships/);
  assert.equal((await aliceChat.callTool({ name: 'fetch', arguments: { id: bob.transcript.id } })).isError, true);
  assert.deepEqual((await bobChat.callTool({ name: 'scribe_recent_transcripts', arguments: {} })).structuredContent.transcripts.map(item => item.title), ['Bob planning']);

  // Refresh keeps the same profile and library.
  const refreshed = await (await form(relay.origin, '/token', { grant_type: 'refresh_token', client_id: CHATGPT_CLIENT_METADATA,
    refresh_token: aliceTokens.refresh_token, resource: relay.origin + '/mcp' })).json();
  const again = await connectClient(t, relay, refreshed.access_token);
  assert.equal((await again.callTool({ name: 'scribe_profile', arguments: {} })).structuredContent.id, aliceProfile.id);
  assert.equal((await alice.account.grants()).grants[0].client_name, 'ChatGPT');

  // Disconnecting in ChatGPT revokes the grant; Bob's connection is untouched.
  assert.equal((await form(relay.origin, '/revoke', { client_id: CHATGPT_CLIENT_METADATA, token: refreshed.refresh_token })).status, 200);
  assert.equal((await fetch(relay.origin + '/mcp', { headers: { Authorization: `Bearer ${refreshed.access_token}` } })).status, 401);
  assert.equal((await alice.account.grants()).grants.length, 0);
  assert.equal((await bobChat.callTool({ name: 'scribe_recent_transcripts', arguments: {} })).isError, undefined);
  // Disconnecting from the Mac ends Bob's.
  await bob.account.revoke();
  assert.equal((await fetch(relay.origin + '/mcp', { headers: { Authorization: `Bearer ${bobTokens.access_token}` } })).status, 401);
});

test('the ChatGPT desktop app signs in as its native client on a loopback callback', async t => {
  const { root } = await fixture(t);
  const relay = await startRelay(t, root, { redirectURIs: [CALLBACK, 'http://127.0.0.1/callback', 'http://localhost/callback'],
    fetch: serveAll({ [CHATGPT_CLIENT_METADATA]: CHATGPT_DOCUMENT, [CODEX_CLIENT_METADATA]: CODEX_DOCUMENT }) });
  const mac = await startMac(t, relay.origin, 'Alice');
  const tokens = await install(relay, mac, { clientID: CODEX_CLIENT_METADATA, callbackURL: 'http://127.0.0.1:53682/callback', name: 'Codex' });
  const client = await connectClient(t, relay, tokens.access_token);
  assert.deepEqual((await client.callTool({ name: 'scribe_recent_transcripts', arguments: {} })).structuredContent.transcripts.map(item => item.title), ['Alice planning']);
  assert.equal((await mac.account.grants()).grants[0].client_name, 'Codex');
  // Any loopback port, but only the allowed path, host and scheme.
  for (const redirect of ['http://127.0.0.1:53682/other', 'http://attacker.example:53682/callback', 'https://127.0.0.1:53682/callback']) {
    assert.equal(relay.provider.allowedRedirect(redirect), false, redirect);
  }
});

test('only allowlisted, consistent client metadata documents identify a client', async () => {
  const base = { origin: 'https://relay.example', owners: new Map(), redirectURIs: [CALLBACK], clientMetadataDocuments: [CHATGPT_CLIENT_METADATA] };
  const fetched = [];
  const provider = new ScribeOAuthProvider({ ...base, fetch: serve(CHATGPT_DOCUMENT, fetched) });
  assert.equal(await provider.clientsStore.getClient('https://attacker.example/client.json'), undefined);
  assert.equal(await provider.clientsStore.getClient('http://169.254.169.254/latest/meta-data'), undefined);
  assert.deepEqual(fetched, [], 'client_id never steers a fetch');
  const client = await provider.clientsStore.getClient(CHATGPT_CLIENT_METADATA);
  assert.deepEqual([client.token_endpoint_auth_method, client.redirect_uris, client.client_secret], ['none', [CALLBACK], undefined]);

  for (const document of [{ ...CHATGPT_DOCUMENT, client_id: 'https://attacker.example/client.json' },
    { ...CHATGPT_DOCUMENT, redirect_uris: ['https://attacker.example/callback'] },
    { ...CHATGPT_DOCUMENT, token_endpoint_auth_methods_supported: ['private_key_jwt'], token_endpoint_auth_method: 'private_key_jwt' }]) {
    const rejecting = new ScribeOAuthProvider({ ...base, fetch: serve(document) });
    assert.equal(await rejecting.clientsStore.getClient(CHATGPT_CLIENT_METADATA), undefined, JSON.stringify(document));
  }
  // A hostile document keeps only operator-approved callbacks.
  const mixed = new ScribeOAuthProvider({ ...base, fetch: serve({ ...CHATGPT_DOCUMENT, redirect_uris: [CALLBACK, 'https://attacker.example/cb'] }) });
  assert.deepEqual((await mixed.clientsStore.getClient(CHATGPT_CLIENT_METADATA)).redirect_uris, [CALLBACK]);
  // An outage does not disconnect ChatGPT: the last validated document keeps working.
  provider.state.clients[CHATGPT_CLIENT_METADATA].metadata_fetched_at = 0;
  provider.fetchDocument = async () => { throw new Error('offline'); };
  assert.equal((await provider.clientsStore.getClient(CHATGPT_CLIENT_METADATA)).client_name, 'ChatGPT');
});

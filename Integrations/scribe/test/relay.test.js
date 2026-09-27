import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { readFile, stat } from 'node:fs/promises';
import path from 'node:path';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { AgentHub, OwnerDirectory } from '../src/relay.js';
import { answer, relayOrigin } from '../src/agent.js';
import { TranscriptLibrary } from '../src/store.js';
import { fixture } from './fixture.js';
import { CALLBACK, startMac, startRelay } from './relay-fixture.js';

async function connect(relay, mac) {
  const register = await fetch(relay.origin + '/register', { method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ client_name: 'ChatGPT', redirect_uris: [CALLBACK], token_endpoint_auth_method: 'none', grant_types: ['authorization_code', 'refresh_token'] }) });
  const client = await register.json();
  const verifier = randomBytes(32).toString('base64url');
  const challenge = createHash('sha256').update(verifier).digest('base64url');
  async function consent(linkCode) {
    const page = await fetch(relay.origin + '/authorize?' + new URLSearchParams({ client_id: client.client_id, redirect_uri: CALLBACK, response_type: 'code',
      code_challenge: challenge, code_challenge_method: 'S256', scope: 'transcripts.read', state: 's', resource: relay.origin + '/mcp' }), { redirect: 'manual' });
    const html = await page.text();
    assert.match(html, /link code/); assert.doesNotMatch(html, /owner key/i);
    const request = html.match(/name="request" value="([^"]+)"/)[1];
    return fetch(relay.origin + '/consent', { method: 'POST', redirect: 'manual', headers: { Origin: relay.origin }, body: new URLSearchParams({ request, decision: 'allow', link_code: linkCode }) });
  }
  const { code } = await mac.account.linkCode();
  const approved = await consent(code.toLowerCase().replace('-', ' ')); // typed loosely
  assert.equal(approved.status, 303);
  const location = new URL(approved.headers.get('location'));
  assert.equal(location.searchParams.get('iss'), relay.origin + '/');
  assert.equal((await consent(code)).status, 403, 'link codes are single use');
  const token = await fetch(relay.origin + '/token', { method: 'POST', body: new URLSearchParams({ grant_type: 'authorization_code', client_id: client.client_id,
    code: location.searchParams.get('code'), code_verifier: verifier, redirect_uri: CALLBACK, resource: relay.origin + '/mcp' }) });
  assert.equal(token.status, 200);
  return { client, tokens: await token.json(), consent };
}

async function mcp(t, relay, accessToken) {
  const client = new Client({ name: 'chatgpt-test', version: '1' });
  t.after(() => client.close());
  await client.connect(new StreamableHTTPClientTransport(new URL(relay.origin + '/mcp'), { requestInit: { headers: { Authorization: `Bearer ${accessToken}` } } }));
  return client;
}

test('relay serves each owner only their own Mac library through one stable endpoint', async t => {
  const { root } = await fixture(t);
  const relay = await startRelay(t, root);
  const metadata = await (await fetch(relay.origin + '/.well-known/oauth-authorization-server')).json();
  assert.equal(metadata.authorization_response_iss_parameter_supported, true);
  assert.equal((await fetch(relay.origin + '/mcp')).status, 401);

  const alice = await startMac(t, relay.origin, 'Alice');
  const bob = await startMac(t, relay.origin, 'Bob');
  const aliceLink = JSON.parse(await readFile(path.join(alice.root, 'state/relay.json'), 'utf8'));
  assert.equal((await stat(path.join(alice.root, 'state/relay.json'))).mode & 0o777, 0o600);
  assert.notEqual(aliceLink.owner_id, JSON.parse(await readFile(path.join(bob.root, 'state/relay.json'), 'utf8')).owner_id);

  const { tokens, consent } = await connect(relay, alice);
  assert.equal((await consent('ABCDE-FGHJK')).status, 403, 'an invented code names no owner');
  const client = await mcp(t, relay, tokens.access_token);
  const recent = await client.callTool({ name: 'scribe_recent_transcripts', arguments: {} });
  assert.deepEqual(recent.structuredContent.transcripts.map(item => item.title), ['Alice planning']);
  assert.match((await client.callTool({ name: 'fetch', arguments: { id: alice.transcript.id } })).structuredContent.text, /Alice ships/);
  // Knowing another owner's transcript ID does not reach their library.
  const crossRead = await client.callTool({ name: 'scribe_get_transcript', arguments: { id: bob.transcript.id } });
  assert.equal(crossRead.isError, true); assert.match(crossRead.content[0].text, /not found/);
  assert.equal((await client.callTool({ name: 'scribe_search_transcripts', arguments: { query: 'Bob' } })).structuredContent.total, 0);

  // Each owner sees and manages only its own grants.
  assert.equal((await alice.account.grants()).grants.length, 1);
  assert.equal((await alice.account.grants()).grants[0].client_name, 'ChatGPT');
  assert.equal((await bob.account.grants()).grants.length, 0);
  const grantID = (await alice.account.grants()).grants[0].id;
  await assert.rejects(bob.account.revoke(grantID), /404/);
  assert.equal((await client.callTool({ name: 'scribe_recent_transcripts', arguments: {} })).isError, undefined);

  // Revocation from the Mac ends the connection, including refresh.
  await alice.account.revoke(grantID);
  assert.equal((await fetch(relay.origin + '/mcp', { headers: { Authorization: `Bearer ${tokens.access_token}` } })).status, 401);

  // The relay stores hashes and owner IDs only: no secrets, tokens, or transcript text.
  const state = (await readFile(path.join(root, 'relay/oauth.json'), 'utf8')) + await readFile(path.join(root, 'relay/owners.json'), 'utf8');
  for (const secret of [tokens.access_token, tokens.refresh_token, aliceLink.agent_secret, 'Alice ships']) assert.ok(!state.includes(secret));
  assert.equal((await stat(path.join(root, 'relay/owners.json'))).mode & 0o777, 0o600);
});

test('relay agents are authenticated, confined to their own calls, and unlink ends everything', async t => {
  const { root } = await fixture(t);
  const relay = await startRelay(t, root);
  const alice = await startMac(t, relay.origin, 'Alice');
  const bob = await startMac(t, relay.origin, 'Bob');
  const { tokens } = await connect(relay, alice);
  const client = await mcp(t, relay, tokens.access_token);

  // Bob's Mac cannot answer a request addressed to Alice's owner.
  const bobSecret = bob.account.linked().agent_secret;
  const hijack = relay.hub.call(alice.account.linked().owner_id, 'list', { limit: 1, offset: 0 });
  const pendingID = [...relay.hub.owners.get(alice.account.linked().owner_id).pending.keys()][0];
  const forged = await fetch(relay.origin + '/agent/responses', { method: 'POST', headers: { Authorization: `Bearer ${bobSecret}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ id: pendingID, result: { transcripts: [], total: 99, next_offset: null, skipped_runs: 0 } }) });
  assert.equal(forged.status, 404);
  assert.notEqual((await hijack).total, 99);
  assert.equal((await fetch(relay.origin + '/agent/poll', { method: 'POST', headers: { Authorization: 'Bearer invented' } })).status, 401);

  // An offline Mac yields a clear error instead of a hang.
  bob.controller.abort(); await bob.running;
  await new Promise(resolve => setTimeout(resolve, 1100));
  await assert.rejects(relay.hub.call(bob.account.linked().owner_id, 'list', {}), /not connected/);

  // Unlinking forgets the owner, its tokens and link codes, and stops its agent.
  const aliceOwner = alice.account.linked().owner_id;
  await alice.account.unlink();
  await assert.rejects(alice.running, /unlinked/);
  assert.equal((await fetch(relay.origin + '/mcp', { headers: { Authorization: `Bearer ${tokens.access_token}` } })).status, 401);
  assert.equal(relay.owners.has(aliceOwner), false);
  assert.ok(!(await readFile(path.join(root, 'relay/owners.json'), 'utf8')).includes(aliceOwner));
  assert.throws(() => alice.account.linked(), /not linked/);
  void client;
});

test('Mac agent answers only validated read-only calls', async t => {
  const { root, add } = await fixture(t); const transcript = await add();
  const library = new TranscriptLibrary(root);
  assert.equal((await answer(library, { method: 'list', args: {} })).result.total, 1);
  assert.match((await answer(library, { method: 'get', args: { id: transcript.id } })).result.text, /Friday/);
  for (const call of [{ method: 'delete', args: {} }, { method: 'constructor', args: {} }, { method: 'snapshot', args: {} },
    { method: 'get', args: { id: '../../etc/passwd' } }, { method: 'list', args: { limit: 5000 } }, { method: 'list', args: { root: '/' } }]) {
    const result = await answer(library, call);
    assert.ok(result.error && !result.result, JSON.stringify(call));
  }
  assert.match((await answer(library, { method: 'get', args: { id: transcript.id, revision: 7 } })).error, /changed/);
  assert.throws(() => relayOrigin('http://relay.example.com'), /HTTPS/);
  assert.equal(relayOrigin('relay.example.com/mcp'), 'https://relay.example.com');
});

test('link codes are unguessable in form, single use, expiring and owner-scoped', () => {
  const owners = new OwnerDirectory({ linkCodeTTL: 600 });
  const { ownerId, agentSecret } = owners.register();
  assert.equal(owners.authenticate(agentSecret), ownerId);
  assert.equal(owners.authenticate('guess'), undefined);
  const { code } = owners.issueLinkCode(ownerId);
  assert.match(code, /^[0-9A-HJKMNP-TV-Z]{5}-[0-9A-HJKMNP-TV-Z]{5}$/);
  assert.equal(owners.redeemLinkCode(code), ownerId);
  assert.equal(owners.redeemLinkCode(code), undefined);
  for (let i = 0; i < 5; i++) owners.issueLinkCode(ownerId);
  assert.throws(() => owners.issueLinkCode(ownerId), /Too many/);
  const expiring = new OwnerDirectory({ linkCodeTTL: -1 });
  const other = expiring.register();
  assert.equal(expiring.redeemLinkCode(expiring.issueLinkCode(other.ownerId).code), undefined);
  const removed = new OwnerDirectory();
  const gone = removed.register(); const pending = removed.issueLinkCode(gone.ownerId);
  removed.remove(gone.ownerId);
  assert.equal(removed.redeemLinkCode(pending.code), undefined);
  assert.equal(removed.authenticate(gone.agentSecret), undefined);
});

test('hub times out an unresponsive Mac and bounds queued calls', async () => {
  const hub = new AgentHub({ pollTimeoutMs: 50, callTimeoutMs: 50, offlineAfterMs: 1000, maxQueued: 1 });
  const polled = hub.poll('owner'); // online, but never answers
  const first = hub.call('owner', 'list', {});
  assert.equal((await polled).length, 1);
  await assert.rejects(hub.call('owner', 'list', {}), /busy/);
  await assert.rejects(first, /did not answer/);
});

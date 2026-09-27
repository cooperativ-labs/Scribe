import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { OwnerDirectory } from '../src/relay.js';
import { DEMO_OWNER, DemoLibrary } from '../src/demo.js';
import { legalConfig } from '../src/legal.js';
import { fixture } from './fixture.js';
import { CALLBACK, startMac, startRelay } from './relay-fixture.js';

// What OpenAI's Plugins Directory review needs from the relay: a reviewer demo
// library reached with a reusable code, public privacy/terms/support pages, and the
// domain-verification token. The submission's test cases (docs/directory-submission.md)
// are checked here at the tool level against the same demo library reviewers use.

const REVIEWER_CODE = 'REVIEW-7QX4-M2KD-9PLT-W3HN';
const DAY = 86_400_000;

async function authorize(relay, linkCode) {
  const register = await fetch(relay.origin + '/register', { method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ client_name: 'ChatGPT', redirect_uris: [CALLBACK], token_endpoint_auth_method: 'none', grant_types: ['authorization_code', 'refresh_token'] }) });
  const client = await register.json();
  const verifier = randomBytes(32).toString('base64url');
  const page = await fetch(relay.origin + '/authorize?' + new URLSearchParams({ client_id: client.client_id, redirect_uri: CALLBACK, response_type: 'code',
    code_challenge: createHash('sha256').update(verifier).digest('base64url'), code_challenge_method: 'S256', scope: 'transcripts.read', state: 's', resource: relay.origin + '/mcp' }));
  const request = (await page.text()).match(/name="request" value="([^"]+)"/)[1];
  const approved = await fetch(relay.origin + '/consent', { method: 'POST', redirect: 'manual', headers: { Origin: relay.origin }, body: new URLSearchParams({ request, decision: 'allow', link_code: linkCode }) });
  if (approved.status !== 303) return { status: approved.status };
  const token = await fetch(relay.origin + '/token', { method: 'POST', body: new URLSearchParams({ grant_type: 'authorization_code', client_id: client.client_id,
    code: new URL(approved.headers.get('location')).searchParams.get('code'), code_verifier: verifier, redirect_uri: CALLBACK, resource: relay.origin + '/mcp' }) });
  return { status: 303, client, tokens: await token.json() };
}

async function mcp(t, relay, accessToken) {
  const client = new Client({ name: 'directory-review', version: '1' });
  t.after(() => client.close());
  await client.connect(new StreamableHTTPClientTransport(new URL(relay.origin + '/mcp'), { requestInit: { headers: { Authorization: `Bearer ${accessToken}` } } }));
  return client;
}

test('a reviewer code opens the synthetic demo library, reusably, and nothing else', async t => {
  const { root } = await fixture(t);
  const relay = await startRelay(t, root, { reviewerCode: REVIEWER_CODE });
  const mac = await startMac(t, relay.origin, 'Alice');

  // Reusable: reviewers connect again on every surface they test.
  const first = await authorize(relay, REVIEWER_CODE.toLowerCase().replaceAll('-', ' ')); // typed loosely, like a link code
  const second = await authorize(relay, REVIEWER_CODE);
  assert.equal(first.status, 303); assert.equal(second.status, 303);
  assert.equal((await authorize(relay, 'REVIEW-7QX4-M2KD-9PLT-W3HX')).status, 403, 'a near miss is refused');

  const demo = await mcp(t, relay, first.tokens.access_token);
  const titles = (await demo.callTool({ name: 'scribe_recent_transcripts', arguments: { limit: 50 } })).structuredContent.transcripts.map(item => item.title);
  assert.deepEqual(titles, ['Q4 launch planning', 'Weekly design review', 'Customer interview: Lakeside Bakery', 'Monthly budget review', 'Support team sync']);
  // The demo grant cannot reach a real library, even with a real transcript ID.
  const cross = await demo.callTool({ name: 'scribe_get_transcript', arguments: { id: mac.transcript.id } });
  assert.equal(cross.isError, true);
  assert.equal((await demo.callTool({ name: 'scribe_search_transcripts', arguments: { query: 'Alice' } })).structuredContent.total, 0);

  // And a real owner's link code never lands on the demo library.
  const { code } = await mac.account.linkCode();
  const owner = await mcp(t, relay, (await authorize(relay, code)).tokens.access_token);
  assert.deepEqual((await owner.callTool({ name: 'scribe_recent_transcripts', arguments: {} })).structuredContent.transcripts.map(item => item.title), ['Alice planning']);
  const demoID = (await new DemoLibrary().list({ limit: 1 })).transcripts[0].id;
  assert.equal((await owner.callTool({ name: 'scribe_get_transcript', arguments: { id: demoID } })).isError, true);

  // Profiles tell the demo library and the real one apart.
  const profiles = await Promise.all([demo, owner].map(async client => (await client.callTool({ name: 'scribe_profile', arguments: {} })).structuredContent.id));
  assert.notEqual(profiles[0], profiles[1]);

  // A Mac cannot answer on the demo library's behalf, and ChatGPT's revoke ends a demo grant.
  assert.equal(relay.hub.respond(DEMO_OWNER, 'anything', { result: {} }), false);
  const revoke = await fetch(relay.origin + '/revoke', { method: 'POST', body: new URLSearchParams({ client_id: second.client.client_id, token: second.tokens.refresh_token }) });
  assert.equal(revoke.status, 200);
  assert.equal((await fetch(relay.origin + '/mcp', { method: 'POST', headers: { Authorization: `Bearer ${second.tokens.access_token}`, 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list' }) })).status, 401);
});

test('without a reviewer code the demo library does not exist', async t => {
  const { root } = await fixture(t);
  const relay = await startRelay(t, root);
  assert.equal(relay.owners.has(DEMO_OWNER), false);
  assert.equal((await authorize(relay, REVIEWER_CODE)).status, 403);
  assert.throws(() => new OwnerDirectory({ reviewerCode: 'SHORT-CODE' }), /at least 20/);
  // A reviewer code never authenticates a Mac agent.
  const owners = new OwnerDirectory({ reviewerCode: REVIEWER_CODE });
  assert.equal(owners.authenticate(REVIEWER_CODE), undefined);
  assert.equal(owners.redeemLinkCode(REVIEWER_CODE), DEMO_OWNER);
  assert.equal(owners.redeemLinkCode(REVIEWER_CODE), DEMO_OWNER, 'not consumed');
});

// The five positive submission test cases, at the tool level (P1–P5 in docs/directory-submission.md).
test('the demo library answers every positive submission test case', async t => {
  const { root } = await fixture(t);
  const relay = await startRelay(t, root, { reviewerCode: REVIEWER_CODE });
  const client = await mcp(t, relay, (await authorize(relay, REVIEWER_CODE)).tokens.access_token);
  const call = async (name, args) => { const result = await client.callTool({ name, arguments: args }); assert.notEqual(result.isError, true, name); return result.structuredContent; };
  const read = async title => {
    const { transcripts } = await call('scribe_search_transcripts', { query: title });
    const match = transcripts.find(item => item.title === title);
    assert.ok(match, title);
    return call('scribe_get_transcript', { id: match.id });
  };

  // P1: most recent meeting, with its decisions and action items.
  const [latest] = (await call('scribe_recent_transcripts', { limit: 1 })).transcripts;
  assert.equal(latest.title, 'Q4 launch planning');
  const launch = await call('scribe_get_transcript', { id: latest.id });
  assert.equal(launch.next_offset, null, 'one page holds the whole meeting');
  assert.match(launch.text, /\[00:02:44–[^\]]+\] Maya Chen: Decision made: launch moves to the second Tuesday of next month/);
  assert.match(launch.text, /Tom merges the payment retry fix by Friday\. Priya delivers the menu editor empty state by Monday/);

  // P2: search finds what was decided about the launch date.
  const found = await call('scribe_search_transcripts', { query: 'launch date' });
  assert.equal(found.transcripts[0].title, 'Q4 launch planning');
  assert.match(found.transcripts[0].excerpt, /launch date/i);
  assert.equal(found.transcripts[1].excerpt, '…Second item: we need a weekend rota for the launch. I will draft it once the launch date is set.', 'excerpts start on a word');

  // P3: this week's meetings (the last seven days), each with named owners.
  const week = await call('scribe_recent_transcripts', { after: new Date(Date.now() - 7 * DAY).toISOString(), limit: 50 });
  assert.deepEqual(week.transcripts.map(item => item.title), ['Q4 launch planning', 'Weekly design review', 'Customer interview: Lakeside Bakery']);
  assert.match((await read('Weekly design review')).text, /Priya, can you update the spec today\?/);

  // P4: a speaker's point, found by name.
  const hannah = await call('scribe_search_transcripts', { query: 'Hannah' });
  assert.deepEqual(hannah.transcripts.map(item => item.title), ['Customer interview: Lakeside Bakery']);
  assert.match((await read('Customer interview: Lakeside Bakery')).text, /\[00:00:31–[^\]]+\] Hannah Lee: When the Wi-Fi drops, the tablet stops taking orders/);

  // P5: a decision on a specific topic.
  assert.match((await read('Weekly design review')).text, /receipts truncate item names at forty characters/);
});

// N1–N3: what the plugin must not do is also what its tools cannot do.
test('the published tools are read-only, bounded to one library, and carry justified annotations', async t => {
  const { root } = await fixture(t);
  const relay = await startRelay(t, root, { reviewerCode: REVIEWER_CODE });
  const client = await mcp(t, relay, (await authorize(relay, REVIEWER_CODE)).tokens.access_token);
  const { tools } = await client.listTools();
  assert.deepEqual(tools.map(tool => tool.name).sort(), ['fetch', 'scribe_get_transcript', 'scribe_profile', 'scribe_recent_transcripts', 'scribe_search_transcripts', 'search']);
  for (const tool of tools) {
    assert.deepEqual(tool.annotations, { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false }, tool.name);
    assert.doesNotMatch(tool.name, /delete|remove|send|email|write|update|audio|play/i, 'N1/N2: no write, delete, send or audio tool exists');
  }
  // N3: nothing in any tool's input can name another library.
  for (const tool of tools) for (const key of Object.keys(tool.inputSchema.properties ?? {})) assert.doesNotMatch(key, /owner|library|user|account/i, `${tool.name}.${key}`);
  // Results carry meeting data only: no owner IDs, tokens or file paths.
  const text = JSON.stringify(await client.callTool({ name: 'scribe_recent_transcripts', arguments: { limit: 50 } }));
  assert.doesNotMatch(text, /reviewer-demo|Bearer|\/Users\/|\.m4a/);
});

test('public privacy, terms and support pages, and the domain-verification token', async t => {
  const { root } = await fixture(t);
  const relay = await startRelay(t, root, { appsChallenge: 'oa-challenge-4f9c2e', legal: { publisher: 'Cooperativ Labs', contactEmail: 'privacy@example.com' } });
  for (const [route, heading] of [['/privacy', /Privacy policy/], ['/terms', /Terms of use/], ['/support', /Support/]]) {
    const response = await fetch(relay.origin + route);
    assert.equal(response.status, 200, route);
    assert.match(response.headers.get('content-type'), /text\/html/);
    assert.match(response.headers.get('content-security-policy'), /default-src 'none'/);
    const html = await response.text();
    assert.match(html, heading);
    assert.match(html, /mailto:privacy@example\.com/, `${route} names the contact`);
    assert.doesNotMatch(html, /<script/i);
  }
  const privacy = await (await fetch(relay.origin + '/privacy')).text();
  // What OpenAI requires a privacy policy to state.
  for (const section of [/What the relay stores/, /How we use data, and who receives it/, /Kept until/, /Your controls/, /Children/, /does not store or log it/]) assert.match(privacy, section);
  assert.match(privacy, new RegExp(`relay service at <strong>${new URL(relay.origin).host}`), 'the page names the relay it is served from');
  assert.match(await (await fetch(relay.origin + '/')).text(), /href="\/privacy"[\s\S]*href="\/terms"[\s\S]*href="\/support"/, 'the home page links to them');

  const challenge = await fetch(relay.origin + '/.well-known/openai-apps-challenge');
  assert.equal(challenge.status, 200);
  assert.match(challenge.headers.get('content-type'), /^text\/plain/);
  assert.equal(await challenge.text(), 'oa-challenge-4f9c2e', 'only the token, nothing else');

  const bare = await startRelay(t, root, { stateFile: undefined, ownersFile: undefined });
  assert.equal((await fetch(bare.origin + '/.well-known/openai-apps-challenge')).status, 404);
  assert.match(await (await fetch(bare.origin + '/privacy')).text(), /github\.com\/cooperativ-labs\/Scribe\/issues/, 'without an email, support goes to GitHub issues');
  assert.throws(() => legalConfig({ contactEmail: 'not an email' }), /email/);
});

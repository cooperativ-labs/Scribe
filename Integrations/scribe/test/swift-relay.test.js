import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { access, mkdir, writeFile, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { fixture } from './fixture.js';
import { CALLBACK, startRelay } from './relay-fixture.js';

const bin = path.join(process.env.SCRIBE_MCP_BIN_DIR || fileURLToPath(new URL('../../../Workers/ScribeMCP/.build/debug', import.meta.url)), 'scribe-relay-test-client');
let built = true; try { await access(bin); } catch { built = false; }

function lines(child) {
  const queued = [], waiting = [];
  let errors = '';
  child.stderr.on('data', data => { errors += data.toString(); });
  createInterface({ input: child.stdout }).on('line', line => {
    if (waiting.length) waiting.shift()(line); else queued.push(line);
  });
  return async prefix => {
    const deadline = Date.now() + 8000;
    while (Date.now() < deadline) {
      const line = queued.length ? queued.shift() : await Promise.race([
        new Promise(resolve => waiting.push(resolve)),
        new Promise((_, reject) => setTimeout(() => reject(new Error(`Timed out waiting for ${prefix}; stderr=${errors}`)), 8000)),
      ]);
      if (line.startsWith('error:') || line.startsWith('run-error:') || line.startsWith('Relay unavailable')) throw new Error(`${line}; stderr=${errors}`);
      if (line.startsWith(prefix)) return line;
    }
    throw new Error(`Timed out waiting for ${prefix}`);
  };
}

async function synthetic(root) {
  const meeting = randomUUID(), id = randomUUID(), date = '2026-09-20T10:00:00Z';
  const dir = path.join(root, `meeting--${meeting}`, 'runs', id.toUpperCase());
  await mkdir(dir, { recursive: true });
  await writeFile(path.join(dir, 'job.json'), JSON.stringify({ schemaVersion: 1, id: randomUUID().toUpperCase(), runID: id.toUpperCase(),
    request: { requestID: randomUUID().toUpperCase(), sourceURL: 'file:///synthetic.m4a', languageMode: 'automatic', speakerCount: 'automatic', speakerMatching: 'enabled', modelProfileID: 'parakeet-v3' },
    sourceSnapshotURL: `file://${root}/meeting--${meeting}/source.m4a`, runDirectoryURL: '/synthetic/', sourceFingerprint: meeting,
    modelFingerprint: 'model', configurationFingerprint: 'config', state: 'complete', checkpoints: [], createdAt: date, updatedAt: date }));
  await writeFile(path.join(dir, 'canonical-transcript.json'), JSON.stringify({ schema_version: 1, transcript_id: randomUUID(), revision: 1,
    title: 'Swift relay planning', status: 'complete', created_at: date,
    source: { filename: 'synthetic.m4a', duration_ms: 60_000, checksum: 'sha256' }, language: 'en', language_source: 'detected',
    timestamp_unit: 'milliseconds', timestamp_origin: 'source_start',
    speakers: [{ id: 'speaker_1', identity_assignment: 'manual', label_snapshot: 'Dana' }],
    segments: [{ id: 'segment_1', speaker_id: 'speaker_1', speaker_label: 'Dana', start_ms: 1000, end_ms: 2000,
      text: 'Swift ships on Friday.', overlap: false, timing_quality: 'asr_word' }],
    processing_options: {}, engine_revisions: {}, warnings: [] }));
}

test('Swift client links, answers the Node relay, revokes and unlinks', { skip: !built && 'build Workers/ScribeMCP first (swift build)' }, async t => {
  const { root } = await fixture(t);
  await synthetic(root);
  const relay = await startRelay(t, root);
  const credentials = path.join(root, 'state/relay.json');
  const child = spawn(bin, [relay.origin, root, credentials], { stdio: ['pipe', 'pipe', 'pipe'], env: { ...process.env, PATH: '/usr/bin:/bin' } });
  t.after(() => { child.stdin.end(); child.kill(); });
  const next = lines(child);
  await next('connected');
  assert.equal((await stat(credentials)).mode & 0o777, 0o600);
  child.stdin.write('code\n');
  const code = (await next('code: ')).slice(6);
  assert.match(code, /^[0-9A-HJKMNP-TV-Z]{5}-[0-9A-HJKMNP-TV-Z]{5}$/);

  const registration = await fetch(relay.origin + '/register', { method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ client_name: 'Swift test', redirect_uris: [CALLBACK], token_endpoint_auth_method: 'none', grant_types: ['authorization_code', 'refresh_token'] }) });
  const oauth = await registration.json();
  const verifier = randomBytes(32).toString('base64url');
  const challenge = createHash('sha256').update(verifier).digest('base64url');
  const authorize = await fetch(relay.origin + '/authorize?' + new URLSearchParams({ client_id: oauth.client_id, redirect_uri: CALLBACK,
    response_type: 'code', code_challenge: challenge, code_challenge_method: 'S256', scope: 'transcripts.read', state: 's', resource: relay.origin + '/mcp' }));
  const request = (await authorize.text()).match(/name="request" value="([^"]+)"/)[1];
  const approval = await fetch(relay.origin + '/consent', { method: 'POST', redirect: 'manual', headers: { Origin: relay.origin },
    body: new URLSearchParams({ request, decision: 'allow', link_code: code }) });
  assert.equal(approval.status, 303);
  const authorizationCode = new URL(approval.headers.get('location')).searchParams.get('code');
  const tokenResponse = await fetch(relay.origin + '/token', { method: 'POST', body: new URLSearchParams({ grant_type: 'authorization_code',
    client_id: oauth.client_id, code: authorizationCode, code_verifier: verifier, redirect_uri: CALLBACK, resource: relay.origin + '/mcp' }) });
  assert.equal(tokenResponse.status, 200);
  const token = (await tokenResponse.json()).access_token;
  const client = new Client({ name: 'swift-relay-test', version: '1' });
  t.after(() => client.close());
  await client.connect(new StreamableHTTPClientTransport(new URL(relay.origin + '/mcp'), { requestInit: { headers: { Authorization: `Bearer ${token}` } } }));
  const recent = await client.callTool({ name: 'scribe_recent_transcripts', arguments: {} });
  assert.deepEqual(recent.structuredContent.transcripts.map(item => item.title), ['Swift relay planning']);
  const fetched = await client.callTool({ name: 'scribe_get_transcript', arguments: { id: recent.structuredContent.transcripts[0].id } });
  assert.match(fetched.structuredContent.text, /Swift ships on Friday/);
  child.stdin.write('revoke\n'); await next('revoked');
  assert.equal((await fetch(relay.origin + '/mcp', { headers: { Authorization: `Bearer ${token}` } })).status, 401);
  child.stdin.write('unlink\n'); await next('unlinked');
  await assert.rejects(access(credentials));
});

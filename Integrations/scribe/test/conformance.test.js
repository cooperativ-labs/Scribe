// Drives the Node stdio server and the Swift helper (Scribe.app's
// Contents/Helpers/scribe-mcp, started through scribe-mcp-launcher) with the
// official MCP client against one synthetic library, and requires identical
// answers, so the two cannot diverge while both exist.
//
// The Swift binaries come from Workers/ScribeMCP (`swift build` there), or from
// SCRIBE_MCP_BIN_DIR, which must then contain both. Without them this test is
// skipped, never passed.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const binDir = process.env.SCRIBE_MCP_BIN_DIR || fileURLToPath(new URL('../../../Workers/ScribeMCP/.build/debug', import.meta.url));
const helper = path.join(binDir, 'scribe-mcp'), launcher = path.join(binDir, 'scribe-mcp-launcher');
const built = existsSync(helper) && existsSync(launcher);
if (!built && process.env.SCRIBE_MCP_BIN_DIR) throw new Error(`SCRIBE_MCP_BIN_DIR has no scribe-mcp and scribe-mcp-launcher: ${binDir}`);

// A library in the format Scribe.app writes: complete job.json records and
// canonical transcripts the app's own decoder accepts.
async function library(t) {
  const root = await mkdtemp(path.join(tmpdir(), 'scribe-conformance-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const ids = {};
  async function run(key, { meeting, date, title = null, filename = 'Planning call.m4a', speakers = [['speaker_1', 'Dana']], segments, revision = 1,
    warnings = [], directory, complete = true, corrupt = false }) {
    const id = randomUUID(); ids[key] = id;
    const dir = path.join(root, `meeting--${meeting}`, 'runs', directory || id.toUpperCase());
    await mkdir(dir, { recursive: true });
    // Scribe.app writes job dates in UTC without fractions.
    const jobDate = new Date(date).toISOString().replace('.000Z', 'Z');
    await writeFile(path.join(dir, 'job.json'), JSON.stringify({ schemaVersion: 1, id: randomUUID().toUpperCase(), runID: id.toUpperCase(),
      request: { requestID: randomUUID().toUpperCase(), sourceURL: 'file:///must/not/be/read.m4a', languageMode: 'automatic', speakerCount: 'automatic',
        speakerMatching: 'enabled', modelProfileID: 'parakeet-v3' },
      sourceSnapshotURL: `file://${root}/meeting--${meeting}/source.m4a`, runDirectoryURL: '/must/not/be/read/', sourceFingerprint: meeting,
      modelFingerprint: 'model', configurationFingerprint: 'configuration', state: complete ? 'complete' : 'transcribing', checkpoints: [],
      createdAt: jobDate, updatedAt: jobDate }));
    if (!complete) return;
    const transcript = { schema_version: 1, transcript_id: randomUUID(), revision, title, status: warnings.length ? 'completeWithWarnings' : 'complete',
      created_at: date, source: { filename, duration_ms: 3_600_000, checksum: 'sha256' }, language: 'en', language_source: 'detected',
      timestamp_unit: 'milliseconds', timestamp_origin: 'source_start',
      speakers: speakers.map(([id, label]) => ({ id, identity_assignment: 'manual', label_snapshot: label })),
      segments: segments.map(([speaker, start, text], index) => ({ id: `segment_${index}`, speaker_id: speaker, speaker_label: 'Old label',
        start_ms: start, end_ms: start + 4000, text, overlap: false, timing_quality: 'asr_word' })),
      processing_options: {}, engine_revisions: {}, warnings };
    await writeFile(path.join(dir, 'canonical-transcript.json'), corrupt ? '{"schema_version": 1' : JSON.stringify(transcript, null, 2));
  }
  const long = Array.from({ length: 900 }, (_, i) => [i % 2 ? 'speaker_2' : 'speaker_1', i * 5000,
    `Point ${i}: 😀 we café-tested the rollout plan, ÉTÉ notes and next steps for the quarterly review.`]);
  await run('older', { meeting: 'a', date: '2026-09-18T09:00:00Z', segments: [['speaker_1', 0, 'Superseded draft about Friday.']] });
  await run('planning', { meeting: 'a', date: '2026-09-20T10:00:00Z', title: '  Planning  ', directory: randomUUID().toUpperCase(),
    speakers: [['speaker_1', 'Dana'], ['speaker_2', 'Updated Name']],
    segments: [['speaker_1', 1000, 'Ship the project on Friday.'], ['speaker_2', 65_000, 'Literal [query] matters.'], [null, 3_725_000, 'Unknown voice.']],
    warnings: [{ code: 'low_confidence', message: 'Some words were unclear.', segment_id: 'segment_1' }] });
  await run('processing', { meeting: 'a', date: '2026-09-21T10:00:00Z', complete: false });
  await run('long', { meeting: 'b', date: '2026-09-19T08:30:00Z', filename: '/Users/someone/Recordings/All hands.mp4',
    speakers: [['speaker_1', 'Ana'], ['speaker_2', 'Bo']], segments: long, revision: 3 });
  await run('excerpt', { meeting: 'c', date: '2026-09-17T12:00:00+02:00', title: 'Design review',
    segments: [['speaker_1', 0, `${'lorem ipsum dolor '.repeat(12)}the needle sits here ${'and the text keeps going on '.repeat(12)}`]] });
  await run('broken', { meeting: 'd', date: '2026-09-16T12:00:00Z', corrupt: true, segments: [] });
  await mkdir(path.join(root, 'meeting--empty'));
  return { root, ids };
}

async function connect(t, command, args, env) {
  const client = new Client({ name: 'conformance', version: '1.0.0' });
  await client.connect(new StdioClientTransport({ command, args, env, stderr: 'pipe' }));
  t.after(() => client.close());
  return client;
}

// Every successful result must carry the same structured content, and the same
// JSON as text. Failures compare their message, except input-validation errors,
// whose wording comes from each SDK.
function normalize(result, { validation = false } = {}) {
  if (result.isError) return { isError: true, text: validation ? undefined : result.content[0].text };
  assert.equal(result.content.length, 1); assert.equal(result.content[0].type, 'text');
  return { structuredContent: result.structuredContent, text: JSON.parse(result.content[0].text) };
}

test('Swift helper and Node stdio server answer identically', { skip: !built && 'build Workers/ScribeMCP first (swift build)' }, async t => {
  const { root, ids } = await library(t);
  const node = await connect(t, process.execPath, [fileURLToPath(new URL('../src/cli.js', import.meta.url)), 'stdio'], { SCRIBE_TRANSCRIPTS_DIR: root });
  // The launcher execs the helper; a PATH without node proves neither needs it.
  const swift = await connect(t, launcher, [], { SCRIBE_TRANSCRIPTS_DIR: root, SCRIBE_MCP_HELPER: helper, PATH: '/usr/bin:/bin' });
  const both = async request => Promise.all([request(node), request(swift)]);
  const same = async (label, request) => { const [a, b] = await both(request); assert.deepEqual(b, a, label); return a; };

  await same('server info', c => c.getServerVersion());
  await same('instructions', c => c.getInstructions());
  await same('capabilities', c => c.getServerCapabilities());
  // Node's SDK adds execution.taskSupport "forbidden", the default an absent field means.
  await same('tools', async c => (await c.listTools()).tools.map(({ execution, ...tool }) => {
    if (execution) assert.deepEqual(execution, { taskSupport: 'forbidden' });
    return tool;
  }));
  await same('prompts', c => c.listPrompts());
  await same('prompt', c => c.getPrompt({ name: 'scribe-meeting-notes', arguments: {} }));
  await same('prompt with meeting', c => c.getPrompt({ name: 'scribe-meeting-notes', arguments: { meeting: 'the design review' } }));
  await same('resources', c => c.listResources());
  await same('resource templates', c => c.listResourceTemplates());
  await same('viewer', c => c.readResource({ uri: 'ui://scribe/transcripts-v1.html' }));

  const call = (name, args = {}, options) => async c => normalize(await c.callTool({ name, arguments: args }), options);
  const recent = await same('recent', call('scribe_recent_transcripts'));
  assert.equal(recent.structuredContent.total, 3); assert.equal(recent.structuredContent.skipped_runs, 3);
  assert.equal(recent.structuredContent.transcripts[0].id, ids.planning);
  for (const args of [{ limit: 1 }, { limit: 1, offset: 1 }, { limit: 2, offset: 2 }, { offset: 50 }, { after: '2026-09-19T08:30:00Z' },
    { before: '2026-09-19T08:30:00Z' }, { after: '2026-09-17T11:00:00+01:00', before: '2026-09-20T00:00:00.000Z', limit: 50 }])
    await same(`recent ${JSON.stringify(args)}`, call('scribe_recent_transcripts', args));
  for (const query of ['friday', 'UPDATED NAME', '[query]', 'needle', 'Planning', 'café', 'été', '😀 we', 'all hands', '  point 899  ', 'nothing matches this'])
    await same(`search ${query}`, call('scribe_search_transcripts', { query, limit: 50 }));
  await same('search paged', call('scribe_search_transcripts', { query: 'e', limit: 1, offset: 1 }));
  await same('research search', call('search', { query: 'the' }));

  for (const key of ['planning', 'excerpt']) await same(`get ${key}`, call('scribe_get_transcript', { id: ids[key] }));
  await same('get by uppercase id', call('scribe_get_transcript', { id: ids.planning.toUpperCase() }));
  await same('fetch', call('fetch', { id: ids.long }));
  // Page the long transcript to the end, including pages that would split an emoji.
  for (const max_chars of [1000, 1234, 24000]) {
    let offset = 0, pages = 0;
    while (offset !== null) {
      const page = await same(`page ${max_chars}@${offset}`, call('scribe_get_transcript', { id: ids.long, offset, max_chars, revision: 3 }));
      offset = page.structuredContent.next_offset; pages++;
    }
    assert.ok(pages > 1);
  }
  await same('changed revision', call('scribe_get_transcript', { id: ids.long, revision: 2 }));
  await same('superseded run', call('scribe_get_transcript', { id: ids.older }));
  await same('missing run', call('scribe_get_transcript', { id: randomUUID() }));
  await same('unfinished run', call('scribe_get_transcript', { id: ids.processing }));
  await same('offset beyond end', call('scribe_get_transcript', { id: ids.planning, offset: 999_999 }));
  for (const [name, args] of [['scribe_recent_transcripts', { limit: 999 }], ['scribe_recent_transcripts', { limit: 1.5 }],
    ['scribe_recent_transcripts', { offset: -1 }], ['scribe_recent_transcripts', { after: 'yesterday' }], ['scribe_recent_transcripts', { before: '2026-09-20' }],
    ['scribe_search_transcripts', {}], ['scribe_search_transcripts', { query: '   ' }], ['scribe_search_transcripts', { query: 'x'.repeat(301) }],
    ['scribe_get_transcript', { id: 'not-a-uuid' }], ['scribe_get_transcript', { id: ids.long, max_chars: 999 }],
    ['scribe_get_transcript', { id: ids.long, revision: -1 }], ['fetch', {}], ['search', { query: '' }]]) {
    const result = await same(`invalid ${name} ${JSON.stringify(args)}`, call(name, args, { validation: true }));
    assert.equal(result.isError, true);
  }

  const unavailable = await connect(t, launcher, [], { SCRIBE_TRANSCRIPTS_DIR: path.join(root, 'missing'), SCRIBE_MCP_HELPER: helper });
  const missingNode = await connect(t, process.execPath, [fileURLToPath(new URL('../src/cli.js', import.meta.url)), 'stdio'], { SCRIBE_TRANSCRIPTS_DIR: path.join(root, 'missing') });
  assert.deepEqual(await call('scribe_recent_transcripts')(unavailable), await call('scribe_recent_transcripts')(missingNode));
});

// A client may write its requests and close stdin; both servers answer them all.
test('both servers answer requests written before stdin closes', { skip: !built && 'build Workers/ScribeMCP first (swift build)' }, async t => {
  const { root } = await library(t);
  const requests = [{ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 't', version: '1' } } },
    { jsonrpc: '2.0', method: 'notifications/initialized' },
    { jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'scribe_recent_transcripts', arguments: {} } },
    { jsonrpc: '2.0', id: 3, method: 'tools/list' }].map(message => JSON.stringify(message)).join('\n') + '\n';
  const answers = (command, args, env) => {
    const { status, stdout } = spawnSync(command, args, { input: requests, env, encoding: 'utf8', timeout: 20_000 });
    assert.equal(status, 0);
    return stdout.trim().split('\n').map(line => JSON.parse(line).id).sort();
  };
  assert.deepEqual(answers(process.execPath, [fileURLToPath(new URL('../src/cli.js', import.meta.url)), 'stdio'], { SCRIBE_TRANSCRIPTS_DIR: root }), [1, 2, 3]);
  assert.deepEqual(answers(launcher, [], { SCRIBE_TRANSCRIPTS_DIR: root, SCRIBE_MCP_HELPER: helper, PATH: '/usr/bin:/bin' }), [1, 2, 3]);
});

test('launcher explains a missing helper in one line', { skip: !built && 'build Workers/ScribeMCP first (swift build)' }, () => {
  const { status, stdout, stderr } = spawnSync(launcher, [], { input: '', env: { SCRIBE_MCP_HELPER: '/nonexistent/scribe-mcp' }, encoding: 'utf8' });
  assert.notEqual(status, 0); assert.equal(stdout, '');
  assert.match(stderr, /^scribe-mcp-launcher: .+\n$/);
});

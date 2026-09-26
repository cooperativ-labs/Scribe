import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { fileURLToPath } from 'node:url';
import { createScribeServer } from '../src/server.js';
import { TranscriptLibrary } from '../src/store.js';
import { fixture } from './fixture.js';

test('official MCP client discovers tools, resources and prompts, then retrieves recent transcript', async t => {
  const { root, add } = await fixture(t); const transcript = await add();
  const server = createScribeServer(new TranscriptLibrary(root), { authenticated: true });
  const client = new Client({ name: 'test', version: '1.0.0' });
  const [a, b] = InMemoryTransport.createLinkedPair();
  await server.connect(a); await client.connect(b);
  t.after(async () => { await client.close(); await server.close(); });
  const { tools } = await client.listTools(); assert.equal(tools.length, 5);
  assert.ok(tools.every(tool => tool.annotations.readOnlyHint && tool.outputSchema && tool._meta.securitySchemes[0].type === 'oauth2'));
  const recent = await client.callTool({ name: 'scribe_recent_transcripts', arguments: {} });
  assert.equal(recent.structuredContent.transcripts[0].id, transcript.id);
  const read = await client.callTool({ name: 'scribe_get_transcript', arguments: { id: transcript.id } });
  assert.match(read.structuredContent.text, /Ship the project/);
  assert.equal((await client.callTool({ name: 'scribe_search_transcripts', arguments: { query: 'Friday' } })).structuredContent.total, 1);
  assert.equal((await client.callTool({ name: 'fetch', arguments: { id: transcript.id } })).structuredContent.id, transcript.id);
  assert.equal((await client.callTool({ name: 'search', arguments: { query: 'Friday' } })).structuredContent.results.length, 1);
  assert.equal((await client.callTool({ name: 'scribe_recent_transcripts', arguments: { limit: 999 } })).isError, true);
  assert.equal((await client.callTool({ name: 'scribe_get_transcript', arguments: { id: transcript.id, revision: 999 } })).isError, true);
  assert.equal((await client.listPrompts()).prompts.length, 1);
  const resource = (await client.listResources()).resources[0];
  assert.match((await client.readResource({ uri: resource.uri })).contents[0].text, /ui\/initialize/);
});
test('stdio process emits only MCP on stdout', async t => {
  const { root, add } = await fixture(t); await add();
  const client = new Client({ name: 'stdio-test', version: '1' });
  const transport = new StdioClientTransport({ command: process.execPath,
    args: [process.env.SCRIBE_TEST_BUNDLE || fileURLToPath(new URL('../src/cli.js', import.meta.url)), 'stdio'], env: { SCRIBE_TRANSCRIPTS_DIR: root }, stderr: 'pipe' });
  t.after(() => client.close());
  await client.connect(transport);
  const recent = await client.callTool({ name: 'scribe_recent_transcripts', arguments: {} });
  assert.equal(recent.structuredContent.total, 1);
  assert.equal((await client.readResource({ uri: 'ui://scribe/transcripts-v1.html' })).contents[0].mimeType, 'text/html;profile=mcp-app');
});

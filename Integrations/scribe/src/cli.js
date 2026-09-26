#!/usr/bin/env node
import { homedir } from 'node:os';
import path from 'node:path';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { TranscriptLibrary } from './store.js';
import { createScribeServer } from './server.js';
import { createHTTPApp } from './http.js';

const command = process.argv[2] ?? 'stdio';
const stateDir = process.env.SCRIBE_MCP_STATE_DIR || path.join(homedir(), 'Library/Application Support/Scribe/MCP');
const keyPath = path.join(stateDir, 'owner-key');
try {
  if (command === 'init') {
    mkdirSync(stateDir, { recursive: true, mode: 0o700 });
    writeFileSync(keyPath, randomBytes(32).toString('base64url') + '\n', { flag: 'wx', mode: 0o600 });
    console.error(`Owner key created at ${keyPath}. Use it only in the Scribe consent page, never in a chat. Existing keys are never overwritten.`);
  } else if (command === 'stdio') {
    const library = new TranscriptLibrary(process.env.SCRIBE_TRANSCRIPTS_DIR || path.join(homedir(), 'Meeting Transcripts'));
    await createScribeServer(library).connect(new StdioServerTransport());
  } else if (command === 'http') {
    const library = new TranscriptLibrary(process.env.SCRIBE_TRANSCRIPTS_DIR || path.join(homedir(), 'Meeting Transcripts'));
    if (!process.env.SCRIBE_PUBLIC_URL) throw new Error('Set SCRIBE_PUBLIC_URL to your HTTPS origin.');
    const { app } = createHTTPApp(library, { origin: process.env.SCRIBE_PUBLIC_URL,
      ownerKey: readFileSync(keyPath, 'utf8').trim(),
      redirectURIs: JSON.parse(process.env.SCRIBE_OAUTH_REDIRECT_URIS || '[]'),
      stateFile: path.join(stateDir, 'oauth-state.json') });
    const port = Number(process.env.SCRIBE_MCP_PORT || 8766);
    if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid SCRIBE_MCP_PORT.');
    const listener = app.listen(port, '127.0.0.1', () => console.error(`Scribe MCP listening on 127.0.0.1:${port}; public resource ${process.env.SCRIBE_PUBLIC_URL.replace(/\/$/, '')}/mcp`));
    listener.on('error', () => { console.error('Scribe MCP could not bind its port. Is another instance running?'); process.exitCode = 1; });
    for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => listener.close());
  } else if (command === 'help' || command === '--help') {
    console.log('Scribe MCP: node src/cli.js [stdio|init|http]\nSee Integrations/scribe/README.md for ChatGPT and Claude setup.');
  } else throw new Error('Unknown command. Use stdio, init, http, or help.');
} catch (error) { console.error(`Scribe MCP: ${error.code === 'ENOENT' ? 'Missing owner key. Run the init command first.' : error.message}`); process.exitCode = 1; }

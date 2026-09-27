#!/usr/bin/env node
import { homedir } from 'node:os';
import path from 'node:path';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { TranscriptLibrary } from './store.js';
import { createScribeServer } from './server.js';
import { createHTTPApp } from './http.js';
import { createRelayApp, DEFAULT_RELAY_REDIRECT_URIS } from './relay.js';
import { CHATGPT_CLIENT_METADATA } from './auth.js';
import { RelayAccount, RelayCredentials, runAgent } from './agent.js';

const [command = 'stdio', argument] = process.argv.slice(2);
const stateDir = process.env.SCRIBE_MCP_STATE_DIR || path.join(homedir(), 'Library/Application Support/Scribe/MCP');
const keyPath = path.join(stateDir, 'owner-key');
const library = () => new TranscriptLibrary(process.env.SCRIBE_TRANSCRIPTS_DIR || path.join(homedir(), 'Meeting Transcripts'));
const account = () => new RelayAccount(new RelayCredentials(path.join(stateDir, 'relay.json')));
const redirectURIs = fallback => process.env.SCRIBE_OAUTH_REDIRECT_URIS ? JSON.parse(process.env.SCRIBE_OAUTH_REDIRECT_URIS) : fallback;
const port = fallback => {
  const value = Number(process.env.SCRIBE_MCP_PORT || process.env.PORT || fallback);
  if (!Number.isInteger(value) || value < 1 || value > 65535) throw new Error('Invalid SCRIBE_MCP_PORT.');
  return value;
};
const trustProxy = () => {
  const value = process.env.SCRIBE_TRUST_PROXY;
  if (!value) return undefined;
  if (!/^\d+$/.test(value)) throw new Error('SCRIBE_TRUST_PROXY must be the number of proxies in front of the relay.');
  return Number(value);
};
function listen(app, host, value, label) {
  const listener = app.listen(value, host, () => console.error(`${label} listening on ${host}:${value}; public resource ${process.env.SCRIBE_PUBLIC_URL.replace(/\/$/, '')}/mcp`));
  listener.on('error', () => { console.error('Scribe MCP could not bind its port. Is another instance running?'); process.exitCode = 1; });
  for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => { listener.closeAllConnections(); listener.close(); });
}
// A packaged CLI knows the relay its ChatGPT plugin names (connector.json beside dist/).
const packagedRelay = () => { try { return JSON.parse(readFileSync(new URL('../connector.json', import.meta.url), 'utf8')).connector_url; } catch { return undefined; } };
const relayArgument = () => argument || process.env.SCRIBE_RELAY_URL;
try {
  if (command === 'init') {
    mkdirSync(stateDir, { recursive: true, mode: 0o700 });
    writeFileSync(keyPath, randomBytes(32).toString('base64url') + '\n', { flag: 'wx', mode: 0o600 });
    console.error(`Owner key created at ${keyPath}. Use it only in the Scribe consent page, never in a chat. Existing keys are never overwritten.`);
  } else if (command === 'stdio') {
    await createScribeServer(library()).connect(new StdioServerTransport());
  } else if (command === 'http') {
    if (!process.env.SCRIBE_PUBLIC_URL) throw new Error('Set SCRIBE_PUBLIC_URL to your HTTPS origin.');
    const { app } = createHTTPApp(library(), { origin: process.env.SCRIBE_PUBLIC_URL,
      ownerKey: readFileSync(keyPath, 'utf8').trim(), redirectURIs: redirectURIs([]), clientMetadataDocuments: [CHATGPT_CLIENT_METADATA],
      stateFile: path.join(stateDir, 'oauth-state.json') });
    listen(app, '127.0.0.1', port(8766), 'Scribe MCP');
  } else if (command === 'relay') {
    // The hosted service. It never reads a transcript folder.
    if (!process.env.SCRIBE_PUBLIC_URL) throw new Error('Set SCRIBE_PUBLIC_URL to the relay HTTPS origin.');
    const relayState = process.env.SCRIBE_RELAY_STATE_DIR;
    if (!relayState) throw new Error('Set SCRIBE_RELAY_STATE_DIR to a persistent, private directory.');
    const { app } = createRelayApp({ origin: process.env.SCRIBE_PUBLIC_URL, redirectURIs: redirectURIs(DEFAULT_RELAY_REDIRECT_URIS),
      stateFile: path.join(relayState, 'oauth-state.json'), ownersFile: path.join(relayState, 'owners.json'), trustProxy: trustProxy(),
      // Directory review: a reusable code for the synthetic demo library, and OpenAI's domain-verification token.
      reviewerCode: process.env.SCRIBE_REVIEWER_CODE || undefined, appsChallenge: process.env.OPENAI_APPS_CHALLENGE?.trim() || undefined });
    listen(app, process.env.SCRIBE_BIND_HOST || '127.0.0.1', port(8767), 'Scribe relay');
  } else if (command === 'link') {
    const relay = relayArgument() || packagedRelay();
    if (!relay) throw new Error('Give the relay address: link https://relay.example.com');
    const linked = await account().link(relay);
    console.log(`Linked to ${linked.relay}. Connector URL: ${linked.relay}/mcp`);
  } else if (command === 'connect') {
    // Links on first use when a relay address is given, then serves until stopped.
    const owner = account();
    // The packaged relay is only a default for a Mac that is not linked yet.
    const relay = relayArgument() || (owner.credentials.read() ? undefined : packagedRelay());
    if (relay) await owner.link(relay);
    const controller = new AbortController();
    for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => controller.abort());
    // Scribe.app holds this pipe open; if the app quits or crashes, stop serving.
    if (process.env.SCRIBE_EXIT_WITH_PARENT === '1') { for (const event of ['end', 'close']) process.stdin.on(event, () => controller.abort()); process.stdin.resume(); }
    console.error(`Connector URL: ${owner.linked().relay}/mcp`);
    await runAgent({ account: owner, library: library(), signal: controller.signal, log: message => console.error(message) });
  } else if (command === 'code') {
    const { code, expires_at } = await account().linkCode();
    console.log(code);
    console.error(`Enter this code on Scribe's consent page. It works once and expires at ${new Date(expires_at).toLocaleTimeString()}. Never paste it into a chat.`);
  } else if (command === 'grants') {
    const { grants, online } = await account().grants();
    console.log(JSON.stringify({ online, grants }, null, 2));
  } else if (command === 'revoke') {
    if (!argument) throw new Error('Give a connection ID from grants, or --all.');
    await account().revoke(argument === '--all' ? undefined : argument);
    console.error(argument === '--all' ? 'Disconnected every assistant.' : 'Disconnected.');
  } else if (command === 'unlink') {
    await account().unlink();
    console.error('Unlinked. The relay forgot this library and every connection to it.');
  } else if (command === 'help' || command === '--help') {
    console.log(`Scribe MCP: node cli.mjs <command>
  stdio              Serve this Mac's library over stdio (development; Scribe.app
                     ships Contents/Helpers/scribe-mcp for installed plugins)
  link <relay>       Link this Mac's library to a Scribe relay
  connect [relay]    Serve this library through the relay (links first if needed)
  code               Print a one-time link code for the relay consent page
  grants             List assistants connected through the relay
  revoke <id|--all>  Disconnect one or every assistant
  unlink             Forget this library on the relay and remove its link
  relay              Run the hosted relay service
  init, http         Self-hosted bridge behind your own tunnel
See Integrations/scribe/README.md.`);
  } else throw new Error('Unknown command. Run help for the list.');
} catch (error) { console.error(`Scribe MCP: ${error.code === 'ENOENT' ? 'Missing owner key. Run the init command first.' : error.message}`); process.exitCode = 1; }

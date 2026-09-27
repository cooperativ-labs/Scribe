import { existsSync, readFileSync, writeFileSync, renameSync, mkdirSync, rmSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import path from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { libraryCalls } from './server.js';
import { StoreError } from './store.js';

// The Mac side of the relay. It only makes outbound HTTPS requests: it never
// listens on a port, so no tunnel or public address is needed. It answers only
// the read-only calls in libraryCalls, re-validated here, against its own library.

export class RelayError extends Error {
  constructor(message, status) { super(message); this.status = status; }
}

export function relayOrigin(value) {
  const url = new URL(value.includes('://') ? value : `https://${value}`);
  const loopback = url.protocol === 'http:' && ['127.0.0.1', 'localhost'].includes(url.hostname);
  if ((url.protocol !== 'https:' && !loopback) || url.username || url.password || url.search || url.hash || !['/', '/mcp'].includes(url.pathname)) {
    throw new RelayError('The relay address must be an HTTPS origin such as https://relay.example.com.');
  }
  return url.origin;
}

// relay.json holds this Mac's owner ID and agent secret, mode 0600, beside the owner key.
export class RelayCredentials {
  constructor(file) { this.file = file; }
  read() {
    if (!existsSync(this.file)) return undefined;
    const value = JSON.parse(readFileSync(this.file, 'utf8'));
    if (typeof value.relay !== 'string' || typeof value.owner_id !== 'string' || typeof value.agent_secret !== 'string') throw new RelayError('Relay link file is invalid. Unlink and link again.');
    return value;
  }
  write(value) {
    mkdirSync(path.dirname(this.file), { recursive: true, mode: 0o700 });
    const temp = `${this.file}.${randomUUID()}.tmp`;
    writeFileSync(temp, JSON.stringify(value, null, 2) + '\n', { mode: 0o600, flag: 'wx' });
    renameSync(temp, this.file);
  }
  remove() { rmSync(this.file, { force: true }); }
}

async function request(relay, route, { method = 'POST', secret, body, signal } = {}) {
  const response = await fetch(relay + route, { method, signal, redirect: 'error',
    headers: { ...(secret ? { Authorization: `Bearer ${secret}` } : {}), ...(body ? { 'Content-Type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined });
  const text = await response.text();
  const data = text ? JSON.parse(text) : undefined;
  if (!response.ok) throw new RelayError(data?.error ?? `Relay answered ${response.status}.`, response.status);
  return data;
}

// Owner-side operations, all authenticated with this Mac's agent secret.
export class RelayAccount {
  constructor(credentials) { this.credentials = credentials; }
  linked() {
    const value = this.credentials.read();
    if (!value) throw new RelayError('This Mac is not linked to a Scribe relay yet. Run link first.');
    return value;
  }
  async link(relayURL) {
    const relay = relayOrigin(relayURL);
    const existing = this.credentials.read();
    if (existing) {
      if (existing.relay !== relay) throw new RelayError(`Already linked to ${existing.relay}. Unlink first to change relays.`);
      return existing;
    }
    const { owner_id, agent_secret } = await request(relay, '/agent/register');
    const value = { relay, owner_id, agent_secret, linked_at: new Date().toISOString() };
    this.credentials.write(value);
    return value;
  }
  async call(route, options = {}) { const { relay, agent_secret } = this.linked(); return request(relay, route, { ...options, secret: agent_secret }); }
  linkCode() { return this.call('/agent/link-codes'); }
  grants() { return this.call('/agent/grants', { method: 'GET' }); }
  revoke(id) { return this.call(id ? `/agent/grants/${encodeURIComponent(id)}` : '/agent/grants', { method: 'DELETE' }); }
  async unlink() {
    try { await this.call('/agent/owner', { method: 'DELETE' }); }
    catch (error) { if (error.status !== 401) throw error; } // already forgotten by the relay
    this.credentials.remove();
  }
}

export async function answer(library, { method, args }) {
  const schema = Object.hasOwn(libraryCalls, method) ? libraryCalls[method] : undefined;
  if (!schema) return { error: 'Unsupported Scribe request.' };
  const parsed = schema.safeParse(args);
  if (!parsed.success) return { error: 'Invalid Scribe request.' };
  try { return { result: await library[method](parsed.data) }; }
  catch (error) { return { error: error instanceof StoreError ? error.message : 'Scribe could not read the transcript library.' }; }
}

// Long-polls until stopped or the relay no longer recognizes this Mac.
export async function runAgent({ account, library, signal, log = () => {}, retryDelays = [1000, 2000, 5000, 10000, 30000] }) {
  const { relay, agent_secret: secret } = account.linked();
  let failures = 0, announced = false;
  while (!signal?.aborted) {
    try {
      const { requests } = await request(relay, '/agent/poll', { secret, signal });
      if (!announced) { log(`Connected to ${relay}. Serving this Mac's Scribe library.`); announced = true; }
      failures = 0;
      for (const call of requests) {
        void answer(library, call).then(result => request(relay, '/agent/responses', { secret, body: { id: call.id, ...result } }))
          .catch(() => log('Could not return a response to the relay.'));
      }
    } catch (error) {
      if (signal?.aborted) break;
      if (error.status === 401) throw new RelayError('The relay no longer recognizes this Mac. It was unlinked; link it again from Scribe.', 401);
      const delay = retryDelays[Math.min(failures++, retryDelays.length - 1)];
      if (announced || failures === 1) log(`Relay unavailable (${error.message}). Retrying in ${delay / 1000}s.`);
      announced = false;
      await sleep(delay * (0.5 + Math.random() / 2), undefined, { signal }).catch(() => {});
    }
  }
}

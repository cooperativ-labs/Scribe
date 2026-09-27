import { randomBytes, randomInt, randomUUID, timingSafeEqual } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync, renameSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import express from 'express';
import { rateLimit } from 'express-rate-limit';
import { createHTTPApp } from './http.js';
import { CHATGPT_CLIENT_METADATA, CODEX_CLIENT_METADATA, hash } from './auth.js';
import { createSiteRouter } from './site.js';
import { createLegalRouter } from './legal.js';
import { DEMO_OWNER, DemoLibrary } from './demo.js';
import { StoreError } from './store.js';

// The Scribe relay gives every Scribe library one stable HTTPS MCP endpoint without
// a tunnel. Each Mac links once, becoming an owner with its own secret, then keeps
// an outbound long-poll open. A client's token names exactly one owner; the relay
// forwards that token's read-only calls to that owner's Mac and relays the answer.
// Transcripts pass through memory only; the relay stores no transcript content.

export const DEFAULT_RELAY_REDIRECT_URIS = [
  // ChatGPT's stable callback, used because this server returns RFC 9207 `iss`.
  'https://chatgpt.com/connector_platform_oauth_redirect',
  'https://claude.ai/api/mcp/auth_callback',
  // The ChatGPT desktop app (Codex) and other native clients, on any loopback port.
  'http://127.0.0.1/callback',
  'http://localhost/callback',
];
const LINK_CODE_ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'; // Crockford base32
const LINK_CODE_LENGTH = 10; // 50 bits, single use, ten minutes
const now = () => Math.floor(Date.now() / 1000);
export const normalizeLinkCode = code => code.toUpperCase().replace(/[\s-]/g, '').replace(/O/g, '0').replace(/[IL]/g, '1');

// Linked owners and their agent secrets (hashed). Link codes live only in memory.
// With a reviewer code, the directory also knows one extra owner, the synthetic
// demo library, reached by typing that code where a link code goes. Unlike a link
// code it is reusable, because reviewers connect again on every surface they test.
export class OwnerDirectory {
  constructor({ stateFile, maxOwners = 10000, linkCodeTTL = 600, reviewerCode } = {}) {
    this.stateFile = stateFile; this.maxOwners = maxOwners; this.linkCodeTTL = linkCodeTTL;
    if (reviewerCode !== undefined && normalizeLinkCode(reviewerCode).length < 20) throw new Error('SCRIBE_REVIEWER_CODE must have at least 20 characters.');
    // Normalized like a link code, and longer than any, so the two never collide.
    this.reviewerHash = reviewerCode === undefined ? undefined : hash(normalizeLinkCode(reviewerCode));
    this.state = stateFile && existsSync(stateFile) ? JSON.parse(readFileSync(stateFile, 'utf8')) : { owners: {} };
    if (!this.state.owners) throw new Error('Invalid Scribe relay owner state.');
    this.secrets = new Map(Object.entries(this.state.owners).map(([id, owner]) => [owner.secretHash, id]));
    this.linkCodes = new Map();
  }
  save() {
    if (!this.stateFile) return;
    mkdirSync(path.dirname(this.stateFile), { recursive: true, mode: 0o700 });
    const temp = `${this.stateFile}.${randomUUID()}.tmp`;
    writeFileSync(temp, JSON.stringify(this.state), { mode: 0o600, flag: 'wx' });
    renameSync(temp, this.stateFile);
  }
  register() {
    if (Object.keys(this.state.owners).length >= this.maxOwners) throw new Error('This relay cannot link more libraries.');
    const ownerId = randomUUID(), agentSecret = randomBytes(32).toString('base64url');
    this.state.owners[ownerId] = { secretHash: hash(agentSecret), linkedAt: now() };
    this.secrets.set(hash(agentSecret), ownerId);
    this.save();
    return { ownerId, agentSecret };
  }
  has(ownerId) { return Object.hasOwn(this.state.owners, ownerId) || (ownerId === DEMO_OWNER && this.reviewerHash !== undefined); }
  authenticate(agentSecret) {
    const ownerId = typeof agentSecret === 'string' ? this.secrets.get(hash(agentSecret)) : undefined;
    return ownerId && Object.hasOwn(this.state.owners, ownerId) ? ownerId : undefined;
  }
  remove(ownerId) {
    const owner = this.state.owners[ownerId];
    if (!owner) return;
    this.secrets.delete(owner.secretHash);
    delete this.state.owners[ownerId];
    for (const [key, value] of this.linkCodes) if (value.ownerId === ownerId) this.linkCodes.delete(key);
    this.save();
  }
  prune() { for (const [key, value] of this.linkCodes) if (value.expiresAt <= now()) this.linkCodes.delete(key); }
  issueLinkCode(ownerId) {
    this.prune();
    if ([...this.linkCodes.values()].filter(value => value.ownerId === ownerId).length >= 5) throw new Error('Too many unused link codes. Wait for one to expire.');
    let code = '';
    for (let i = 0; i < LINK_CODE_LENGTH; i++) code += LINK_CODE_ALPHABET[randomInt(LINK_CODE_ALPHABET.length)];
    const expiresAt = now() + this.linkCodeTTL;
    this.linkCodes.set(hash(code), { ownerId, expiresAt });
    return { code: `${code.slice(0, 5)}-${code.slice(5)}`, expiresAt };
  }
  // Single use: a code is consumed on the first attempt that presents it.
  redeemLinkCode(code) {
    this.prune();
    const key = hash(normalizeLinkCode(code));
    if (this.reviewerHash !== undefined && timingSafeEqual(Buffer.from(key), Buffer.from(this.reviewerHash))) return DEMO_OWNER;
    const entry = this.linkCodes.get(key);
    this.linkCodes.delete(key);
    return entry && entry.expiresAt > now() && this.has(entry.ownerId) ? entry.ownerId : undefined;
  }
}

// Routes each owner's calls to that owner's polling Mac and nowhere else.
export class AgentHub {
  constructor({ pollTimeoutMs = 25000, callTimeoutMs = 30000, offlineAfterMs = 40000, maxQueued = 20 } = {}) {
    Object.assign(this, { pollTimeoutMs, callTimeoutMs, offlineAfterMs, maxQueued });
    this.owners = new Map();
  }
  entry(ownerId) {
    let entry = this.owners.get(ownerId);
    if (!entry) this.owners.set(ownerId, entry = { queue: [], waiters: [], pending: new Map(), lastSeen: 0 });
    return entry;
  }
  online(ownerId) {
    const entry = this.owners.get(ownerId);
    return Boolean(entry && (entry.waiters.length || Date.now() - entry.lastSeen < this.offlineAfterMs));
  }
  call(ownerId, method, args) {
    if (!this.online(ownerId)) return Promise.reject(new StoreError('Your Scribe Mac is not connected. Open Scribe on the Mac that holds your transcripts, keep it awake, and try again.'));
    const entry = this.entry(ownerId);
    if (entry.pending.size >= this.maxQueued) return Promise.reject(new StoreError('Scribe is busy. Try again in a moment.'));
    return new Promise((resolve, reject) => {
      const id = randomUUID();
      const timer = setTimeout(() => { entry.pending.delete(id); entry.queue = entry.queue.filter(request => request.id !== id);
        reject(new StoreError('Your Scribe Mac did not answer in time. Check that it is awake and online.')); }, this.callTimeoutMs);
      entry.pending.set(id, { resolve, reject, timer });
      entry.queue.push({ id, method, args });
      this.flush(entry);
    });
  }
  flush(entry) {
    while (entry.queue.length && entry.waiters.length) entry.waiters.shift()(entry.queue.splice(0));
  }
  // Resolves with queued requests, or with none after the poll timeout.
  poll(ownerId, closed) {
    const entry = this.entry(ownerId);
    entry.lastSeen = Date.now();
    if (entry.queue.length) return Promise.resolve(entry.queue.splice(0));
    return new Promise(resolve => {
      const done = requests => { clearTimeout(timer); entry.waiters = entry.waiters.filter(waiter => waiter !== done); entry.lastSeen = Date.now(); resolve(requests); };
      const timer = setTimeout(() => done([]), this.pollTimeoutMs);
      entry.waiters.push(done);
      closed?.(() => done([]));
    });
  }
  // A Mac may only answer requests that were addressed to its own owner.
  respond(ownerId, id, { result, error }) {
    const entry = this.owners.get(ownerId);
    const pending = entry?.pending.get(id);
    if (!pending) return false;
    entry.pending.delete(id); clearTimeout(pending.timer);
    if (error !== undefined) pending.reject(new StoreError(typeof error === 'string' ? error.slice(0, 500) : 'Scribe could not read the transcript library.'));
    else pending.resolve(result);
    return true;
  }
  disconnect(ownerId) {
    const entry = this.owners.get(ownerId);
    if (!entry) return;
    this.owners.delete(ownerId);
    for (const waiter of entry.waiters) waiter([]);
    for (const pending of entry.pending.values()) { clearTimeout(pending.timer); pending.reject(new StoreError('This Scribe library was unlinked.')); }
  }
}

// What a relay-side MCP server reads: the token owner's Mac, reached through the hub.
export class RemoteLibrary {
  constructor(hub, ownerId) { this.hub = hub; this.ownerId = ownerId; }
  list(args) { return this.hub.call(this.ownerId, 'list', args); }
  get(args) { return this.hub.call(this.ownerId, 'get', args); }
}

export function createRelayApp(config) {
  const owners = config.owners ?? new OwnerDirectory({ stateFile: config.ownersFile, maxOwners: config.maxOwners, reviewerCode: config.reviewerCode });
  const demo = config.demoLibrary ?? new DemoLibrary();
  const hub = config.hub ?? new AgentHub(config.hubOptions);
  const routes = (app, provider) => {
    const agent = express.Router();
    const authenticate = (req, res, next) => {
      const [scheme, secret] = (req.get('authorization') ?? '').split(' ');
      req.ownerId = scheme === 'Bearer' ? owners.authenticate(secret) : undefined;
      if (!req.ownerId) return res.status(401).json({ error: 'This Mac is not linked to the Scribe relay. Link it again from Scribe.' });
      next();
    };
    agent.post('/register', rateLimit({ windowMs: 3600000, limit: config.registrationsPerHour ?? 10 }), (_req, res) => {
      try { const { ownerId, agentSecret } = owners.register(); res.status(201).json({ owner_id: ownerId, agent_secret: agentSecret }); }
      catch (error) { res.status(503).json({ error: error.message }); }
    });
    agent.use(rateLimit({ windowMs: 60000, limit: 600 }), authenticate);
    agent.post('/poll', async (req, res) => {
      const requests = await hub.poll(req.ownerId, onClose => res.on('close', onClose));
      if (!res.writableEnded && !res.destroyed) res.json({ requests });
    });
    agent.post('/responses', express.json({ limit: '2mb' }), (req, res) => {
      if (typeof req.body?.id !== 'string') return res.status(400).json({ error: 'Invalid response.' });
      res.status(hub.respond(req.ownerId, req.body.id, req.body) ? 204 : 404).end();
    });
    agent.post('/link-codes', (req, res) => {
      try { const { code, expiresAt } = owners.issueLinkCode(req.ownerId); res.status(201).json({ code, expires_at: new Date(expiresAt * 1000).toISOString() }); }
      catch (error) { res.status(429).json({ error: error.message }); }
    });
    agent.get('/grants', (req, res) => res.json({ grants: provider.grants(req.ownerId), online: hub.online(req.ownerId) }));
    agent.delete('/grants', (req, res) => { provider.revokeOwner(req.ownerId); res.status(204).end(); });
    agent.delete('/grants/:id', (req, res) => res.status(provider.revokeGrant(req.ownerId, req.params.id) ? 204 : 404).end());
    // Unlinking forgets the owner, every grant, and any call in flight.
    agent.delete('/owner', (req, res) => { provider.revokeOwner(req.ownerId); hub.disconnect(req.ownerId); owners.remove(req.ownerId); res.status(204).end(); });
    app.use('/agent', agent);
    // OpenAI's directory proves domain ownership by fetching this exact token.
    app.get('/.well-known/openai-apps-challenge', (_req, res) => config.appsChallenge ? res.type('text/plain').send(config.appsChallenge) : res.status(404).end());
    app.use(createLegalRouter({ host: new URL(config.origin).host, ...config.legal }));
    // The relay's origin is also Scribe's public address: the page and the
    // download button live at the root, where no relay route ever goes.
    app.use(createSiteRouter(config.site));
  };
  const { app, provider } = createHTTPApp(ownerId => ownerId === DEMO_OWNER ? demo : new RemoteLibrary(hub, ownerId), {
    clientMetadataDocuments: [CHATGPT_CLIENT_METADATA, CODEX_CLIENT_METADATA], ...config, owners, routes, largeBodies: new Set(['/agent/responses']),
    limits: { clients: 100000, grants: 200000, grantsPerOwner: 50, grantsPerOwnerFor: { [DEMO_OWNER]: 2000 }, ...config.limits },
  });
  return { app, provider, owners, hub };
}

import { createHash, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync, renameSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import { InvalidClientMetadataError, InvalidGrantError, InvalidScopeError, InvalidTargetError, InvalidTokenError } from '@modelcontextprotocol/sdk/server/auth/errors.js';

export const SCOPE = 'transcripts.read';
const secret = () => randomBytes(32).toString('base64url');
const hash = value => createHash('sha256').update(value).digest('hex');
const now = () => Math.floor(Date.now() / 1000);
const escape = value => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

// One private Scribe library per process. Persist only token hashes. Client records
// survive restarts; authorization codes and browser consent requests do not.
export class ScribeOAuthProvider {
  constructor({ origin, ownerKey, redirectURIs, stateFile }) {
    if (ownerKey.length < 32) throw new Error('Scribe owner key must have at least 32 characters.');
    if (!redirectURIs.length) throw new Error('Configure exact SCRIBE_OAUTH_REDIRECT_URIS before serving HTTP.');
    for (const uri of redirectURIs) {
      const url = new URL(uri);
      if (url.hash || url.username || url.password || (url.protocol !== 'https:' && !(url.protocol === 'http:' && ['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)))) {
        throw new Error('OAuth redirect URIs must use HTTPS (loopback HTTP is allowed).');
      }
    }
    this.origin = new URL(origin).origin;
    this.resource = `${this.origin}/mcp`;
    this.ownerHash = hash(ownerKey);
    this.redirectURIs = new Set(redirectURIs);
    this.stateFile = stateFile;
    this.pending = new Map(); this.codes = new Map();
    this.state = stateFile && existsSync(stateFile) ? JSON.parse(readFileSync(stateFile, 'utf8')) : { clients: {}, access: {}, refresh: {} };
    if (!this.state.clients || !this.state.access || !this.state.refresh) throw new Error('Invalid Scribe OAuth state.');
    this.clientsStore = {
      getClient: id => Object.hasOwn(this.state.clients, id) ? this.state.clients[id] : undefined,
      registerClient: async client => {
        if (!client.redirect_uris?.length || client.redirect_uris.some(uri => !this.redirectURIs.has(uri))) {
          throw new InvalidClientMetadataError('Redirect URI is not in the Scribe operator allowlist.');
        }
        if (client.scope && client.scope !== SCOPE) throw new InvalidClientMetadataError('Only transcripts.read is supported.');
        if (Object.keys(this.state.clients).length >= 1000) throw new InvalidClientMetadataError('Client limit reached.');
        const record = { ...client, client_id: client.client_id ?? randomUUID(), client_id_issued_at: now() };
        this.state.clients[record.client_id] = record; this.save(); return record;
      },
    };
  }
  save() {
    for (const kind of ['access', 'refresh']) for (const [key, value] of Object.entries(this.state[kind])) {
      if (value.expiresAt <= now()) delete this.state[kind][key];
    }
    if (!this.stateFile) return;
    mkdirSync(path.dirname(this.stateFile), { recursive: true, mode: 0o700 });
    const temp = `${this.stateFile}.${randomUUID()}.tmp`;
    writeFileSync(temp, JSON.stringify(this.state), { mode: 0o600, flag: 'wx' });
    renameSync(temp, this.stateFile);
  }
  checkResource(resource) {
    if (!resource || resource.href !== this.resource) throw new InvalidTargetError('Expected the exact Scribe /mcp resource URL.');
  }
  checkScopes(scopes) {
    if (!scopes?.length || scopes.some(scope => scope !== SCOPE)) throw new InvalidScopeError('Request transcripts.read.');
  }
  async authorize(client, params, res) {
    this.checkResource(params.resource); this.checkScopes(params.scopes);
    if (!this.redirectURIs.has(params.redirectUri)) throw new InvalidClientMetadataError('Redirect URI is no longer allowed.');
    if (!/^[A-Za-z0-9_-]{43}$/.test(params.codeChallenge)) throw new InvalidGrantError('A valid S256 PKCE challenge is required.');
    for (const [key, value] of this.pending) if (value.expiresAt <= now()) this.pending.delete(key);
    if (this.pending.size >= 100) throw new InvalidGrantError('Too many pending consent requests.');
    const request = secret();
    this.pending.set(request, { client, params, expiresAt: now() + 300 });
    res.set({ 'Cache-Control': 'no-store', 'Content-Security-Policy': "default-src 'none'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'", 'Referrer-Policy': 'no-referrer' });
    res.type('html').send(`<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Connect Scribe</title><h1>Connect to your Scribe library</h1><p><strong>${escape(client.client_name || 'MCP client')}</strong> requests read access to all transcripts in the configured library.</p><p>Return to: ${escape(params.redirectUri)}</p><p>Transcript text and speaker names can be sent to this client. Audio and editing are not available.</p><form method="post" action="/consent"><input type="hidden" name="request" value="${request}"><label>Scribe owner key <input type="password" name="owner_key" autocomplete="off" required></label><button name="decision" value="allow">Allow transcript access</button><button name="decision" value="deny" formnovalidate>Deny</button></form></html>`);
  }
  consent(req, res) {
    // A random, single-use request ID plus strict Origin validation binds the form.
    if (req.get('origin') !== this.origin) return res.status(403).send('Invalid consent origin.');
    const pending = this.pending.get(req.body.request);
    this.pending.delete(req.body.request);
    if (!pending || pending.expiresAt <= now()) return res.status(400).send('Consent expired. Start connecting again.');
    const { client, params } = pending;
    const redirect = new URL(params.redirectUri);
    if (params.state) redirect.searchParams.set('state', params.state);
    if (req.body.decision === 'deny') { redirect.searchParams.set('error', 'access_denied'); return res.redirect(303, redirect.href); }
    const supplied = hash(typeof req.body.owner_key === 'string' ? req.body.owner_key : '');
    if (req.body.decision !== 'allow' || !timingSafeEqual(Buffer.from(supplied), Buffer.from(this.ownerHash))) return res.status(403).send('Invalid owner key. Start connecting again.');
    const code = secret();
    for (const [key, value] of this.codes) if (value.expiresAt <= now()) this.codes.delete(key);
    this.codes.set(hash(code), { clientId: client.client_id, ...params, expiresAt: now() + 300 });
    redirect.searchParams.set('code', code);
    res.redirect(303, redirect.href);
  }
  code(client, code) {
    const grant = this.codes.get(hash(code));
    if (!grant || grant.clientId !== client.client_id || grant.expiresAt <= now()) throw new InvalidGrantError('Invalid or expired authorization code.');
    return grant;
  }
  async challengeForAuthorizationCode(client, code) { return this.code(client, code).codeChallenge; }
  async exchangeAuthorizationCode(client, code, _verifier, redirectUri, resource) {
    const grant = this.code(client, code);
    this.codes.delete(hash(code));
    this.checkResource(resource);
    if (grant.redirectUri !== redirectUri || grant.resource.href !== resource.href) throw new InvalidGrantError('Authorization request does not match.');
    return this.issue(client.client_id);
  }
  issue(clientId, family = randomUUID()) {
    this.save();
    if (Object.keys(this.state.refresh).length >= 1000) throw new InvalidGrantError('Token limit reached. Revoke an existing connection.');
    const access = secret(), refresh = secret();
    const common = { clientId, scopes: [SCOPE], resource: this.resource, family };
    this.state.access[hash(access)] = { ...common, expiresAt: now() + 3600 };
    this.state.refresh[hash(refresh)] = { ...common, expiresAt: now() + 30 * 86400 };
    this.save();
    return { access_token: access, token_type: 'Bearer', expires_in: 3600, refresh_token: refresh, scope: SCOPE };
  }
  async exchangeRefreshToken(client, token, scopes, resource) {
    this.checkResource(resource);
    if (scopes) this.checkScopes(scopes);
    const grant = this.state.refresh[hash(token)];
    if (!grant || grant.clientId !== client.client_id || grant.expiresAt <= now() || grant.resource !== resource.href) throw new InvalidGrantError('Invalid refresh token.');
    delete this.state.refresh[hash(token)];
    return this.issue(client.client_id, grant.family);
  }
  async verifyAccessToken(token) {
    const grant = this.state.access[hash(token)];
    if (!grant || grant.expiresAt <= now() || grant.resource !== this.resource || !grant.scopes.includes(SCOPE)) throw new InvalidTokenError('Invalid or expired Scribe access token.');
    return { token, ...grant, resource: new URL(grant.resource) };
  }
  async revokeToken(client, { token }) {
    const grant = this.state.access[hash(token)] ?? this.state.refresh[hash(token)];
    if (!grant || grant.clientId !== client.client_id) return;
    for (const kind of ['access', 'refresh']) for (const [key, value] of Object.entries(this.state[kind])) {
      if (value.family === grant.family) delete this.state[kind][key];
    }
    this.save();
  }
}

import { createHash, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync, renameSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import { consentPage, consentProblemPage } from './consent.js';
import { InvalidClientMetadataError, InvalidGrantError, InvalidScopeError, InvalidTargetError, InvalidTokenError } from '@modelcontextprotocol/sdk/server/auth/errors.js';

export const SCOPE = 'transcripts.read';
// The owner of a self-hosted bridge. A relay names each linked library instead.
export const LOCAL_OWNER = 'local';
const secret = () => randomBytes(32).toString('base64url');
export const hash = value => createHash('sha256').update(value).digest('hex');
const now = () => Math.floor(Date.now() / 1000);
// Browsers apply form-action to the redirect that follows the consent POST, so the
// policy names the one validated callback origin this request returns to.
const consentCSP = callback => `default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; form-action 'self' ${new URL(callback).origin}; frame-ancestors 'none'; base-uri 'none'`;
// ChatGPT's Client ID Metadata Document: one stable client identity for every
// ChatGPT user, so marketplace installs need no dynamic registration.
export const CHATGPT_CLIENT_METADATA = 'https://chatgpt.com/oauth/client.json';
// The ChatGPT desktop app's plugin runtime (Codex): a native client whose callback
// is a loopback URL on a port chosen at sign-in.
export const CODEX_CLIENT_METADATA = 'https://chatgpt.com/oauth/codex/client.json';
const LOOPBACK = ['127.0.0.1', 'localhost', '[::1]'];
const CIMD_TTL = 86400;

// Every token belongs to exactly one owner's library. A self-hosted bridge has one
// owner, approved with the owner key. A relay (`owners` set) has many, and consent
// binds the grant to whichever owner issued the one-time link code typed on the
// consent page; nothing a client sends can name or change the owner afterwards.
// Persist only token hashes. Client records survive restarts; authorization codes
// and browser consent requests do not.
export class ScribeOAuthProvider {
  constructor({ origin, ownerKey, owners, redirectURIs, stateFile, limits = {}, clientMetadataDocuments = [], fetch: fetchDocument = fetch }) {
    if (!owners && !(ownerKey?.length >= 32)) throw new Error('Scribe owner key must have at least 32 characters.');
    if (!redirectURIs.length) throw new Error('Configure exact SCRIBE_OAUTH_REDIRECT_URIS before serving HTTP.');
    for (const uri of redirectURIs) {
      const url = new URL(uri);
      if (url.hash || url.username || url.password || (url.protocol !== 'https:' && !(url.protocol === 'http:' && ['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)))) {
        throw new Error('OAuth redirect URIs must use HTTPS (loopback HTTP is allowed).');
      }
    }
    this.origin = new URL(origin).origin;
    this.issuer = new URL(origin).href;
    this.resource = `${this.origin}/mcp`;
    this.owners = owners;
    this.ownerHash = owners ? undefined : hash(ownerKey);
    this.limits = { clients: 1000, grants: 1000, grantsPerOwner: 50, ...limits };
    this.redirectURIs = new Set(redirectURIs);
    // Only these exact CIMD URLs are ever fetched, so client_id cannot steer requests.
    this.clientMetadataDocuments = new Set(clientMetadataDocuments);
    this.fetchDocument = fetchDocument;
    this.stateFile = stateFile;
    this.pending = new Map(); this.codes = new Map();
    this.state = stateFile && existsSync(stateFile) ? JSON.parse(readFileSync(stateFile, 'utf8')) : { clients: {}, access: {}, refresh: {} };
    if (!this.state.clients || !this.state.access || !this.state.refresh) throw new Error('Invalid Scribe OAuth state.');
    this.clientsStore = {
      getClient: id => this.clientMetadataDocuments.has(id) ? this.metadataClient(id)
        : Object.hasOwn(this.state.clients, id) ? this.state.clients[id] : undefined,
      registerClient: async client => {
        if (!client.redirect_uris?.length || client.redirect_uris.some(uri => !this.allowedRedirect(uri))) {
          throw new InvalidClientMetadataError('Redirect URI is not in the Scribe operator allowlist.');
        }
        if (client.scope && client.scope !== SCOPE) throw new InvalidClientMetadataError('Only transcripts.read is supported.');
        this.pruneClients();
        if (Object.keys(this.state.clients).length >= this.limits.clients) throw new InvalidClientMetadataError('Client limit reached.');
        const record = { ...client, client_id: client.client_id ?? randomUUID(), client_id_issued_at: now() };
        this.state.clients[record.client_id] = record; this.save(); return record;
      },
    };
  }
  // A CIMD client is the document at its client_id URL, refreshed daily. It is a
  // public client: PKCE protects the code, and only allowlisted callbacks are kept.
  // If the document cannot be fetched, the last validated copy keeps working.
  async metadataClient(id) {
    const known = this.state.clients[id];
    if (known?.metadata_fetched_at > now() - CIMD_TTL) return known;
    try {
      const response = await this.fetchDocument(id, { redirect: 'error', signal: AbortSignal.timeout(5000), headers: { Accept: 'application/json' } });
      const text = await response.text();
      if (!response.ok || text.length > 16384) throw new Error('Unavailable client metadata.');
      const document = JSON.parse(text);
      const methods = [document.token_endpoint_auth_methods_supported ?? document.token_endpoint_auth_method].flat();
      const redirects = Array.isArray(document.redirect_uris) ? document.redirect_uris.filter(uri => this.allowedRedirect(uri)) : [];
      if (document.client_id !== id || !methods.includes('none') || !redirects.length) throw new Error('Unusable client metadata.');
      const client = { client_id: id, client_name: typeof document.client_name === 'string' ? document.client_name.slice(0, 100) : undefined,
        redirect_uris: redirects, token_endpoint_auth_method: 'none', grant_types: ['authorization_code', 'refresh_token'], response_types: ['code'],
        client_id_issued_at: known?.client_id_issued_at ?? now(), metadata_fetched_at: now() };
      this.state.clients[id] = client; this.save();
      return client;
    } catch { return known; }
  }
  // Exact match, except that an allowed loopback callback may use any port (RFC 8252
  // §7.3): a native app listens on a port chosen at sign-in, and the code only ever
  // reaches that same machine, where PKCE still binds it to the app that asked.
  allowedRedirect(uri) {
    if (typeof uri !== 'string') return false;
    if (this.redirectURIs.has(uri)) return true;
    let url;
    try { url = new URL(uri); } catch { return false; }
    if (url.protocol !== 'http:' || !LOOPBACK.includes(url.hostname) || url.username || url.password || url.hash) return false;
    url.port = '';
    return this.redirectURIs.has(url.href);
  }
  // Grants from before owner binding were all issued by a self-hosted bridge.
  ownerOf(grant) { return grant.ownerId ?? LOCAL_OWNER; }
  ownerExists(ownerId) { return this.owners ? this.owners.has(ownerId) : ownerId === LOCAL_OWNER; }
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
  // Dynamic registration runs once per connection, so on a shared relay abandoned
  // registrations would eventually exhaust the limit. Drop week-old clients that
  // never received a grant.
  pruneClients() {
    if (Object.keys(this.state.clients).length < this.limits.clients) return;
    const used = new Set(Object.values(this.state.refresh).map(grant => grant.clientId));
    for (const [id, client] of Object.entries(this.state.clients)) {
      if (!used.has(id) && !this.clientMetadataDocuments.has(id) && client.client_id_issued_at < now() - 7 * 86400) delete this.state.clients[id];
    }
  }
  checkResource(resource) {
    if (!resource || resource.href !== this.resource) throw new InvalidTargetError('Expected the exact Scribe /mcp resource URL.');
  }
  checkScopes(scopes) {
    if (!scopes?.length || scopes.some(scope => scope !== SCOPE)) throw new InvalidScopeError('Request transcripts.read.');
  }
  // RFC 9207: name the issuer in every authorization response so a client can
  // detect mix-up attacks. ChatGPT then uses its stable callback for every user.
  callback(uri, values) {
    const redirect = new URL(uri);
    for (const [key, value] of Object.entries(values)) if (value !== undefined) redirect.searchParams.set(key, value);
    redirect.searchParams.set('iss', this.issuer);
    return redirect.href;
  }
  async authorize(client, params, res) {
    this.checkResource(params.resource); this.checkScopes(params.scopes);
    if (!this.allowedRedirect(params.redirectUri)) throw new InvalidClientMetadataError('Redirect URI is no longer allowed.');
    if (!/^[A-Za-z0-9_-]{43}$/.test(params.codeChallenge)) throw new InvalidGrantError('A valid S256 PKCE challenge is required.');
    for (const [key, value] of this.pending) if (value.expiresAt <= now()) this.pending.delete(key);
    if (this.pending.size >= 100) throw new InvalidGrantError('Too many pending consent requests.');
    const request = secret();
    this.pending.set(request, { client, params, attempts: 0, expiresAt: now() + 300 });
    this.renderConsent(res, request, { client, params });
  }
  renderConsent(res, request, { client, params }, error) {
    // same-origin, not no-referrer: under no-referrer a browser submits the form with
    // `Origin: null`, which the consent origin check must refuse. Other sites still get no referrer.
    res.set({ 'Cache-Control': 'no-store', 'Content-Security-Policy': consentCSP(params.redirectUri), 'Referrer-Policy': 'same-origin' });
    res.type('html').send(consentPage({ clientName: client.client_name, redirectUri: params.redirectUri, request, relay: Boolean(this.owners), error }));
  }
  consent(req, res) {
    // A random, single-use request ID plus strict Origin validation binds the form.
    const problem = (status, heading, detail) => res.status(status).set('Content-Security-Policy', "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'")
      .type('html').send(consentProblemPage(heading, detail));
    if (req.get('origin') !== this.origin) return problem(403, 'This request did not come from Scribe', 'For your safety, Scribe only accepts approvals made on its own page. Start connecting again from your assistant.');
    const pending = this.pending.get(req.body.request);
    if (!pending || pending.expiresAt <= now() || !['allow', 'deny'].includes(req.body.decision)) {
      this.pending.delete(req.body.request);
      return problem(400, 'This request has expired', 'Connection requests last five minutes and can be answered once. Start connecting again from your assistant.');
    }
    const { client, params } = pending;
    if (req.body.decision === 'deny') { this.pending.delete(req.body.request); return res.redirect(303, this.callback(params.redirectUri, { error: 'access_denied', state: params.state })); }
    const ownerId = this.consentingOwner(req.body);
    // A mistyped code or key gets the form back, a few times per request; the
    // /consent rate limit and single-use codes still bound guessing.
    if (!ownerId && ++pending.attempts < 3) return this.renderConsent(res.status(403), req.body.request, pending,
      this.owners ? 'That code didn’t work. Check it against Scribe, or press Get Link Code for a new one.' : 'That owner key didn’t work.');
    this.pending.delete(req.body.request);
    if (!ownerId) return this.owners
      ? problem(403, 'That link code didn’t work', 'Link codes work once and expire after ten minutes. In Scribe, press Get Link Code for a new one, then start connecting again from your assistant.')
      : problem(403, 'That owner key didn’t work', 'Check the key in Scribe → Settings → Assistants, then start connecting again from your assistant.');
    const code = secret();
    for (const [key, value] of this.codes) if (value.expiresAt <= now()) this.codes.delete(key);
    this.codes.set(hash(code), { clientId: client.client_id, ownerId, ...params, expiresAt: now() + 300 });
    res.redirect(303, this.callback(params.redirectUri, { code, state: params.state }));
  }
  consentingOwner(body) {
    if (this.owners) return typeof body.link_code === 'string' ? this.owners.redeemLinkCode(body.link_code) : undefined;
    const supplied = hash(typeof body.owner_key === 'string' ? body.owner_key : '');
    return timingSafeEqual(Buffer.from(supplied), Buffer.from(this.ownerHash)) ? LOCAL_OWNER : undefined;
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
    return this.issue(client.client_id, grant.ownerId);
  }
  issue(clientId, ownerId = LOCAL_OWNER, family = randomUUID(), grantedAt = now()) {
    this.save();
    if (!this.ownerExists(ownerId)) throw new InvalidGrantError('This Scribe library is no longer linked.');
    const refresh = Object.values(this.state.refresh);
    const families = new Set(refresh.filter(grant => this.ownerOf(grant) === ownerId && grant.family !== family).map(grant => grant.family));
    if (refresh.length >= this.limits.grants || families.size >= (this.limits.grantsPerOwnerFor?.[ownerId] ?? this.limits.grantsPerOwner)) throw new InvalidGrantError('Token limit reached. Disconnect an existing connection in Scribe.');
    const access = secret(), refreshToken = secret();
    const common = { clientId, ownerId, scopes: [SCOPE], resource: this.resource, family, grantedAt };
    this.state.access[hash(access)] = { ...common, expiresAt: now() + 3600 };
    this.state.refresh[hash(refreshToken)] = { ...common, expiresAt: now() + 30 * 86400 };
    this.save();
    return { access_token: access, token_type: 'Bearer', expires_in: 3600, refresh_token: refreshToken, scope: SCOPE };
  }
  async exchangeRefreshToken(client, token, scopes, resource) {
    this.checkResource(resource);
    if (scopes) this.checkScopes(scopes);
    const grant = this.state.refresh[hash(token)];
    if (!grant || grant.clientId !== client.client_id || grant.expiresAt <= now() || grant.resource !== resource.href) throw new InvalidGrantError('Invalid refresh token.');
    delete this.state.refresh[hash(token)];
    return this.issue(client.client_id, this.ownerOf(grant), grant.family, grant.grantedAt);
  }
  async verifyAccessToken(token) {
    const grant = this.state.access[hash(token)];
    if (!grant || grant.expiresAt <= now() || grant.resource !== this.resource || !grant.scopes.includes(SCOPE) || !this.ownerExists(this.ownerOf(grant))) {
      throw new InvalidTokenError('Invalid or expired Scribe access token.');
    }
    const ownerId = this.ownerOf(grant);
    return { token, ...grant, ownerId, resource: new URL(grant.resource), extra: { ownerId } };
  }
  async revokeToken(client, { token }) {
    const grant = this.state.access[hash(token)] ?? this.state.refresh[hash(token)];
    if (!grant || grant.clientId !== client.client_id) return;
    this.revoke(value => value.family === grant.family);
  }
  revoke(matches) {
    let removed = 0;
    for (const kind of ['access', 'refresh']) for (const [key, value] of Object.entries(this.state[kind])) {
      if (matches(value)) { delete this.state[kind][key]; removed++; }
    }
    for (const [key, value] of this.codes) if (matches(value)) this.codes.delete(key);
    this.save();
    return removed > 0;
  }
  // One entry per connection the owner approved, for the owner's own review.
  grants(ownerId) {
    const families = new Map();
    for (const grant of Object.values(this.state.refresh)) {
      if (this.ownerOf(grant) !== ownerId || grant.expiresAt <= now()) continue;
      const client = this.state.clients[grant.clientId];
      const current = families.get(grant.family);
      if (!current || current.expires_at < grant.expiresAt) families.set(grant.family, { id: grant.family,
        client_name: client?.client_name || 'MCP client', granted_at: grant.grantedAt ?? null, expires_at: grant.expiresAt });
    }
    return [...families.values()].sort((a, b) => (b.granted_at ?? 0) - (a.granted_at ?? 0));
  }
  // Scoped to the owner, so an owner can never revoke (or probe) another owner's grant.
  revokeGrant(ownerId, family) { return this.revoke(value => this.ownerOf(value) === ownerId && value.family === family); }
  revokeOwner(ownerId) { return this.revoke(value => this.ownerOf(value) === ownerId); }
}

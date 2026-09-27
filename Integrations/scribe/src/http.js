import express from 'express';
import { rateLimit } from 'express-rate-limit';
import { createOAuthMetadata, mcpAuthRouter } from '@modelcontextprotocol/sdk/server/auth/router.js';
import { requireBearerAuth } from '@modelcontextprotocol/sdk/server/auth/middleware/bearerAuth.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { createScribeServer } from './server.js';
import { hash, SCOPE, ScribeOAuthProvider } from './auth.js';
import { ICON_PATH, iconPNG } from './brand.js';

// Serves OAuth and MCP for Scribe libraries. `library` is either one library (a
// self-hosted bridge) or a function from the token's owner to that owner's library
// (a relay). The owner always comes from the verified token, never from a request.
export function createHTTPApp(library, config) {
  const origin = new URL(config.origin);
  if (origin.pathname !== '/' || origin.search || origin.hash || origin.username || origin.password ||
      (origin.protocol !== 'https:' && !(origin.protocol === 'http:' && ['localhost', '127.0.0.1'].includes(origin.hostname)))) throw new Error('SCRIBE_PUBLIC_URL must be an HTTPS origin (loopback HTTP is allowed for testing).');
  const provider = new ScribeOAuthProvider(config);
  const libraryFor = typeof library === 'function' ? library : () => library;
  const app = express();
  app.disable('x-powered-by');
  // Only trust forwarded client addresses for rate limiting when the operator says
  // how many proxies sit in front. Host is never taken from forwarded headers.
  if (config.trustProxy) app.set('trust proxy', config.trustProxy);
  app.use((req, res, next) => {
    res.set({ 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer' });
    // A reverse proxy must preserve Host. Never trust forwarded host headers.
    if (req.get('host') !== origin.host) return res.status(403).send('Invalid Host.');
    if (req.get('origin') && req.get('origin') !== origin.origin) return res.status(403).send('Invalid Origin.');
    next();
  });
  // Routes named in largeBodies (a linked Mac's transcript responses) parse their own bodies.
  const json = express.json({ limit: '64kb' });
  app.use((req, res, next) => config.largeBodies?.has(req.path) ? next() : json(req, res, next));
  app.use(express.urlencoded({ extended: false, limit: '16kb' }));
  app.post('/consent', rateLimit({ windowMs: 60000, limit: 10 }), (req, res) => provider.consent(req, res));
  const metadata = { ...createOAuthMetadata({ provider, issuerUrl: origin, scopesSupported: [SCOPE] }), authorization_response_iss_parameter_supported: true,
    ...(provider.clientMetadataDocuments.size ? { client_id_metadata_document_supported: true } : {}) };
  app.get('/.well-known/oauth-authorization-server', (_req, res) => res.json(metadata));
  // Error redirects come from the SDK's authorize handler; add RFC 9207 `iss` to
  // them too, since a client that relies on it rejects responses without it.
  app.use('/authorize', (_req, res, next) => {
    const redirect = res.redirect.bind(res);
    res.redirect = (status, url) => {
      const target = new URL(url);
      if (target.origin !== origin.origin && !target.searchParams.has('iss')) target.searchParams.set('iss', provider.issuer);
      return redirect(status, target.href);
    };
    next();
  });
  app.use(mcpAuthRouter({ provider, issuerUrl: origin, resourceServerUrl: new URL('/mcp', origin), scopesSupported: [SCOPE], resourceName: 'Scribe transcripts' }));
  app.get('/.well-known/oauth-protected-resource', (_req, res) => res.json({ resource: provider.resource, authorization_servers: [origin.href], scopes_supported: [SCOPE] }));
  // The icon the MCP server names, and the favicon connector UIs look up for this domain.
  app.get([ICON_PATH, '/favicon.ico'], (_req, res, next) => {
    const png = iconPNG();
    if (!png) return next();
    res.set('Cache-Control', 'public, max-age=86400').type('png').send(png);
  });
  app.get('/health', (_req, res) => res.json({ status: 'ok', service: 'scribe-mcp' }));
  config.routes?.(app, provider);
  app.use('/mcp', rateLimit({ windowMs: 60000, limit: 120 }), requireBearerAuth({ verifier: provider, requiredScopes: [SCOPE], resourceMetadataUrl: `${origin.origin}/.well-known/oauth-protected-resource/mcp` }));
  app.all('/mcp', async (req, res) => {
    const { ownerId } = req.auth.extra;
    // Stable per library on this server and never reused: owner IDs are random and never reassigned.
    const profile = { id: hash(`scribe-profile|${provider.issuer}|${ownerId}`).slice(0, 32), name: 'Scribe library' };
    const server = createScribeServer(libraryFor(ownerId), { authenticated: true, profile, origin: origin.origin });
    const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
    res.on('close', () => { void transport.close(); void server.close(); });
    try { await server.connect(transport); await transport.handleRequest(req, res, req.body); }
    catch { if (!res.headersSent) res.status(500).json({ error: 'MCP request failed.' }); }
  });
  app.use((error, _req, res, _next) => res.status(error.status === 413 ? 413 : 400).json({ error: 'Invalid request.' }));
  return { app, provider };
}

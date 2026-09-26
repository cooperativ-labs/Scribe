import express from 'express';
import { rateLimit } from 'express-rate-limit';
import { mcpAuthRouter } from '@modelcontextprotocol/sdk/server/auth/router.js';
import { requireBearerAuth } from '@modelcontextprotocol/sdk/server/auth/middleware/bearerAuth.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { createScribeServer } from './server.js';
import { SCOPE, ScribeOAuthProvider } from './auth.js';

export function createHTTPApp(library, config) {
  const origin = new URL(config.origin);
  if (origin.pathname !== '/' || origin.search || origin.hash || origin.username || origin.password ||
      (origin.protocol !== 'https:' && !(origin.protocol === 'http:' && ['localhost', '127.0.0.1'].includes(origin.hostname)))) throw new Error('SCRIBE_PUBLIC_URL must be an HTTPS origin (loopback HTTP is allowed for testing).');
  const provider = new ScribeOAuthProvider(config);
  const app = express();
  app.disable('x-powered-by');
  app.use((req, res, next) => {
    res.set({ 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer' });
    // A reverse proxy must preserve Host. Never trust forwarded host headers.
    if (req.get('host') !== origin.host) return res.status(403).send('Invalid Host.');
    if (req.get('origin') && req.get('origin') !== origin.origin) return res.status(403).send('Invalid Origin.');
    next();
  });
  app.use(express.json({ limit: '64kb' }));
  app.use(express.urlencoded({ extended: false, limit: '16kb' }));
  app.post('/consent', rateLimit({ windowMs: 60000, limit: 10 }), (req, res) => provider.consent(req, res));
  app.use(mcpAuthRouter({ provider, issuerUrl: origin, resourceServerUrl: new URL('/mcp', origin), scopesSupported: [SCOPE], resourceName: 'Scribe transcripts' }));
  app.get('/.well-known/oauth-protected-resource', (_req, res) => res.json({ resource: provider.resource, authorization_servers: [origin.href], scopes_supported: [SCOPE] }));
  app.get('/health', (_req, res) => res.json({ status: 'ok', service: 'scribe-mcp' }));
  app.use('/mcp', rateLimit({ windowMs: 60000, limit: 120 }), requireBearerAuth({ verifier: provider, requiredScopes: [SCOPE], resourceMetadataUrl: `${origin.origin}/.well-known/oauth-protected-resource/mcp` }));
  app.all('/mcp', async (req, res) => {
    const server = createScribeServer(library, { authenticated: true });
    const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
    res.on('close', () => { void transport.close(); void server.close(); });
    try { await server.connect(transport); await transport.handleRequest(req, res, req.body); }
    catch { if (!res.headersSent) res.status(500).json({ error: 'MCP request failed.' }); }
  });
  app.use((error, _req, res, _next) => res.status(error.status === 413 ? 413 : 400).json({ error: 'Invalid request.' }));
  return { app, provider };
}

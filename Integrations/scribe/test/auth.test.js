import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { ScribeOAuthProvider } from '../src/auth.js';

test('tokens reject wrong client, resource, scope and expiry; revocation is client-bound', async () => {
  const provider = new ScribeOAuthProvider({ origin: 'https://scribe.example', ownerKey: 'x'.repeat(43), redirectURIs: ['https://client.example/callback'] });
  const client = { client_id: 'a' }, other = { client_id: 'b' };
  const resource = new URL('https://scribe.example/mcp');
  const tokens = provider.issue(client.client_id);
  await assert.rejects(provider.exchangeRefreshToken(other, tokens.refresh_token, undefined, resource), /Invalid refresh/);
  await assert.rejects(provider.exchangeRefreshToken(client, tokens.refresh_token, ['transcripts.write'], resource), /transcripts.read/);
  await assert.rejects(provider.exchangeRefreshToken(client, tokens.refresh_token, undefined, new URL('https://other.example/mcp')), /exact Scribe/);
  await provider.revokeToken(other, { token: tokens.access_token });
  assert.equal((await provider.verifyAccessToken(tokens.access_token)).clientId, 'a');
  Object.values(provider.state.access)[0].expiresAt = 1;
  await assert.rejects(provider.verifyAccessToken(tokens.access_token), /expired/);
  Object.values(provider.state.refresh)[0].expiresAt = 1;
  await assert.rejects(provider.exchangeRefreshToken(client, tokens.refresh_token, undefined, resource), /Invalid refresh/);
  await assert.rejects(provider.verifyAccessToken('invented-token'), /Invalid/);
});

test('codes enforce expiry, client and exact redirect/resource binding', async () => {
  const provider = new ScribeOAuthProvider({ origin: 'https://scribe.example', ownerKey: 'x'.repeat(43), redirectURIs: ['https://client.example/callback'] });
  const client = { client_id: 'a' }, resource = new URL('https://scribe.example/mcp');
  const code = 'test-code', key = createHash('sha256').update(code).digest('hex');
  const grant = { clientId: 'a', codeChallenge: 'challenge', redirectUri: 'https://client.example/callback', resource, expiresAt: Math.floor(Date.now() / 1000) + 300 };
  provider.codes.set(key, { ...grant, expiresAt: 1 });
  await assert.rejects(provider.challengeForAuthorizationCode(client, code), /expired/);
  provider.codes.set(key, grant);
  await assert.rejects(provider.challengeForAuthorizationCode({ client_id: 'b' }, code), /Invalid/);
  await assert.rejects(provider.exchangeAuthorizationCode(client, code, undefined, 'https://client.example/other', resource), /does not match/);
  assert.equal(provider.codes.size, 0);
  provider.codes.set(key, grant);
  await assert.rejects(provider.exchangeAuthorizationCode(client, code, undefined, grant.redirectUri, new URL('https://wrong.example/mcp')), /exact Scribe/);
  await assert.rejects(provider.challengeForAuthorizationCode({ client_id: 'a' }, 'unknown-code'), /Invalid or expired/);
  assert.throws(() => new ScribeOAuthProvider({ origin: 'https://scribe.example', ownerKey: 'short', redirectURIs: ['https://client.example/callback'] }), /32/);
  assert.throws(() => new ScribeOAuthProvider({ origin: 'https://scribe.example', ownerKey: 'x'.repeat(43), redirectURIs: ['http://unsafe.example/callback'] }), /HTTPS/);
  await assert.rejects(provider.clientsStore.registerClient({ redirect_uris: ['https://client.example/callback/extra'] }), /allowlist/);
});

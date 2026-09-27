import { createServer } from 'node:http';
import path from 'node:path';
import { createRelayApp } from '../src/relay.js';
import { RelayAccount, RelayCredentials, runAgent } from '../src/agent.js';
import { TranscriptLibrary } from '../src/store.js';
import { fixture } from './fixture.js';

export const CALLBACK = 'https://chatgpt.com/connector_platform_oauth_redirect';

export async function startRelay(t, root, options = {}) {
  const listener = createServer(); await new Promise(resolve => listener.listen(0, '127.0.0.1', resolve));
  t.after(() => { listener.closeAllConnections(); listener.close(); });
  const origin = `http://127.0.0.1:${listener.address().port}`;
  const relay = createRelayApp({ origin, redirectURIs: [CALLBACK], stateFile: path.join(root, 'relay/oauth.json'), ownersFile: path.join(root, 'relay/owners.json'),
    hubOptions: { pollTimeoutMs: 200, callTimeoutMs: 2000, offlineAfterMs: 1000 }, ...options });
  listener.on('request', relay.app);
  return { origin, ...relay };
}

// A Mac: its own library, its own link file, and a running agent.
export async function startMac(t, relayURL, name) {
  const { root, add } = await fixture(t);
  const transcript = await add({ title: `${name} planning`, text: `${name} ships on Friday.` });
  const account = new RelayAccount(new RelayCredentials(path.join(root, 'state/relay.json')));
  await account.link(relayURL);
  const controller = new AbortController();
  const running = runAgent({ account, library: new TranscriptLibrary(root), signal: controller.signal, retryDelays: [20] });
  t.after(() => controller.abort());
  return { root, transcript, account, controller, running };
}

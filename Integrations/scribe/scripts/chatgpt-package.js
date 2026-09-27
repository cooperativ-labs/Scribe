import { cp, mkdir, readdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';

// The portable ChatGPT plugin: one package for every Scribe owner. It names only the
// relay's shared /mcp endpoint; which library a connection reads is decided at
// consent time by the owner's link code, never by the package. So nobody builds a
// per-user manifest, and no account-specific plugin_asdk_app ID (.app.json) is used.

export const PLUGIN_SCHEMA = 'https://agent-plugins.org/schemas/1.0.0/plugin.schema.json';
export const MCP_SCHEMA = 'https://agent-plugins.org/schemas/1.0.0/mcp.schema.json';
const VERSION = '0.1.0';
const json = (file, value) => writeFile(file, JSON.stringify(value, null, 2) + '\n');

const httpsURL = (value, label, { mcp = false } = {}) => {
  let url;
  try { url = new URL(value); } catch { throw new Error(`${label} must be an HTTPS URL.`); }
  if (url.protocol !== 'https:' || url.username || url.password || url.hash || (mcp && (url.search || url.pathname !== '/mcp'))) {
    throw new Error(mcp ? `${label} must be the exact HTTPS /mcp endpoint, such as https://relay.example.com/mcp.` : `${label} must be an HTTPS URL.`);
  }
  return url.href;
};

export function chatGPTManifest({ website, privacy, terms } = {}) {
  const links = Object.fromEntries(Object.entries({ websiteURL: website, privacyPolicyURL: privacy, termsOfServiceURL: terms })
    .filter(([, value]) => value).map(([key, value]) => [key, httpsURL(value, key)]));
  return {
    $schema: PLUGIN_SCHEMA, name: 'scribe', version: VERSION,
    description: 'Read your Scribe meeting transcripts and turn them into grounded summaries, decisions and action items.',
    author: { name: 'Cooperativ' }, repository: 'https://github.com/cooperativ-labs/scribe', license: 'UNLICENSED',
    keywords: ['scribe', 'transcripts', 'meetings', 'notes', 'mcp'],
    extensions: { 'com.openai': { interface: {
      displayName: 'Scribe',
      shortDescription: 'Summarize your Scribe meetings',
      longDescription: 'Find recent Scribe meetings, search transcripts, and turn timestamped conversations into notes, decisions and action items. Transcripts stay on your Mac: Scribe connects out to its relay, and each connection reads only the library whose owner approved it with a one-time link code. Read-only; no audio.',
      developerName: 'Cooperativ', category: 'Productivity', capabilities: ['Read'], ...links,
      defaultPrompt: ['Summarize my most recent Scribe meeting with decisions and action items.',
        'Search my Scribe transcripts for what we decided about the launch date.'],
      brandColor: '#5B6CF9', composerIcon: './assets/icon.png', logo: './assets/logo.png',
    } } },
  };
}

// Writes <output>/plugins/scribe and a marketplace at <output>/.agents/plugins, the
// layout `codex plugin marketplace add <output>` and the ChatGPT desktop app read.
export async function writeChatGPTPackage({ root, output, url, links }) {
  const endpoint = httpsURL(url, '--url', { mcp: true });
  const plugin = path.join(output, 'plugins/scribe');
  await rm(plugin, { recursive: true, force: true }); // never keep files from an earlier package
  await mkdir(path.join(plugin, 'assets'), { recursive: true });
  await json(path.join(plugin, 'plugin.json'), chatGPTManifest(links));
  await json(path.join(plugin, 'mcp.json'), { $schema: MCP_SCHEMA, mcpServers: { scribe: { type: 'streamable-http', url: endpoint } } });
  await cp(path.join(root, 'skills'), path.join(plugin, 'skills'), { recursive: true });
  for (const name of ['icon.png', 'logo.png']) await cp(path.join(root, 'assets', name), path.join(plugin, 'assets', name));
  await mkdir(path.join(output, '.agents/plugins'), { recursive: true });
  await json(path.join(output, '.agents/plugins/marketplace.json'), { name: 'scribe', interface: { displayName: 'Scribe' },
    plugins: [{ name: 'scribe', source: { source: 'local', path: './plugins/scribe' },
      policy: { installation: 'AVAILABLE', authentication: 'ON_INSTALL' }, category: 'Productivity' }] });
  await validateChatGPTPackage(output);
  return plugin;
}

const exactKeys = (value, allowed, label) => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error(`${label} must be an object.`);
  const extra = Object.keys(value).filter(key => !allowed.includes(key));
  if (extra.length) throw new Error(`${label} has unsupported fields: ${extra.join(', ')}.`);
};
async function contained(root, relative, label) {
  if (typeof relative !== 'string' || !relative.startsWith('./')) throw new Error(`${label} must be a ./ path inside the plugin.`);
  const target = path.resolve(root, relative);
  if (!target.startsWith(path.resolve(root) + path.sep)) throw new Error(`${label} leaves the plugin root.`);
  return stat(target).catch(() => { throw new Error(`${label} does not exist: ${relative}`); });
}

// Checks a generated package against the Agent Plugins 1.0.0 schemas and OpenAI's
// path and marketplace rules, so a broken package fails the build, not an install.
export async function validateChatGPTPackage(output) {
  const read = async file => JSON.parse(await readFile(path.join(output, file), 'utf8'));
  const marketplace = await read('.agents/plugins/marketplace.json');
  exactKeys(marketplace, ['name', 'interface', 'plugins'], 'marketplace.json');
  if (!Array.isArray(marketplace.plugins) || !marketplace.plugins.length) throw new Error('marketplace.json lists no plugins.');
  for (const entry of marketplace.plugins) {
    if (!['AVAILABLE', 'INSTALLED_BY_DEFAULT', 'NOT_AVAILABLE'].includes(entry.policy?.installation) || !['ON_INSTALL', 'ON_USE'].includes(entry.policy?.authentication) || !entry.category) {
      throw new Error(`Marketplace entry ${entry.name} needs policy.installation, policy.authentication and category.`);
    }
    if (entry.source?.source !== 'local') throw new Error('Marketplace entries must be local plugin folders.');
    await contained(output, entry.source.path, `${entry.name} source.path`);
    const root = path.resolve(output, entry.source.path);
    const manifest = JSON.parse(await readFile(path.join(root, 'plugin.json'), 'utf8'));
    exactKeys(manifest, ['$schema', 'name', 'version', 'description', 'author', 'homepage', 'repository', 'license', 'keywords', 'extensions'], 'plugin.json');
    if (manifest.$schema !== PLUGIN_SCHEMA) throw new Error('plugin.json must declare the Agent Plugins 1.0.0 schema.');
    if (!/^(?!.*(?:--|\.\.))[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/.test(manifest.name) || manifest.name.length > 64 || manifest.name !== entry.name) throw new Error('plugin.json name must be kebab-case and match its marketplace entry.');
    if (manifest.author) exactKeys(manifest.author, ['name', 'email', 'url'], 'plugin.json author');
    const openai = manifest.extensions?.['com.openai'];
    if (openai) {
      exactKeys(openai, ['apps', 'hooks', 'interface'], 'extensions.com.openai');
      if (openai.apps) throw new Error('A portable package must not map an account-specific plugin_asdk_app ID.');
      for (const key of ['composerIcon', 'logo']) if (openai.interface?.[key]) await contained(root, openai.interface[key], `interface.${key}`);
      for (const [index, shot] of (openai.interface?.screenshots ?? []).entries()) await contained(root, shot, `interface.screenshots[${index}]`);
    }
    await stat(path.join(root, '.app.json')).then(() => { throw new Error('A portable package must not contain .app.json.'); }, () => {});
    const mcp = JSON.parse(await readFile(path.join(root, 'mcp.json'), 'utf8'));
    exactKeys(mcp, ['$schema', 'mcpServers'], 'mcp.json');
    if (mcp.$schema !== MCP_SCHEMA) throw new Error('mcp.json must declare the Agent Plugins 1.0.0 MCP schema.');
    for (const [name, server] of Object.entries(mcp.mcpServers ?? {})) {
      exactKeys(server, ['type', 'url', 'headers'], `mcp.json ${name}`);
      if (server.type !== 'streamable-http') throw new Error(`mcp.json ${name} must be a remote streamable-http server.`);
      if (server.headers) throw new Error(`mcp.json ${name} must not carry credentials; users authorize with OAuth.`);
      httpsURL(server.url, `mcp.json ${name} url`, { mcp: true });
    }
    for (const skill of await readdir(path.join(root, 'skills'))) {
      const text = await readFile(path.join(root, 'skills', skill, 'SKILL.md'), 'utf8');
      const front = text.match(/^---\n([\s\S]*?)\n---\n/)?.[1] ?? '';
      if (!new RegExp(`^name: ${skill}$`, 'm').test(front) || !/^description: \S/m.test(front)) throw new Error(`skills/${skill}/SKILL.md needs name and description front matter.`);
    }
  }
  return marketplace;
}

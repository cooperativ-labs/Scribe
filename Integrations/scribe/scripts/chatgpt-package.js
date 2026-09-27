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

export const PUBLISHER = 'Cooperativ Labs';

// The relay serves its own public pages (src/site.js, src/legal.js), so a package
// built for a relay links to that relay's pages unless told otherwise.
export function listingLinks(url, { website, privacy, terms, support } = {}) {
  const origin = new URL(url).origin;
  return { website: website ?? `${origin}/`, privacy: privacy ?? `${origin}/privacy`, terms: terms ?? `${origin}/terms`, support: support ?? `${origin}/support` };
}

export function chatGPTManifest({ website, privacy, terms, support } = {}) {
  const links = Object.fromEntries(Object.entries({ websiteURL: website, privacyPolicyURL: privacy, termsOfServiceURL: terms, supportURL: support })
    .filter(([, value]) => value).map(([key, value]) => [key, httpsURL(value, key)]));
  return {
    $schema: PLUGIN_SCHEMA, name: 'scribe', version: VERSION,
    description: 'Read your Scribe meeting transcripts and turn them into grounded summaries, decisions and action items.',
    author: { name: PUBLISHER, ...(website ? { url: links.websiteURL } : {}) }, ...(website ? { homepage: links.websiteURL } : {}),
    repository: 'https://github.com/cooperativ-labs/Scribe', license: 'UNLICENSED',
    keywords: ['scribe', 'transcripts', 'meetings', 'notes', 'mcp'],
    extensions: { 'com.openai': { interface: {
      displayName: 'Scribe',
      shortDescription: 'Summarize your Scribe meetings',
      longDescription: 'Ask ChatGPT about the meetings you recorded with Scribe for Mac. Find recent meetings, search transcripts by topic or speaker, and turn timestamped conversations into summaries, decisions and action items that cite when each thing was said.\n\nYour transcripts stay on your Mac. Scribe connects out to its relay, and a connection reads only the library whose owner approved it with a one-time link code from Scribe. Access is read-only: ChatGPT cannot change or delete transcripts, and recording audio is never shared. Disconnect at any time from Scribe → Settings → Assistants.\n\nRequires Scribe for Mac (free, macOS 15 or later on Apple silicon) running on the Mac that holds your transcripts.',
      developerName: PUBLISHER, category: 'Productivity', capabilities: ['Read'], ...links,
      defaultPrompt: ['Summarize my most recent Scribe meeting with decisions and action items.',
        'Search my Scribe transcripts for what we decided about the launch date.',
        'List the action items and owners from my Scribe meetings this week.'],
      brandColor: '#5B6CF9', composerIcon: './assets/icon.png', logo: './assets/logo.png',
    } } },
  };
}

// Writes <output>/plugins/scribe and a marketplace at <output>/.agents/plugins, the
// layout `codex plugin marketplace add <output>` and the ChatGPT desktop app read.
export async function writeChatGPTPackage({ root, output, url, links }) {
  const endpoint = httpsURL(url, '--url', { mcp: true });
  links = listingLinks(endpoint, links);
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
    directoryListing(manifest);
    if (manifest.$schema !== PLUGIN_SCHEMA) throw new Error('plugin.json must declare the Agent Plugins 1.0.0 schema.');
    if (!/^(?!.*(?:--|\.\.))[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/.test(manifest.name) || manifest.name.length > 64 || manifest.name !== entry.name) throw new Error('plugin.json name must be kebab-case and match its marketplace entry.');
    if (manifest.author) exactKeys(manifest.author, ['name', 'email', 'url'], 'plugin.json author');
    const openai = manifest.extensions?.['com.openai'];
    if (openai) {
      exactKeys(openai, ['apps', 'hooks', 'interface'], 'extensions.com.openai');
      if (openai.apps) throw new Error('A portable package must not map an account-specific plugin_asdk_app ID.');
      for (const key of ['composerIcon', 'logo']) {
        if (!openai.interface?.[key]) throw new Error(`interface.${key} is required for the Plugins Directory.`);
        await contained(root, openai.interface[key], `interface.${key}`);
        await squareImage(path.resolve(root, openai.interface[key]), `interface.${key}`);
      }
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
      if (front.match(/^description: (.*)$/m)[1].length > 1024 || `${manifest.name}:${skill}`.length > 64 || !text.slice(text.indexOf('\n---\n', 4) + 5).trim()) throw new Error(`skills/${skill}/SKILL.md exceeds the directory's skill limits or has no body.`);
    }
  }
  return marketplace;
}

// OpenAI's final Plugins Directory limits (developers.openai.com/plugins/deploy/submission-errors).
// They are stricter than the loader's, so a package that passes here also installs.
export const DIRECTORY_CATEGORIES = ['Productivity', 'Creativity', 'Developer Tools', 'Business & Operations', 'Data & Analytics', 'Communication',
  'Education & Research', 'Security', 'Finance', 'Healthcare', 'Travel', 'Entertainment', 'Other'];
const CONTROL = /[\u0000-\u0009\u000B-\u001F\u007F\u2028\u2029\u200B-\u200F\u202A-\u202E\u2060-\u2064\uFEFF]/;
const text = (value, label, max, { multiline = false, required = true } = {}) => {
  if (value === undefined && !required) return;
  if (typeof value !== 'string' || !value.trim()) throw new Error(`${label} is required.`);
  if (value.length > max) throw new Error(`${label} is longer than ${max} characters.`);
  if (CONTROL.test(value) || (!multiline && value.includes('\n'))) throw new Error(`${label} contains unsupported characters.`);
};
const luminance = hex => {
  const [r, g, b] = [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16) / 255).map(c => c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
};
export const contrast = (a, b) => { const [x, y] = [luminance(a), luminance(b)].sort((m, n) => n - m); return (x + 0.05) / (y + 0.05); };

export function directoryListing(manifest) {
  text(manifest.name, 'name', 64);
  if (!/^[A-Za-z0-9][A-Za-z0-9_-]*$/.test(manifest.name)) throw new Error('name may use only ASCII letters, digits, _ and -.');
  if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/.test(manifest.version ?? '') || manifest.version.length > 64) throw new Error('version must be a semantic version.');
  text(manifest.description, 'description', 1024);
  text(manifest.author?.name, 'author.name', 120);
  const ui = manifest.extensions?.['com.openai']?.interface;
  if (!ui) throw new Error('extensions.com.openai.interface is required for the Plugins Directory.');
  text(ui.displayName, 'interface.displayName', 30);
  text(ui.shortDescription, 'interface.shortDescription', 30);
  text(ui.longDescription, 'interface.longDescription', 4000, { multiline: true });
  text(ui.developerName, 'interface.developerName', 80);
  if (!DIRECTORY_CATEGORIES.includes(ui.category)) throw new Error(`interface.category must be one of: ${DIRECTORY_CATEGORIES.join(', ')}.`);
  if (!Array.isArray(ui.capabilities) || ui.capabilities.length > 20) throw new Error('interface.capabilities allows at most 20 entries.');
  ui.capabilities.forEach((value, index) => text(value, `interface.capabilities[${index}]`, 120));
  const prompts = ui.defaultPrompt ?? [];
  if (!Array.isArray(prompts) || prompts.length > 3) throw new Error('interface.defaultPrompt allows at most 3 prompts.');
  prompts.forEach((value, index) => { text(value, `interface.defaultPrompt[${index}]`, 128); if (/(^|\s)@\w/.test(value)) throw new Error('Starter prompts must not @mention an MCP server.'); });
  const normalized = prompts.map(value => value.normalize('NFKC').trim().replace(/\s+/g, ' ').toLowerCase());
  if (new Set(normalized).size !== normalized.length) throw new Error('interface.defaultPrompt entries must be unique.');
  // A remote MCP listing needs all four public pages.
  for (const key of ['websiteURL', 'privacyPolicyURL', 'termsOfServiceURL', 'supportURL']) {
    text(ui[key], `interface.${key}`, 1024);
    httpsURL(ui[key], `interface.${key}`);
  }
  if (ui.brandColor !== undefined) {
    if (!/^#[0-9A-Fa-f]{6}$/.test(ui.brandColor)) throw new Error('interface.brandColor must be a six-digit hex color.');
    if (contrast(ui.brandColor, '#FFFFFF') < 2) throw new Error('interface.brandColor needs 2:1 contrast against white.');
  }
  return manifest;
}

// Logos must be square raster images between 48 and 4096 pixels and under 5 MiB.
async function squareImage(file, label) {
  const data = await readFile(file);
  if (data.length > 5 * 1024 * 1024) throw new Error(`${label} is larger than 5 MiB.`);
  if (data.readUInt32BE(0) !== 0x89504e47 || data.toString('ascii', 12, 16) !== 'IHDR') throw new Error(`${label} must be a PNG.`);
  const width = data.readUInt32BE(16), height = data.readUInt32BE(20);
  if (width !== height || width < 48 || width > 4096) throw new Error(`${label} must be square, 48 to 4096 pixels (is ${width}×${height}).`);
}

// The ZIP the submission portal takes: exactly one plugin root at the archive root.
export async function writeSubmissionArchive({ plugin, file, zip = 'zip' }) {
  const { execFile } = await import('node:child_process');
  const { promisify } = await import('node:util');
  await rm(file, { force: true });
  await mkdir(path.dirname(file), { recursive: true });
  // -X drops macOS extended attributes; -D omits directory entries; no dot-files.
  await promisify(execFile)(zip, ['-r', '-X', '-D', '-q', file, '.', '-x', '.*', '*/.*'], { cwd: plugin });
  return file;
}

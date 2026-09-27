import { chmod, cp, mkdir, rm, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { MCP_SCHEMA, PLUGIN_SCHEMA, PUBLISHER } from './chatgpt-package.js';

// The local plugin: one directory that Claude Code, Codex / the ChatGPT desktop app and
// Cursor each install as it is. Every harness reads its own manifest and server config:
//
//   .claude-plugin/plugin.json  Claude Code, whose server is .mcp.json
//   .codex-plugin/plugin.json   Codex and ChatGPT desktop, whose server is mcp.json
//   .cursor-plugin/plugin.json  Cursor, whose server is .cursor-plugin/mcp.json
//
// The harnesses start a plugin's server in different directories and expand different
// variables, so each config names the launcher the way its harness resolves it (see
// serverConfigs). Given the launcher from Scribe.app, the servers run
// `scribe-mcp-launcher`, which finds Scribe.app at every start and execs its read-only
// helper, so the tree holds no server code.

export const LAUNCHER = 'scribe-mcp-launcher';
const VERSION = '0.1.0';
const SITE = 'https://scribe.ovld.ai/';
const DESCRIPTION = 'Find recent Scribe meetings, search transcripts, and turn timestamped conversations into notes and action items.';
const json = (file, value) => writeFile(file, JSON.stringify(value, null, 2) + '\n');

// The plugin's identity and OpenAI listing metadata, as an Agent Plugins 1.0.0 manifest.
export function agentPluginsManifest() {
  return {
    $schema: PLUGIN_SCHEMA, name: 'scribe', version: VERSION, description: DESCRIPTION,
    author: { name: PUBLISHER, url: SITE }, homepage: SITE,
    repository: 'https://github.com/cooperativ-labs/Scribe', license: 'UNLICENSED', keywords: ['scribe', 'transcripts', 'meetings', 'mcp'],
    extensions: { 'com.openai': { interface: {
      displayName: 'Scribe',
      shortDescription: 'Read your Scribe meetings',
      longDescription: 'Find recent meetings recorded with Scribe for Mac, search transcripts by topic or speaker, and turn timestamped conversations into summaries, decisions and action items.\n\nThe plugin runs the read-only transcript server inside Scribe.app on this Mac. It cannot change or delete transcripts, and recording audio is never exposed. When the assistant reads a transcript, its text goes to the assistant\'s service like anything else in the chat. Requires Scribe for Mac.',
      developerName: PUBLISHER, category: 'Productivity', capabilities: ['Read'],
      websiteURL: SITE, privacyPolicyURL: new URL('/privacy', SITE).href, termsOfServiceURL: new URL('/terms', SITE).href, supportURL: new URL('/support', SITE).href,
      defaultPrompt: ['Summarize my most recent Scribe meeting with decisions and action items.',
        'Search my Scribe transcripts for what we decided about the launch date.'],
      brandColor: '#5B6CF9', composerIcon: './assets/icon.png', logo: './assets/icon.png',
    } } },
  };
}

// Codex reads .codex-plugin/plugin.json in its own shape: the same fields, with the listing
// under a top-level `interface` and explicit pointers to the skills and server config. (It
// ignores extensions.com.openai there, and finds no server without the pointer.)
export function codexManifest() {
  const { $schema, extensions, ...fields } = agentPluginsManifest();
  return { ...fields, skills: './skills/', mcpServers: './mcp.json', interface: extensions['com.openai'].interface };
}

export function cursorManifest() {
  const { name, version, description, author, homepage, repository, license, keywords } = agentPluginsManifest();
  return { name, version, description, author, homepage, repository, license, keywords, skills: './skills/', mcpServers: './.cursor-plugin/mcp.json' };
}

// Claude Code and Cursor start the server in the user's project and expand their own
// plugin-root variable in `command`; Codex starts it in `cwd`, relative to the plugin root.
// mcp.json is an Agent Plugins MCP document, so a client that reads that format natively
// resolves it the same way.
export function serverConfigs({ launcher }) {
  const run = root => ({ command: `${root}/${LAUNCHER}` });
  return {
    '.mcp.json': { mcpServers: { scribe: run('${CLAUDE_PLUGIN_ROOT}') } },
    // Keep the local Codex server distinct from a Scribe Relay server a user
    // may already have configured as `scribe` in ~/.codex/config.toml.
    'mcp.json': { $schema: MCP_SCHEMA, mcpServers: { 'scribe-local': { type: 'stdio', ...run('.'), cwd: './' } } },
    '.cursor-plugin/mcp.json': { mcpServers: { scribe: { type: 'stdio', ...run('${CURSOR_PLUGIN_ROOT}') } } },
  };
}

// Writes the plugin to `plugin`, replacing whatever was there.
export async function writeLocalPlugin({ root, plugin, launcher }) {
  const info = launcher && await stat(launcher).catch(() => null);
  if (!info?.isFile() || !(info.mode & 0o111)) throw new Error(`--launcher is required and must be an executable file: ${launcher}`);
  await rm(plugin, { recursive: true, force: true }); // never keep files from an earlier package
  await mkdir(path.join(plugin, 'assets'), { recursive: true });
  for (const name of ['.claude-plugin', 'skills', 'ui']) await cp(path.join(root, name), path.join(plugin, name), { recursive: true });
  // One icon serves as the server icon, the composer icon and the logo.
  await cp(path.join(root, 'assets/icon.png'), path.join(plugin, 'assets/icon.png'));
  for (const name of ['.codex-plugin', '.cursor-plugin']) await mkdir(path.join(plugin, name));
  await json(path.join(plugin, '.codex-plugin/plugin.json'), codexManifest());
  await json(path.join(plugin, '.cursor-plugin/plugin.json'), cursorManifest());
  for (const [name, value] of Object.entries(serverConfigs({ launcher }))) await json(path.join(plugin, name), value);
  await cp(launcher, path.join(plugin, LAUNCHER));
  await chmod(path.join(plugin, LAUNCHER), 0o755);
  return plugin;
}

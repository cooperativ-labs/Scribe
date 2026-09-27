import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { readFile, readdir, access, writeFile, mkdir, stat, constants } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { fixture } from './fixture.js';
import Ajv2020 from 'ajv/dist/2020.js';
import { PLUGIN_SCHEMA, directoryListing, validateChatGPTPackage, writeChatGPTPackage } from '../scripts/chatgpt-package.js';
const exec = promisify(execFile);
const script = fileURLToPath(new URL('../scripts/package.js', import.meta.url));
const builtLauncher = path.join(process.env.SCRIBE_MCP_BIN_DIR || fileURLToPath(new URL('../../../Workers/ScribeMCP/.build/debug', import.meta.url)), 'scribe-mcp-launcher');
async function launcherFor(t) {
  try { await access(builtLauncher); return builtLauncher; } catch {
    const { root } = await fixture(t);
    const launcher = path.join(root, 'scribe-mcp-launcher');
    await writeFile(launcher, '#!/bin/sh\nexit 0\n', { mode: 0o755 });
    return launcher;
  }
}

test('one portable ChatGPT package and marketplace serve every owner through the relay', async t => {
  const { root } = await fixture(t);
  const launcher = await launcherFor(t);
  await exec(process.execPath, [script, '--output', root, '--launcher', launcher, '--url', 'https://relay.example/mcp', '--privacy-url', 'https://scribe.example/privacy']);
  const json = async file => JSON.parse(await readFile(path.join(root, file), 'utf8'));
  const marketplace = await json('chatgpt/.agents/plugins/marketplace.json');
  assert.deepEqual(marketplace.plugins[0], { name: 'scribe', source: { source: 'local', path: './plugins/scribe' },
    policy: { installation: 'AVAILABLE', authentication: 'ON_INSTALL' }, category: 'Productivity' });
  const plugin = await json('chatgpt/plugins/scribe/plugin.json');
  assert.equal(plugin.$schema, 'https://agent-plugins.org/schemas/1.0.0/plugin.schema.json');
  const ui = plugin.extensions['com.openai'].interface;
  assert.equal(ui.displayName, 'Scribe'); assert.equal(ui.privacyPolicyURL, 'https://scribe.example/privacy');
  // Unset listing links are the relay's own public pages, which every relay serves.
  assert.equal(ui.termsOfServiceURL, 'https://relay.example/terms'); assert.equal(ui.supportURL, 'https://relay.example/support');
  assert.equal(ui.websiteURL, 'https://relay.example/');
  // The directory submission archive holds exactly the plugin, at its root.
  const { stdout } = await exec('unzip', ['-Z1', path.join(root, 'submission/scribe-0.1.0.zip')]);
  assert.deepEqual(stdout.trim().split('\n').sort(), ['assets/icon.png', 'assets/logo.png', 'mcp.json', 'plugin.json', 'skills/scribe-transcripts/SKILL.md']);
  // Nothing per user or per account: no registered app mapping, no credentials, one shared endpoint.
  assert.equal(plugin.extensions['com.openai'].apps, undefined);
  await assert.rejects(access(path.join(root, 'chatgpt/plugins/scribe/.app.json')));
  assert.deepEqual((await json('chatgpt/plugins/scribe/mcp.json')).mcpServers, { scribe: { type: 'streamable-http', url: 'https://relay.example/mcp' } });
  for (const file of ['skills/scribe-transcripts/SKILL.md', 'assets/icon.png', 'assets/logo.png']) await access(path.join(root, 'chatgpt/plugins/scribe', file));
  // The relay connection's CLI and Scribe's Settings learn the same relay from connector.json.
  assert.deepEqual(await json('relay/connector.json'), { connector_url: 'https://relay.example/mcp' });
  for (const file of ['relay/dist/cli.mjs', 'relay/THIRD-PARTY-NOTICES.txt']) await access(path.join(root, file));

  const marketplaceJSON = await json('claude/.claude-plugin/marketplace.json');
  assert.equal(marketplaceJSON.plugins[0].source, './plugins/scribe');
  await access(path.join(root, 'claude/plugins/scribe/ui/transcripts.html'));
  await assert.rejects(access(path.join(root, 'claude/plugins/scribe/dist/cli.mjs')));
  assert.deepEqual((await json('claude/plugins/scribe/.mcp.json')).mcpServers.scribe, { command: '${CLAUDE_PLUGIN_ROOT}/scribe-mcp-launcher' });

  // Packaging without a relay leaves no stale relay default behind.
  await exec(process.execPath, [script, '--output', root, '--launcher', launcher]);
  await assert.rejects(access(path.join(root, 'relay/connector.json')));
  for (const url of ['http://unsafe.example/mcp', 'https://relay.example/other', 'https://relay.example/mcp?owner=1']) {
    await assert.rejects(exec(process.execPath, [script, '--output', root, '--launcher', launcher, '--url', url]), url);
  }
});

test('package validation rejects account-specific or unsafe packages', async t => {
  const { root } = await fixture(t);
  const source = fileURLToPath(new URL('..', import.meta.url));
  const plugin = await writeChatGPTPackage({ root: source, output: root, url: 'https://relay.example/mcp' });
  const edit = async (file, change) => {
    const value = JSON.parse(await readFile(path.join(plugin, file), 'utf8'));
    change(value); await writeFile(path.join(plugin, file), JSON.stringify(value));
  };
  await validateChatGPTPackage(root);
  const cases = [
    ['plugin.json', value => { value.extensions['com.openai'].apps = './.app.json'; }, /plugin_asdk_app/],
    ['plugin.json', value => { value.extensions['com.openai'].interface.logo = '../../logo.png'; }, /\.\/ path|leaves/],
    ['plugin.json', value => { value.skills = './skills'; }, /unsupported fields/],
    ['mcp.json', value => { value.mcpServers.scribe.headers = { Authorization: 'Bearer x' }; }, /credentials/],
    ['mcp.json', value => { value.mcpServers.scribe = { type: 'stdio', command: 'node' }; }, /unsupported fields|streamable-http/],
    // OpenAI's final directory limits.
    ['plugin.json', value => { value.extensions['com.openai'].interface.shortDescription = 'Summarize all of your Scribe meetings'; }, /shortDescription is longer than 30/],
    ['plugin.json', value => { value.extensions['com.openai'].interface.defaultPrompt.push('A fourth prompt'); }, /at most 3/],
    ['plugin.json', value => { value.extensions['com.openai'].interface.defaultPrompt[1] = ' summarize my most recent Scribe meeting with decisions and action items. '; }, /unique/],
    ['plugin.json', value => { delete value.extensions['com.openai'].interface.supportURL; }, /supportURL is required/],
    ['plugin.json', value => { value.extensions['com.openai'].interface.category = 'Meetings'; }, /category must be one of/],
    ['plugin.json', value => { value.extensions['com.openai'].interface.brandColor = '#F0F0F0'; }, /contrast/],
    ['plugin.json', value => { value.extensions['com.openai'].interface.logo = './skills/scribe-transcripts/SKILL.md'; }, /PNG/],
  ];
  for (const [file, change, message] of cases) {
    await writeChatGPTPackage({ root: source, output: root, url: 'https://relay.example/mcp' });
    await edit(file, change);
    await assert.rejects(validateChatGPTPackage(root), message);
  }
});

// The launcher this checkout built, if any; otherwise a stand-in executable of the same name.

// Where a harness would find the executable an MCP config runs. Claude Code and Cursor
// start the server in the user's project and expand their plugin-root variable; Codex
// starts it in `cwd`, resolved under the plugin root, and in the project without one.
function serverFile(plugin, server) {
  const expand = value => value.replace(/\$\{(?:CLAUDE|CURSOR)_PLUGIN_ROOT\}/g, plugin);
  const base = server.cwd ? path.resolve(plugin, expand(server.cwd)) : path.resolve('/project');
  const file = path.resolve(base, expand(server.command));
  assert.ok(file.startsWith(plugin + path.sep), `${file} is outside the plugin`);
  return file;
}

test('one local plugin tree serves Claude Code, Codex and Cursor through the launcher', async t => {
  const { root } = await fixture(t);
  let launcher = builtLauncher;
  try { await access(launcher); } catch {
    launcher = path.join(root, 'stand-in/scribe-mcp-launcher');
    await mkdir(path.dirname(launcher)); await writeFile(launcher, '#!/bin/sh\nexit 0\n', { mode: 0o755 });
  }
  await exec(process.execPath, [script, '--output', path.join(root, 'out'), '--launcher', launcher]);
  const plugin = path.join(root, 'out/claude/plugins/scribe');
  const json = async file => JSON.parse(await readFile(path.join(plugin, file), 'utf8'));

  // Only the plugin's own files: three manifests, their server configs, skills, viewer, icon, launcher.
  const files = (await readdir(plugin, { recursive: true, withFileTypes: true })).filter(entry => entry.isFile())
    .map(entry => path.relative(plugin, path.join(entry.parentPath, entry.name))).sort();
  assert.deepEqual(files, ['.claude-plugin/plugin.json', '.codex-plugin/plugin.json', '.cursor-plugin/mcp.json', '.cursor-plugin/plugin.json',
    '.mcp.json', 'assets/icon.png', 'mcp.json', 'scribe-mcp-launcher', 'skills/scribe-transcripts/SKILL.md', 'ui/transcripts.html']);
  assert.ok(!files.some(file => /\.[cm]?js$/.test(file)), 'no JavaScript when a launcher is supplied');
  let bytes = 0;
  for (const file of files) bytes += (await stat(path.join(plugin, file))).size;
  assert.ok(bytes < 200 * 1024, `the plugin is ${bytes} bytes`);

  // Each harness's manifest names its server config, and each config runs the launcher in the tree.
  assert.equal((await json('.claude-plugin/plugin.json')).name, 'scribe');
  assert.deepEqual(Object.keys((await json('mcp.json')).mcpServers), ['scribe-local'],
    'the local Codex server must not collide with a Scribe Relay server');
  const codex = await json('.codex-plugin/plugin.json'), cursor = await json('.cursor-plugin/plugin.json');
  const configs = { '.mcp.json': 'Claude Code', [codex.mcpServers]: 'Codex', [cursor.mcpServers]: 'Cursor' };
  assert.deepEqual(Object.keys(configs).map(file => path.normalize(file)), ['.mcp.json', 'mcp.json', '.cursor-plugin/mcp.json']);
  for (const file of Object.keys(configs)) {
    const servers = Object.values((await json(file)).mcpServers);
    assert.equal(servers.length, 1, file);
    const target = serverFile(plugin, servers[0]);
    assert.equal(target, path.join(plugin, 'scribe-mcp-launcher'), `${configs[file]} (${file})`);
    await access(target, constants.X_OK);
  }
  for (const manifest of [codex, cursor]) await access(path.join(plugin, manifest.skills, 'scribe-transcripts/SKILL.md'));
  // The app embeds these checked-in templates without npm. Keep them in sync
  // with the Node packager used for standalone distribution.
  const template = fileURLToPath(new URL('../local-plugin-template/', import.meta.url));
  for (const file of ['.claude-plugin/plugin.json', '.codex-plugin/plugin.json', '.cursor-plugin/plugin.json',
    '.cursor-plugin/mcp.json', '.mcp.json', 'mcp.json']) {
    assert.deepEqual(await json(file), JSON.parse(await readFile(path.join(template, file), 'utf8')), file);
  }
  assert.deepEqual(JSON.parse(await readFile(path.join(root, 'out/claude/.claude-plugin/marketplace.json'), 'utf8')),
    JSON.parse(await readFile(path.join(template, 'marketplace.json'), 'utf8')));

  // Codex's manifest is the Agent Plugins manifest in Codex's shape: read back into that
  // form it validates against the Agent Plugins 1.0.0 schema and OpenAI's listing limits,
  // and mcp.json is an Agent Plugins MCP document.
  const ajv = new Ajv2020({ strict: false });
  const schema = async name => JSON.parse(await readFile(fileURLToPath(new URL(`schemas/${name}`, import.meta.url)), 'utf8'));
  const { skills, mcpServers, interface: listing, ...fields } = codex;
  const manifest = { $schema: PLUGIN_SCHEMA, ...fields, extensions: { 'com.openai': { interface: listing } } };
  const validPlugin = ajv.compile(await schema('plugin.schema.json'));
  assert.ok(validPlugin(manifest), JSON.stringify(validPlugin.errors));
  directoryListing(manifest);
  assert.deepEqual([listing.displayName, listing.capabilities], ['Scribe', ['Read']]);
  for (const asset of [listing.composerIcon, listing.logo]) await access(path.join(plugin, asset));
  const validMCP = ajv.compile(await schema('mcp.schema.json'));
  assert.ok(validMCP(await json('mcp.json')), JSON.stringify(validMCP.errors));

  // A path that is not an executable file is refused rather than packaged.
  await assert.rejects(exec(process.execPath, [script, '--output', path.join(root, 'out'), '--launcher', path.join(root, 'missing')]), /must be an executable file/);
});

test('local packaging requires the Swift launcher', async t => {
  const { root } = await fixture(t);
  await assert.rejects(exec(process.execPath, [script, '--output', root]), /--launcher/);
});

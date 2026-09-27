import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { readFile, access, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { fixture } from './fixture.js';
import { validateChatGPTPackage, writeChatGPTPackage } from '../scripts/chatgpt-package.js';
const exec = promisify(execFile);
const script = fileURLToPath(new URL('../scripts/package.js', import.meta.url));

test('one portable ChatGPT package and marketplace serve every owner through the relay', async t => {
  const { root } = await fixture(t);
  await exec(process.execPath, [script, '--output', root, '--url', 'https://relay.example/mcp', '--privacy-url', 'https://scribe.example/privacy']);
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
  // The bundled CLI and Scribe's Settings learn the same relay from connector.json.
  assert.deepEqual(await json('claude/plugins/scribe/connector.json'), { connector_url: 'https://relay.example/mcp' });

  const marketplaceJSON = await json('claude/.claude-plugin/marketplace.json');
  assert.equal(marketplaceJSON.plugins[0].source, './plugins/scribe');
  for (const file of ['dist/cli.mjs', 'ui/transcripts.html', 'THIRD-PARTY-NOTICES.txt', 'docs/remote-access.md']) await access(path.join(root, 'claude/plugins/scribe', file));

  // Packaging without a relay leaves no stale relay default behind.
  await exec(process.execPath, [script, '--output', root]);
  await assert.rejects(access(path.join(root, 'claude/plugins/scribe/connector.json')));
  for (const url of ['http://unsafe.example/mcp', 'https://relay.example/other', 'https://relay.example/mcp?owner=1']) {
    await assert.rejects(exec(process.execPath, [script, '--output', root, '--url', url]), url);
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

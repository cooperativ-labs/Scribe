import { cp, mkdir, writeFile, readdir, readFile, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { parseArgs } from 'node:util';
import { writeChatGPTPackage, writeSubmissionArchive } from './chatgpt-package.js';
import { writeLocalPlugin } from './local-plugin.js';
await import('./build.js');
const { values } = parseArgs({ options: { url: { type: 'string', default: process.env.SCRIBE_CONNECTOR_URL }, output: { type: 'string' },
  launcher: { type: 'string' },
  'website-url': { type: 'string' }, 'privacy-url': { type: 'string' }, 'terms-url': { type: 'string' }, 'support-url': { type: 'string' } } });
const root = fileURLToPath(new URL('..', import.meta.url));
if (!values.launcher) throw new Error('Package a local plugin with --launcher <scribe-mcp-launcher>.');
const output = values.output ? path.resolve(values.output) : path.join(root, 'dist/packages');
const json = (file, value) => writeFile(file, JSON.stringify(value, null, 2) + '\n');
// The local plugin every desktop harness installs, inside a Claude Code marketplace.
const plugin = await writeLocalPlugin({ root, plugin: path.join(output, 'claude/plugins/scribe'), launcher: values.launcher && path.resolve(values.launcher) });
// The deployable Node relay service stays outside the Mac app and local plugin.
// Keep its CLI, connector.json and dependency notices in the relay package.
const relay = path.join(output, 'relay');
await rm(relay, { recursive: true, force: true });
await mkdir(path.join(relay, 'dist'), { recursive: true });
await cp(path.join(root, 'dist/cli.mjs'), path.join(relay, 'dist/cli.mjs'));
// Bundle dependency notices with the distributable, including transitive packages.
const licenses = [];
async function collect(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (!entry.isDirectory() || entry.name.startsWith('.')) continue;
    const folder = path.join(directory, entry.name);
    if (entry.name.startsWith('@')) { await collect(folder); continue; }
    for (const name of await readdir(folder)) if (/^(licen[sc]e|notice)(\.|$)/i.test(name)) {
      try { licenses.push(`${path.relative(path.join(root, 'node_modules'), folder)}/${name}\n${await readFile(path.join(folder, name), 'utf8')}`); } catch { /* license directories are not text files */ }
    }
  }
}
await collect(path.join(root, 'node_modules'));
await writeFile(path.join(relay, 'THIRD-PARTY-NOTICES.txt'), licenses.join('\n\n----------------\n\n'));
await mkdir(path.join(output, 'claude/.claude-plugin'), { recursive: true });
await json(path.join(output, 'claude/.claude-plugin/marketplace.json'), { name: 'scribe-local', metadata: { description: 'Local Scribe meeting transcript integration.' }, owner: { name: 'Cooperativ' }, plugins: [{ name: 'scribe', source: './plugins/scribe', description: 'Local Scribe transcript retrieval over MCP.', version: '0.1.0' }] });
// The ChatGPT package names the relay's shared endpoint, so it needs the relay's URL.
// connector.json tells the relay CLI (and Scribe's Settings) which relay that is.
if (values.url) {
  await json(path.join(relay, 'connector.json'), { connector_url: new URL(values.url).href });
  const chatgpt = await writeChatGPTPackage({ root, output: path.join(output, 'chatgpt'), url: values.url,
    links: { website: values['website-url'], privacy: values['privacy-url'], terms: values['terms-url'], support: values['support-url'] } });
  const { version } = JSON.parse(await readFile(path.join(chatgpt, 'plugin.json'), 'utf8'));
  // The same plugin, zipped for the Plugins Directory submission portal.
  const archive = await writeSubmissionArchive({ plugin: chatgpt, file: path.join(output, `submission/scribe-${version}.zip`) });
  console.log(`ChatGPT marketplace: ${path.join(output, 'chatgpt')} (plugin ${chatgpt})\nDirectory submission archive: ${archive}`);
}
console.log(`Local plugin (scribe-mcp-launcher): ${plugin}\nClaude marketplace: ${path.join(output, 'claude')}\nRelay service CLI: ${relay}`);

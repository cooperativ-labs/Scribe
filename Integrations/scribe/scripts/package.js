import { cp, mkdir, writeFile, readdir, readFile, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { parseArgs } from 'node:util';
import { writeChatGPTPackage, writeSubmissionArchive } from './chatgpt-package.js';
await import('./build.js');
const { values } = parseArgs({ options: { url: { type: 'string', default: process.env.SCRIBE_CONNECTOR_URL }, output: { type: 'string' },
  'website-url': { type: 'string' }, 'privacy-url': { type: 'string' }, 'terms-url': { type: 'string' }, 'support-url': { type: 'string' } } });
const root = fileURLToPath(new URL('..', import.meta.url));
const output = values.output ? path.resolve(values.output) : path.join(root, 'dist/packages');
const claude = path.join(output, 'claude/plugins/scribe');
const json = (file, value) => writeFile(file, JSON.stringify(value, null, 2) + '\n');
await mkdir(path.join(claude, 'dist'), { recursive: true });
// Directory listing material (screenshots, submission notes) is for the portal, not the plugin.
const forPortal = new Set([path.join(root, 'docs/listing'), path.join(root, 'docs/directory-submission.md')]);
for (const name of ['.claude-plugin', '.mcp.json', 'skills', 'ui', 'docs', 'README.md']) await cp(path.join(root, name), path.join(claude, name), { recursive: true, filter: source => !forPortal.has(source) });
await cp(path.join(root, 'dist/cli.mjs'), path.join(claude, 'dist/cli.mjs'));
// The MCP server inlines this icon in serverInfo.
await mkdir(path.join(claude, 'assets'), { recursive: true });
await cp(path.join(root, 'assets/icon.png'), path.join(claude, 'assets/icon.png'));
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
await writeFile(path.join(claude, 'THIRD-PARTY-NOTICES.txt'), licenses.join('\n\n----------------\n\n'));
await mkdir(path.join(output, 'claude/.claude-plugin'), { recursive: true });
await json(path.join(output, 'claude/.claude-plugin/marketplace.json'), { name: 'scribe-local', metadata: { description: 'Local Scribe meeting transcript integration.' }, owner: { name: 'Cooperativ' }, plugins: [{ name: 'scribe', source: './plugins/scribe', description: 'Local Scribe transcript retrieval over MCP.', version: '0.1.0' }] });
// The ChatGPT package names the relay's shared endpoint, so it needs the relay's URL.
// connector.json tells the bundled CLI (and Scribe's Settings) which relay that is.
const connector = path.join(claude, 'connector.json');
if (values.url) await json(connector, { connector_url: new URL(values.url).href });
else await rm(connector, { force: true });
if (values.url) {
  const plugin = await writeChatGPTPackage({ root, output: path.join(output, 'chatgpt'), url: values.url,
    links: { website: values['website-url'], privacy: values['privacy-url'], terms: values['terms-url'], support: values['support-url'] } });
  const { version } = JSON.parse(await readFile(path.join(plugin, 'plugin.json'), 'utf8'));
  // The same plugin, zipped for the Plugins Directory submission portal.
  const archive = await writeSubmissionArchive({ plugin, file: path.join(output, `submission/scribe-${version}.zip`) });
  console.log(`ChatGPT marketplace: ${path.join(output, 'chatgpt')} (plugin ${plugin})\nDirectory submission archive: ${archive}`);
}
console.log(`Claude marketplace: ${path.join(output, 'claude')}`);

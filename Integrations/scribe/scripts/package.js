import { cp, mkdir, writeFile, readdir, readFile, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { parseArgs } from 'node:util';
import { writeChatGPTPackage } from './chatgpt-package.js';
await import('./build.js');
const { values } = parseArgs({ options: { url: { type: 'string', default: process.env.SCRIBE_CONNECTOR_URL }, output: { type: 'string' },
  'website-url': { type: 'string' }, 'privacy-url': { type: 'string' }, 'terms-url': { type: 'string' } } });
const root = fileURLToPath(new URL('..', import.meta.url));
const output = values.output ? path.resolve(values.output) : path.join(root, 'dist/packages');
const claude = path.join(output, 'claude/plugins/scribe');
const json = (file, value) => writeFile(file, JSON.stringify(value, null, 2) + '\n');
await mkdir(path.join(claude, 'dist'), { recursive: true });
for (const name of ['.claude-plugin', '.mcp.json', 'skills', 'ui', 'docs', 'README.md']) await cp(path.join(root, name), path.join(claude, name), { recursive: true });
await cp(path.join(root, 'dist/cli.mjs'), path.join(claude, 'dist/cli.mjs'));
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
if (values.url) console.log(`ChatGPT marketplace: ${path.join(output, 'chatgpt')} (plugin ${await writeChatGPTPackage({ root, output: path.join(output, 'chatgpt'), url: values.url,
  links: { website: values['website-url'], privacy: values['privacy-url'], terms: values['terms-url'] } })})`);
console.log(`Claude marketplace: ${path.join(output, 'claude')}`);

import { cp, mkdir, writeFile, readdir, readFile, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { parseArgs } from 'node:util';
await import('./build.js');
const { values } = parseArgs({ options: { url: { type: 'string' }, 'app-id': { type: 'string' }, output: { type: 'string' } } });
const root = fileURLToPath(new URL('..', import.meta.url));
const output = values.output ? path.resolve(values.output) : path.join(root, 'dist/packages');
const claude = path.join(output, 'claude/plugins/scribe');
const json = (file, value) => writeFile(file, JSON.stringify(value, null, 2) + '\n');
await mkdir(path.join(claude, 'dist'), { recursive: true });
for (const name of ['.claude-plugin', '.mcp.json', 'skills', 'ui', 'README.md']) await cp(path.join(root, name), path.join(claude, name), { recursive: true });
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
if (values.url) {
  const url = new URL(values.url);
  if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash || url.pathname !== '/mcp') throw new Error('--url must be the exact HTTPS /mcp endpoint.');
  if (values['app-id'] && !/^plugin_asdk_app[A-Za-z0-9_-]+$/.test(values['app-id'])) throw new Error('Invalid ChatGPT registered plugin ID.');
  const chatgpt = path.join(output, 'chatgpt/scribe');
  await mkdir(chatgpt, { recursive: true });
  const manifest = { $schema: 'https://agent-plugins.org/schemas/1.0.0/plugin.schema.json', name: 'scribe', version: '0.1.0',
    description: 'Read Scribe meeting transcripts and create grounded summaries and action items.', author: { name: 'Cooperativ' } };
  if (values['app-id']) {
    manifest.extensions = { 'com.openai': { apps: './.app.json' } };
    await json(path.join(chatgpt, '.app.json'), { apps: { scribe: { id: values['app-id'] } } });
  } else await rm(path.join(chatgpt, '.app.json'), { force: true });
  await json(path.join(chatgpt, 'plugin.json'), manifest);
  await json(path.join(chatgpt, 'mcp.json'), { $schema: 'https://agent-plugins.org/schemas/1.0.0/mcp.schema.json', mcpServers: { scribe: { type: 'streamable-http', url: url.href } } });
  await cp(path.join(root, 'skills'), path.join(chatgpt, 'skills'), { recursive: true });
  console.log(`ChatGPT portable plugin: ${chatgpt}`);
}
console.log(`Claude marketplace: ${path.join(output, 'claude')}`);

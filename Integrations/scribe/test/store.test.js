import { test } from 'node:test';
import assert from 'node:assert/strict';
import { writeFile, symlink, mkdir, rename } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import path from 'node:path';
import { TranscriptLibrary } from '../src/store.js';
import { fixture } from './fixture.js';

test('latest saved run per source, date filters, literal search and saved speaker labels', async t => {
  const { root, add } = await fixture(t);
  await add({ meeting: 'one', date: '2026-09-18T10:00:00Z', text: 'Old transcript' });
  const current = await add({ meeting: 'one', date: '2026-09-20T10:00:00Z', text: 'Literal [query] ships Friday.' });
  // Historical Scribe stores use a directory UUID distinct from job.runID.
  await rename(current.dir, path.join(path.dirname(current.dir), randomUUID()));
  await add({ meeting: 'one', date: '2026-09-21T10:00:00Z', complete: false });
  await add({ meeting: 'two', date: '2026-09-19T10:00:00Z' });
  const library = new TranscriptLibrary(root);
  const page = await library.list({ limit: 1 });
  assert.equal(page.total, 2); assert.equal(page.transcripts[0].id, current.id); assert.equal(page.next_offset, 1); assert.equal(page.skipped_runs, 1);
  assert.equal((await library.list({ query: '[query]' })).total, 1);
  assert.equal((await library.list({ query: 'UPDATED NAME' })).total, 2);
  assert.equal((await library.list({ query: 'Old transcript' })).total, 0);
  assert.equal((await library.list({ before: '2026-09-20T10:00:00Z' })).total, 1);
  const result = await library.get({ id: current.id });
  assert.match(result.text, /00:00:01.*Updated name/); assert.doesNotMatch(JSON.stringify(result), /Old name|planning.wav|must\/not/);
});
test('complete pagination and revision checks, deletion, corrupt files and path boundaries', async t => {
  const { root, add } = await fixture(t);
  const current = await add({ text: 'A😀long meeting '.repeat(4000) });
  const library = new TranscriptLibrary(root);
  let offset = 0, combined = '';
  do { const result = await library.get({ id: current.id, offset, max_chars: 1234, revision: 1 }); combined += result.text; offset = result.next_offset; } while (offset !== null);
  assert.equal(combined, (await library.get({ id: current.id, max_chars: 100000 })).text);
  await writeFile(path.join(current.dir, 'canonical-transcript.json'), JSON.stringify({ ...current.data, revision: 2 }));
  await assert.rejects(library.get({ id: current.id, revision: 1 }), /changed/);
  await assert.rejects(library.get({ id: '../../etc/passwd' }), /not found/);
  await assert.rejects(library.get({ id: current.id, offset: 999999 }), /beyond/);
  await writeFile(path.join(current.dir, 'canonical-transcript.json'), 'broken');
  assert.equal((await library.list()).total, 0);
  const outside = await fixture(t); const other = await outside.add();
  await symlink(path.dirname(path.dirname(other.dir)), path.join(root, 'meeting--symlink'));
  await mkdir(path.join(root, 'meeting--escaped'));
  await symlink(path.dirname(other.dir), path.join(root, 'meeting--escaped/runs'));
  assert.equal((await library.list()).total, 0);
  await assert.rejects(new TranscriptLibrary(path.join(root, 'missing')).list(), /unavailable/);
});

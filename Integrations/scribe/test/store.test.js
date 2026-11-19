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
  do { const result = await library.get({ id: current.id, offset, max_chars: 1234, revision: 1 }); assert.doesNotMatch(result.text, /[\uD800-\uDBFF]$/); combined += result.text; offset = result.next_offset; } while (offset !== null);
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
test('meeting notes: old job records, newer or unsafe notes files, and pagination left as it was', async t => {
  const { root, add } = await fixture(t);
  const note = (text, offset = null) => ({ id: randomUUID(), text, recordingOffsetMilliseconds: offset });
  const entry = (draftID, notes) => ({ draftID, recorderSessionID: randomUUID(), attachedRevision: 1, notes });
  const notesFile = (meeting, body) => writeFile(path.join(root, `meeting--${meeting}`, 'meeting-notes.json'), JSON.stringify(body));
  // The fixture's job.json has no request at all, as job records from before
  // drafts did: every entry is the meeting's notes.
  const old = await add({ meeting: 'old', text: 'Plain transcript '.repeat(300) });
  await notesFile('old', { schemaVersion: 1, entries: [entry(randomUUID(), [note('Remember the heron', 61_000), note(' ')])] });
  const newer = await add({ meeting: 'newer' });
  await notesFile('newer', { schemaVersion: 2, entries: [entry(randomUUID(), [note('From the future heron')])] });
  const linked = await add({ meeting: 'linked' });
  const outside = path.join(root, '..', `outside-${randomUUID()}.json`);
  await writeFile(outside, JSON.stringify({ schemaVersion: 1, entries: [entry(randomUUID(), [note('Outside heron')])] }));
  t.after(() => import('node:fs/promises').then(fs => fs.rm(outside, { force: true })));
  await symlink(outside, path.join(root, 'meeting--linked', 'meeting-notes.json'));
  const library = new TranscriptLibrary(root);

  const first = await library.get({ id: old.id, max_chars: 1000 });
  assert.deepEqual(first.notes.map(({ text, offset_ms }) => [text, offset_ms]), [['Remember the heron', 61_000]]);
  assert.equal(first.revision, 1);
  // Notes come whole with every page and never change the paged text.
  let offset = 0, pages = 0, text = '';
  while (offset !== null) {
    const page = await library.get({ id: old.id, offset, max_chars: 1000, revision: 1 });
    assert.deepEqual(page.notes, first.notes); text += page.text; offset = page.next_offset; pages++;
  }
  assert.ok(pages > 1); assert.doesNotMatch(text, /heron/);
  for (const run of [newer, linked]) assert.deepEqual((await library.get({ id: run.id })).notes, []);
  const found = await library.list({ query: 'heron' });
  assert.deepEqual(found.transcripts.map(item => item.id), [old.id]);
  assert.equal(found.transcripts[0].excerpt, undefined);
  assert.deepEqual(found.transcripts[0].matched_note, { id: first.notes[0].id, offset_ms: 61_000, excerpt: 'Remember the heron' });
  assert.equal((await library.list({})).transcripts.every(item => !('matched_note' in item)), true);
});

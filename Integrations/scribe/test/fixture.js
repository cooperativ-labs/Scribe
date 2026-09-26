import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
export async function fixture(t) {
  const root = await mkdtemp(path.join(tmpdir(), 'scribe-mcp-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  async function add({ meeting = randomUUID(), id = randomUUID(), date = '2026-09-20T10:00:00Z', title = 'Planning', text = 'Ship the project on Friday.', revision = 1, complete = true } = {}) {
    const dir = path.join(root, `meeting--${meeting}`, 'runs', id);
    await mkdir(dir, { recursive: true });
    await writeFile(path.join(dir, 'job.json'), JSON.stringify({ runID: id, createdAt: date, runDirectoryURL: '/must/not/be/read' }));
    const data = { schema_version: 1, transcript_id: randomUUID(), revision, title, created_at: date, status: 'complete',
      source: { filename: 'planning.wav', duration_ms: 60000 }, language: 'en', timestamp_unit: 'milliseconds', timestamp_origin: 'source_start',
      speakers: [{ id: 'speaker_1', label_snapshot: 'Updated name' }],
      segments: [{ id: 'segment_1', speaker_id: 'speaker_1', speaker_label: 'Old name', start_ms: 1000, end_ms: 2000, text }], warnings: [] };
    if (complete) await writeFile(path.join(dir, 'canonical-transcript.json'), JSON.stringify(data));
    return { id, dir, data };
  }
  return { root, add };
}

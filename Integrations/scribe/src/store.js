import { constants } from 'node:fs';
import { open, readdir, realpath } from 'node:fs/promises';
import path from 'node:path';
import { z } from 'zod';

const timestamp = z.string().refine(value => Number.isFinite(Date.parse(value)));
export const canonicalSchema = z.object({
  schema_version: z.literal(1), transcript_id: z.string().max(200), revision: z.number().int().nonnegative(),
  title: z.string().max(2000).nullish(), created_at: timestamp,
  status: z.enum(['complete', 'completeWithWarnings', 'noSpeech']),
  source: z.object({ filename: z.string().max(2000), duration_ms: z.number().nonnegative() }),
  language: z.string().max(100), timestamp_unit: z.literal('milliseconds'), timestamp_origin: z.literal('source_start'),
  speakers: z.array(z.object({ id: z.string(), label_snapshot: z.string().max(2000) })).max(500),
  segments: z.array(z.object({ id: z.string(), speaker_id: z.string().nullish(), speaker_label: z.string().max(2000),
    start_ms: z.number().nonnegative(), end_ms: z.number().nonnegative(), text: z.string(),
  })),
  warnings: z.array(z.object({ code: z.string().max(200), message: z.string().max(4000) })).max(1000),
});
const jobSchema = z.object({ runID: z.string().uuid(), createdAt: timestamp });
export class StoreError extends Error {}
const MAX_FILE_BYTES = 32 * 1024 * 1024;

// Only walk Scribe's known layout. Never follow filenames supplied by an MCP caller
// or the absolute paths recorded in job.json. Symlinks must resolve inside the store.
async function readJSON(root, filename) {
  const resolved = await realpath(filename);
  if (!resolved.startsWith(root + path.sep)) throw new StoreError('Unsafe transcript path.');
  const file = await open(filename, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stat = await file.stat();
    if (!stat.isFile() || stat.size > MAX_FILE_BYTES) throw new StoreError('Transcript file exceeds the supported size.');
    return JSON.parse(await file.readFile('utf8'));
  } finally { await file.close(); }
}
async function directories(root, folder) {
  const resolved = await realpath(folder);
  if (resolved !== root && !resolved.startsWith(root + path.sep)) throw new StoreError('Unsafe transcript path.');
  return (await readdir(folder, { withFileTypes: true })).filter(entry => entry.isDirectory() && !entry.name.startsWith('.'));
}
function timecode(ms) {
  const seconds = Math.floor(ms / 1000);
  return `${String(Math.floor(seconds / 3600)).padStart(2, '0')}:${String(Math.floor(seconds / 60) % 60).padStart(2, '0')}:${String(seconds % 60).padStart(2, '0')}`;
}
function titleOf(t) { return t.title?.trim() || path.basename(t.source.filename); }
export function summary(run) {
  const t = run.transcript;
  return { id: run.id, title: titleOf(t), created_at: t.created_at, processed_at: run.createdAt,
    revision: t.revision, duration_ms: t.source.duration_ms, language: t.language,
    status: t.status, speakers: t.speakers.map(s => s.label_snapshot),
    url: `scribe://transcripts/${run.id}` };
}
export function transcriptText(t) {
  const speakers = new Map(t.speakers.map(s => [s.id, s.label_snapshot]));
  return t.segments.map(s => `[${timecode(s.start_ms)}–${timecode(s.end_ms)}] ${speakers.get(s.speaker_id) ?? s.speaker_label}: ${s.text}`).join('\n');
}
export class TranscriptLibrary {
  constructor(root) { this.root = path.resolve(root); }
  async snapshot() {
    let root, meetings;
    try { root = await realpath(this.root); meetings = await directories(root, root); }
    catch { throw new StoreError('Scribe transcript folder is unavailable. Check SCRIBE_TRANSCRIPTS_DIR and folder permissions.'); }
    const runs = [];
    let skipped = 0, count = 0;
    for (const meeting of meetings.filter(entry => entry.name.startsWith('meeting--'))) {
      const folder = path.join(root, meeting.name, 'runs');
      let entries;
      try { entries = await directories(root, folder); } catch { skipped++; continue; }
      for (const entry of entries) {
        if (++count > 10000) throw new StoreError('Library exceeds 10,000 runs. Select a smaller transcript folder.');
        if (!z.string().uuid().safeParse(entry.name).success) { skipped++; continue; }
        try {
          const dir = path.join(folder, entry.name);
          const job = jobSchema.parse(await readJSON(root, path.join(dir, 'job.json')));
          // TranscriptStore identifies runs by job.runID. Historical stores can
          // have a different UUID directory name; never treat it as the identity.
          const transcript = canonicalSchema.parse(await readJSON(root, path.join(dir, 'canonical-transcript.json')));
          runs.push({ id: job.runID.toLowerCase(), meeting: meeting.name, createdAt: job.createdAt, transcript });
        } catch { skipped++; }
      }
    }
    runs.sort((a, b) => Date.parse(b.createdAt) - Date.parse(a.createdAt) || a.id.localeCompare(b.id));
    return { runs, skipped };
  }
  async list({ query = '', after, before, limit = 10, offset = 0 } = {}) {
    const { runs, skipped } = await this.snapshot();
    const seen = new Set();
    const latest = runs.filter(run => { if (seen.has(run.meeting)) return false; seen.add(run.meeting); return true; });
    const needle = query.trim().toLocaleLowerCase();
    const matches = latest.filter(run => {
      const date = Date.parse(run.transcript.created_at);
      if (after && date < Date.parse(after) || before && date >= Date.parse(before)) return false;
      const t = run.transcript;
      return !needle || [titleOf(t), ...t.speakers.map(s => s.label_snapshot), ...t.segments.map(s => s.text)]
        .some(text => text.toLocaleLowerCase().includes(needle));
    });
    return { transcripts: matches.slice(offset, offset + limit).map(run => {
      const result = summary(run);
      if (needle) {
        const match = run.transcript.segments.find(s => s.text.toLocaleLowerCase().includes(needle));
        if (match) {
          const index = match.text.toLocaleLowerCase().indexOf(needle);
          result.excerpt = match.text.slice(Math.max(0, index - 80), index + 200);
        }
      }
      return result;
    }), total: matches.length, next_offset: offset + limit < matches.length ? offset + limit : null, skipped_runs: skipped };
  }
  async get({ id, offset = 0, max_chars = 16000, revision }) {
    const { runs } = await this.snapshot();
    const run = runs.find(run => run.id === id.toLowerCase());
    if (!run) throw new StoreError('Transcript not found. List recent transcripts again; it may have been deleted or is still processing.');
    if (revision !== undefined && revision !== run.transcript.revision) throw new StoreError('Transcript changed. Restart retrieval at offset 0 with its new revision.');
    const text = transcriptText(run.transcript);
    if (offset > text.length) throw new StoreError('Offset is beyond the end of this transcript.');
    return { ...summary(run), text: text.slice(offset, offset + max_chars), offset,
      total_chars: text.length, next_offset: offset + max_chars < text.length ? offset + max_chars : null,
      warnings: run.transcript.warnings };
  }
}

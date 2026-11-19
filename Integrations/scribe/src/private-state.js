import { randomUUID } from 'node:crypto';
import { mkdirSync, renameSync, writeFileSync } from 'node:fs';
import path from 'node:path';

// Publish complete private state on the same volume as the destination.
export function writePrivateState(file, data) {
  mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const temporary = `${file}.${randomUUID()}.tmp`;
  writeFileSync(temporary, data, { mode: 0o600, flag: 'wx' });
  renameSync(temporary, file);
}

#!/usr/bin/env python3
"""Run isolated diarization on existing prepared.wav files, serially.

Raw outputs stay in --output. No ASR, grouping, source writes, or audio uploads.
SpeakerKit requires predownloaded models; its exclusive reconciliation stays OFF.
"""
import argparse
import hashlib
import json
import pathlib
import subprocess
import time


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('runs', nargs='+', type=pathlib.Path)
    p.add_argument('--engine', choices=['fluid', 'speakerkit'], required=True)
    p.add_argument('--binary', type=pathlib.Path, required=True)
    p.add_argument('--models', type=pathlib.Path, required=True)
    p.add_argument('--manifest', type=pathlib.Path)
    p.add_argument('--revision', required=True)
    p.add_argument('--output', type=pathlib.Path, required=True)
    a = p.parse_args()
    a.output.mkdir(parents=True, exist_ok=True)
    for run in a.runs:
        for count in [None, 2]:
            mode = 'automatic' if count is None else 'exact-two'
            key = f'{run.parent.parent.name}-{a.engine}-{mode}'
            audio = run / 'prepared.wav'
            common = dict(engine=a.engine, revision=a.revision, binary_sha256=sha(a.binary),
                          audio_sha256=sha(audio), known_speaker_count=count)
            log = a.output / f'{key}.log'
            if a.engine == 'fluid':
                if not a.manifest:
                    p.error('--manifest required for FluidAudio')
                command = [str(a.binary), '--audio', str(audio), '--manifest', str(a.manifest), '--models', str(a.models)]
                if count:
                    command += ['--known-speaker-count', str(count)]
                raw = a.output / f'{key}.raw.json'
                with log.open('w') as err, raw.open('w') as out:
                    start = time.monotonic()
                    result = subprocess.run(command, stdout=out, stderr=err)
                    elapsed = time.monotonic() - start
                document = json.loads(raw.read_text()) if result.returncode == 0 else {}
                if result.returncode == 0 and document.get('engine', {}).get('runtimeRevision') != a.revision:
                    raise ValueError('FluidAudio executable lacks the expected engine revision; rebuild current sources before benchmarking')
            else:
                rttm = a.output / f'{key}.rttm'
                command = [str(a.binary), 'diarize', '--audio-path', str(audio), '--model-path', str(a.models),
                           '--rttm-path', str(rttm), '--verbose']
                if count:
                    command += ['--num-speakers', str(count)]
                with log.open('w') as out:
                    start = time.monotonic()
                    result = subprocess.run(command, stdout=out, stderr=subprocess.STDOUT)
                    elapsed = time.monotonic() - start
                intervals = []
                if result.returncode == 0:
                    for line in rttm.read_text().splitlines():
                        fields = line.split()
                        if len(fields) != 10 or fields[0] != 'SPEAKER':
                            raise ValueError(f'Invalid RTTM row in {rttm}')
                        start_sec, duration = float(fields[3]), float(fields[4])
                        intervals.append(dict(speakerID=fields[7], startSeconds=start_sec, endSeconds=start_sec + duration))
                document = dict(intervals=intervals)
            # Preserve simultaneous intervals; do not convert to exclusive turns.
            for interval in document.get('intervals', []):
                interval['overlapsAnotherSpeaker'] = any(
                    other['speakerID'] != interval['speakerID'] and
                    min(other['endSeconds'], interval['endSeconds']) > max(other['startSeconds'], interval['startSeconds'])
                    for other in document['intervals'])
            document['benchmark'] = dict(**common, process_wall_seconds=elapsed,
                                         exit_code=result.returncode, command=command)
            (a.output / f'{key}.json').write_text(json.dumps(document, indent=2) + '\n')
            print(key, 'exit', result.returncode, 'seconds', round(elapsed, 3), flush=True)


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Compile and replay the actual host sources. Output contains private transcript text.

Usage: replay.py RUN TRANSCRIPT_OR_saved DIARIZATION --output PRIVATE_JSON
Requires macOS/Swift. No inference, networking or source-meeting writes.
"""
import argparse
import pathlib
import subprocess
import tempfile
import shutil


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('run')
    p.add_argument('transcript')
    p.add_argument('diarization')
    p.add_argument('--output', required=True, type=pathlib.Path)
    p.add_argument('--keep-executable', type=pathlib.Path, help='Copy the built host replay for further runs')
    a = p.parse_args()
    root = pathlib.Path(__file__).resolve().parents[2]
    host = root / 'Modules/Transcription/Sources/Transcription'
    with tempfile.TemporaryDirectory(prefix='scribe-host-replay-') as temp:
        temp = pathlib.Path(temp)
        # Extract the complete production mapping type, avoiding AVFoundation's
        # unrelated preparation/service dependencies. Do not reimplement it.
        source = (host / 'Import/AudioPreparationService.swift').read_text()
        mapping = source.split('public struct AudioTimeMapping:', 1)[1].split('\npublic struct PhaseCancellationWarning:', 1)[0]
        mapping_path = temp / 'AudioTimeMapping.swift'
        mapping_path.write_text('import Foundation\npublic struct AudioTimeMapping:' + mapping)
        bundle_path = temp / 'Bundle.swift'
        bundle_path.write_text('import Foundation\nextension Bundle { static var module: Bundle { .main } }\n')
        names = ['CanonicalTranscript', 'WorkerASRTranscript', 'TokenTimingReconciler',
                 'SpeakerTurnBuilder', 'TranscriptDisplayGrouper']
        executable = temp / 'replay'
        subprocess.run(['swiftc', '-O', '-module-cache-path', str(temp / 'module-cache'),
                        *[str(host / f'Transcript/{n}.swift') for n in names],
                        str(mapping_path), str(bundle_path), str(root / 'Tools/DiarizationAnalysis/Replay.swift'),
                        '-o', str(executable)], check=True)
        if a.keep_executable:
            shutil.copy2(executable, a.keep_executable)
        with a.output.open('w') as output:
            transcript = '--saved-words' if a.transcript == 'saved' else a.transcript
            subprocess.run([str(executable), a.run, transcript, a.diarization], stdout=output, check=True)


if __name__ == '__main__':
    main()

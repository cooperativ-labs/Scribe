#!/usr/bin/env python3
"""Make local WAV review clips and transcript-free candidate annotations.

These are signal/model observations, NOT listening-based or human annotations.
Keep --output private: it contains audio. --annotations may be shared separately.
"""
import argparse
import array
import csv
import json
import math
import pathlib
import subprocess
import tempfile
import wave


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--audio', type=pathlib.Path, required=True)
    p.add_argument('--replay', type=pathlib.Path, required=True)
    p.add_argument('--fluid', type=pathlib.Path, required=True)
    p.add_argument('--speakerkit', type=pathlib.Path, required=True)
    p.add_argument('--output', type=pathlib.Path, required=True)
    p.add_argument('--annotations', type=pathlib.Path, required=True)
    a = p.parse_args()
    words = json.loads(a.replay.read_text())['words']
    engines = {name: json.loads(path.read_text())['intervals'] for name, path in [('fluid', a.fluid), ('speakerkit', a.speakerkit)]}
    candidates = [('opening-exchange', 65, 85, 'Opening greeting exchange; text-only reference may combine both voices.'),
                  ('early-pause', 79, 101, 'Historical word absorbed a long pause; verify actual acoustic endpoint.')]
    gaps = [(y['startMs']-x['endMs'], x['endMs'], y['startMs']) for x,y in zip(words,words[1:]) if x['endMs']>600_000 and y['startMs']<3_000_000]
    gap, start, end = max(gaps)
    candidates.append(('mid-recording-pause', start/1000-3, end/1000+3, f'Decoder word gap {gap} ms; energy alone cannot prove silence or word boundaries.'))
    acknowledgment = next(w for w in words if 600_000<w['startMs']<3_000_000 and w['text'].casefold().strip('.,?!') in ['yeah','okay','yep'] and w['endMs']-w['startMs']<400)
    candidates.append(('short-acknowledgment', acknowledgment['startMs']/1000-3, acknowledgment['endMs']/1000+3, 'Short acknowledgment selected from ASR text; verify voice, interruption, and timing by listening.'))
    for name, intervals in engines.items():
        overlap = next((t for t in intervals if t.get('overlapsAnotherSpeaker') and 120<t['startSeconds']<3300), None)
        if overlap:
            candidates.append((name+'-overlap-candidate', overlap['startSeconds']-2, min(overlap['endSeconds']+2, overlap['startSeconds']+14), 'Model-reported overlapping interval; not verified simultaneous speech.'))
    longest = max(words, key=lambda w: w['endMs']-w['startMs'])
    candidates.append(('long-word', longest['startMs']/1000-2, longest['endMs']/1000+2, 'Longest reconstructed word; do not apply a blanket duration cap.'))
    boundary = 14.88*50
    candidates.append(('chunk-boundary', boundary-5, boundary+5, 'Nominal 14.88-second chunk grid at 744 s; inspect continuity, not a known acoustic boundary.'))
    a.output.mkdir(parents=True, exist_ok=True)
    results = []
    # AVFoundation preparation can produce IEEE float WAV. Decode a temporary
    # signed-16 listening copy; diarizer benchmarks still use the original bytes.
    with tempfile.TemporaryDirectory(prefix='scribe-excerpt-pcm-') as temp:
        pcm = pathlib.Path(temp)/'audio.wav'
        subprocess.run(['ffmpeg', '-v', 'error', '-i', str(a.audio), '-ac', '1', '-ar', '16000',
                        '-c:a', 'pcm_s16le', str(pcm)], check=True)
        extract(pcm, a, candidates, engines, results)
    a.annotations.write_text(json.dumps(dict(human_review_complete=False, excerpts=results),indent=2)+'\n')
    with (a.output/'human-review.tsv').open('w') as file:
        writer = csv.writer(file, delimiter='\t')
        writer.writerow(['clip','source_start_seconds','source_end_seconds','reviewer','speaker_changes','pauses','acknowledgment','overlap','uncertain'])
        for row in results:
            writer.writerow([row['id']+'.wav',row['source_start_seconds'],row['source_end_seconds'],'','','','','',''])
    print(f'{len(results)} private clips; human review remains pending')


def extract(pcm, a, candidates, engines, results):
    with wave.open(str(pcm), 'rb') as source:
        assert source.getnchannels()==1 and source.getsampwidth()==2, 'Requires mono signed-16 PCM WAV'
        rate = source.getframerate()
        for key, start, end, note in candidates:
            start = max(0, start)
            end = min(end, source.getnframes()/rate)
            first, last = round(start*rate), round(end*rate)
            source.setpos(first)
            raw = source.readframes(last-first)
            with wave.open(str(a.output/f'{key}.wav'), 'wb') as clip:
                clip.setparams((1, 2, rate, 0, 'NONE', 'not compressed'))
                clip.writeframes(raw)
            samples = array.array('h', raw)
            # Non-overlapping 100 ms RMS bins: useful for pause inspection,
            # explicitly not VAD, word alignment or speaker/overlap evidence.
            step = rate//10
            bins = [round(20*math.log10(max(1e-9, math.sqrt(sum(x*x for x in samples[i:i+step])/len(samples[i:i+step]))/32768)), 2)
                    for i in range(0, len(samples), step)]
            row = dict(id=key, source_start_seconds=round(first/rate, 3), source_end_seconds=round(last/rate, 3),
                       annotation_kind='machine-selected; signal/model review only; listening pending',
                       note=note, rms_bin_seconds=.1, rms_dbfs=bins,
                       reviewed_speaker_changes=None, reviewed_pause_boundaries=None,
                       reviewed_acknowledgment_speaker=None, reviewed_overlap=None,
                       engine_observations={})
            for name, intervals in engines.items():
                local = [t for t in intervals if min(t['endSeconds'],end)>max(t['startSeconds'],start)]
                row['engine_observations'][name] = dict(speakers=sorted({t['speakerID'] for t in local}),
                    intervals=len(local), overlap_intervals=sum(t.get('overlapsAnotherSpeaker', False) for t in local))
            results.append(row)


if __name__ == '__main__':
    main()

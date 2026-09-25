#!/usr/bin/env python3
"""Convert an RTTM hypothesis into Scribe's worker diarization.json shape.

Replay only reads intervals (speakerID, startSeconds, endSeconds, qualityScore,
overlapsAnotherSpeaker); wder.py also reads engine.runtimeRevision for
provenance. Speakers are renamed speaker_1..N by first appearance, matching the
worker's convention. Engines that emit RTTM (FluidAudio nemotron3-diarize,
pyannote, SpeakerKit) can then be scored with score.sh unchanged.
"""
import argparse
import json
import pathlib


def read_rttm(path):
    rows = []
    for line in pathlib.Path(path).read_text().splitlines():
        fields = line.split()
        if not fields or fields[0] != "SPEAKER":
            continue
        start, duration = float(fields[3]), float(fields[4])
        if duration > 0:
            rows.append((start, start + duration, fields[7]))
    if not rows:
        raise ValueError(f"No SPEAKER rows in {path}")
    return sorted(rows)


def to_intervals(rows):
    names = {}
    for _, _, label in rows:
        names.setdefault(label, f"speaker_{len(names) + 1}")
    intervals = []
    for start, end, label in rows:
        overlaps = any(o_label != label and o_start < end and start < o_end
                       for o_start, o_end, o_label in rows)
        intervals.append(dict(speakerID=names[label], startSeconds=start, endSeconds=end,
                              qualityScore=1, overlapsAnotherSpeaker=overlaps))
    return intervals


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("rttm", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--runtime", required=True, help='e.g. "FluidAudio 0.17.2 nemotron3 offline"')
    parser.add_argument("--revision", required=True, help="Runtime git revision, recorded as engine.runtimeRevision")
    parser.add_argument("--model-revision", default="unknown")
    parser.add_argument("--source-duration", type=float, help="Seconds; defaults to the last interval end")
    parser.add_argument("--processing-seconds", type=float, help="Wall-clock diarization time, if measured")
    args = parser.parse_args()

    rows = read_rttm(args.rttm)
    intervals = to_intervals(rows)
    document = dict(
        intervals=intervals,
        sourceDurationSeconds=args.source_duration or max(end for _, end, _ in rows),
        engine=dict(runtime=args.runtime, runtimeRevision=args.revision, modelRevision=args.model_revision),
        timings=dict(totalProcessingSeconds=args.processing_seconds) if args.processing_seconds else None,
        convertedFrom=dict(format="rttm", filename=args.rttm.name),
    )
    args.output.write_text(json.dumps(document, indent=1))
    speakers = len({i["speakerID"] for i in intervals})
    print(f"{len(intervals)} intervals, {speakers} speakers, "
          f"{sum(i['overlapsAnotherSpeaker'] for i in intervals)} overlapping -> {args.output}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Score a Scribe diarization replay against local speaker ground truth.

The tool deliberately writes no transcript text or real speaker identifiers.  It
replays the production Swift host through ``replay.py`` unless ``--host-replay``
points at an executable previously built by that harness.  The saved replay JSON
is held in a temporary directory and is never included in the aggregate output.

Examples:
  # Score speaker assignments manually corrected in canonical-transcript.json.
  python3 Tools/DiarizationAnalysis/wder.py "$RUN" --output metrics.json

  # Score a MacWhisper JSON, SRT/VTT, or ``Speaker: utterance`` text export.
  python3 Tools/DiarizationAnalysis/wder.py "$RUN" --reference reference.json \
    --transcript "$EVAL/transcript.json" --diarization "$EVAL/fluid.json" \
    --output metrics.json
"""
import argparse
import collections
import difflib
import functools
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import tempfile


WORD_RE = re.compile(r"\w+", re.UNICODE)
SPEAKER_LINE_RE = re.compile(r"^\s*([^:\n]{1,120}):\s*(\S.*)$")
TIMESTAMP_RE = re.compile(
    r"(?P<start>\d{1,2}:\d{2}:\d{2}[,.]\d{3})\s*-->\s*"
    r"(?P<end>\d{1,2}:\d{2}:\d{2}[,.]\d{3})"
)
JSON_TIMESTAMP_RANGE_RE = re.compile(
    r"^\s*(?P<start>(?:\d{1,2}:)?\d{1,2}:\d{2}(?:[,.]\d{1,3})?)\s*-\s*"
    r"(?P<end>(?:\d{1,2}:)?\d{1,2}:\d{2}(?:[,.]\d{1,3})?)\s*$"
)


def lexical(text):
    return WORD_RE.findall(text.casefold())


def sha256(path):
    digest = hashlib.sha256()
    with pathlib.Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def milliseconds(value, key=""):
    """Decode a JSON timestamp; explicit ``*_ms`` fields remain milliseconds."""
    if value is None:
        return None
    value = float(value)
    return round(value if key.casefold().endswith("ms") else value * 1000)


def parse_srt_timestamp(value):
    parts = value.replace(",", ".").split(":")
    if len(parts) == 2:
        hours, minutes, seconds = 0, parts[0], parts[1]
    elif len(parts) == 3:
        hours, minutes, seconds = parts
    else:
        raise ValueError(f"Unrecognised timestamp: {value!r}")
    return round((int(hours) * 3600 + int(minutes) * 60 + float(seconds)) * 1000)


def parse_json_timestamp_range(value):
    match = JSON_TIMESTAMP_RANGE_RE.match(str(value))
    if not match:
        raise ValueError(f"Unrecognised JSON timestamp range: {value!r}")
    return parse_srt_timestamp(match.group("start")), parse_srt_timestamp(match.group("end"))


def speaker_and_text(lines):
    text = " ".join(line.strip() for line in lines if line.strip())
    match = SPEAKER_LINE_RE.match(text)
    if not match:
        raise ValueError("Every reference caption/text line must start with 'Speaker:'.")
    return match.group(1).strip(), match.group(2).strip()


def parse_caption_reference(source):
    blocks = re.split(r"\n\s*\n", source.replace("\r\n", "\n").strip())
    result = []
    for block in blocks:
        lines = [line.strip() for line in block.splitlines() if line.strip() and line.strip() != "WEBVTT"]
        if not lines:
            continue
        timestamp_index = next((i for i, line in enumerate(lines) if "-->" in line), None)
        if timestamp_index is None:
            # Plain text permits one speaker utterance per physical line.
            for line in lines:
                speaker, text = speaker_and_text([line])
                result.append(dict(speaker=speaker, text=text))
            continue
        match = TIMESTAMP_RE.search(lines[timestamp_index])
        if not match:
            raise ValueError(f"Unrecognised SRT/VTT timing line: {lines[timestamp_index]!r}")
        speaker, text = speaker_and_text(lines[timestamp_index + 1:])
        result.append(dict(speaker=speaker, text=text,
                           start_ms=parse_srt_timestamp(match.group("start")),
                           end_ms=parse_srt_timestamp(match.group("end"))))
    return result


def parse_json_reference(document):
    entries = document if isinstance(document, list) else document.get("segments")
    if not isinstance(entries, list):
        raise ValueError("Reference JSON must be a list or contain a 'segments' list.")
    result = []
    for entry in entries:
        if not isinstance(entry, dict):
            raise ValueError("Reference JSON entries must be objects.")
        speaker = next((entry.get(key) for key in ("speaker", "speakerName", "speaker_name", "speaker_id") if entry.get(key) is not None), None)
        text = next((entry.get(key) for key in ("text", "transcript", "content") if entry.get(key) is not None), None)
        if text is None:
            raise ValueError("Reference JSON entries require a text field.")
        # Reviewed benchmark exports may retain transcript rows whose speaker was
        # intentionally left unset. They cannot provide speaker ground truth.
        if speaker is None:
            continue
        start_key = next((key for key in ("start_ms", "startMs", "start", "startTime") if key in entry), None)
        end_key = next((key for key in ("end_ms", "endMs", "end", "endTime") if key in entry), None)
        segment = dict(speaker=str(speaker), text=str(text))
        if "timestamp" in entry:
            segment["start_ms"], segment["end_ms"] = parse_json_timestamp_range(entry["timestamp"])
        elif start_key is not None or end_key is not None:
            if start_key is None or end_key is None:
                raise ValueError("Timestamped reference entries need both start and end.")
            segment["start_ms"] = milliseconds(entry[start_key], start_key)
            segment["end_ms"] = milliseconds(entry[end_key], end_key)
            if segment["end_ms"] < segment["start_ms"]:
                raise ValueError("Reference end precedes start.")
        result.append(segment)
    return result


def parse_reference(path):
    path = pathlib.Path(path)
    text = path.read_text(encoding="utf-8-sig")
    if path.suffix.casefold() == ".json":
        return parse_json_reference(json.loads(text))
    return parse_caption_reference(text)


def manual_reference(canonical):
    """Canonical rows, not their word text, define the manual annotation window."""
    result = []
    for segment in canonical.get("segments", []):
        if segment.get("attribution_source") != "manual":
            continue
        speaker = segment.get("speaker_id")
        if speaker is None:
            continue
        result.append(dict(speaker=str(speaker), text="", start_ms=segment["start_ms"],
                           end_ms=segment["end_ms"]))
    return result


def timed_pairs(words, reference, require_contained=False):
    """Associate each replayed word with the reference row of greatest overlap."""
    pairs, used_rows = [], set()
    for word_index, word in enumerate(words):
        start, end = word.get("startMs"), word.get("endMs")
        if start is None or end is None:
            continue
        ranked = []
        for row_index, row in enumerate(reference):
            if require_contained and not (row["start_ms"] <= start and end <= row["end_ms"]):
                continue
            overlap = max(0, min(end, row["end_ms"]) - max(start, row["start_ms"]))
            if overlap:
                ranked.append((overlap, -row_index, row_index))
        if ranked:
            row_index = max(ranked)[2]
            pairs.append((word_index, row_index, reference[row_index]["speaker"]))
            used_rows.add(row_index)
    return pairs, used_rows


def text_pairs(words, reference):
    hypothesis = [(token, word_index) for word_index, word in enumerate(words)
                  for token in lexical(word.get("text", ""))]
    target = [(token, row_index, row["speaker"]) for row_index, row in enumerate(reference)
              for token in lexical(row["text"])]
    matcher = difflib.SequenceMatcher(None, [item[0] for item in hypothesis],
                                      [item[0] for item in target], autojunk=False)
    pairs, used_rows = [], set()
    for hyp_start, ref_start, length in matcher.get_matching_blocks():
        for offset in range(length):
            _, word_index = hypothesis[hyp_start + offset]
            _, row_index, speaker = target[ref_start + offset]
            pairs.append((word_index, row_index, speaker))
            used_rows.add(row_index)
    return pairs, used_rows, len(hypothesis), len(target)


def anonymous_ids(values, prefix):
    result = {}
    for value in values:
        if value not in result:
            result[value] = f"{prefix}_{len(result) + 1}"
    return result


def optimal_mapping(counts, hypothesis_ids, reference_ids):
    """Maximum-weight one-to-one mapping with a deterministic unmatched option."""
    scores = [[counts[(hypothesis, reference)] for reference in reference_ids]
              for hypothesis in hypothesis_ids]

    @functools.lru_cache(maxsize=None)
    def solve(index, used):
        if index == len(hypothesis_ids):
            return 0, ()
        best_score, best_tail = solve(index + 1, used)
        best = (best_score, (None,) + best_tail)
        for ref_index in range(len(reference_ids)):
            if used & (1 << ref_index):
                continue
            tail_score, tail = solve(index + 1, used | (1 << ref_index))
            candidate = (scores[index][ref_index] + tail_score, (ref_index,) + tail)
            # Strictly prefer the earlier deterministic unmatched/ID choice on ties.
            if candidate[0] > best[0]:
                best = candidate
        return best

    _, choices = solve(0, 0)
    return {hypothesis_ids[index]: reference_ids[choice]
            for index, choice in enumerate(choices) if choice is not None}


def engine_revision(diarization):
    for container in (diarization.get("engine"), diarization.get("benchmark"), diarization):
        if isinstance(container, dict):
            for key in ("revision", "engineRevision", "engine_revision", "runtimeRevision", "runtime_revision"):
                if container.get(key):
                    return str(container[key])
    return None


def paragraph_metrics(segments):
    counts = []
    for segment in segments:
        if "word_count" in segment:
            counts.append(segment["word_count"])
        elif segment.get("words") is not None:
            counts.append(len(segment["words"]))
        else:
            counts.append(len(segment.get("text", "").split()))
    return dict(paragraph_count=len(counts), single_word_paragraph_count=counts.count(1))


def score_replay(replay, reference, source, metadata):
    words, labels = replay["words"], replay["labels"]
    timed = bool(reference) and all("start_ms" in row and "end_ms" in row for row in reference)
    if timed:
        pairs, used_rows = timed_pairs(words, reference, require_contained=source == "manual_canonical_segments")
        alignment = dict(method="time", scored_words=len(pairs), replay_words=len(words),
                         replay_word_coverage_pct=round(100 * len(pairs) / len(words), 3) if words else None,
                         reference_segments=len(reference), matched_reference_segments=len(used_rows),
                         reference_segment_coverage_pct=round(100 * len(used_rows) / len(reference), 3) if reference else None)
    else:
        pairs, used_rows, hypothesis_tokens, reference_tokens = text_pairs(words, reference)
        alignment = dict(method="text_sequence_matcher", matched_lexical_tokens=len(pairs),
                         replay_lexical_tokens=hypothesis_tokens, reference_lexical_tokens=reference_tokens,
                         replay_lexical_coverage_pct=round(100 * len(pairs) / hypothesis_tokens, 3) if hypothesis_tokens else None,
                         reference_lexical_coverage_pct=round(100 * len(pairs) / reference_tokens, 3) if reference_tokens else None,
                         reference_segments=len(reference), matched_reference_segments=len(used_rows),
                         reference_segment_coverage_pct=round(100 * len(used_rows) / len(reference), 3) if reference else None)
    raw_hypotheses = [labels[word_index] for word_index, _, _ in pairs if labels[word_index] is not None]
    raw_references = [speaker for _, _, speaker in pairs]
    hyp_ids = anonymous_ids(raw_hypotheses, "hypothesis")
    ref_ids = anonymous_ids(raw_references, "reference")
    counts = collections.Counter((hyp_ids[labels[word_index]], ref_ids[speaker])
                                 for word_index, _, speaker in pairs if labels[word_index] is not None)
    hypotheses, references = list(hyp_ids.values()), list(ref_ids.values())
    mapping = optimal_mapping(counts, hypotheses, references)
    correct = wrong = unknown = 0
    confusion = {hypothesis: collections.Counter() for hypothesis in hypotheses}
    for word_index, _, raw_reference in pairs:
        reference_id = ref_ids[raw_reference]
        raw_hypothesis = labels[word_index]
        if raw_hypothesis is None:
            unknown += 1
            continue
        hypothesis_id = hyp_ids[raw_hypothesis]
        confusion[hypothesis_id][reference_id] += 1
        if mapping.get(hypothesis_id) == reference_id:
            correct += 1
        else:
            wrong += 1
    total = len(pairs)
    rate = lambda count: round(100 * count / total, 3) if total else None
    return dict(schema_version=1, transcript_free=True, ground_truth=dict(source=source, **metadata),
                alignment=alignment,
                agreement=dict(scored_words=total, correct_words=correct, wrong_words=wrong,
                               unknown_words=unknown, correct_pct=rate(correct), wrong_pct=rate(wrong),
                               unknown_pct=rate(unknown), wder_pct=rate(wrong + unknown),
                               optimal_one_to_one_mapping=mapping,
                               per_speaker_confusion={hypothesis: dict(sorted(row.items()))
                                                      for hypothesis, row in sorted(confusion.items())}),
                paragraphs=paragraph_metrics(replay.get("segments", [])))


def replay_run(args):
    if args.host_replay:
        output = subprocess.check_output([str(args.host_replay), str(args.run), "--saved-words" if args.transcript == "saved" else str(args.transcript), str(args.diarization)] + ([str(args.source_energy), str(args.source_minimum_agreement)] if args.source_energy else []))
        return json.loads(output), sha256(args.host_replay)
    with tempfile.TemporaryDirectory(prefix="scribe-wder-") as temporary:
        temporary = pathlib.Path(temporary)
        output, executable = temporary / "replay.json", temporary / "host-replay"
        subprocess.run([sys.executable, str(args.replay_script), str(args.run), str(args.transcript),
                        str(args.diarization), "--output", str(output), "--keep-executable", str(executable)] + (["--source-energy", str(args.source_energy), "--source-minimum-agreement", str(args.source_minimum_agreement)] if args.source_energy else []), check=True)
        return json.loads(output.read_text()), sha256(executable)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("run", type=pathlib.Path)
    parser.add_argument("--diarization", type=pathlib.Path, help="Defaults to RUN/diarization.json")
    parser.add_argument("--transcript", default="saved", help="Worker transcript JSON, or 'saved' (default)")
    parser.add_argument("--reference", type=pathlib.Path, help="MacWhisper JSON, SRT/VTT, or Speaker: text reference")
    parser.add_argument("--host-replay", type=pathlib.Path, help="Previously compiled replay.py host executable")
    parser.add_argument("--replay-script", type=pathlib.Path, default=pathlib.Path(__file__).with_name("replay.py"))
    parser.add_argument("--source-minimum-agreement", type=float, default=0.95, help="Calibration override (production: 0.95)")
    parser.add_argument("--source-energy", type=pathlib.Path, help="Opt in using an aligned source-energy.json")
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--effective-speakers", action="store_true", help="Score presentation labels including bounded inferences; canonical labels remain the default")
    args = parser.parse_args()
    args.diarization = args.diarization or args.run / "diarization.json"
    canonical_path = args.run / "canonical-transcript.json"
    canonical = json.loads(canonical_path.read_text())
    if args.reference:
        reference, source = parse_reference(args.reference), "imported_reference"
        metadata = dict(reference_sha256=sha256(args.reference), reference_format=args.reference.suffix.casefold().lstrip(".") or "text")
    else:
        reference, source = manual_reference(canonical), "manual_canonical_segments"
        metadata = dict(canonical_sha256=sha256(canonical_path), manual_segments=len(reference))
    if not reference:
        raise ValueError("No scoreable ground-truth speaker segments were found.")
    replay, executable_sha256 = replay_run(args)
    if args.effective_speakers:
        if "effective_labels" not in replay:
            raise ValueError("This cached host lacks effective labels; rebuild it with replay.py.")
        replay["labels"] = replay["effective_labels"]
    diarization = json.loads(args.diarization.read_text())
    result = score_replay(replay, reference, source, metadata)
    result["source_minimum_agreement"] = args.source_minimum_agreement if args.source_energy else None
    result["source_energy_prior"] = replay.get("source_energy_prior")
    result["source_energy_sha256"] = sha256(args.source_energy) if args.source_energy else None
    result["attribution_view"] = "effective" if args.effective_speakers else "canonical"
    if "display_paragraphs" in replay:
        result["display_paragraphs"] = paragraph_metrics(replay["display_paragraphs"])
    if "display_asides" in replay:
        asides = replay["display_asides"]
        result["display_asides"] = dict(aside_count=len(asides),
                                        word_count=sum(aside["word_count"] for aside in asides),
                                        source_segment_count=sum(aside["source_segment_count"] for aside in asides))
    result["provenance"] = dict(run_revision=canonical.get("revision"), executable_sha256=executable_sha256,
                                engine_revision=engine_revision(diarization), diarization_sha256=sha256(args.diarization))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()

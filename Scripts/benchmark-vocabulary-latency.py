#!/usr/bin/env python3
"""Measure empty/active vocabulary in one persistent, offline dictation worker.

Use prepared 16 kHz mono speech and a synthetic vocabulary snapshot. The worker
is warmed once, then each cycle measures empty, active, active, empty vocabulary.
No transcript text is written to the report. All inference runs deny networking.
"""
import argparse
import json
from pathlib import Path
import selectors
import shutil
import subprocess
import tempfile
import time
import wave


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worker", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--models", type=Path, required=True)
    parser.add_argument("--audio", type=Path, required=True)
    parser.add_argument("--vocabulary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cycles", type=int, default=3)
    parser.add_argument("--idle-seconds", type=int, default=0,
                        help="After the cycles, keep the same worker idle, then compare again")
    parser.add_argument("--warm-vocabulary", action="store_true",
                        help="Send the snapshot with warm so the worker prepares its vocabulary booster")
    args = parser.parse_args()
    if args.cycles < 1:
        parser.error("--cycles must be positive")
    if args.idle_seconds < 0:
        parser.error("--idle-seconds must be nonnegative")
    with wave.open(str(args.audio), "rb") as audio:
        if audio.getframerate() != 16_000 or audio.getnchannels() != 1 or not 0 < audio.getnframes() <= 16_000 * 300:
            parser.error("--audio must be nonempty 16 kHz mono PCM WAV, at most five minutes")
    snapshot = json.loads(args.vocabulary.read_text())
    if not snapshot.get("terms"):
        parser.error("--vocabulary must contain terms")
    rows = []
    with tempfile.TemporaryDirectory(prefix="scribe-vocabulary-latency-") as scratch:
        directory = Path(scratch)
        audio = directory / "audio.wav"
        shutil.copyfile(args.audio, audio)
        policy = directory / "offline.sb"
        policy.write_text("(version 1)\n(allow default)\n(deny network*)\n")
        command = ["/usr/bin/sandbox-exec", "-f", str(policy),
                   str(args.worker.resolve()), "--manifest", str(args.manifest.resolve()),
                   "--models-directory", str(args.models.resolve()), "--mode", "dictation"]
        with args.output.with_suffix(".log").open("w") as log:
            process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=log, text=True, bufsize=1)

            def request(label, operation, **payload):
                started = time.monotonic()
                process.stdin.write(json.dumps({"version": 2, "kind": "request", "requestID": label,
                                               "payload": {"operation": operation, **payload}}) + "\n")
                process.stdin.flush()
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout, selectors.EVENT_READ)
                    while True:
                        if not selector.select(max(0, 180 - (time.monotonic() - started))):
                            raise TimeoutError(label)
                        line = process.stdout.readline()
                        if not line:
                            raise RuntimeError(f"Worker exited during {label}; see {log.name}")
                        response = json.loads(line)
                        if response.get("requestID") == label and response["kind"] in ("stage_result", "error"):
                            break
                elapsed = time.monotonic() - started
                result = response["payload"]
                if response["kind"] == "error":
                    raise RuntimeError(result)
                row = {"label": label, "wallSeconds": round(elapsed, 4), "status": result.get("status"),
                       "warning": result.get("vocabularyWarning"), "tokens": len(result.get("tokens", []))}
                # Worker-reported stage timings and booster readiness/source; no text.
                for key, name in (("timings", "timings"), ("vocabularyBooster", "booster")):
                    if key in result:
                        row[name] = result[key]
                if operation == "dictate":
                    if result.get("status") != "complete" or not row["tokens"] or row["warning"]:
                        raise RuntimeError(f"Invalid benchmark response: {row}")
                    record = json.loads((directory / "dictation-transcript.json").read_text())
                    row["replacements"] = len(record["vocabularyReplacements"])
                rows.append(row)
                print(json.dumps(row), flush=True)
                args.output.write_text(json.dumps({"cycles": args.cycles, "networkDenied": True,
                                                  "idleSeconds": args.idle_seconds,
                                                  "warmVocabulary": args.warm_vocabulary,
                                                  "rows": rows}, indent=2) + "\n")

            try:
                warm = {"vocabulary": snapshot} if args.warm_vocabulary else {}
                request("warm", "warm", **warm)
                for cycle in range(1, args.cycles + 1):
                    for position, active in enumerate([False, True, True, False], 1):
                        (directory / "vocabulary.json").write_text(json.dumps(
                            snapshot if active else {"revision": None, "terms": []}))
                        request(f"{cycle}.{position}-{'vocabulary' if active else 'empty'}", "dictate",
                                audioPath=str(audio), runDirectory=str(directory), vocabularyPath="vocabulary.json")
                if args.idle_seconds:
                    print(f"Keeping the same worker idle for {args.idle_seconds} seconds", flush=True)
                    time.sleep(args.idle_seconds)
                    request("after-idle-warm", "warm", **warm)
                    for position, active in enumerate([False, True, True, False], 1):
                        (directory / "vocabulary.json").write_text(json.dumps(
                            snapshot if active else {"revision": None, "terms": []}))
                        request(f"after-idle.{position}-{'vocabulary' if active else 'empty'}", "dictate",
                                audioPath=str(audio), runDirectory=str(directory), vocabularyPath="vocabulary.json")
                request("unload", "unload")
            finally:
                process.stdin.close()
                if process.poll() is None:
                    process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


if __name__ == "__main__":
    main()

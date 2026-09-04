"""Scores the timeline gate for every reconstructed fixture case.

The exit criterion for the timeline builder is the implementation plan's
section 8 timeline row: at most one 10 ms processing block of residual alignment
error at the start and the end of a calibrated fixture, and no cumulative drift
beyond that bound. `audio-metrics` measures the residual directly, so this script
runs it once per case with the leading offset the reconstruction preserved, then
reports the two alignment gates and the drift implied by the difference between
them.
"""

import json
import subprocess
import sys

BLOCK_MS = 10.0


def main(work, metrics):
    with open(f"{work}/harness.json") as handle:
        harness = json.load(handle)

    rows, failures = [], []
    for case in harness["cases"]:
        name = case["case"]
        report_path = f"{work}/{name}-metrics.json"
        subprocess.run(
            [
                metrics,
                "--fixture", f"Tests/Fixtures/Generated/{name}",
                # Measured on the offset-trimmed copy: the preserved lead is checked
                # exactly, as a frame count, rather than being rediscovered by a
                # correlation that would have to search up to 2.6 seconds through
                # leading silence.
                "--processed", case["aligned"],
                "--output", report_path,
                "--quiet",
            ],
            check=True,
        )
        with open(report_path) as handle:
            report = json.load(handle)

        offset_exact = case["microphoneLeadingSilenceFrames"] == case["expectedLeadingSilenceFrames"]
        alignment = report["alignment"]
        # A silent fixture has nothing to correlate, so its windows come back null.
        # That is "not measurable here", not a pass and not a failure; the duration
        # check below is what still holds it to the gate.
        start = (alignment["start"]["timeline"] or {}).get("residualErrorMilliseconds")
        end = (alignment["end"]["timeline"] or {}).get("residualErrorMilliseconds")
        # Cumulative drift is what the timeline gate is really about: a residual that
        # grows from the start window to the end window, or a duration that no longer
        # matches the source, is drift the reconstruction failed to account for.
        cumulative = None if start is None or end is None else end - start
        duration = report["duration"]["deltaMillisecondsVersusMicrophone"]

        passed = offset_exact and abs(duration) <= BLOCK_MS
        for value in (start, end, cumulative):
            if value is not None and abs(value) > BLOCK_MS:
                passed = False
        if not passed:
            failures.append(name)
        rows.append((name, case["microphoneLeadingSilenceFrames"], offset_exact, start, end,
                     cumulative, duration, case["measuredDriftPPM"], case["driftCorrected"], passed))

    def cell(value, width=8):
        return "n/a".rjust(width) if value is None else f"{value:{width}.3f}"

    width = max(len(row[0]) for row in rows)
    print()
    print(f"{'case'.ljust(width)}  lead frames  lead  start ms    end ms  cumulative  duration ms   drift ppm  gate")
    for name, lead, offset_exact, start, end, cumulative, duration, ppm, corrected, passed in rows:
        drift = f"{ppm:9.3f}{'*' if corrected else ' '}"
        print(
            f"{name.ljust(width)}  {lead:11d}  {'ok' if offset_exact else 'BAD':>4}"
            f"  {cell(start)}  {cell(end)}  {cell(cumulative, 10)}  {cell(duration, 11)}  {drift}"
            f"  {'pass' if passed else 'FAIL'}"
        )
    print("\n* drift was measured and corrected on the processing copy.")
    print(f"gate: |residual| <= {BLOCK_MS} ms at start and end, no cumulative growth beyond that,")
    print(f"      duration within {BLOCK_MS} ms of the source track, and the preserved microphone")
    print("      lead matching the session's own offset exactly. n/a = a silent fixture has no")
    print("      signal to correlate; its duration still holds it to the gate.")

    if failures:
        print(f"\nFAILED: {', '.join(failures)}")
        return 1
    print(f"\nAll {len(rows)} fixture cases meet the timeline gate.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))

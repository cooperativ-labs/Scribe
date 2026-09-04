"""Scores the implementation-plan section 8 echo and local-speech gates for the
echo canceller and mixdown.

Two gates, applied to the fixture class each one names:

  Echo reduction  - "at least 20 dB median echo-energy reduction after
                    convergence in controlled far-end-only fixtures". Applied to
                    every synthetic case whose echo track demonstrably reaches
                    the microphone, measured by `audio-metrics` on the cleaned
                    microphone, before mix gain.

  Local speech    - "less than 1 dB level change in near-end-only fixtures
                    before mix gain". Applied to the synthetic cases with no
                    far-end in the microphone, which is what "near-end-only"
                    names. Cases that carry both echo and local speech are
                    double-talk, which section 8 covers with listening checks
                    rather than a numeric bound; their level change is printed as
                    an observation and is not gated here.

Every published `final.flac` is additionally held to the true-peak ceiling and
the clipping bound, and to matching the reconstructed timeline's duration.

The real-room fixtures have no ground truth, so they are measured directly:
source microphone against cleaned microphone, after a convergence window.
"""

import json
import struct
import subprocess
import sys

CONVERGENCE_SECONDS = 2.0
SAMPLE_RATE = 48000


def read_wav_mono(path):
    with open(path, "rb") as handle:
        data = handle.read()
    index, channels, bits, payload = 12, 1, 16, b""
    while index + 8 <= len(data):
        chunk = data[index:index + 4]
        size = struct.unpack("<I", data[index + 4:index + 8])[0]
        if chunk == b"fmt ":
            channels = struct.unpack("<H", data[index + 10:index + 12])[0]
            bits = struct.unpack("<H", data[index + 22:index + 24])[0]
        elif chunk == b"data":
            payload = data[index + 8:index + 8 + size]
            break
        index += 8 + size + (size & 1)
    if bits == 16:
        frames = len(payload) // (2 * channels)
        samples = struct.unpack("<%dh" % (frames * channels), payload[:frames * channels * 2])
        return [samples[i * channels] / 32768.0 for i in range(frames)]
    if bits == 32:
        frames = len(payload) // (4 * channels)
        samples = struct.unpack("<%df" % (frames * channels), payload[:frames * channels * 4])
        return [samples[i * channels] for i in range(frames)]
    raise SystemExit("unsupported WAV bit depth %d in %s" % (bits, path))


def energy_db(samples):
    if not samples:
        return None
    total = sum(value * value for value in samples)
    return 10 * __import__("math").log10(total / len(samples)) if total > 0 else None


def attenuation_profile(source, cleaned, skip):
    """Per-10 ms-block attenuation over blocks where the source microphone is active.

    "No lost words" is a listening judgement, but a canceller that eats speech
    leaves a measurable trace: long consecutive runs of heavily attenuated active
    blocks. A canceller that only removes echo attenuates in scattered blocks
    where the echo happens to dominate. This does not replace the listening
    check; it says whether one is likely to find anything.
    """
    import math
    block = SAMPLE_RATE // 100
    peak = max((abs(value) for value in source[skip:]), default=0.0)
    if peak <= 0:
        return None
    floor = peak * 0.05  # 26 dB below the take's peak: silence between phrases
    deep, active, run, longest = 0, 0, 0, 0
    for start in range(skip, min(len(source), len(cleaned)) - block, block):
        before = sum(v * v for v in source[start:start + block]) / block
        after = sum(v * v for v in cleaned[start:start + block]) / block
        if math.sqrt(before) < floor:
            run = 0
            continue
        active += 1
        change = 10 * math.log10(after / before) if after > 0 and before > 0 else -99.0
        if change <= -12:
            deep += 1
            run += 1
            longest = max(longest, run)
        else:
            run = 0
    return {"activeBlocks": active, "deeplyAttenuated": deep, "longestRunMs": longest * 10}


def reference_correlation(reference, signal, shift, skip):
    """Normalized correlation between a track and the system reference that
    should be echoing into it.

    On a real take there is no near-end ground truth, so "did it remove the echo
    and only the echo?" cannot be answered by level alone. This answers half of
    it exactly: how much reference-correlated content is left. Paired with the
    level that remains, a large drop here with energy still present is echo
    removed and near-end kept.
    """
    import math
    cross = source_energy = reference_energy = 0.0
    for index in range(skip, min(len(signal), len(reference) - shift)):
        if index + shift < 0:
            continue
        a, b = signal[index], reference[index + shift]
        cross += a * b
        source_energy += a * a
        reference_energy += b * b
    if source_energy <= 0 or reference_energy <= 0:
        return None
    return cross / math.sqrt(source_energy * reference_energy)


def gate(report, name):
    for entry in report["gates"]:
        if entry == name:
            return report["gates"][entry]
    return None


def cell(value, width=9, digits=3):
    if value is None:
        return "n/a".rjust(width)
    return ("%%%d.%df" % (width, digits)) % value


def score_synthetic(work, metrics, fixtures):
    with open("%s/mixdown.json" % work) as handle:
        cases = json.load(handle)["cases"]

    rows, failures, reductions = [], [], []
    for case in cases:
        name = case["case"]
        clean_report = "%s/%s-clean-metrics.json" % (work, name)
        subprocess.run([
            metrics, "--fixture", "%s/%s" % (fixtures, name),
            "--processed", case["cleanedMicrophone"],
            "--output", clean_report, "--quiet",
        ], check=True)
        with open(clean_report) as handle:
            clean = json.load(handle)

        mix = None
        if not case["failure"]:
            mix_report = "%s/%s-mix-metrics.json" % (work, name)
            subprocess.run([
                metrics, "--fixture", "%s/%s" % (fixtures, name),
                "--processed", case["finalMix"],
                "--output", mix_report, "--quiet",
            ], check=True)
            with open(mix_report) as handle:
                mix = json.load(handle)

        far_end = clean["farEnd"]["reachesMicrophone"]
        echo = clean["gates"].get("echoEnergyReductionDb", {})
        near = clean["gates"].get("nearEndLevelChangeDb", {})
        echo_db = echo.get("measured") if echo.get("applicable") else None
        near_db = near.get("measured") if near.get("applicable") else None
        peak = mix["gates"]["truePeakDbTP"]["measured"] if mix else None
        clipped = mix["gates"]["clippedSamples"]["measured"] if mix else None
        duration = mix["duration"]["deltaMillisecondsVersusExpected"] if mix else None

        passed, notes = True, []
        if far_end and echo_db is not None:
            reductions.append(echo_db)
            if echo_db < 20:
                passed, _ = False, notes.append("echo<20dB")
        if not far_end and near_db is not None:
            if abs(near_db) >= 1:
                passed, _ = False, notes.append("nearEnd>=1dB")
        if peak is not None and peak > -1 + 1e-6:
            passed, _ = False, notes.append("truePeak>-1dBTP")
        if clipped:
            passed, _ = False, notes.append("clipped")
        if duration is not None and abs(duration) > 10:
            passed, _ = False, notes.append("duration")
        if case["failure"]:
            passed = False
            notes.append("job failed")
        if not passed:
            failures.append(name)
        rows.append((name, case["decision"], far_end, echo_db, near_db, peak, clipped, duration, passed, notes))

    width = max(len(row[0]) for row in rows)
    print()
    print("Synthetic suite — cleaned microphone (before mix gain) and published mix")
    print(f"{'case'.ljust(width)}  {'decision'.ljust(26)} farEnd  echoRedDb  nearEndDb   peakDbTP  clip  durMs  gate")
    for name, decision, far_end, echo_db, near_db, peak, clipped, duration, passed, notes in rows:
        print(
            f"{name.ljust(width)}  {decision.ljust(26)} {'yes' if far_end else ' no':>6}"
            f"  {cell(echo_db)}  {cell(near_db, 9, 4)}  {cell(peak, 9)}"
            f"  {'-' if clipped is None else clipped:>4}  {cell(duration, 5, 1)}"
            f"  {'pass' if passed else 'FAIL ' + ','.join(notes)}"
        )
    if reductions:
        ordered = sorted(reductions)
        median = ordered[len(ordered) // 2] if len(ordered) % 2 else (ordered[len(ordered) // 2 - 1] + ordered[len(ordered) // 2]) / 2
        print("\nmedian echo-energy reduction across far-end-reaching cases: %.2f dB (gate: >= 20 dB)" % median)
        if median < 20:
            failures.append("median echo reduction")
    return failures


def score_real(work):
    try:
        with open("%s/real.json" % work) as handle:
            cases = json.load(handle)["cases"]
    except FileNotFoundError:
        print("\n(no real-room run in this work directory)")
        return []

    print("\nReal-room fixtures — source microphone against cleaned microphone, after %.0f s" % CONVERGENCE_SECONDS)
    print(f"{'case'.ljust(24)}  {'decision'.ljust(26)}  delayMs   micDbFS  cleanDbFS   changeDb")
    failures = []
    skip = int(CONVERGENCE_SECONDS * SAMPLE_RATE)
    for case in cases:
        if case["failure"]:
            print(f"{case['case'].ljust(24)}  {'failed'.ljust(26)}  {case['failure'][:60]}")
            failures.append(case["case"])
            continue
        lead = case.get("microphoneLeadFrames", 0)
        source = read_wav_mono("%s/microphone.wav" % case["fixtureDirectory"])
        cleaned = read_wav_mono(case["cleanedMicrophone"])[lead:]
        count = min(len(source), len(cleaned))
        before = energy_db(source[skip:count])
        after = energy_db(cleaned[skip:count])
        change = None if before is None or after is None else after - before
        delay = case["delaySamples"]
        print(
            f"{case['case'].ljust(24)}  {case['decision'].ljust(26)}  "
            f"{'n/a' if delay is None else '%7.2f' % (delay / 48.0)}  {cell(before, 8, 2)}  {cell(after, 9, 2)}  {cell(change, 9, 2)}"
        )
        if case["delaySamples"] is not None:
            reference = read_wav_mono("%s/system.wav" % case["fixtureDirectory"])
            # Microphone sample i lines up with reference sample i + lead - delay.
            shift = lead - case["delaySamples"]
            before_corr = reference_correlation(reference, source, shift, skip)
            after_corr = reference_correlation(reference, cleaned, shift, skip)
            print("    reference correlation: %+.4f before, %+.4f after" % (before_corr or 0, after_corr or 0))
        if "double-talk" in case["case"]:
            profile = attenuation_profile(source, cleaned, skip)
            if profile:
                print(
                    "    double-talk speech survival: %d of %d active 10 ms blocks attenuated by more than 12 dB; "
                    "longest consecutive run %d ms"
                    % (profile["deeplyAttenuated"], profile["activeBlocks"], profile["longestRunMs"])
                )
                print("    listening check artefacts: %s  and  %s" % (case["cleanedMicrophone"], case["finalMix"]))
                print("    the listening check itself is a human step and is not performed here.")
        # The only numeric bound section 8 places on a real fixture is that a
        # near-end-only take must not lose level. The far-end-only and double-talk
        # takes are listening checks; their numbers are recorded, not gated.
        if "near-end-only" in case["case"] and change is not None and abs(change) >= 1:
            failures.append(case["case"])
    return failures


def main(work, metrics, fixtures="Tests/Fixtures/Generated"):
    failures = score_synthetic(work, metrics, fixtures) + score_real(work)
    print()
    print("gates: echo-energy reduction >= 20 dB after convergence on far-end-reaching cases;")
    print("       local-speech level change < 1 dB on near-end-only cases; every published mix")
    print("       at or under -1 dBTP with no clipped samples and its timeline's duration.")
    print("       Double-talk cases carry both signals; section 8 covers those with listening")
    print("       checks, so their near-end change is reported above but not gated.")
    if failures:
        print("\nFAILED: %s" % ", ".join(sorted(set(failures))))
        return 1
    print("\nAll cases meet the echo and local-speech gates.")
    return 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))

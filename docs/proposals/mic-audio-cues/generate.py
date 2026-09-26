#!/usr/bin/env python3
"""Render Air Ding v2 (warm body) using only the Python standard library."""

from array import array
import math
from pathlib import Path
import random
import sys
import wave


RATE = 48_000
DURATION = 0.72
OUTPUT = Path(__file__).resolve().parents[3] / "Scribe/App/Resources"


def render():
    rng = random.Random(1076)
    dry = []
    phase = 0.0
    filtered_noise = 0.0
    for index in range(round(RATE * DURATION)):
        t = index / RATE
        # Retain the original pitch gesture; support A5 with a warm A4 body.
        frequency = 880.0 * (1.0 - 0.028 * math.exp(-t / 0.022))
        phase += 2.0 * math.pi * frequency / RATE
        attack = 1.0 - math.exp(-((t / 0.013) ** 2))
        body = 0.95 * math.sin(0.5 * phase) * math.exp(-t / 0.195)
        warmth = 0.16 * math.sin(0.25 * phase) * math.exp(-t / 0.150)
        core = 0.58 * math.sin(phase) * math.exp(-t / 0.165)
        fifth = 0.09 * math.sin(1.5 * phase) * math.exp(-t / 0.115)
        octave = 0.035 * math.sin(2.0 * phase) * math.exp(-t / 0.085)
        bloom = 0.035 * (1.0 - math.exp(-t / 0.035))
        bloom *= math.sin(3.0 * phase) * math.exp(-t / 0.135)
        noise = rng.uniform(-1.0, 1.0)
        filtered_noise += 0.22 * (noise - filtered_noise)
        air = 0.018 * filtered_noise * math.exp(-t / 0.12)
        dry.append(attack * (body + warmth + core + fifth + octave + bloom + air))

    # Quiet, diffuse reflections make the tone feel open without a long bell ring.
    channels = []
    for delays in ((0.023, 0.047, 0.079, 0.113), (0.031, 0.059, 0.089, 0.127)):
        wet = dry.copy()
        for seconds, gain in zip(delays, (0.11, 0.075, 0.045, 0.025)):
            offset = round(seconds * RATE)
            for index in range(offset, len(wet)):
                wet[index] += gain * dry[index - offset]
        # Both boundaries are silent, including when the entire cue is reversed.
        fade = round(0.080 * RATE)
        for index in range(fade):
            wet[-fade + index] *= 0.5 * (1.0 + math.cos(math.pi * index / (fade - 1)))
        channels.append(wet)

    peak = max(abs(value) for channel in channels for value in channel)
    gain = (10 ** (-12 / 20)) / peak
    return [(round(left * gain * 32767), round(right * gain * 32767))
            for left, right in zip(*channels)]


def write_wav(name, frames):
    samples = array("h", (sample for frame in frames for sample in frame))
    if sys.byteorder != "little":
        samples.byteswap()
    with wave.open(str(OUTPUT / name), "wb") as output:
        output.setnchannels(2)
        output.setsampwidth(2)
        output.setframerate(RATE)
        output.writeframes(samples.tobytes())


if __name__ == "__main__":
    start = render()
    stop = start[::-1]
    write_wav("ScribeMicStart.wav", start)
    write_wav("ScribeMicStop.wav", stop)
    print("Rendered bundled start and stop cues (0.72 s each). Peak: -12 dBFS.")

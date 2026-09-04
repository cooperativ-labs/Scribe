# FLAC encoder feasibility

## Decision

Use the system AudioToolbox FLAC encoder through `AVAudioFile`, with a mandatory
post-finalization decode-and-compare verification pass before a file is
published. On the measured Apple-silicon host it meets the plan's file
correctness requirements: all required sample rates and layouts produced a
24-bit FLAC file, decoded to the exact integer PCM supplied to the encoder,
and retained the exact frame count through a partial final write.

This removes the present need to bundle `libFLAC` solely for encoding and its
license/build maintenance. Keep the `FLACEncoder` API independent of this
choice so `libFLAC` remains a straightforward fallback if target-OS matrix
testing finds a regression. The system API does not expose libFLAC-style
encoder verification, so the explicit decode verification is a release
requirement, not an optional test.

## Reproducible experiment

The local Swift package contains `FLACProbe`:

```sh
cd Native/FLACBridge
swift run -c release FLACProbe
```

It writes with `AVAudioFile` using `kAudioFormatFLAC`, a requested 24-bit
output depth, and non-interleaved Int32 client buffers. Its input starts as
Float32 and is converted before encoding by:

1. clamp to `[-1, 1]`;
2. multiply by `2^23`;
3. round using Swift's `.toNearestOrAwayFromZero`;
4. clamp the resulting integer to `[-2^23, 2^23 - 1]`; and
5. left-align that signed 24-bit value in the AudioToolbox Int32 container.

The fixture is 480,003 frames, written in 1,023-frame chunks. Neither number
is a typical FLAC block size, so finalization must flush a partial block. It
parses the written FLAC `STREAMINFO` block to check the stored bit depth and
total samples, decodes through `AVAudioFile`, re-applies the same quantizer,
and compares every decoded integer sample.

## Measurements

Run on 2026-09-03: Apple Silicon, macOS 27.0 (build 26A5425a), Xcode 27.0
beta / Swift 6.4, optimized (`-c release`) package build. Times include writer
finalization; they do not include decoding and verification.

| Rate | Layout | Frames written/decoded/STREAMINFO | 24-bit | Integer mismatches | Encode time | Speed |
| --- | --- | --- | --- | --- | ---: | ---: |
| 44.1 kHz | mono | 480,003 / 480,003 / 480,003 | yes | 0 | 54.855 ms | 198.4× real time |
| 44.1 kHz | stereo | 480,003 / 480,003 / 480,003 | yes | 0 | 95.962 ms | 113.4× real time |
| 48 kHz | mono | 480,003 / 480,003 / 480,003 | yes | 0 | 32.874 ms | 304.2× real time |
| 48 kHz | stereo | 480,003 / 480,003 / 480,003 | yes | 0 | 79.161 ms | 126.3× real time |
| 96 kHz | mono | 480,003 / 480,003 / 480,003 | yes | 0 | 34.220 ms | 146.1× real time |
| 96 kHz | stereo | 480,003 / 480,003 / 480,003 | yes | 0 | 69.973 ms | 71.5× real time |

The slowest observed case is still more than 35 times the plan's processing
budget of 2× real time. The stored FLAC file's format ID was `flac` in every
case; `STREAMINFO` reported 24 bits per sample and the requested sample count.
The decoded sample rate and channel count exactly matched each requested rate
and layout. This validates no padding and correct partial-block flushing. As a
separate metadata check, `afinfo` reported the 48 kHz stereo file as 480,003
valid frames, 24-bit source, and 10.000063 seconds (480,003 / 48,000), even
though its final 4,608-frame packet contains 3,837 unused remainder frames.

## Known constraint: the 4,608-frame packet floor

Found while implementing `FLACEncoder`. The AudioToolbox FLAC encoder writes in
4,608-frame packets and discards a lone partial packet: a stream shorter than
4,608 frames produces a 42-byte stub whose first four bytes are zero rather than
`fLaC`, and no decoder will open it. The behaviour is identical through
`AVAudioFile` and `ExtAudioFile`, and identical at 44.1, 48, and 96 kHz, so it
belongs to the codec rather than to the writer. At 48 kHz the floor is 96 ms.

Streams at or above that floor are unaffected, including their partial final
packet: 4,608, 4,609, 5,000, 8,191, and 480,003 frames all decode with the exact
frame count. `FLACEncoder.finish()` therefore checks the submitted frame count
before finalizing and reports `FLACEncoderError.streamTooShort`, so a stub is
never published. This does not change the recommendation — meeting exports are
minutes long — but it does mean the system encoder cannot be used to write an
arbitrarily short file, and a bundled `libFLAC` would be the answer if sub-packet
exports ever become a requirement.

## Scope and follow-up

This is a synthetic PCM encoding test, not a substitute for the planned
release matrix. Before advertising support, run the same command on the macOS
15 release builds and Intel hardware named in the implementation plan. The
production encoder should write to a temporary URL, release/finalize the
writer, validate FLAC metadata and a decode round trip, calculate the file
checksum, then atomically rename it. A failed encode or verification must
never publish the temporary file under its final name.

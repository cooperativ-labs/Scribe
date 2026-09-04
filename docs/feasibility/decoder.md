# Decoder and media-prober feasibility

## Decision

Keep Ogg/Opus in the initial import matrix. Scribe will bundle a minimal, pinned FFmpeg 7.1.1 shared-library build and use its `ffprobe` executable for content-based import probing. The reproducible builder is [`Scripts/build-ffmpeg.sh`](../../Scripts/build-ffmpeg.sh); its SHA-256-pinned upstream archive is `733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1`. The configuration contains no GPL, version-3-only, nonfree, or external codec options and enables only the demuxers/parsers/decoders needed by WAV, FLAC, MP3, M4A/AAC, AIFF, CAF, and Ogg/Opus. Distribution must include [`Native/FFmpeg/NOTICE.md`](../../Native/FFmpeg/NOTICE.md), the LGPL 2.1 text, the corresponding FFmpeg source, and replaceable shared FFmpeg dylibs.

AVFoundation remains useful for the next stage's local PCM conversion for WAV, FLAC, MP3, M4A/AAC, AIFF, and CAF. It is not the authoritative prober: it does not provide the same damaged-file diagnostics or uniform stream metadata, and Ogg/Opus remains outside the supported Apple import matrix. The `ffprobe` dependency is therefore intentional, not a filename-based fallback.

## Behaviour

`Modules/Transcription/Sources/Transcription/Import/MediaProbe.swift` launches the bundled `ffprobe` with an argument array (not a shell), parses JSON emitted from the media bytes, and returns the detected container, every audio stream's codec/channel count/sample rate, stream count, and duration. A caller receives all streams rather than an implicitly mixed track, so decoding can require an explicit choice for multitrack content.

Inputs are classified as structured `MediaProbeError` values: malformed or truncated data is `corrupt`, protected/decryption-signalled input is `encrypted`, and unrecognized containers/codecs or missing input is `unsupported`. The user-facing import layer can display those classifications per file without relying on an extension.

## Verification

Run the integration matrix on a development machine with the pinned tools:

```sh
Scripts/build-ffmpeg.sh
SCRIBE_FFPROBE="$PWD/Native/FFmpeg/prefix/bin/ffprobe" \
SCRIBE_FFMPEG="$PWD/Native/FFmpeg/prefix/bin/ffmpeg" \
swift test --package-path Modules/Transcription
```

`MediaProberTests` generates mono and stereo content in WAV, FLAC, MP3, M4A/AAC, AIFF, CAF, and Ogg/Opus, deliberately gives every output a misleading or absent suffix, checks 44.1/48 kHz metadata, exercises Unicode and spaces in paths, and checks that random bytes named `.m4a` produce a structured corrupt error. The tests use a development FFmpeg with MP3 and Opus encoders only to synthesize test inputs; the production probe uses the pinned bundled `ffprobe`.

`AudioPreparationServiceTests` uses the same matrix with the pinned bundled `ffmpeg`: it creates an immutable cache snapshot plus a playback copy and a 16 kHz mono PCM WAV, requires an explicit stream choice for multitrack media, verifies working-frame/source-time round trips to within one millisecond, and flags an anti-phase stereo downmix while preserving left/right channel-selection alternatives. The decoder build enables only the LGPL `pan` and `aresample` filters required for this conversion.

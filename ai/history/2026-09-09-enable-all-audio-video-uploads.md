# Enable all audio and video uploads (coo:983.2ms0)

Dropped `.flac` and QuickTime `.m4a` files were refused with "This file's format is not supported: The source file does not exist or is not readable." Pinned `ffprobe` could read both formats when given a real filesystem path. Finder drops often supply file-reference URLs (`/.file/id=…`) that FileManager understands and ffprobe does not; the importer treated that as an unsupported format.

## What changed

- Resolve file-reference URLs and pass an explicit `file:` input to `ffprobe`/`ffmpeg` before probing or decoding.
- Probe and enqueue the resolved URL for dropped files; hold security-scoped access across that work.
- Accept any container ffprobe can open if its audio codec is in the LGPL decoder set, including video files (MP4/MOV, MKV/WebM, AVI, MPEG-TS, FLV, ASF).
- Expand the pinned FFmpeg 7.1.1 configure line with those demuxers and audio-only decoders (`--disable-autodetect` so host libraries such as X11 are not linked).
- Drop target copy now says audio or video files.

## Tests

`SCRIBE_FFPROBE`/`SCRIBE_FFMPEG` pointed at `Native/FFmpeg/prefix`: `swift test --package-path Modules/Transcription` — 247 tests, 0 failures. New coverage for file-reference FLAC/M4A, Matroska/WebM/MP4 containers, and format-name mapping.

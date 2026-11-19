# FFmpeg notice

Scribe's transcription importer bundles FFmpeg and FFprobe 9.0.2 from the same source archive. The LGPL build enables local file I/O, audio and video demuxing, audio-only decoding, and PCM WAV output. Networking, external codec libraries, GPL components, version-3-only components, and nonfree components are disabled.

FFmpeg is licensed under the GNU Lesser General Public License, version 2.1 or later, for this configuration. Scribe loads FFmpeg as replaceable shared libraries. The signed app includes the corresponding upstream source archive, build configuration, and bundle relinking script in `Contents/Resources/ThirdPartyNotices/FFmpegSource`. The combined app notice `FFmpeg.txt` includes the upstream LGPL text. Copy `FFmpegSource` to a writable directory and run `Scripts/build-ffmpeg.sh` there to rebuild from the included archive.

The archive's detached OpenPGP signature was verified against FFmpeg's release key `FCF986EA15E6E293A5644F10B4322F04D67658D8`. `source.env` pins the version and SHA-256 used by the build and packaging scripts. The bundled library majors are libavutil 61, libavcodec 63, libavformat 63, libavfilter 12, and libswresample 7.

[Upstream release and signature](https://ffmpeg.org/download.html#releases) · [FFmpeg distribution guidance](https://ffmpeg.org/legal.html)

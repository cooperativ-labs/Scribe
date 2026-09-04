# FFmpeg notice

Scribe's transcription importer bundles a deliberately minimal build of FFmpeg and `ffprobe` produced by `Scripts/build-ffmpeg.sh`. The script pins FFmpeg 7.1.1 and its source checksum, and its configure line does not enable GPL, version-3-only, nonfree, or external codec-library options.

FFmpeg is licensed under the GNU Lesser General Public License, version 2.1 or later, for this configuration. Ship the corresponding FFmpeg source, this notice, the exact build script/configuration, and the LGPL 2.1 license text alongside every distributed binary. If the configure line changes, regenerate the notices and re-evaluate licensing before release. See https://ffmpeg.org/legal.html for FFmpeg's current distribution guidance.

The separate application source code is not represented as being licensed under the LGPL by this notice. This is a shared-library build; retain the installed FFmpeg dylibs as replaceable shared libraries and preserve their license notice when packaging the app.

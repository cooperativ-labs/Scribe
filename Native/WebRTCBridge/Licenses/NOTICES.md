# Third-party notices — WebRTC audio processing

Scribe links a pinned build of the WebRTC Audio Processing Module. This
directory holds the licence and attribution files that must ship with the
application (IMPLEMENTATION_PLAN.md section 5: "Include dependency notices and
licenses in the app bundle"). Copy the whole directory into the bundle's
resources; do not ship the library without it.

The files here are copied verbatim from the pinned upstream sources by
`Scripts/build-webrtc-apm.sh`. They are committed as well as generated so that
the notices exist in a fresh checkout, before anyone has run a build.

## webrtc-audio-processing 2.1

- Upstream: <https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing>
- Git tag `v2.1`, revision `846fe90a289f58b7c9303a635142aa2c7caa93e5`
- A standalone extraction of the audio processing code from the WebRTC project,
  synced from the upstream WebRTC M131 branch.
- Licence: BSD 3-Clause, with an additional patent grant.
- Files: `webrtc-audio-processing-COPYING.txt`,
  `webrtc-audio-processing-AUTHORS.txt`, `webrtc-LICENSE.txt`,
  `webrtc-PATENTS.txt`

The WebRTC licence and the additional patent grant in `webrtc-PATENTS.txt` both
apply to the extracted code, and both must be reproduced in the distributed
application.

## Abseil 20240722.0 (LTS)

- Upstream: <https://github.com/abseil/abseil-cpp>
- The only external dependency of the audio processing module. Its static
  archives are linked into Scribe alongside the module.
- Licence: Apache License 2.0.
- File: `abseil-cpp-LICENSE.txt`

## Build-time-only tools

meson and ninja are used to produce the static library and are not distributed
with the application, so their licences are not reproduced here. They are pinned
in `../Vendor/webrtc-apm.lock` for reproducibility.

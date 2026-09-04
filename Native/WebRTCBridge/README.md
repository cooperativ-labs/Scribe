# WebRTCBridge

Scribe's echo cancellation. This package pins one upstream release of the WebRTC
Audio Processing Module, builds it reproducibly as a static library with AEC3
enabled, and exposes a deliberately small interface to the rest of the app.

The point of the narrow interface is containment. WebRTC is a large C++ codebase
with its own reference counting, its own threading rules, and a header set that
does not belong in an app target. Everything Scribe uses is
`Sources/CWebRTCAPM/include/scribe_apm.h`: construct, configure, analyze a render
block, process a capture block, set the stream delay, reset, read metrics.

## Layout

```text
Native/WebRTCBridge/
  Package.swift                     # points the compiler and linker at Vendor/prefix
  Vendor/
    webrtc-apm.lock                 # the pin: URLs, revisions, checksums, toolchain
    cache/      build/  prefix/  toolchain/    # generated, not committed
  Licenses/                         # notices that must ship in the app bundle
  Scripts/
    build-webrtc-apm.sh             # fetch, verify, build, install, record
    run-tests.sh                    # tests, tests under ASan, leak check
  Sources/
    CWebRTCAPM/                     # the Objective-C++ shim and its C header
    WebRTCBridge/                   # the Swift face: EchoCanceller, PlanarAudioBlock
  Tests/WebRTCBridgeTests/
```

Only `Vendor/webrtc-apm.lock` and the sources are committed. `Vendor/cache`,
`Vendor/build`, `Vendor/prefix`, and `Vendor/toolchain` are build products.

## Building

From the repository root:

```bash
Scripts/build-native-dependencies.sh            # every native dependency
Scripts/build-native-dependencies.sh webrtc-apm # just this one
Scripts/build-native-dependencies.sh webrtc-apm -- --force   # rebuild
Scripts/build-native-dependencies.sh webrtc-apm -- --verify-only  # checksums only
```

`swift build` in this directory links whatever the script installed into
`Vendor/prefix/macos-<arch>`. Without a build first, the manifest prints a
warning and the link fails; there is no vendored binary in the repository.

The build needs `python3` and network access on its first run. It does not need
Homebrew, Xcode command-line packages beyond the toolchain, or `depot_tools`:
meson and ninja are installed at pinned versions into a private virtualenv under
`Vendor/toolchain`, and every downloaded file is checksummed before use. Set
`MESON` and `NINJA` to use an existing toolchain instead.

## What is pinned

| Item | Value |
| --- | --- |
| Project | `webrtc-audio-processing` (freedesktop.org / PulseAudio maintainers) |
| Release | 2.1, 2025-01-22 |
| Git tag | `v2.1` |
| Git revision | `846fe90a289f58b7c9303a635142aa2c7caa93e5` |
| Upstream WebRTC branch | M131 |
| Source | `https://freedesktop.org/software/pulseaudio/webrtc-audio-processing/webrtc-audio-processing-2.1.tar.xz` |
| Source SHA-256 | `ae9302824b2038d394f10213cab05312c564a038434269f11dbf68f511f9f9fe` |
| Abseil | 20240722.0, SHA-256 `f50e5ac311a81382da7fa75b97310e4b9006474f9560ac46f54a9967f07d4ae3` |
| Abseil meson patch | wrapdb `abseil-cpp_20240722.0-3`, SHA-256 `12dd8df1488a314c53e3751abd2750cf233b830651d168b6a9f15e7d0cf71f7b` |
| Build toolchain | meson 1.7.2, ninja 1.11.1.4 |
| Deployment target | macOS 15.0 |

The release tarball published on freedesktop.org is used rather than a GitLab
auto-generated archive, because auto-generated archives are regenerated on the
server and their bytes are not stable enough to pin a checksum against.

`webrtc-audio-processing` is used rather than the WebRTC tree itself because the
full tree requires `depot_tools`, `gn`, and a Chromium checkout, none of which
fit a pinned, offline-capable, checksum-verified build. The extraction tracks
upstream's API as-is, so `api/audio/audio_processing.h` here is the same
interface the WebRTC documentation describes.

A mismatched checksum aborts the build. That is deliberate: a silently
substituted DSP library would still produce audio, just wrong audio, in a
recording the user believes is private and local.

After a build, `Vendor/prefix/macos-arm64/build-info.json` records every input
revision and checksum, the toolchain versions, the target, and the SHA-256 and
architecture of the archive that was produced.

### Reproducibility

Two clean builds of this tree produce a byte-identical archive. That was checked
by building twice from scratch, and again from a copy of the package at a
different filesystem path:

```text
libwebrtc-audio-processing-2.a  sha256 ef33c3b8605965d7f5721e79becb341805ea0c5be3bf98810dfcaec21bef3a4e
```

`ZERO_AR_DATE=1` in the build script is what makes this true; without it Apple's
archiver stamps every member with the current time and no two builds agree.

The claim has limits worth stating. It holds for the same macOS and Xcode
toolchain: a different clang emits different code, so a toolchain upgrade will
change the checksum without anything in the pin changing. Treat the checksum in
`build-info.json` as a record of what a given machine produced, not as a value to
assert in a test.

### Changing the pin

1. Edit `Vendor/webrtc-apm.lock`.
2. Run `Scripts/build-native-dependencies.sh webrtc-apm -- --clean`.
3. Re-run `Scripts/run-tests.sh` and re-check the section 8 audio gates: an
   upstream bump can change AEC behaviour without changing the API.

## The interface

`scribe_apm.h` is plain C, so Swift imports it directly, and it is the only WebRTC
surface the rest of the app sees.

| Concern | Entry point |
| --- | --- |
| Construct | `scribe_apm_create` / `scribe_apm_destroy` |
| Configure | `ScribeAPMConfig`, `scribe_apm_default_config` |
| Render path | `scribe_apm_analyze_render` |
| Capture path | `scribe_apm_process_capture` |
| Delay | `scribe_apm_set_stream_delay_ms` / `scribe_apm_stream_delay_ms` |
| Reset | `scribe_apm_reset` |
| Metrics | `scribe_apm_metrics` |
| Provenance | `scribe_apm_upstream_revision` |

Swift code uses `EchoCanceller` and `PlanarAudioBlock` rather than the C symbols:

```swift
let canceller = try EchoCanceller()            // stereo render, mono capture, 48 kHz
try canceller.setStreamDelay(milliseconds: 30) // from the timeline, never from a clock
try canceller.analyzeRenderBlock(renderBlock)  // 480 frames x 2 channels
try canceller.processCaptureBlock(captureBlock, into: &cleanedBlock)
let metrics = canceller.metrics()
```

Defaults follow IMPLEMENTATION_PLAN.md section 5: 48 kHz, stereo render input,
mono capture, AEC3 on, and automatic gain control and noise suppression off, so
that a measured change in the capture signal is attributable to AEC3 alone.

Two rules the interface cannot enforce, and callers must honour:

- **One block is 10 ms.** 480 frames per channel at 48 kHz. Anything else is
  rejected rather than padded.
- **The stream delay is acoustic, not wall-clock.** It is the delay between a
  render block being analyzed and the capture block containing its echo. In the
  offline pipeline it comes from the reconstructed timeline. It is never the
  duration of a processing call, which has nothing to do with the echo path.

An instance is not thread-safe. Render and capture calls must be serialized;
section 2 puts DSP on one serial queue.

`reset()` drops the adapted filter but keeps the declared stream delay, matching
upstream. If the discontinuity also moved the delay, declare the new value.

## Intel (x86_64) path — documented, not built

Section 1 of the plan is Apple Silicon first, with Intel validated separately
before it is advertised. Nothing here has been built or run on x86_64.

The plumbing exists. `build-webrtc-apm.sh --arch x86_64` selects the
`macos-x86_64` prefix, writes a meson cross file when the host is arm64, and
passes `-arch x86_64` through the compiler and linker flags; `Package.swift`
picks the matching prefix when the manifest itself is compiled for x86_64. The
architecture is gated behind `SCRIBE_ALLOW_UNVALIDATED_ARCH=1` so that nobody
ships an Intel slice believing it was tested:

```bash
SCRIBE_ALLOW_UNVALIDATED_ARCH=1 \
  Scripts/build-native-dependencies.sh webrtc-apm -- --arch x86_64
```

What still has to be settled before Intel can be supported:

- **AVX2 objects.** On x86, upstream compiles the AVX2 kernels into a separate
  `webrtc_audio_processing_privatearch` static library and links the module
  against it. That target is not installed. On arm64 the equivalent internal
  static libraries are merged into the installed archive, so this probably
  works, but "probably" is not a link that has been performed. Confirm the AVX2
  symbols are present in the installed archive, and extend the archive-collection
  step in `build-webrtc-apm.sh` if they are not.
- **Baseline SSE.** Upstream's `inline-sse` option defaults on, assuming SSE/SSE2.
  That holds for every Intel Mac, so no change is expected.
- **A universal binary.** Distribution needs one library per slice joined with
  `lipo -create`, and a `Package.swift` that points at the universal prefix.
  Neither exists; today the manifest picks one slice.
- **Validation on Intel hardware.** The section 8 gates — 20 dB median echo
  reduction, under 1 dB near-end level change, capture under 10% of a core — are
  hardware-dependent and have not been measured on Intel.

## Licences

`Licenses/` holds the notices that must ship in the app bundle: the
webrtc-audio-processing licence and authors, the WebRTC licence and its
additional patent grant, and the Abseil licence. `Licenses/NOTICES.md` explains
what each covers. The build script refreshes these files from the pinned sources;
they are also committed so a fresh checkout has them before any build has run.

## Verifying

```bash
Native/WebRTCBridge/Scripts/run-tests.sh
```

This runs the Swift tests, runs them again under Address Sanitizer, and then
runs a leak check. The leak check is separate because Address Sanitizer on
macOS/arm64 reports memory errors but refuses leak detection outright
(`detect_leaks is not supported on this platform`), so leaks are found with the
system `leaks` tool against the same test bundle.

The tests cover the exit criteria for this work: construct the module, push
480-sample 48 kHz blocks through the render and capture paths, and read metrics.
One test builds a far-end-only fixture — broadband noise played back, heard by
the microphone as a 30 ms delayed copy at half amplitude — and measures the
energy reduction after convergence. It currently measures about 28 dB.

That number is a smoke test, not the section 8 release gate. The gate is 20 dB
*median* reduction across a fixture suite that includes double-talk, delay
changes, drift, clipping, and asymmetric stereo, measured against real
recordings as well as synthetic ones. A single clean synthetic case says the
canceller is wired up correctly; it says nothing about how it behaves in a room.

#!/usr/bin/env bash
#
# Run the bridge's checks the way the objective's exit criteria describe them:
# the Swift tests, the same tests under Address Sanitizer, and a leak check.
#
# The leak check is a separate step on purpose. Address Sanitizer on macOS/arm64
# reports memory errors but refuses to do leak detection —
# "detect_leaks is not supported on this platform" — so leaks are found with the
# system `leaks` tool against the same test bundle instead.
#
# Usage: Native/WebRTCBridge/Scripts/run-tests.sh [--skip-asan] [--skip-leaks]

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

log() { printf '\033[1m[bridge-tests]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[bridge-tests] error:\033[0m %s\n' "$*" >&2; exit 1; }

RUN_ASAN=1
RUN_LEAKS=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-asan)  RUN_ASAN=0; shift ;;
    --skip-leaks) RUN_LEAKS=0; shift ;;
    -h|--help)    sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)            die "unknown argument: $1" ;;
  esac
done

cd "${PACKAGE_DIR}"

if [[ ! -f "Vendor/prefix/macos-$(uname -m)/lib/libwebrtc-audio-processing-2.a" ]]; then
  die "the pinned module has not been built. Run Scripts/build-native-dependencies.sh first."
fi

log "swift test"
swift test

if [[ "${RUN_ASAN}" == "1" ]]; then
  log "swift test --sanitize=address"
  swift test --sanitize=address
fi

if [[ "${RUN_LEAKS}" == "1" ]]; then
  # Rebuild without the sanitizer: an ASan-instrumented bundle cannot be launched
  # by `leaks` (the interceptors load too late through xctest's dlopen).
  log "rebuilding without the sanitizer for the leak check"
  swift build --build-tests >/dev/null

  BIN_PATH="$(swift build --build-tests --show-bin-path | tail -1)"
  BUNDLE="${BIN_PATH}/WebRTCBridgeTests.xctest"
  [[ -d "${BUNDLE}" ]] || die "could not find the test bundle at ${BUNDLE}"

  log "leaks --atExit on ${BUNDLE}"
  OUTPUT="$(MallocStackLogging=1 leaks --atExit -- "$(xcrun -f xctest)" "${BUNDLE}" 2>&1)" || {
    printf '%s\n' "${OUTPUT}" >&2
    die "the leak check failed"
  }

  printf '%s\n' "${OUTPUT}" | grep -E 'Test run with|leaks for' || true
  if ! printf '%s\n' "${OUTPUT}" | grep -q '0 leaks for 0 total leaked bytes'; then
    printf '%s\n' "${OUTPUT}" >&2
    die "leaks reported leaked memory"
  fi
  # A bundle that ran no tests would also leak nothing, so confirm it ran them.
  printf '%s\n' "${OUTPUT}" | grep -q 'Test run with .* passed' \
    || die "the leak check ran but the tests did not pass inside it"
fi

log "all checks passed"

#!/usr/bin/env bash
#
# Build the pinned WebRTC and FFmpeg components Scribe bundles.
#
# Each component has its own build script that pins its upstream revision and
# checksums. The system AudioToolbox FLAC encoder needs no separate build.
#
# Usage:
#   Scripts/build-native-dependencies.sh                 # build both components
#   Scripts/build-native-dependencies.sh --list          # show components and status
#   Scripts/build-native-dependencies.sh webrtc-apm      # build one component
#   Scripts/build-native-dependencies.sh webrtc-apm -- --clean --force
#
# Anything after `--` is passed through to each selected component's script.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

log()  { printf '\033[1m[native]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[native] error:\033[0m %s\n' "$*" >&2; exit 1; }

COMPONENT_NAMES=(
  "webrtc-apm"
  "ffmpeg"
)
COMPONENT_SCRIPTS=(
  "Native/WebRTCBridge/Scripts/build-webrtc-apm.sh"
  "Scripts/build-ffmpeg.sh"
)

script_for() {
  local wanted="$1" index=0
  for name in "${COMPONENT_NAMES[@]}"; do
    if [[ "${name}" == "${wanted}" ]]; then
      printf '%s' "${COMPONENT_SCRIPTS[${index}]}"
      return 0
    fi
    index=$((index + 1))
  done
  return 1
}

list_components() {
  local index=0
  printf 'Components:\n'
  for name in "${COMPONENT_NAMES[@]}"; do
    local relative="${COMPONENT_SCRIPTS[${index}]}"
    local state="missing"
    [[ -x "${REPO_ROOT}/${relative}" ]] && state="available"
    printf '  %-12s %-48s %s\n' "${name}" "${relative}" "${state}"
    index=$((index + 1))
  done
}

SELECTED=()
PASSTHROUGH=()
SAW_SEPARATOR=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --)        SAW_SEPARATOR=1; shift; PASSTHROUGH=("$@"); break ;;
    --list)    list_components; exit 0 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)        die "unknown option: $1 (component options go after --)" ;;
    *)         SELECTED+=("$1"); shift ;;
  esac
done
[[ "${SAW_SEPARATOR}" == "1" ]] || PASSTHROUGH=()

if [[ ${#SELECTED[@]} -eq 0 ]]; then
  SELECTED=("${COMPONENT_NAMES[@]}")
fi

BUILT=()

for component in "${SELECTED[@]}"; do
  relative="$(script_for "${component}")" \
    || die "unknown component: ${component} (try --list)"
  builder="${REPO_ROOT}/${relative}"

  [[ -x "${builder}" ]] || die "missing builder for ${component}: ${relative}"

  log "building ${component}"
  "${builder}" ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}
  BUILT+=("${component}")
done

log "built: ${BUILT[*]:-none}"

#!/usr/bin/env bash
#
# Build every pinned native dependency Scribe links against.
#
# Scribe bundles its native audio dependencies rather than downloading them at
# runtime (IMPLEMENTATION_PLAN.md section 1: no runtime downloads, no network).
# Each dependency lives under Native/<Bridge>/ and owns a build script that pins
# its own upstream revision and checksums; this script is the one entry point
# that runs them.
#
# Usage:
#   Scripts/build-native-dependencies.sh                 # build everything available
#   Scripts/build-native-dependencies.sh --list          # show components and status
#   Scripts/build-native-dependencies.sh webrtc-apm      # build one component
#   Scripts/build-native-dependencies.sh webrtc-apm -- --clean --force
#
# Anything after `--` is passed through to each selected component's script.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

log()  { printf '\033[1m[native]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[native]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[native] error:\033[0m %s\n' "$*" >&2; exit 1; }

# component name : builder script, relative to the repository root.
# A component whose script does not exist yet is reported and skipped rather
# than failing the run, so this stays usable while the bridges land separately.
COMPONENT_NAMES=(
  "webrtc-apm"
  "flac"
  "ffmpeg"
)
COMPONENT_SCRIPTS=(
  "Native/WebRTCBridge/Scripts/build-webrtc-apm.sh"
  "Native/FLACBridge/Scripts/build-flac.sh"
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
    local state="missing (not implemented yet)"
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
SKIPPED=()

for component in "${SELECTED[@]}"; do
  relative="$(script_for "${component}")" \
    || die "unknown component: ${component} (try --list)"
  builder="${REPO_ROOT}/${relative}"

  if [[ ! -x "${builder}" ]]; then
    warn "skipping ${component}: ${relative} does not exist yet"
    SKIPPED+=("${component}")
    continue
  fi

  log "building ${component}"
  "${builder}" ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}
  BUILT+=("${component}")
done

log "built: ${BUILT[*]:-none}"
[[ ${#SKIPPED[@]} -eq 0 ]] || warn "skipped: ${SKIPPED[*]}"

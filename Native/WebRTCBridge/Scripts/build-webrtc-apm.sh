#!/usr/bin/env bash
#
# Build the pinned WebRTC Audio Processing Module (AEC3) as a static library.
#
# Everything this script needs is named in Vendor/webrtc-apm.lock. It downloads
# the pinned tarballs, refuses to continue on a checksum mismatch, builds with a
# private pinned meson/ninja, and installs headers plus static archives into
# Vendor/prefix/<platform>. Native/WebRTCBridge/Package.swift links whatever is
# in that prefix, so a successful run here is what makes `swift build` work.
#
# Usage:
#   build-webrtc-apm.sh [--arch arm64|x86_64] [--clean] [--force] [--verify-only]
#
# Environment overrides:
#   MESON, NINJA                 use an existing toolchain instead of the venv
#   SCRIBE_NATIVE_CACHE          shared download cache (default Vendor/cache)
#   SCRIBE_ALLOW_UNVALIDATED_ARCH=1
#                                permit --arch x86_64 (see README, Intel path)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
VENDOR_DIR="${BRIDGE_DIR}/Vendor"
LOCK_FILE="${VENDOR_DIR}/webrtc-apm.lock"

log()  { printf '\033[1m[webrtc-apm]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[webrtc-apm]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[webrtc-apm] error:\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "${LOCK_FILE}" ]] || die "missing lock file: ${LOCK_FILE}"
# shellcheck source=../Vendor/webrtc-apm.lock
source "${LOCK_FILE}"

ARCH="$(uname -m)"
DO_CLEAN=0
DO_FORCE=0
VERIFY_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)        ARCH="${2:?--arch needs a value}"; shift 2 ;;
    --arch=*)      ARCH="${1#*=}"; shift ;;
    --clean)       DO_CLEAN=1; shift ;;
    --force)       DO_FORCE=1; shift ;;
    --verify-only) VERIFY_ONLY=1; shift ;;
    -h|--help)     sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)             die "unknown argument: $1" ;;
  esac
done

HOST_ARCH="$(uname -m)"
case "${ARCH}" in
  arm64) ;;
  x86_64)
    # The Intel path is implemented but deliberately not exercised. See
    # Native/WebRTCBridge/README.md, "Intel (x86_64) path".
    if [[ "${SCRIBE_ALLOW_UNVALIDATED_ARCH:-0}" != "1" ]]; then
      die "x86_64 is documented but not validated. Read Native/WebRTCBridge/README.md
       and re-run with SCRIBE_ALLOW_UNVALIDATED_ARCH=1 if you intend to build it."
    fi
    ;;
  *) die "unsupported architecture: ${ARCH}" ;;
esac

PLATFORM="macos-${ARCH}"
CACHE_DIR="${SCRIBE_NATIVE_CACHE:-${VENDOR_DIR}/cache}"
WORK_DIR="${VENDOR_DIR}/build/${PLATFORM}"
SRC_DIR="${WORK_DIR}/${WEBRTC_APM_SRCDIR}"
BUILD_DIR="${WORK_DIR}/build"
PREFIX_DIR="${VENDOR_DIR}/prefix/${PLATFORM}"
TOOLCHAIN_DIR="${VENDOR_DIR}/toolchain"
LICENSE_DIR="${BRIDGE_DIR}/Licenses"
STAMP_FILE="${PREFIX_DIR}/.build-stamp"

# The stamp records every input that can change the output. If it still matches,
# the prefix is already correct and rebuilding would only burn time.
STAMP_VALUE="${WEBRTC_APM_VERSION}|${WEBRTC_APM_SHA256}|${ABSEIL_SHA256}|${ABSEIL_PATCH_SHA256}|${MESON_VERSION}|${NINJA_VERSION}|${MACOS_DEPLOYMENT_TARGET}|${ARCH}|v3"

if [[ "${DO_CLEAN}" == "1" ]]; then
  log "removing ${WORK_DIR} and ${PREFIX_DIR}"
  rm -rf "${WORK_DIR}" "${PREFIX_DIR}"
fi

# ---------------------------------------------------------------------------
# 1. Fetch and verify
# ---------------------------------------------------------------------------

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

fetch() {
  local url="$1" file="$2" want="$3" dest="${CACHE_DIR}/$2"
  if [[ -f "${dest}" ]]; then
    local have; have="$(sha256_of "${dest}")"
    if [[ "${have}" == "${want}" ]]; then
      log "cached  ${file}"
      return 0
    fi
    warn "cached ${file} has checksum ${have}, expected ${want}; re-downloading"
    rm -f "${dest}"
  fi
  log "fetching ${file}"
  curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
       --output "${dest}.partial" "${url}" \
    || die "download failed: ${url}"
  local have; have="$(sha256_of "${dest}.partial")"
  if [[ "${have}" != "${want}" ]]; then
    rm -f "${dest}.partial"
    die "checksum mismatch for ${file}
       expected ${want}
       actual   ${have}
       Refusing to build. Either the pin in webrtc-apm.lock is stale or the
       download was tampered with."
  fi
  mv "${dest}.partial" "${dest}"
}

mkdir -p "${CACHE_DIR}"
fetch "${WEBRTC_APM_URL}"  "${WEBRTC_APM_ARCHIVE}"    "${WEBRTC_APM_SHA256}"
fetch "${ABSEIL_URL}"      "${ABSEIL_ARCHIVE}"        "${ABSEIL_SHA256}"
fetch "${ABSEIL_PATCH_URL}" "${ABSEIL_PATCH_ARCHIVE}" "${ABSEIL_PATCH_SHA256}"

if [[ "${VERIFY_ONLY}" == "1" ]]; then
  log "all pinned sources verified; --verify-only, stopping here"
  exit 0
fi

if [[ "${DO_FORCE}" != "1" && -f "${STAMP_FILE}" ]] \
   && [[ "$(cat "${STAMP_FILE}")" == "${STAMP_VALUE}" ]] \
   && [[ -f "${PREFIX_DIR}/lib/lib${WEBRTC_APM_NAME}-${WEBRTC_APM_ABI_MAJOR}.a" ]]; then
  log "prefix ${PREFIX_DIR} is already up to date (use --force to rebuild)"
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Toolchain (pinned meson + ninja in a private virtualenv)
# ---------------------------------------------------------------------------

if [[ -n "${MESON:-}" && -n "${NINJA:-}" ]]; then
  log "using caller-supplied toolchain: ${MESON} / ${NINJA}"
else
  if [[ ! -x "${TOOLCHAIN_DIR}/bin/meson" || ! -x "${TOOLCHAIN_DIR}/bin/ninja" ]]; then
    log "bootstrapping meson ${MESON_VERSION} and ninja ${NINJA_VERSION}"
    command -v python3 >/dev/null || die "python3 is required to bootstrap meson"
    rm -rf "${TOOLCHAIN_DIR}"
    python3 -m venv "${TOOLCHAIN_DIR}" || die "could not create the build virtualenv"
    "${TOOLCHAIN_DIR}/bin/pip" install --quiet --disable-pip-version-check \
        "meson==${MESON_VERSION}" "ninja==${NINJA_VERSION}" \
      || die "could not install the pinned meson/ninja"
  fi
  MESON="${TOOLCHAIN_DIR}/bin/meson"
  NINJA="${TOOLCHAIN_DIR}/bin/ninja"
fi
# meson locates the backend through the NINJA variable and PATH, not through
# an argument, so both have to point at the pinned binary.
export NINJA
PATH="$(dirname -- "${NINJA}"):${PATH}"
export PATH

log "meson $("${MESON}" --version), ninja $("${NINJA}" --version)"

# ---------------------------------------------------------------------------
# 3. Unpack, seeding the meson wrap cache so the build does not fetch abseil
# ---------------------------------------------------------------------------

rm -rf "${SRC_DIR}" "${BUILD_DIR}"
mkdir -p "${WORK_DIR}"
log "unpacking ${WEBRTC_APM_ARCHIVE}"
tar -xf "${CACHE_DIR}/${WEBRTC_APM_ARCHIVE}" -C "${WORK_DIR}"
[[ -d "${SRC_DIR}" ]] || die "unexpected tarball layout, ${SRC_DIR} not found"

mkdir -p "${SRC_DIR}/subprojects/packagecache"
cp "${CACHE_DIR}/${ABSEIL_ARCHIVE}"       "${SRC_DIR}/subprojects/packagecache/"
cp "${CACHE_DIR}/${ABSEIL_PATCH_ARCHIVE}" "${SRC_DIR}/subprojects/packagecache/"

# ---------------------------------------------------------------------------
# 4. Configure and build
# ---------------------------------------------------------------------------

export MACOSX_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET}"

# Apple's archiver stamps each member with the current time, which alone makes
# two identical builds produce different bytes. Zeroing it lets the checksum in
# build-info.json actually mean something: the same inputs give the same archive.
export ZERO_AR_DATE=1
export SOURCE_DATE_EPOCH=0

ARCH_FLAGS=("-arch" "${ARCH}" "-mmacosx-version-min=${MACOS_DEPLOYMENT_TARGET}")
MESON_ARGS=(
  setup "${BUILD_DIR}" "${SRC_DIR}"
  --prefix "${PREFIX_DIR}"
  --libdir lib
  --includedir include
  --buildtype release
  --default-library static
  --wrap-mode nodownload
  -Db_ndebug=true
  -Db_staticpic=true
  -Dcpp_std=c++17
  "-Dc_args=${ARCH_FLAGS[*]}"
  "-Dcpp_args=${ARCH_FLAGS[*]}"
  "-Dc_link_args=${ARCH_FLAGS[*]}"
  "-Dcpp_link_args=${ARCH_FLAGS[*]}"
)

if [[ "${ARCH}" != "${HOST_ARCH}" ]]; then
  # Cross-compiling within macOS: same OS and toolchain, different slice.
  CROSS_FILE="${WORK_DIR}/cross-${ARCH}.ini"
  cat > "${CROSS_FILE}" <<CROSS_EOF
[binaries]
c = ['clang', '-arch', '${ARCH}']
cpp = ['clang++', '-arch', '${ARCH}']
ar = 'ar'
strip = 'strip'

[host_machine]
system = 'darwin'
cpu_family = '$([[ "${ARCH}" == "x86_64" ]] && echo x86_64 || echo aarch64)'
cpu = '${ARCH}'
endian = 'little'
CROSS_EOF
  MESON_ARGS+=(--cross-file "${CROSS_FILE}")
  log "cross-building ${ARCH} on ${HOST_ARCH} via ${CROSS_FILE}"
fi

# --wrap-mode nodownload above lets meson resolve the abseil wrap from the
# package cache seeded in step 3 while forbidding it from reaching the network
# on its own. Every byte that enters the build has been checksummed by fetch().

log "configuring (${PLATFORM}, deployment target ${MACOS_DEPLOYMENT_TARGET})"
rm -rf "${PREFIX_DIR}"
"${MESON}" "${MESON_ARGS[@]}" >"${WORK_DIR}/meson-setup.log" 2>&1 \
  || { tail -40 "${WORK_DIR}/meson-setup.log" >&2; die "meson setup failed (full log: ${WORK_DIR}/meson-setup.log)"; }

log "building"
"${MESON}" compile -C "${BUILD_DIR}" >"${WORK_DIR}/meson-build.log" 2>&1 \
  || { tail -60 "${WORK_DIR}/meson-build.log" >&2; die "build failed (full log: ${WORK_DIR}/meson-build.log)"; }

log "installing into ${PREFIX_DIR}"
"${MESON}" install -C "${BUILD_DIR}" --quiet >"${WORK_DIR}/meson-install.log" 2>&1 \
  || { tail -40 "${WORK_DIR}/meson-install.log" >&2; die "install failed (full log: ${WORK_DIR}/meson-install.log)"; }

# ---------------------------------------------------------------------------
# 5. Collect the abseil archives the module needs at link time
# ---------------------------------------------------------------------------
#
# meson installs only the module's own archive. Abseil is built as a subproject,
# so its archives stay in the build tree; a static link of the module still needs
# their symbols. Copy them next to the module so Package.swift has one -L path.

ABSL_COUNT=0
while IFS= read -r archive; do
  cp "${archive}" "${PREFIX_DIR}/lib/"
  ABSL_COUNT=$((ABSL_COUNT + 1))
done < <(find "${BUILD_DIR}/subprojects" -name 'libabsl_*.a' -type f 2>/dev/null | sort)
log "collected ${ABSL_COUNT} abseil archives"

APM_LIB="${PREFIX_DIR}/lib/lib${WEBRTC_APM_NAME}-${WEBRTC_APM_ABI_MAJOR}.a"
[[ -f "${APM_LIB}" ]] || die "expected ${APM_LIB} to exist after install"

# A static library that silently lost AEC3 would still link and still produce
# audio, just uncancelled audio. Check for the symbol instead of trusting exit
# codes.
# grep -c rather than grep -q: `set -o pipefail` turns the SIGPIPE that an
# early-exiting grep sends to nm into a pipeline failure.
AEC3_SYMBOLS="$(nm -g "${APM_LIB}" 2>/dev/null | grep -c 'EchoCanceller3' || true)"
if [[ "${AEC3_SYMBOLS}" -eq 0 ]]; then
  die "the installed archive contains no EchoCanceller3 symbols; AEC3 is missing"
fi

# ---------------------------------------------------------------------------
# 6. Licenses and notices
# ---------------------------------------------------------------------------

mkdir -p "${LICENSE_DIR}"
copy_license() {
  local src="$1" dest="$2"
  [[ -f "${src}" ]] || { warn "missing license file ${src}"; return 0; }
  cp "${src}" "${LICENSE_DIR}/${dest}"
}
copy_license "${SRC_DIR}/COPYING"        "webrtc-audio-processing-COPYING.txt"
copy_license "${SRC_DIR}/AUTHORS"        "webrtc-audio-processing-AUTHORS.txt"
copy_license "${SRC_DIR}/webrtc/LICENSE" "webrtc-LICENSE.txt"
copy_license "${SRC_DIR}/webrtc/PATENTS" "webrtc-PATENTS.txt"

ABSEIL_SRC="$(find "${SRC_DIR}/subprojects" -maxdepth 1 -type d -name 'abseil-cpp-*' | head -1)"
if [[ -n "${ABSEIL_SRC}" ]]; then
  copy_license "${ABSEIL_SRC}/LICENSE" "abseil-cpp-LICENSE.txt"
fi

# ---------------------------------------------------------------------------
# 7. Record exactly what was built
# ---------------------------------------------------------------------------

APM_LIB_SHA="$(sha256_of "${APM_LIB}")"
APM_LIB_ARCHS="$(lipo -archs "${APM_LIB}" 2>/dev/null || echo unknown)"

cat > "${PREFIX_DIR}/build-info.json" <<INFO_EOF
{
  "component": "webrtc-audio-processing",
  "version": "${WEBRTC_APM_VERSION}",
  "gitTag": "${WEBRTC_APM_GIT_TAG}",
  "gitRevision": "${WEBRTC_APM_GIT_REV}",
  "upstreamWebRTCBranch": "${WEBRTC_APM_UPSTREAM_WEBRTC_BRANCH}",
  "sourceUrl": "${WEBRTC_APM_URL}",
  "sourceSha256": "${WEBRTC_APM_SHA256}",
  "abseil": {
    "version": "${ABSEIL_VERSION}",
    "sourceUrl": "${ABSEIL_URL}",
    "sourceSha256": "${ABSEIL_SHA256}",
    "mesonPatchSha256": "${ABSEIL_PATCH_SHA256}"
  },
  "toolchain": { "meson": "${MESON_VERSION}", "ninja": "${NINJA_VERSION}" },
  "target": {
    "platform": "${PLATFORM}",
    "arch": "${ARCH}",
    "macosDeploymentTarget": "${MACOS_DEPLOYMENT_TARGET}",
    "buildType": "release",
    "libraryType": "static"
  },
  "output": {
    "library": "lib/lib${WEBRTC_APM_NAME}-${WEBRTC_APM_ABI_MAJOR}.a",
    "librarySha256": "${APM_LIB_SHA}",
    "libraryArchs": "${APM_LIB_ARCHS}",
    "abseilArchiveCount": ${ABSL_COUNT}
  }
}
INFO_EOF

printf '%s' "${STAMP_VALUE}" > "${STAMP_FILE}"

log "done"
log "  library : ${APM_LIB}"
log "  archs   : ${APM_LIB_ARCHS}"
log "  headers : ${PREFIX_DIR}/include/${WEBRTC_APM_NAME}-${WEBRTC_APM_ABI_MAJOR}"
log "  metadata: ${PREFIX_DIR}/build-info.json"

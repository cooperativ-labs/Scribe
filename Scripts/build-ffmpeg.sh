#!/usr/bin/env bash
# Builds the minimal LGPL-only FFmpeg 7.1.1 toolchain used for import and decoding.
# Usage: Scripts/build-ffmpeg.sh [install-prefix]
set -euo pipefail

readonly VERSION="7.1.1"
readonly ARCHIVE="ffmpeg-${VERSION}.tar.xz"
readonly SHA256="733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1"
readonly SOURCE_URL="https://ffmpeg.org/releases/${ARCHIVE}"
readonly ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PREFIX="${1:-${ROOT}/Native/FFmpeg/prefix}"
readonly CACHE="${ROOT}/Native/FFmpeg/cache"
readonly BUILD="${ROOT}/Native/FFmpeg/build"

mkdir -p "${CACHE}" "${BUILD}"
if [[ ! -f "${CACHE}/${ARCHIVE}" ]]; then curl --fail --location --proto '=https' --tlsv1.2 --output "${CACHE}/${ARCHIVE}" "${SOURCE_URL}"; fi
echo "${SHA256}  ${CACHE}/${ARCHIVE}" | shasum -a 256 --check --status
rm -rf "${BUILD}/ffmpeg-${VERSION}"
tar -xf "${CACHE}/${ARCHIVE}" -C "${BUILD}"
pushd "${BUILD}/ffmpeg-${VERSION}" >/dev/null

# No --enable-gpl, --enable-version3, --enable-nonfree, or external codec library is permitted.
# --disable-autodetect keeps accidental host libraries (X11, x264, …) out of the LGPL build.
# Demuxers cover popular audio and video containers; only audio decoders are enabled because
# transcription extracts the soundtrack and never decodes video.
export SOURCE_DATE_EPOCH=1736640000
./configure \
  --prefix="${PREFIX}" --disable-doc --disable-debug --disable-network --disable-autodetect \
  --disable-static --enable-shared --disable-everything --disable-avdevice --disable-postproc --disable-swscale --disable-ffplay \
  --enable-avcodec --enable-avformat --enable-avutil --enable-swresample \
  --enable-ffmpeg --enable-ffprobe --enable-avfilter --enable-filter=pan,aresample \
  --enable-protocol=file \
  --enable-demuxer=wav,flac,mp3,mov,aiff,caf,ogg,matroska,avi,mpegts,mpegps,mpegvideo,flv,asf,aac,ac3,amr,dts,wavpack,ape,au,voc,w64,spdif,truehd,mlp,tta,dsf \
  --enable-parser=aac,flac,mpegaudio,opus,vorbis,ac3,amr,dca \
  --enable-muxer=wav --enable-encoder=pcm_s16le \
  --enable-decoder=aac,aac_latm,alac,flac,mp3,mp2,opus,vorbis,wmav1,wmav2,wmapro,ac3,eac3,dca,truehd,mlp,amrnb,amrwb,wavpack,ape,nellymoser,gsm,adpcm_ima_qt,adpcm_ms,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_f32le,pcm_f32be,pcm_f64le,pcm_f64be,pcm_u8,pcm_mulaw,pcm_alaw
make -j"$(sysctl -n hw.ncpu)"
rm -rf "${PREFIX}"
make install
popd >/dev/null
"${PREFIX}/bin/ffprobe" -version
"${PREFIX}/bin/ffmpeg" -version
printf 'Installed LGPL FFmpeg probe toolchain at %s\n' "${PREFIX}"

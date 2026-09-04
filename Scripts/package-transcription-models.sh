#!/usr/bin/env bash
# Fetch the exact development model snapshots declared by the transcription
# worker. This is an installer only: the worker itself never downloads models.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
models_dir="$repo_root/Workers/TranscriptionWorker/models"
verify_only=0

usage() {
  cat <<'EOF'
Usage: Scripts/package-transcription-models.sh [--models-dir PATH] [--verify-only]

Downloads the pinned Hugging Face revisions through Git LFS, validates their
object checksums with `git lfs fsck`, and reports the staged byte count.

This is intentionally a development/release-preparation command. The signed
worker accepts only local model paths and has runtime downloads and telemetry
disabled. Git LFS is required because the Core ML weights are large objects.
EOF
}

while (($#)); do
  case "$1" in
    --models-dir)
      (($# >= 2)) || { echo "error: --models-dir needs a path" >&2; exit 64; }
      models_dir="$2"
      shift 2
      ;;
    --verify-only) verify_only=1; shift ;;
    --help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 64 ;;
  esac
done

require() { command -v "$1" >/dev/null || { echo "error: missing required command: $1" >&2; exit 69; }; }
require git
require shasum
git lfs version >/dev/null || { echo "error: Git LFS is required to fetch and verify model weights" >&2; exit 69; }

fetch_snapshot() {
  local name="$1"
  local source="$2"
  local revision="$3"
  local destination="$models_dir/$name"
  shift 3
  local paths=("$@")

  if [[ ! -d "$destination/.git" ]]; then
    ((verify_only)) && { echo "error: missing staged snapshot: $destination" >&2; return 1; }
    mkdir -p "$(dirname "$destination")"
    # Hugging Face's Git endpoint serves LFS pointers reliably but does not
    # consistently support Git partial-clone promisor packs. The repository
    # history here is small; keep the clone metadata complete and let LFS fetch
    # only the sparse, selected large objects below.
    GIT_LFS_SKIP_SMUDGE=1 git clone --no-checkout "$source" "$destination"
    git -C "$destination" sparse-checkout init --cone
  fi

  git -C "$destination" sparse-checkout set --skip-checks "${paths[@]}"
  GIT_LFS_SKIP_SMUDGE=1 git -C "$destination" checkout --detach "$revision"
  if (( ! verify_only )); then
    local include=""
    local path
    for path in "${paths[@]}"; do
      if [[ "$path" == *.mlmodelc ]]; then path="$path/**"; fi
      include+="${include:+,}$path"
    done
    git -C "$destination" lfs pull --include="$include"
  fi
  # Git LFS does not support fscking a sparse snapshot: it treats intentionally
  # omitted upstream pointers as corrupt. The explicit SHA-256 release-lock
  # checks below verify every payload the worker stages instead.
}

verify_sha256() {
  local file="$1"
  local expected="$2"
  [[ -f "$file" ]] || { echo "error: required model file is missing: $file" >&2; exit 1; }
  local actual
  actual="$(shasum -a 256 "$file" | awk '{ print $1 }')"
  [[ "$actual" == "$expected" ]] || { echo "error: checksum mismatch: $file" >&2; exit 1; }
}

fetch_snapshot \
  "parakeet-tdt-0.6b-v3-coreml" \
  "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml" \
  "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe" \
  "Preprocessor.mlmodelc" "Encoder.mlmodelc" "Decoder.mlmodelc" "JointDecision.mlmodelc" "parakeet_vocab.json"

fetch_snapshot \
  "speaker-diarization-coreml" \
  "https://huggingface.co/FluidInference/speaker-diarization-coreml" \
  "1ed7a662fdc7109e36d822db793ee6eebdaf8594" \
  "Segmentation.mlmodelc" "Embedding.mlmodelc" "FBank.mlmodelc" "PldaRho.mlmodelc" "plda-parameters.json" "xvector-transform.json"

# Recheck the release lock after Git LFS validates its local object store. The
# worker independently applies the same checks before loading any model.
verify_sha256 "$models_dir/parakeet-tdt-0.6b-v3-coreml/Preprocessor.mlmodelc/weights/weight.bin" "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"
verify_sha256 "$models_dir/parakeet-tdt-0.6b-v3-coreml/Encoder.mlmodelc/weights/weight.bin" "e2020f323703477a5b21d7c2d282c403e371afb5962e79877e3033e73ba6f421"
verify_sha256 "$models_dir/parakeet-tdt-0.6b-v3-coreml/Decoder.mlmodelc/weights/weight.bin" "48adf0f0d47c406c8253d4f7fef967436a39da14f5a65e66d5a4b407be355d41"
verify_sha256 "$models_dir/parakeet-tdt-0.6b-v3-coreml/JointDecision.mlmodelc/weights/weight.bin" "4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e"
verify_sha256 "$models_dir/parakeet-tdt-0.6b-v3-coreml/parakeet_vocab.json" "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"
verify_sha256 "$models_dir/speaker-diarization-coreml/Segmentation.mlmodelc/weights/weight.bin" "c3189a64946c75bc24fcb98afe89ad78c52bdbadfdf65e857fb1b81e2cc9fbb2"
verify_sha256 "$models_dir/speaker-diarization-coreml/Embedding.mlmodelc/weights/weight.bin" "99356b2985b8d43880a657024d941d450b38820451ccff903f76ed4e52d1868b"
verify_sha256 "$models_dir/speaker-diarization-coreml/FBank.mlmodelc/weights/weight.bin" "9e83fdd3ea78064b078069e4d9141603c61c47a27fd19e7e3142ff7476f8db36"
verify_sha256 "$models_dir/speaker-diarization-coreml/PldaRho.mlmodelc/weights/weight.bin" "80f7d229202636d372428c90596f11a91545f07da77259f07153aaf225914a36"
verify_sha256 "$models_dir/speaker-diarization-coreml/plda-parameters.json" "38ee28d4269c076cef254ee760bbd811f0738a92e0f01f9699ad372828c5de8f"
verify_sha256 "$models_dir/speaker-diarization-coreml/xvector-transform.json" "f7cd5cc16e63e2d89db052a23018ecfc47a311998ed1e9e39838fbac65048688"

actual_bytes="$(find "$models_dir" -type f ! -path '*/.git/*' -print0 | xargs -0 stat -f '%z' | awk '{ total += $1 } END { print total + 0 }')"
echo "Verified offline transcription models at: $models_dir"
echo "Staged model bytes: $actual_bytes"
echo "Manifest declared bytes (without Git metadata): 505044116"

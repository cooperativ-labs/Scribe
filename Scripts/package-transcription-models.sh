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

Downloads the pinned Hugging Face revisions through Git LFS and HTTPS, then
verifies the files listed in the release manifest. --verify-only reads an
existing model directory without changing it or making network requests.

This is intentionally a development/release-preparation command. The signed
worker accepts only local model paths and has runtime downloads and telemetry
disabled. Fetching Core ML weights requires Git LFS.
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
require python3
if (( ! verify_only )); then
  require git
  git lfs version >/dev/null || { echo "error: Git LFS is required to fetch model weights" >&2; exit 69; }
fi

fetch_snapshot() {
  local name="$1"
  local source="$2"
  local revision="$3"
  local destination="$models_dir/$name"
  shift 3
  local paths=("$@")

  if [[ ! -d "$destination/.git" ]]; then
    mkdir -p "$(dirname "$destination")"
    # Hugging Face's Git endpoint serves LFS pointers reliably but does not
    # consistently support Git partial-clone promisor packs. The repository
    # history here is small; keep the clone metadata complete and let LFS fetch
    # only the sparse, selected large objects below.
    GIT_LFS_SKIP_SMUDGE=1 git clone --no-checkout "$source" "$destination"
    git -C "$destination" sparse-checkout init --cone
  fi

  local sparse_paths=("${paths[@]}")
  # Keep a previously staged original encoder available to the previous app.
  if [[ "$name" == parakeet-tdt-0.6b-v3-coreml && -d "$destination/Encoder.mlmodelc" ]]; then
    sparse_paths+=("Encoder.mlmodelc")
  fi
  git -C "$destination" sparse-checkout set --skip-checks "${sparse_paths[@]}"
  GIT_LFS_SKIP_SMUDGE=1 git -C "$destination" checkout --detach "$revision"
  local include=""
  local path
  for path in "${paths[@]}"; do
    if [[ "$path" == *.mlmodelc ]]; then path="$path/**"; fi
    include+="${include:+,}$path"
  done
  git -C "$destination" lfs pull --include="$include"
  # Git LFS does not support fscking a sparse snapshot: it treats intentionally
  # omitted upstream pointers as corrupt. The explicit SHA-256 release-lock
  # checks below verify every payload the worker stages instead.
}

if (( ! verify_only )); then
  fetch_snapshot \
    "parakeet-tdt-0.6b-v3-coreml" \
    "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml" \
    "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe" \
    "Preprocessor.mlmodelc" "Encoder_v2.mlmodelc" "Decoder.mlmodelc" "JointDecision.mlmodelc" "parakeet_vocab.json"

  fetch_snapshot \
    "speaker-diarization-coreml" \
    "https://huggingface.co/FluidInference/speaker-diarization-coreml" \
    "1ed7a662fdc7109e36d822db793ee6eebdaf8594" \
    "Segmentation.mlmodelc" "Embedding.mlmodelc" "FBank.mlmodelc" "PldaRho.mlmodelc" "plda-parameters.json" "xvector-transform.json"

  python3 "$repo_root/Scripts/install-vocabulary-models.py" --models-dir "$models_dir"
fi

python3 - "$repo_root/Workers/TranscriptionWorker/model_manifest.json" "$models_dir" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

manifest = json.loads(Path(sys.argv[1]).read_text())
models_dir = Path(sys.argv[2])
verified_bytes = 0
for asset in manifest["assets"]:
    for item in asset["requiredFiles"]:
        path = models_dir / asset["relativePath"] / item["relativePath"]
        if not path.is_file() or path.stat().st_size != item["bytes"]:
            raise SystemExit(f"Missing model file or size mismatch: {path}")
        if "sha256" in item:
            digest = hashlib.sha256()
            with path.open("rb") as stream:
                while data := stream.read(1024 * 1024):
                    digest.update(data)
            if digest.hexdigest() != item["sha256"]:
                raise SystemExit(f"Checksum mismatch: {path}")
        verified_bytes += item["bytes"]

if verified_bytes != manifest["totalDeclaredOnDiskBytes"]:
    raise SystemExit("Verified bytes do not match the manifest total")
print(f"Verified offline transcription models at: {models_dir}")
print(f"Verified manifest files: {verified_bytes} bytes")
PY

#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

# Optional local-only fixtures are copied only after comparison with the committed
# mobile manifest. The app itself never bundles these model test resources.
if [[ "${1:-}" == "--models" ]]; then
  python3 - <<'PY'
from pathlib import Path
import hashlib, json, shutil
source = Path('Workers/TranscriptionWorker/models')
target = Path('Tests/ScribeMobileTests/DeviceFixtures/models')
manifest = json.loads(Path('Scribe/Mobile/model_manifest.json').read_text())
for asset in manifest['assets']:
    for entry in asset['requiredFiles']:
        relative = Path(asset['relativePath']) / entry['relativePath']
        path = source / relative
        data = path.read_bytes()
        if len(data) != entry['bytes'] or hashlib.sha256(data).hexdigest() != entry['sha256']:
            raise SystemExit(f'Model integrity mismatch: {relative}')
        output = target / relative
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, output)
print('Verified model fixtures staged for physical-device testing.')
PY
  shift
fi
if [[ $# == 0 ]]; then
  echo 'Usage: Scripts/test-mobile.sh [--models] <xcodebuild destination> [extra xcodebuild arguments]' >&2
  echo 'Example: Scripts/test-mobile.sh --models "id=<iPad UDID>" DEVELOPMENT_TEAM=<team> -allowProvisioningUpdates' >&2
  exit 2
fi
destination="$1"
shift
xcodebuild -project ScribeMobile.xcodeproj -scheme ScribeMobile \
  -destination "$destination" -derivedDataPath build/mobile-device "$@" test

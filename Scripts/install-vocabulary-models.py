#!/usr/bin/env python3
"""Explicit installer for the optional vocabulary group; never imported at runtime."""
import argparse
import hashlib
import json
from pathlib import Path
import tempfile
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument("--models-dir", type=Path, required=True)
parser.add_argument("--verify-only", action="store_true")
options = parser.parse_args()
manifest = json.loads((Path(__file__).resolve().parents[1] / "Workers/TranscriptionWorker/model_manifest.json").read_text())
for asset in manifest["assets"]:
    if asset["id"] != "parakeet-ctc-110m":
        continue
    for item in asset["requiredFiles"]:
        target = options.models_dir / asset["relativePath"] / item["relativePath"]
        def valid(path):
            if not path.is_file() or path.stat().st_size != item["bytes"]:
                return False
            with path.open("rb") as stream:
                digest = hashlib.sha256()
                while data := stream.read(1024 * 1024):
                    digest.update(data)
                return digest.hexdigest() == item["sha256"]
        if valid(target):
            continue
        if options.verify_only:
            raise SystemExit(f"Missing or invalid vocabulary asset: {target}")
        target.parent.mkdir(parents=True, exist_ok=True)
        url = asset["upstream"]["repository"] + "/resolve/" + asset["upstream"]["revision"] + "/" + item["relativePath"]
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as output:
                temporary = Path(output.name)
                with urllib.request.urlopen(url) as source:
                    while data := source.read(1024 * 1024):
                        output.write(data)
            if not valid(temporary):
                raise SystemExit(f"Checksum failed: {target}")
            temporary.replace(target)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
print("Verified optional offline vocabulary models")

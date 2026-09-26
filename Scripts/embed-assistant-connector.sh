#!/usr/bin/env bash
# Packages Integrations/scribe and copies its Claude marketplace into the app,
# where Settings → Assistants finds it to install the Claude Code plugin and to
# serve the connector for ChatGPT and Claude.
#
#   Scripts/embed-assistant-connector.sh <Scribe.app>             # required
#   Scripts/embed-assistant-connector.sh --optional <Scribe.app>  # skip without npm
#
# A development build passes --optional, so a machine without Node still
# builds; Settings then says the package is missing. A release requires it.
set -euo pipefail

optional=0
if [[ "${1:-}" == "--optional" ]]; then optional=1; shift; fi
if (($# != 1)); then
  echo "usage: $(basename "$0") [--optional] <Scribe.app>" >&2
  exit 2
fi

app_path="$1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
integration_dir="$repo_root/Integrations/scribe"
destination="$app_path/Contents/Resources/AssistantConnector/claude"

die() { echo "error: $*" >&2; exit 1; }

[[ -d "$app_path/Contents" ]] || die "not an app bundle: $app_path"
if ! command -v npm >/dev/null 2>&1; then
  ((optional)) || die "npm is required to package the assistant connector (Node.js 22 or newer)."
  echo "note: npm not found; this build omits the assistant connector and Settings → Assistants cannot install it."
  exit 0
fi

echo "Packaging the assistant connector…"
# `npm ci` keeps the bundle's dependencies exactly the locked ones.
npm --prefix "$integration_dir" ci --no-audit --no-fund >/dev/null
npm --prefix "$integration_dir" run --silent package >/dev/null
source_dir="$integration_dir/dist/packages/claude"
[[ -f "$source_dir/.claude-plugin/marketplace.json" ]] || die "packaging did not produce $source_dir"

rm -rf "$destination"
mkdir -p "$(dirname "$destination")"
ditto "$source_dir" "$destination"
echo "Embedded the assistant connector in $destination"

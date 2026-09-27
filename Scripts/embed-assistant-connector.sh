#!/usr/bin/env bash
# Embed the static local plugin with the Swift launcher already built into Scribe.app.
# npm is only needed when packaging the separate Node relay service or remote plugin.
set -euo pipefail
if (($# != 1)); then
  echo "usage: $(basename "$0") <Scribe.app>" >&2
  exit 2
fi
app_path="$1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="$repo_root/Integrations/scribe"
destination="$app_path/Contents/Resources/AssistantConnector/claude"
launcher="$app_path/Contents/Helpers/scribe-mcp-launcher"
[[ -d "$app_path/Contents" && -x "$launcher" ]] || { echo "error: embed the MCP helper first" >&2; exit 1; }
rm -rf "$destination"
plugin="$destination/plugins/scribe"
mkdir -p "$plugin/assets" "$destination/.claude-plugin" "$destination/relay"
for folder in .claude-plugin .codex-plugin .cursor-plugin; do
  ditto "$source_dir/local-plugin-template/$folder" "$plugin/$folder"
done
for name in .mcp.json mcp.json; do
  cp "$source_dir/local-plugin-template/$name" "$plugin/$name"
done
cp "$source_dir/local-plugin-template/marketplace.json" "$destination/.claude-plugin/marketplace.json"
ditto "$source_dir/skills" "$plugin/skills"
ditto "$source_dir/ui" "$plugin/ui"
cp "$source_dir/assets/icon.png" "$plugin/assets/icon.png"
cp "$launcher" "$plugin/scribe-mcp-launcher"
chmod 755 "$plugin/scribe-mcp-launcher"
relay_url="${SCRIBE_CONNECTOR_URL-https://scribe.ovld.ai/mcp}"
if [[ -n "$relay_url" ]]; then
  [[ "$relay_url" != *'"'* && "$relay_url" != *'\\'* ]] || { echo "error: invalid SCRIBE_CONNECTOR_URL" >&2; exit 1; }
  printf '{"connector_url":"%s"}\n' "$relay_url" > "$destination/relay/connector.json"
fi
echo "Embedded the native assistant connector in $destination"

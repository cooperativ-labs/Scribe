#!/usr/bin/env bash
# Notarize the current, already-versioned Scribe commit and publish it.
#
# Run Scripts/bump-minor-version.sh, review and commit the result, then invoke
# this command. It deliberately never changes a version or creates a commit.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

usage() {
  cat <<'EOF'
Usage: Scripts/release-app.sh [--inputs PATH]

--inputs PATH  Local release-input environment file passed to package-app.sh.
               Defaults to Scripts/release-inputs.local.env.

The root .env supplies DEVELOPER_ID_APPLICATION, NOTARYTOOL_PROFILE, APPLE_ID,
APPLE_APP_SPECIFIC_PASSWORD, and APPLE_TEAM_ID. Copy .env.example; never
commit .env or release-inputs.local.env.
EOF
}

die() { echo "error: $*" >&2; exit 1; }

load_env_value() {
  local name="$1"
  local env_file="$2"
  local value

  # Only parse known scalar keys. Release credentials must not cause arbitrary
  # shell code in .env to execute.
  value="$(sed -nE "s/^${name}=(.*)$/\\1/p" "$env_file" | tail -n 1)"
  case "$value" in
    \"*\") value="${value:1:${#value}-2}" ;;
    \'*\') value="${value:1:${#value}-2}" ;;
  esac
  printf '%s' "$value"
}

inputs_file="$repo_root/Scripts/release-inputs.local.env"
while (($#)); do
  case "$1" in
    --inputs)
      (($# >= 2)) || die "--inputs requires a path"
      inputs_file="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -f "$inputs_file" ]] || die "release inputs are missing: $inputs_file"

env_file="$repo_root/.env"
[[ -f "$env_file" ]] || die "missing $env_file; copy .env.example and fill its values"
for name in DEVELOPER_ID_APPLICATION NOTARYTOOL_PROFILE APPLE_ID APPLE_APP_SPECIFIC_PASSWORD APPLE_TEAM_ID; do
  if [[ -z "${!name:-}" ]]; then
    export "$name=$(load_env_value "$name" "$env_file")"
  fi
  [[ -n "${!name:-}" ]] || die "$name is required; see .env.example"
done

version="$(sed -nE '/<key>CFBundleShortVersionString<\/key>/ { n; s#^[[:space:]]*<string>([0-9]+\.[0-9]+\.[0-9]+)</string>[[:space:]]*$#\1#p; }' Scribe/App/Info.plist)"
[[ -n "$version" ]] || die "could not read Scribe's version from Scribe/App/Info.plist"
tag="v$version"

branch="$(git branch --show-current)"
[[ -n "$branch" ]] || die "refusing to release from a detached HEAD"
if [[ -n "$(git status --porcelain)" ]]; then
  cat >&2 <<'EOF'
Refusing to release with uncommitted changes. Commit the reviewed version bump
and release changes first; this script will tag and push that commit.
EOF
  exit 1
fi

git fetch origin --tags
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  die "tag $tag already exists locally or on origin"
fi

# Store the profile in the login keychain immediately before packaging. The
# package script submits via the profile, so passwords never enter an archive,
# command-line argument to submit, or checked-in configuration.
xcrun notarytool store-credentials "$NOTARYTOOL_PROFILE" \
  --apple-id "$APPLE_ID" \
  --password "$APPLE_APP_SPECIFIC_PASSWORD" \
  --team-id "$APPLE_TEAM_ID"

distribution_dir="$repo_root/dist"
# Keep the distribution directory limited to the artifacts from this release.
# The archive is versioned, so removing only the current path would leave
# archives and checksums from earlier releases behind.
rm -f -- \
  "$distribution_dir"/Scribe-*-macos.zip \
  "$distribution_dir"/Scribe-*-macos.zip.sha256
archive_path="$distribution_dir/Scribe-$version-macos.zip"
rm -f -- "$archive_path" "$archive_path.sha256"
Scripts/package-app.sh --inputs "$inputs_file" --notary-profile "$NOTARYTOOL_PROFILE" --output "$archive_path"
[[ -f "$archive_path" ]] || die "notarization completed but no release archive was produced"
shasum -a 256 "$archive_path" | sed 's|  .*/|  |' > "$archive_path.sha256"

git tag --annotate "$tag" --message "Scribe $version"
git push origin "HEAD:refs/heads/$branch" "refs/tags/$tag"

if ! command -v gh >/dev/null 2>&1; then
  cat >&2 <<EOF
Published $tag, but the GitHub CLI is not installed so the notarized archive
was not uploaded. Install gh, then run:
  gh release create "$tag" "$archive_path" "$archive_path.sha256" --title "Scribe $tag" --generate-notes
EOF
  exit 1
fi

gh release create "$tag" "$archive_path" "$archive_path.sha256" \
  --title "Scribe $tag" --generate-notes
echo "Published $tag with $archive_path"

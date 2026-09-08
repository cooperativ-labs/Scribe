#!/usr/bin/env bash
# Read and edit Scribe's custom transcription vocabulary from a shell.
#
# This is the same list the Vocabulary section of Scribe's Settings window
# edits: one JSON document under Application Support, opened under an advisory
# lock, so an edit made here while the window is open is picked up there and
# neither overwrites the other.
#
#   Scripts/vocab.sh list
#   Scripts/vocab.sh add "Livmarli" --alias "Liv Mali, Liv-Marli"
#   Scripts/vocab.sh import glossary.txt
#   Scripts/vocab.sh --help
#
# The helper is built once into build/dev/ScribeVocabulary and reused after
# that, so repeated calls are fast.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package="$repo_root/Tools/ScribeVocabulary"
scratch="$repo_root/build/dev/ScribeVocabulary"

# The build output is quiet unless it fails: this script's stdout is the
# command's own output, which callers parse.
swift build --package-path "$package" --scratch-path "$scratch" --configuration release >/dev/null
bin_dir="$(swift build --package-path "$package" --scratch-path "$scratch" --configuration release --show-bin-path)"

exec "$bin_dir/scribe-vocab" "$@"

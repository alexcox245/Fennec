#!/bin/zsh
# Regenerates Docs/SOURCE_MANIFEST.sha256 from every file git tracks, plus any
# new files staged for addition. Run after editing tracked sources.
#
# Note: never use `path` as a variable name in this repo's zsh scripts; zsh
# ties it to $PATH and every later command dies with "command not found".
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

MANIFEST="Docs/SOURCE_MANIFEST.sha256"

{
  git ls-files
  git diff --cached --name-only --diff-filter=A
} | sort -u | while read -r tracked_file; do
  case "$tracked_file" in
    "$MANIFEST"|*.DS_Store|*xcuserdata/*) continue ;;
  esac
  [[ -f "$tracked_file" ]] || continue
  print -r -- "$(shasum -a 256 "$tracked_file" | cut -d' ' -f1)  ./$tracked_file"
done > "$MANIFEST"

print "Wrote $(wc -l < "$MANIFEST" | tr -d ' ') entries to $MANIFEST"

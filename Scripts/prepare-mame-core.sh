#!/usr/bin/env bash
# Prepare the MAME headless source used by cores/MAME/MAME.xcodeproj.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MAME_DIR="$REPO_ROOT/cores/MAME"
DEPS_DIR="$MAME_DIR/deps"
SRC_DIR="$DEPS_DIR/mame"
PATCH_FILE="$MAME_DIR/patches/mame-headless-clang21-apple.patch"
REVISION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["cores"]["MAME"]["revision"])' "$REPO_ROOT/cores/upstream.json")
REMOTE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["cores"]["MAME"]["url"])' "$REPO_ROOT/cores/upstream.json")

mkdir -p "$DEPS_DIR"

if [ ! -e "$SRC_DIR/.git" ]; then
  echo "Cloning OpenEmu-Silicon/mame into $SRC_DIR..."
  git clone --no-tags "$REMOTE" "$SRC_DIR"
fi

cd "$SRC_DIR"

# Keep the applied patch so an updated patch can replace it without resetting
# any other edits in the downloaded source.
APPLIED_PATCH=$(git rev-parse --git-path cassowary-apple.patch)
if [ -f "$APPLIED_PATCH" ] && { ! cmp -s "$APPLIED_PATCH" "$PATCH_FILE" || [ "$(git rev-parse HEAD)" != "$REVISION" ]; }; then
  if ! git apply --reverse --check "$APPLIED_PATCH"; then
    echo "error: cached MAME patch has additional edits; leaving them untouched" >&2
    exit 1
  fi
  git apply --reverse "$APPLIED_PATCH"
fi

# Existing checkouts may still point origin at the old stuartcarnie/mame remote;
# repoint before fetching so the pinned revision resolves.
git remote set-url origin "$REMOTE"

git fetch --no-tags origin "$REVISION"
git checkout --detach "$REVISION"

if git apply --check "$PATCH_FILE" >/dev/null 2>&1; then
  echo "Applying Apple Silicon / Clang 21 patch..."
  git apply "$PATCH_FILE"
elif git apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
  echo "Patch already applied."
else
  echo "error: patch does not apply cleanly and is not already applied: $PATCH_FILE" >&2
  git status --short >&2 || true
  exit 1
fi

cp "$PATCH_FILE" "$APPLIED_PATCH"

echo "MAME source ready at $SRC_DIR"

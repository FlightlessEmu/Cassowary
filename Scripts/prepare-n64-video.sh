#!/usr/bin/env bash
# Fetch the sources the Nintendo 64 video plugin is built from.
#
# Mupen64Plus draws through the paraLLEl-RDP plugin on Apple devices: they
# have no OpenGL, which the GLideN64 plugin needs. paraLLEl-RDP renders with
# Vulkan, which MoltenVK turns into Metal. Neither is committed here (MoltenVK
# alone is hundreds of megabytes once built); this clones both at the
# revisions below into cores/Mupen64Plus/deps/, which git ignores, and applies
# our one local change. Scripts/cassowary/build-n64-video.sh builds them.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
DEPS_DIR="$REPO_ROOT/cores/Mupen64Plus/deps"

# highscore-emu's paraLLEl-RDP adds the mupen64plus plugin glue (gfx_m64p.cpp,
# parallel_imp.cpp) to Themaister's renderer. MIT licensed.
RDP_REMOTE="https://github.com/highscore-emu/parallel-rdp.git"
RDP_REVISION="2cdcce76c3cbdf76997f7dc5e5d0e0a98993f5fa"
RDP_PATCH="$REPO_ROOT/cores/Mupen64Plus/patches/parallel-rdp-logging.patch"

# Khronos's MoltenVK, unchanged. Apache 2.0 licensed.
MVK_REMOTE="https://github.com/KhronosGroup/MoltenVK.git"
MVK_REVISION="4aaf714aa1b3e78e26ecfcefa9c75e9a576c500b"

fetch() { # remote revision directory
  local remote=$1 revision=$2 dir=$3
  if [ ! -e "$dir/.git" ]; then
    echo "Cloning $remote into $dir..."
    git clone --no-tags "$remote" "$dir"
  fi
  if [ "$(git -C "$dir" rev-parse HEAD)" != "$revision" ]; then
    git -C "$dir" fetch --no-tags origin "$revision"
    git -C "$dir" checkout --detach "$revision"
  fi
}

mkdir -p "$DEPS_DIR"
fetch "$RDP_REMOTE" "$RDP_REVISION" "$DEPS_DIR/parallel-rdp"
fetch "$MVK_REMOTE" "$MVK_REVISION" "$DEPS_DIR/MoltenVK"

cd "$DEPS_DIR/parallel-rdp"
if git apply --check "$RDP_PATCH" >/dev/null 2>&1; then
  echo "Applying the paraLLEl-RDP logging patch..."
  git apply "$RDP_PATCH"
elif ! git apply --reverse --check "$RDP_PATCH" >/dev/null 2>&1; then
  echo "error: patch does not apply cleanly and is not already applied: $RDP_PATCH" >&2
  git status --short >&2 || true
  exit 1
fi

echo "N64 video sources ready in $DEPS_DIR"

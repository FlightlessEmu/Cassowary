#!/bin/bash
#
# post-edit-core.sh — Cursor postToolUse hook for Write/Edit tool calls.
#
# When the agent edits a file inside a core plugin directory, surface a
# reminder that any in-game test result must be preceded by install-core.sh
# and verify-core-installed.sh, or it is invalid.
#
# Why this hook exists:
#   The single most expensive failure mode in this repo is claiming a core
#   test result against a stale installed plugin while the freshly-built
#   binary sits unused in DerivedData. The protocol to prevent this is
#   already documented in AGENTS.md and CLAUDE.md, and the tooling already
#   exists in Scripts/. But agents (including the one that wrote this hook)
#   have demonstrably ignored that protocol. This hook is the mechanical
#   enforcement layer: every edit to a core file produces a fresh reminder
#   in the agent's tool output, which the agent has to acknowledge.
#
# This hook does not block edits. It only surfaces context.
#
# Input (stdin, JSON):
#   {
#     "tool_name": "Write" | "Edit" | "StrReplace" | ...,
#     "tool_input": { "path": "..." | "filePath": "...", ... },
#     ...
#   }
#
# Output (stdout, JSON):
#   { "additional_context": "..." }
#
# Exit code 0 always (fail-open by design — never break the agent's flow).

set -uo pipefail

# Always exit 0 — failures here must not break the agent.
trap 'exit 0' ERR

input=$(cat)

# Try to extract the edited file path from common shapes. Different Cursor
# tools use different key names (path / filePath / target_notebook).
# Use a single jq invocation that tries each in order.
if ! command -v jq >/dev/null 2>&1; then
  # No jq available — silently no-op. The hook is informational only.
  echo '{}'
  exit 0
fi

path=$(echo "$input" | jq -r '
  .tool_input.path //
  .tool_input.filePath //
  .tool_input.file_path //
  .tool_input.target_notebook //
  empty
')

if [ -z "$path" ]; then
  echo '{}'
  exit 0
fi

# Determine the repo root from this script's location.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Normalise: if the edited path is absolute and inside the repo, strip the
# repo prefix. Otherwise treat it as already-relative.
case "$path" in
  "$REPO_ROOT"/*) rel_path="${path#$REPO_ROOT/}" ;;
  /*)             # absolute but outside repo — not interesting
                  echo '{}'; exit 0 ;;
  *)              rel_path="$path" ;;
esac

# Cores live under cores/. The first path component selects the group; when
# it is `cores`, the core name is the second component.
# Core directories contain an `Info.plist` plus a `*.xcodeproj` (or are
# referenced by the workspace). Use a simple filesystem check rather than
# maintaining a hardcoded list.
core=""
case "$rel_path" in
  cores/*) core="${rel_path#cores/}"; core="${core%%/*}" ;;
esac

if [ -z "$core" ] || [ ! -d "$REPO_ROOT/cores/$core" ]; then
  echo '{}'
  exit 0
fi
if [ ! -f "$REPO_ROOT/cores/$core/Info.plist" ]; then
  # Not a core directory.
  echo '{}'
  exit 0
fi
# Filter further: only fire for source-file edits (skip docs, READMEs, etc.).
case "$rel_path" in
  *.m|*.mm|*.h|*.hpp|*.c|*.cpp|*.swift|*.metal|*.plist) ;;
  *) echo '{}'; exit 0 ;;
esac

# Emit a reminder pointing at the iOS build-and-test loop.
reminder=$(cat <<EOF
You just edited a file in the **${core}** core plugin directory (${rel_path}).

Cores are built for iOS and staged into the app bundle. Before you (or the
user) report any in-game test result for ${core}:

  1. Build it:  ./Scripts/cassowary/build-core-ios.sh ${core}
  2. Rebuild and stage: ./Scripts/cassowary/build-cassowary.sh
  3. Run it:    ./Scripts/cassowary/run-cassowary.sh
     End to end: ./Scripts/cassowary/test-cassowary.sh

The app loads plugins from its own bundle, not from build/. If you do not
rebuild and restage, the app keeps running the previously staged plugin.
EOF
)

# Emit the reminder as additional_context for postToolUse.
jq -n --arg ctx "$reminder" '{additional_context: $ctx}'
exit 0

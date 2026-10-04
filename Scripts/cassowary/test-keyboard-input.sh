#!/bin/zsh
# Check the production keyboard manager using Apple's GameController framework.
set -euo pipefail
cd "${0:A:h}/../.."

KEYBOARD_CHECK_DIR=$(mktemp -d)
trap 'rm -rf "$KEYBOARD_CHECK_DIR"' EXIT
xcrun swiftc -parse-as-library \
  Cassowary/Sources/Controls/KeyboardControlManager.swift \
  Scripts/cassowary/tests/KeyboardControlManagerCheck.swift \
  -o "$KEYBOARD_CHECK_DIR/keyboard-input-check"
"$KEYBOARD_CHECK_DIR/keyboard-input-check"

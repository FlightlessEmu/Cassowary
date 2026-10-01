#!/bin/zsh
#
# Checks the rules play history merges by, without building the app.
#
# Play history (last played, play count, favorite) is merged whenever two
# devices sync, and a mistake there quietly loses plays or brings back a
# removed favorite. This pulls PlayInfo out of TransferProtocol.swift,
# compiles it with Scripts/cassowary/checks/play-history.swift, and runs it.
#
# Usage:
#   Scripts/cassowary/check-play-history.sh
#
# Exit status is 0 when every check passed.

set -euo pipefail
cd "${0:A:h}/../.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

{
  print -- "import Foundation"
  sed -n '/^struct PlayInfo: Codable, Hashable {/,/^}$/p' Cassowary/Sources/Transfer/TransferProtocol.swift
} > "$WORK/PlayInfo.swift"

# Swift only runs top-level code from a file named main.swift.
cp Scripts/cassowary/checks/play-history.swift "$WORK/main.swift"
swiftc -O "$WORK/PlayInfo.swift" "$WORK/main.swift" -o "$WORK/check"
"$WORK/check"

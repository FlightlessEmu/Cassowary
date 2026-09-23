#!/bin/sh
# Copies staged plugin bundles into the built app and signs them.
#
# Called from the Copy PlugIns phase in Cassowary/project.yml (both the iOS
# and tvOS targets). $1 is the staged plugins directory, e.g.
# "${SRCROOT}/PlugIns" or "${SRCROOT}/PlugIns-tvOS".
#
# Plugin bundles have to be copied as bundles, not flattened into the
# resources directory, which is what a plain resource entry would do.
set -e

SRC="$1"
DEST="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/PlugIns"
mkdir -p "$DEST/Cores" "$DEST/Systems"
rsync -a --delete "$SRC/Cores/" "$DEST/Cores/"
rsync -a --delete "$SRC/Systems/" "$DEST/Systems/"
# Xcode signs the app and the embedded frameworks but not these
# bundles: they arrive here by rsync, outside any embed phase. A
# real iPhone refuses to load an unsigned plugin, so sign them with
# the identity Xcode is about to use for the app. A dylib inside a
# plugin is signed first, because a signature seals its contents.
if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]; then
  for bundle in "$DEST/Cores/"*.oecoreplugin "$DEST/Systems/"*.oesystemplugin; do
    [ -e "$bundle" ] || continue
    find "$bundle" -type f -name "*.dylib" -exec codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" {} \;
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" "$bundle"
  done
fi
# A stamp inside the bundle, declared as this phase's output, is how
# Xcode knows the app changed and signs it again. The phase runs on
# every build (see basedOnDependencyAnalysis in project.yml): plugins are
# staged by copying files into a folder, and a file that changes
# inside a plugin does not move any date Xcode watches, so anything
# that made the phase skippable would let a rebuilt core go stale.
touch "$DEST/.plugins-copied"

#!/bin/sh
# Build a release-ready fetcher.koplugin.zip.
#
# The archive is root-wrapped (a single top-level `fetcher.koplugin/` folder)
# so it can be extracted straight into KOReader's plugins/ directory — matching
# the convention of the other plugins Fetcher manages.
set -eu

PLUGIN="fetcher.koplugin"
OUT="$PLUGIN.zip"
BUILD_DIR="build/$PLUGIN"

# Files that ship in the plugin (code + docs). Keep in sync with the repo.
FILES="main.lua _meta.lua README.md LICENSE CHANGELOG.md fetcher_sources.lua.sample"

rm -rf build "$OUT"
mkdir -p "$BUILD_DIR"
for f in $FILES; do
    cp "$f" "$BUILD_DIR/$f"
done

( cd build && zip -r -X "../$OUT" "$PLUGIN" >/dev/null )
rm -rf build

echo "Built $OUT:"
unzip -l "$OUT"

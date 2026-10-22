#!/bin/zsh
# Packages a built Synapse.app into a drag-to-Applications disk image.
#   Scripts/make-dmg.sh <path/to/Synapse.app> <output.dmg> [signing identity]
set -euo pipefail
APP="$1"
OUT="$2"
IDENTITY="${3:-}"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/Synapse.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$OUT"
hdiutil create -volname "Synapse" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$OUT" -quiet
if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" --timestamp=none "$OUT"
  codesign --verify --verbose=1 "$OUT"
fi
echo "Created $OUT"

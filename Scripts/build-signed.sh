#!/bin/zsh
# Builds a Release copy of Synapse, signs it, and installs it to /Applications.
#   SYNAPSE_SIGN_IDENTITY  signing identity (name or SHA-1). Defaults to the first valid "Apple Development" identity.
#   SYNAPSE_INSTALL=0      build and sign only, don't copy to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${SYNAPSE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning | grep -v REVOKED | grep "Apple Development" | head -1 | awk '{print $2}')
fi
if [[ -z "$IDENTITY" ]]; then
  echo "No valid code signing identity found. Set SYNAPSE_SIGN_IDENTITY." >&2
  exit 1
fi

xcodegen generate -q
xcodebuild -project Synapse.xcodeproj -scheme Synapse -configuration Release -derivedDataPath build/Release build -quiet

APP=build/Release/Build/Products/Release/Synapse.app
codesign --force --timestamp=none --options runtime --sign "$IDENTITY" "$APP/Contents/MacOS/synapse-cli"
codesign --force --timestamp=none --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=1 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "^Authority=|^Identifier=" | head -3

if [[ "${SYNAPSE_INSTALL:-1}" == "1" ]]; then
  pkill -x Synapse 2>/dev/null || true
  rm -rf /Applications/Synapse.app
  cp -R "$APP" /Applications/
  echo "Installed /Applications/Synapse.app"
fi

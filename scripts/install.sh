#!/bin/zsh
# Installs the latest Decibel release into /Applications.
#   curl -fsSL https://raw.githubusercontent.com/ml450/decibel/main/scripts/install.sh | zsh
set -euo pipefail
TMP=$(mktemp -d)
curl -fsSL -o "$TMP/Decibel.zip" https://github.com/ml450/decibel/releases/latest/download/Decibel.zip
ditto -x -k "$TMP/Decibel.zip" "$TMP"
osascript -e 'tell application id "local.hearing.app" to quit' 2>/dev/null || true
sleep 1
rm -rf /Applications/Decibel.app
ditto "$TMP/Decibel.app" /Applications/Decibel.app
rm -rf "$TMP"
open /Applications/Decibel.app
echo "Decibel installed in /Applications."

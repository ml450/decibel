#!/bin/zsh
# Builds Decibel, runs the self-test, and publishes Decibel.zip as a GitHub release.
# Usage: scripts/release.sh 1.1 "What changed"
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: scripts/release.sh <version> [notes]}
NOTES=${2:-"Decibel $VERSION"}
BUILD=$(git rev-list --count HEAD)

[[ -z "$(git status --porcelain)" ]] || { echo "Commit your changes first."; exit 1; }

sed -i '' -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $VERSION;/; s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = $BUILD;/" Decibel.xcodeproj/project.pbxproj

xcodebuild -project Decibel.xcodeproj -scheme Decibel -configuration Release \
  -derivedDataPath build/DerivedData clean build | grep -E "error|BUILD" || true
APP=build/DerivedData/Build/Products/Release/Decibel.app
"$APP/Contents/MacOS/Decibel" --selftest | tail -1

rm -f build/Decibel.zip
ditto -c -k --keepParent "$APP" build/Decibel.zip

git commit -qam "Release $VERSION" || true
git tag "v$VERSION"
git push -q origin HEAD "v$VERSION"
gh release create "v$VERSION" build/Decibel.zip --title "Decibel $VERSION" --notes "$NOTES"
echo "Released Decibel $VERSION"

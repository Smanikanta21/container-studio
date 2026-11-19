#!/bin/zsh
set -euo pipefail
studio_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$studio_root"
studio_derived="$studio_root/.build/xcode"
xcodebuild -project ContainerStudio.xcodeproj -scheme "Container Studio" \
  -configuration Release -derivedDataPath "$studio_derived" \
  -destination "platform=macOS,arch=arm64" build
studio_app="$studio_root/dist/Container Studio.app"
# Replace only this generated app bundle, retaining the rest of dist.
rm -rf "$studio_app"
ditto "$studio_derived/Build/Products/Release/Container Studio.app" "$studio_app"
codesign --verify --deep --strict "$studio_app"
printf 'Built %s\n' "$studio_app"

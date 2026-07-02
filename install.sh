#!/bin/bash
#
# Build Isle in Debug and install it to /Applications, replacing any existing
# copy. Local installs are always the Debug build on purpose: logging (see
# `Log`) is compiled only into Debug, so this is the version that writes session
# logs to ~/Library/Application Support/Isle/logs/ for later debugging.
#
# Usage: ./install.sh
#
set -euo pipefail

cd "$(dirname "$0")"

echo "Building Isle (Debug)…"
xcodebuild -project Isle.xcodeproj -scheme Isle -configuration Debug \
    -destination 'platform=macOS' build >/dev/null

APP=$(xcodebuild -project Isle.xcodeproj -scheme Isle -configuration Debug \
    -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{d=$2}/ FULL_PRODUCT_NAME /{n=$2}END{print d"/"n}')

if [ ! -d "$APP" ]; then
    echo "error: built app not found at $APP" >&2
    exit 1
fi

echo "Quitting any running Isle…"
osascript -e 'tell application "Isle" to quit' 2>/dev/null || true
sleep 1
pkill -x Isle 2>/dev/null || true

echo "Installing to /Applications/Isle.app…"
rm -rf /Applications/Isle.app
cp -R "$APP" /Applications/Isle.app
codesign --verify --deep --strict /Applications/Isle.app

echo "Launching…"
open /Applications/Isle.app

echo "Done. Logs: ~/Library/Application Support/Isle/logs/"

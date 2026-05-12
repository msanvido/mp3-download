#!/bin/bash
# Build MP3Download as a proper .app bundle so TCC (Audio Capture permission) works.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="MP3Download"
APP_BUNDLE="${APP_NAME}.app"
BUILD_DIR=".build/release"

echo "==> Building Swift package (release)"
swift build -c release

if [[ ! -x "${BUILD_DIR}/${APP_NAME}" ]]; then
    echo "Build failed: ${BUILD_DIR}/${APP_NAME} not found" >&2
    exit 1
fi

echo "==> Assembling ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP_BUNDLE}/Contents/Info.plist"

echo "==> Ad-hoc signing with entitlements"
codesign --force --deep --sign - \
    --entitlements Resources/MP3Download.entitlements \
    --options runtime \
    "${APP_BUNDLE}"

echo ""
echo "Built ${APP_BUNDLE}. Launch it with:"
echo "  open ${APP_BUNDLE}"
echo ""
echo "First launch will prompt for Audio Capture permission. Grant it,"
echo "then click Start Recording and play music in Apple Music/Spotify/Amazon Music."

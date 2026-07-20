#!/bin/bash
set -e

APP_NAME="ExportsSyncer"
BUNDLE_ID="com.ivp.exports-syncer"
BUILD_DIR=".build/release"
APP_DIR="dist/${APP_NAME}.app"

echo "Building ${APP_NAME}..."
swift build -c release

echo "Creating app bundle..."
rm -rf dist
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp "Sources/${APP_NAME}/Info.plist" "${APP_DIR}/Contents/Info.plist"

# Code sign (ad-hoc) so LaunchAgent / Keychain work without a dev cert
codesign --force --sign - \
    --entitlements "Sources/${APP_NAME}/${APP_NAME}-entitlement.plist" \
    "${APP_DIR}" 2>/dev/null || \
codesign --force --sign - "${APP_DIR}"

echo "Done: ${APP_DIR}"
echo ""
echo "To install: cp -r ${APP_DIR} /Applications/"
echo "Then open /Applications/${APP_NAME}.app"

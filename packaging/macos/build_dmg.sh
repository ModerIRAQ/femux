#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-0.0.0}"
DIST_DIR="dist/macos"
RELEASE_DIR="build/macos/Build/Products/Release"
DMG_PATH="${DIST_DIR}/Femux-${VERSION}-macos.dmg"

if [[ ! -d "${RELEASE_DIR}" ]]; then
  echo "macOS release folder not found at ${RELEASE_DIR}. Run: flutter build macos --release"
  exit 1
fi

APP_BUNDLE="$(find "${RELEASE_DIR}" -maxdepth 1 -name "*.app" | head -n 1)"
if [[ -z "${APP_BUNDLE}" ]]; then
  echo "No .app bundle found in ${RELEASE_DIR}"
  exit 1
fi

STAGING_DIR="${DIST_DIR}/dmg-root"
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"
cp -R "${APP_BUNDLE}" "${STAGING_DIR}/"

mkdir -p "${DIST_DIR}"
rm -f "${DMG_PATH}"
hdiutil create \
  -volname "Femux" \
  -srcfolder "${STAGING_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

rm -rf "${STAGING_DIR}"
echo "Created ${DMG_PATH}"

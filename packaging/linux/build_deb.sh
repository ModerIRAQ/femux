#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-0.0.0}"
APP_NAME="femux"
ARCH="amd64"
BUNDLE_DIR="build/linux/x64/release/bundle"
DIST_DIR="dist/linux"
PKG_DIR="${DIST_DIR}/${APP_NAME}_${VERSION}_${ARCH}"
DEB_PATH="${DIST_DIR}/${APP_NAME}_${VERSION}_${ARCH}.deb"

if [[ ! -d "${BUNDLE_DIR}" ]]; then
  echo "Linux bundle not found at ${BUNDLE_DIR}. Run: flutter build linux --release"
  exit 1
fi

mkdir -p "${PKG_DIR}/DEBIAN"
mkdir -p "${PKG_DIR}/opt/${APP_NAME}"
mkdir -p "${PKG_DIR}/usr/share/applications"
mkdir -p "${PKG_DIR}/usr/share/icons/hicolor/256x256/apps"

cp -R "${BUNDLE_DIR}/"* "${PKG_DIR}/opt/${APP_NAME}/"
cp "windows/runner/resources/app_icon.png" "${PKG_DIR}/usr/share/icons/hicolor/256x256/apps/${APP_NAME}.png"

cat > "${PKG_DIR}/DEBIAN/control" <<EOF
Package: ${APP_NAME}
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: ${ARCH}
Maintainer: Femux Contributors <opensource@femux.dev>
Depends: libgtk-3-0, libstdc++6
Description: Femux desktop terminal workspace
 Multi-pane, multi-tab terminal workspace built with Flutter.
EOF

cat > "${PKG_DIR}/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
chmod +x /opt/${APP_NAME}/${APP_NAME} || true
EOF
chmod 755 "${PKG_DIR}/DEBIAN/postinst"

cat > "${PKG_DIR}/usr/share/applications/${APP_NAME}.desktop" <<EOF
[Desktop Entry]
Name=Femux
Comment=Desktop terminal workspace
Exec=/opt/${APP_NAME}/${APP_NAME}
Icon=${APP_NAME}
Terminal=false
Type=Application
Categories=Utility;Development;
StartupWMClass=femux
EOF

mkdir -p "${DIST_DIR}"
dpkg-deb --build --root-owner-group "${PKG_DIR}" "${DEB_PATH}"
rm -rf "${PKG_DIR}"

echo "Created ${DEB_PATH}"

#!/bin/bash
# Build Signloader.app from the SwiftPM executable target.
#
#   ./build.sh              release build -> build/Signloader.app
#   ./build.sh debug        debug build
#   ./build.sh run          build + launch
#   ./build.sh install      build + copy to /Applications
#   ./build.sh icon         regenerate Resources/AppIcon.icns only
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Signloader"
BUNDLE_ID="dev.local.signloader"
VERSION="1.0.0"
ICON_SRC="Tools/make-icon.swift"
ICON_ICNS="Resources/AppIcon.icns"
APP_DIR="build/${APP_NAME}.app"

# ---------------------------------------------------------------- icon ------

make_icon() {
  [ -f "$ICON_SRC" ] || return 0
  # Regenerate only when the source is newer than the last .icns.
  if [ -f "$ICON_ICNS" ] && [ "$ICON_ICNS" -nt "$ICON_SRC" ]; then
    return 0
  fi
  echo "==> icon"
  local work
  work="$(mktemp -d)"
  swift "$ICON_SRC" "$work/AppIcon.iconset" >/dev/null
  # Assert the geometry before shipping it: nothing may touch the canvas edge
  # (i.e. get clipped), the glyph ink must be centred, the badge must stay
  # inside the squircle.
  python3 Tools/check-icon.py "$work/AppIcon.iconset/icon_512x512@2x.png" | sed 's/^/   /'
  mkdir -p "$(dirname "$ICON_ICNS")"
  iconutil -c icns "$work/AppIcon.iconset" -o "$ICON_ICNS"
  rm -rf "$work"
  echo "   $ICON_ICNS ($(du -h "$ICON_ICNS" | cut -f1 | tr -d ' '))"
}

# ---------------------------------------------------------------- build -----

build() {
  local config="$1"

  echo "==> swift build -c ${config}"
  swift build -c "$config"

  local bin
  bin="$(swift build -c "$config" --show-bin-path)/${APP_NAME}"
  [ -x "$bin" ] || { echo "executable not found at $bin"; exit 1; }

  make_icon

  rm -rf "$APP_DIR"
  mkdir -p "${APP_DIR}/Contents/MacOS"
  mkdir -p "${APP_DIR}/Contents/Resources"
  cp "$bin" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
  [ -f "$ICON_ICNS" ] && cp "$ICON_ICNS" "${APP_DIR}/Contents/Resources/"

  cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <!-- CFBundleIconFile points at the .icns in Resources. Do NOT set
         CFBundleIconName here: that key names an Asset Catalog icon, and when
         macOS cannot resolve it wraps the real icon in a grey placeholder. -->
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Local dev tool</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>iOS Application Archive</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>dev.local.signloader.ipa</string>
            </array>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>dev.local.signloader.ipa</string>
            <key>UTTypeDescription</key><string>iOS Application Archive</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.zip-archive</string>
                <string>public.data</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array><string>ipa</string></array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
PLIST

  # Ad-hoc sign: a stable signature keeps Gatekeeper from re-prompting when only
  # the binary changes, and the signature must cover Resources/AppIcon.icns.
  echo "==> codesign (ad-hoc)"
  codesign --force --sign - --timestamp=none "${APP_DIR}" >/dev/null 2>&1 || \
    echo "   (ad-hoc signing skipped)"

  # Re-register so LaunchServices picks up the document type and the new icon
  # (`open -a Signloader.app foo.ipa` needs this to reach the app).
  local lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  [ -x "$lsregister" ] && "$lsregister" -f "$(pwd)/${APP_DIR}" || true

  echo "==> built ${APP_DIR}"
}

# -------------------------------------------------------------- dispatch ----

case "${1:-release}" in
  icon)    make_icon ;;
  run)     build release; open "$APP_DIR" ;;
  install) build release
           target="/Applications/${APP_NAME}.app"
           echo "==> install → ${target}"
           rm -rf "$target"
           ditto "$APP_DIR" "$target"
           lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
           [ -x "$lsregister" ] && "$lsregister" -f "$target" || true
           echo "   installed ${target}" ;;
  *)       build "${1:-release}" ;;
esac

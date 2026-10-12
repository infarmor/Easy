#!/usr/bin/env bash
# Packs build/Easy.app into a drag-to-Applications disk image, and checks the result the way the Mac it
# lands on would: signature valid through the image, arm64 only, and every library it names resolvable.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Easy.app"
BIN="Contents/MacOS/SwiftLite"
STAGING="build/dmg-staging"

if [[ ! -f "$APP/$BIN" ]]; then
  echo "Нет $APP — сначала ./build.sh" >&2
  exit 1
fi

# A dmg of a stale binary is the most misleading artifact possible: it installs and opens fine.
STALE=$(find Sources -name '*.swift' -newer "$APP/$BIN" -print -quit)
if [[ -n "$STALE" ]]; then
  echo "Бинарь старше исходников (например $STALE) — сначала ./build.sh" >&2
  exit 1
fi

python3 tools/check-bundle.py "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/Easy-$VERSION.dmg"

rm -rf "$STAGING"
mkdir -p "$STAGING"
# ditto, not cp: it keeps the code signature and the symlinks inside the framework bundle.
ditto "$APP" "$STAGING/Easy.app"
ln -s /Applications "$STAGING/Applications"

codesign --verify --deep --strict --verbose=1 "$STAGING/Easy.app"

rm -f "$DMG"
hdiutil create -volname "Easy $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG" > /dev/null
hdiutil verify "$DMG" > /dev/null
rm -rf "$STAGING"

# Read the app back out of the mounted image: what is verified here is what the dmg really carries.
MOUNT=$(hdiutil attach -nobrowse -readonly "$DMG" | awk -F'\t' '/\/Volumes\//{print $NF; exit}')
trap 'hdiutil detach "$MOUNT" -force > /dev/null 2>&1 || true' EXIT
codesign --verify --deep --strict --verbose=1 "$MOUNT/Easy.app"
python3 tools/check-bundle.py "$MOUNT/Easy.app"
echo "архитектура: $(lipo -archs "$MOUNT/Easy.app/$BIN")"

echo "Готово: $DMG ($(du -h "$DMG" | cut -f1))"

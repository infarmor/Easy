#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# The TDLib built into vendor/tdlib is the one the code targets; Homebrew only has the outdated 1.8.0.
if [[ -z "${TDLIB_PREFIX:-}" ]]; then
  if [[ -f vendor/tdlib/lib/libtdjson.dylib ]]; then
    TDLIB_PREFIX="$PWD/vendor/tdlib"
  else
    TDLIB_PREFIX=/opt/homebrew/opt/tdlib
  fi
fi
export TDLIB_PREFIX
# The bundle carries the new name; the identifier and the data folder stay, so the session survives.
APP="build/iGram.app"
BIN="SwiftLite"

swift build -c release --arch arm64
BIN_DIR=$(swift build -c release --arch arm64 --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp "$BIN_DIR/$BIN" "$APP/Contents/MacOS/$BIN"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
mkdir -p "$APP/Contents/Resources"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
cp Resources/container-migration.plist "$APP/Contents/Resources/container-migration.plist"

# Bundle libtdjson so the app does not depend on Homebrew keeping the same prefix.
cp -L "$TDLIB_PREFIX/lib/libtdjson.dylib" "$APP/Contents/Frameworks/libtdjson.dylib"
chmod u+w "$APP/Contents/Frameworks/libtdjson.dylib"
install_name_tool -id @rpath/libtdjson.dylib "$APP/Contents/Frameworks/libtdjson.dylib"

RECORDED=$(otool -L "$APP/Contents/MacOS/$BIN" | awk '/libtdjson/{print $1; exit}')
if [[ -n "$RECORDED" ]]; then
  install_name_tool -change "$RECORDED" @rpath/libtdjson.dylib "$APP/Contents/MacOS/$BIN"
fi
# Development rpaths (build folders, vendor/tdlib, TDLIB_PREFIX, and the Xcode toolchain paths `swift build`
# leaves behind) come first in the search order and must not outrank the copies bundled into Frameworks.
# An absolute rpath other than the OS Swift directory can only point at this machine's dev tools; nothing in
# the bundle resolves through it, because every Swift library is referenced as /usr/lib/swift/... directly.
for RPATH in $(otool -l "$APP/Contents/MacOS/$BIN" | awk '$1 == "cmd" && $2 == "LC_RPATH" {getline; getline; print $2}'); do
  if [[ "$RPATH" == "$PWD"* || "$RPATH" == "$TDLIB_PREFIX"* || ( "$RPATH" == /* && "$RPATH" != "/usr/lib/swift" ) ]]; then
    install_name_tool -delete_rpath "$RPATH" "$APP/Contents/MacOS/$BIN"
  fi
done
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/$BIN"

# Lottie (animated stickers) comes as a universal framework; the app is arm64-only, so the Intel half is dropped.
LOTTIE_BIN="$APP/Contents/Frameworks/Lottie.framework/Versions/A/Lottie"
ditto "$BIN_DIR/Lottie.framework" "$APP/Contents/Frameworks/Lottie.framework"
lipo -thin arm64 "$LOTTIE_BIN" -output "$LOTTIE_BIN.arm64"
mv "$LOTTIE_BIN.arm64" "$LOTTIE_BIN"

if otool -L "$APP/Contents/MacOS/$BIN" "$APP/Contents/Frameworks/libtdjson.dylib" | grep -q /opt/homebrew; then
  echo "Внимание: бандл ссылается на библиотеки Homebrew и не запустится без них" >&2
fi

codesign --force --sign - "$APP/Contents/Frameworks/libtdjson.dylib"
codesign --force --sign - "$APP/Contents/Frameworks/Lottie.framework"
# Sandboxed: the entitlements go on the app itself; the bundled libraries inherit its sandbox.
codesign --force --sign - --entitlements Resources/iGram.entitlements "$APP"

echo "Собрано: $APP (TDLib из $TDLIB_PREFIX)"

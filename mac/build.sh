#!/bin/bash
# Builds the macOS app with the Swift command-line toolchain (no Xcode required).
#   ./mac/build.sh          release build
#   ./mac/build.sh debug    fast build, no optimisation
#   ./mac/build.sh run      build then launch the app
# Compiles mac/Sources and shared/Sources together. Every .swift in those
# two directories is part of the binary.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
APP="$ROOT/build/SysMon.app"
BIN_DIR="$ROOT/build/.sysmon-bin"
NAME="SysMon"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
MODE="${1:-release}"

MARKETING_VERSION="${MARKETING_VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

OPT="-O"
[ "$MODE" = "debug" ] && OPT="-Onone"

rm -rf "$APP"
rm -rf "$BIN_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$BIN_DIR"
trap 'rm -rf "$BIN_DIR"' EXIT

echo "→ compiling ($MODE) $MARKETING_VERSION ($BUILD_NUMBER)"
# Releases ship one DMG per architecture; the default keeps local release
# builds universal, debug builds native-only for speed.
ARCHES=(${BUILD_ARCHS:-arm64 x86_64})
[ "$MODE" = "debug" ] && ARCHES=("$(uname -m)")
for ARCH in "${ARCHES[@]}"; do
    echo "→ compiling $ARCH"
    swiftc $OPT -parse-as-library -swift-version 5 \
        -target "${ARCH}-apple-macosx26.0" \
        -sdk "$SDK" \
        "$ROOT"/Sources/*.swift \
        "$REPO"/shared/Sources/*.swift \
        -o "$BIN_DIR/$NAME-$ARCH"
done
if [ "${#ARCHES[@]}" -gt 1 ]; then
    lipo -create "$BIN_DIR/$NAME-arm64" "$BIN_DIR/$NAME-x86_64" \
        -output "$APP/Contents/MacOS/$NAME"
    lipo -info "$APP/Contents/MacOS/$NAME" | grep -Eq 'arm64.*x86_64|x86_64.*arm64'
else
    cp "$BIN_DIR/$NAME-${ARCHES[0]}" "$APP/Contents/MacOS/$NAME"
fi

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
[ -f "$REPO/LICENSE" ] && cp "$REPO/LICENSE" "$APP/Contents/Resources/LICENSE.txt"

printf 'APPL????' > "$APP/Contents/PkgInfo"

IDENTITY="${CODESIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP" && echo "✓ signature valid"

echo "✓ built $APP"

if [ "$MODE" = "run" ] || [ "${2:-}" = "run" ]; then
    pkill -x "$NAME" 2>/dev/null || true
    sleep 0.4
    open "$APP"
    echo "✓ launched"
fi

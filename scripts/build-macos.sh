#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
HOST_TARGET="$(rustc -vV | awk '/^host:/{print $2}')"

export MACOSX_DEPLOYMENT_TARGET=14.0
mkdir -p "$ROOT/apps/macos/Vendor"

if [[ "${1:-}" == "--universal" ]]; then
  rustup target add aarch64-apple-darwin x86_64-apple-darwin
  cargo build --release -p olico-ffi --target aarch64-apple-darwin
  cargo build --release -p olico-ffi --target x86_64-apple-darwin
  lipo -create \
    "$ROOT/target/aarch64-apple-darwin/release/libolico_ffi.a" \
    "$ROOT/target/x86_64-apple-darwin/release/libolico_ffi.a" \
    -output "$ROOT/apps/macos/Vendor/libolico_ffi.a"
  swift build --package-path "$ROOT/apps/macos" -c release --arch arm64 --arch x86_64
  BIN_DIR="$(swift build --package-path "$ROOT/apps/macos" -c release --arch arm64 --arch x86_64 --show-bin-path)"
  BINARY="$BIN_DIR/Olico"
else
  cargo build --release -p olico-ffi --target "$HOST_TARGET"
  cp "$ROOT/target/$HOST_TARGET/release/libolico_ffi.a" "$ROOT/apps/macos/Vendor/libolico_ffi.a"
  swift build --package-path "$ROOT/apps/macos" -c release
  BIN_DIR="$(swift build --package-path "$ROOT/apps/macos" -c release --show-bin-path)"
  BINARY="$BIN_DIR/Olico"
fi

APP="$ROOT/build/Olico.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Olico"
for bundle in "$BIN_DIR"/*.bundle; do
  [[ -e "$bundle" ]] && cp -R "$bundle" "$APP/Contents/Resources/"
done
sed "s/__VERSION__/$VERSION/g" "$ROOT/apps/macos/Resources/Info.plist" > "$APP/Contents/Info.plist"

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --sign "$CODESIGN_IDENTITY" "$APP"
else
  # TCC keys grants to the designated requirement. Ad-hoc signing defaults to
  # a cdhash requirement that changes on every rebuild, so user-granted
  # Accessibility/Screen Recording permission silently stops matching. Pin the
  # requirement to the bundle identifier so grants survive rebuilds.
  codesign --force --sign - -r "=designated => identifier \"$BUNDLE_ID\"" "$APP"
fi
echo "Built $APP"

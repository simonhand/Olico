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
  BINARY="$(swift build --package-path "$ROOT/apps/macos" -c release --arch arm64 --arch x86_64 --show-bin-path)/Olico"
else
  cargo build --release -p olico-ffi --target "$HOST_TARGET"
  cp "$ROOT/target/$HOST_TARGET/release/libolico_ffi.a" "$ROOT/apps/macos/Vendor/libolico_ffi.a"
  swift build --package-path "$ROOT/apps/macos" -c release
  BINARY="$(swift build --package-path "$ROOT/apps/macos" -c release --show-bin-path)/Olico"
fi

APP="$ROOT/build/Olico.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Olico"
sed "s/__VERSION__/$VERSION/g" "$ROOT/apps/macos/Resources/Info.plist" > "$APP/Contents/Info.plist"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --sign "$CODESIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "Built $APP"

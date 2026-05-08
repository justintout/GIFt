#!/usr/bin/env bash
set -euo pipefail

# Build and package GIFt.app (universal by default).
# Usage: scripts/build_app.sh [--arm64-only]

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="GIFt"
APP_BUNDLE="$ROOT/dist/${APP_NAME}.app"
ZIP_PATH="$ROOT/dist/${APP_NAME}.zip"
BUILD_VERSION="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)"

mkdir -p "$ROOT/dist"

ARCH_FLAGS=(--arch arm64 --arch x86_64)
if [[ "${1:-}" == "--arm64-only" ]]; then
  ARCH_FLAGS=(--arch arm64)
fi

echo "==> Building release binary (${ARCH_FLAGS[*]})"
swift build -c release "${ARCH_FLAGS[@]}"

# Locate the built binary (universal builds land in .build/apple/...).
BIN_CANDIDATES=(
  "$ROOT/.build/apple/Products/Release/gift"
  "$ROOT/.build/arm64-apple-macosx/release/gift"
  "$ROOT/.build/x86_64-apple-macosx/release/gift"
)

BIN_PATH=""
for path in "${BIN_CANDIDATES[@]}"; do
  if [[ -x "$path" ]]; then
    BIN_PATH="$path"
    break
  fi
done

if [[ -z "$BIN_PATH" ]]; then
  echo "Failed to find built binary." >&2
  exit 1
fi

echo "==> Staging app bundle at $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cat > "$APP_BUNDLE/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>GIFt</string>
  <key>CFBundleIdentifier</key><string>com.justintout.gift</string>
  <key>CFBundleExecutable</key><string>GIFt</string>
  <key>CFBundleVersion</key><string>__BUILD_VERSION__</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
perl -pi -e "s/__BUILD_VERSION__/$BUILD_VERSION/g" "$APP_BUNDLE/Contents/Info.plist"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/GIFt"
chmod +x "$APP_BUNDLE/Contents/MacOS/GIFt"

echo "==> Ad-hoc signing"
codesign --deep --force --sign - "$APP_BUNDLE"

echo "==> Creating zip: $ZIP_PATH"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "Done."
echo "Zip to share: $ZIP_PATH"
echo "Unsigned: recipients should Control-click > Open on first launch."

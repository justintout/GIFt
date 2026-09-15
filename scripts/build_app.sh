#!/usr/bin/env bash
set -euo pipefail

# Build and package GIFt.app (universal by default).
#
# Signing identity, in order of precedence: $GIFT_SIGN_IDENTITY, then the first Developer ID
# Application identity in the keychain, then ad-hoc. Ad-hoc builds run locally but make recipients
# approve the app by hand, and macOS invalidates their Screen Recording grant on every rebuild.
#
# Usage:
#   scripts/build_app.sh [--arm64-only] [--notarize]

usage() {
  awk '
    /^# Build/ { printing = 1 }
    printing && /^#/ { sub(/^# ?/, ""); print; next }
    printing && !/^#/ { exit }
  ' "$0"
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="GIFt"
APP_BUNDLE="$ROOT/dist/${APP_NAME}.app"
ZIP_PATH="$ROOT/dist/${APP_NAME}.zip"
BUILD_VERSION="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)"
NOTARY_PROFILE="${GIFT_NOTARY_PROFILE:-gift-notary}"

mkdir -p "$ROOT/dist"

ARCH_FLAGS=(--arch arm64 --arch x86_64)
BIN_CANDIDATES=(
  "$ROOT/.build/apple/Products/Release/gift"
  "$ROOT/.build/arm64-apple-macosx/release/gift"
  "$ROOT/.build/x86_64-apple-macosx/release/gift"
)
NOTARIZE=false

for arg in "$@"; do
  case "$arg" in
    --arm64-only)
      ARCH_FLAGS=(--arch arm64)
      BIN_CANDIDATES=(
        "$ROOT/.build/arm64-apple-macosx/release/gift"
      )
      ;;
    --notarize)
      NOTARIZE=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# Ad-hoc signing cannot be notarized, so pick the identity before deciding what is possible.
SIGN_IDENTITY="${GIFT_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ { print $2; exit }')"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="-"
fi

if [[ "$NOTARIZE" == true && "$SIGN_IDENTITY" == "-" ]]; then
  echo "--notarize needs a Developer ID Application identity." >&2
  echo "Set GIFT_SIGN_IDENTITY, or create the certificate in Xcode > Settings > Accounts." >&2
  exit 2
fi

echo "==> Building release binary (${ARCH_FLAGS[*]})"
swift build -c release "${ARCH_FLAGS[@]}"

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
echo "==> Using binary: $BIN_PATH"

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

# No --deep: the bundle carries no nested code, and Apple recommends against it.
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "==> Signing ad-hoc (no Developer ID identity found)"
  echo "    Recipients must approve this by hand, and macOS will drop the Screen Recording"
  echo "    grant whenever the binary changes. Set GIFT_SIGN_IDENTITY to sign properly."
  codesign --force --sign - "$APP_BUNDLE"
else
  echo "==> Signing with: $SIGN_IDENTITY"
  # Hardened runtime and a secure timestamp are both required for notarization.
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
fi

codesign --verify --strict "$APP_BUNDLE"

create_zip() {
  rm -f "$ZIP_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
}

echo "==> Creating zip: $ZIP_PATH"
create_zip

if [[ "$NOTARIZE" == true ]]; then
  echo "==> Submitting for notarization with profile '$NOTARY_PROFILE' (takes a few minutes)"
  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

  echo "==> Stapling the ticket to the app"
  xcrun stapler staple "$APP_BUNDLE"

  # Re-zip so the archive carries the stapled ticket and validates without a network round trip.
  create_zip
fi

echo "Done."
echo "Zip to share: $ZIP_PATH"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "Signature: ad-hoc — recipients should Control-click > Open on first launch."
elif [[ "$NOTARIZE" == true ]]; then
  echo "Signature: Developer ID, notarized and stapled — this opens with a plain double-click."
  spctl --assess --type execute --verbose=2 "$APP_BUNDLE" 2>&1 || true
else
  echo "Signature: Developer ID, not notarized — Gatekeeper will still block recipients."
  echo "Re-run with --notarize before sharing this build."
fi

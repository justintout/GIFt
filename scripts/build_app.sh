#!/usr/bin/env bash
set -euo pipefail

# Build and package GIFt.app (universal by default).
#
# Signing identity, in order of precedence: $GIFT_SIGN_IDENTITY, then the first Developer ID
# Application identity in the keychain, then ad-hoc. Ad-hoc builds run locally but make recipients
# approve the app by hand, and macOS invalidates their Screen Recording grant on every rebuild.
#
# The version comes from --version (calendar style, YYYY.M.N) and is required with --notarize, so
# a release cannot ship unversioned. Local builds without it are 0.0.0. The build number is the
# commit count, which only grows because history is kept linear.
#
# Usage:
#   scripts/build_app.sh [--arm64-only] [--version YYYY.M.N] [--notarize]

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
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD)"
VERSION="0.0.0"
NOTARY_PROFILE="${GIFT_NOTARY_PROFILE:-gift-notary}"

mkdir -p "$ROOT/dist"

ARCH_FLAGS=(--arch arm64 --arch x86_64)
BIN_CANDIDATES=(
  "$ROOT/.build/apple/Products/Release/gift"
  "$ROOT/.build/arm64-apple-macosx/release/gift"
  "$ROOT/.build/x86_64-apple-macosx/release/gift"
)
NOTARIZE=false

while [[ $# -gt 0 ]]; do
  arg="$1"
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
    --version)
      VERSION="${2:-}"
      if [[ ! "$VERSION" =~ ^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$ ]]; then
        echo "--version needs a calendar version like 2026.10.1, got '$VERSION'." >&2
        exit 2
      fi
      shift
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
  shift
done

if [[ "$NOTARIZE" == true && "$VERSION" == "0.0.0" ]]; then
  echo "--notarize needs --version, so a release cannot ship unversioned." >&2
  exit 2
fi

# Ad-hoc signing cannot be notarized, so pick the identity before deciding what is possible.
SIGN_IDENTITY="${GIFT_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '!found && /Developer ID Application/ { print $2; found = 1 }')"
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
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleVersion</key><string>__BUILD_NUMBER__</string>
  <key>CFBundleShortVersionString</key><string>__VERSION__</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
perl -pi -e "s/__BUILD_NUMBER__/$BUILD_NUMBER/g; s/__VERSION__/$VERSION/g" "$APP_BUNDLE/Contents/Info.plist"
cp "$ROOT/Packaging/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

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
  echo "Signature: ad-hoc — recipients must approve it by hand, and macOS drops the"
  echo "           Screen Recording grant every time the binary changes."
elif [[ "$SIGN_IDENTITY" != *"Developer ID Application"* ]]; then
  echo "Signature: $SIGN_IDENTITY"
  echo "           A development signature. Stable across rebuilds, so permissions stick"
  echo "           locally, but Gatekeeper blocks it for anyone else."
elif [[ "$NOTARIZE" == true ]]; then
  echo "Signature: Developer ID, notarized and stapled — opens with a plain double-click."
  spctl --assess --type execute --verbose=2 "$APP_BUNDLE" 2>&1 || true
else
  echo "Signature: Developer ID, not notarized — Gatekeeper will still block recipients."
  echo "Re-run with --notarize before sharing this build."
fi

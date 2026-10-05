#!/usr/bin/env bash
set -euo pipefail

# Package dist/GIFt.app into dist/GIFt-<version>.dmg, then sign it with the identity that signed
# the app, notarize it, and staple the ticket. Run scripts/build_app.sh --version <v> --notarize
# first. Writes a .sha256 beside the image for the release page.
#
# Usage:
#   scripts/make_dmg.sh <version>

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
APP_BUNDLE="$ROOT/dist/GIFt.app"
DMG_PATH="$ROOT/dist/GIFt-${VERSION}.dmg"
NOTARY_PROFILE="${GIFT_NOTARY_PROFILE:-gift-notary}"
DMGBUILD_VENV="$ROOT/.build/dmgbuild"
DMGBUILD_VERSION="1.6.7"

if [[ ! "$VERSION" =~ ^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$ ]]; then
  echo "Usage: scripts/make_dmg.sh <version>, for example 2026.10.1" >&2
  exit 2
fi
if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "No app at $APP_BUNDLE. Run scripts/build_app.sh --version $VERSION --notarize first." >&2
  exit 1
fi
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
if [[ "$BUNDLE_VERSION" != "$VERSION" ]]; then
  echo "dist/GIFt.app is version $BUNDLE_VERSION, not $VERSION. Rebuild it first." >&2
  exit 1
fi
# The image must be signed by the same identity as the app inside it.
# awk reads to the end rather than exiting at the first match: an early exit breaks the pipe,
# and with pipefail that ends the script silently.
SIGN_IDENTITY="$(codesign -dvv "$APP_BUNDLE" 2>&1 | awk -F= '!found && /^Authority=/ { print $2; found = 1 }')"
if [[ "$SIGN_IDENTITY" != Developer\ ID\ Application* ]]; then
  echo "dist/GIFt.app is not signed with a Developer ID identity (found '${SIGN_IDENTITY:-none}')." >&2
  exit 1
fi

if [[ ! -x "$DMGBUILD_VENV/bin/dmgbuild" ]]; then
  echo "==> Installing dmgbuild $DMGBUILD_VERSION into $DMGBUILD_VENV"
  python3 -m venv "$DMGBUILD_VENV"
  "$DMGBUILD_VENV/bin/pip" install --quiet "dmgbuild==$DMGBUILD_VERSION"
fi

echo "==> Building $DMG_PATH"
rm -f "$DMG_PATH"
"$DMGBUILD_VENV/bin/dmgbuild" \
  -s "$ROOT/Packaging/dmg_settings.py" \
  -D app="$APP_BUNDLE" \
  -D icon="$ROOT/Packaging/AppIcon.icns" \
  -D background="$ROOT/Packaging/dmg-background.png" \
  "GIFt" "$DMG_PATH"

echo "==> Signing with: $SIGN_IDENTITY"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"

echo "==> Submitting for notarization with profile '$NOTARY_PROFILE' (takes a few minutes)"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"

(cd "$ROOT/dist" && shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$DMG_PATH").sha256")
echo "Done: $DMG_PATH"

#!/usr/bin/env bash
set -euo pipefail

# Rebuild GIFt and launch it as close to a first-run user state as macOS allows.
# This resets GIFt's Screen Recording TCC decision and its UserDefaults domain.
#
# Usage:
#   scripts/dev_fresh_launch.sh [--skip-build] [--no-reset-defaults] [--no-launch] [--universal]

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="GIFt"
BUNDLE_ID="com.justintout.gift"
APP_BUNDLE="$ROOT/dist/${APP_NAME}.app"

skip_build=false
reset_defaults=true
launch_app=true
build_arg=(--arm64-only)

usage() {
  awk '
    /^# Rebuild/ { printing = 1 }
    printing && /^#/ { sub(/^# ?/, ""); print; next }
    printing && !/^#/ { exit }
  ' "$0"
}

for arg in "$@"; do
  case "$arg" in
    --skip-build)
      skip_build=true
      ;;
    --no-reset-defaults)
      reset_defaults=false
      ;;
    --no-launch)
      launch_app=false
      ;;
    --universal)
      build_arg=()
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

echo "==> Quitting any running $APP_NAME instance"
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
pkill -x gift >/dev/null 2>&1 || true

if [[ "$skip_build" == false ]]; then
  echo "==> Rebuilding app bundle"
  "$ROOT/scripts/build_app.sh" "${build_arg[@]}"
elif [[ ! -d "$APP_BUNDLE" ]]; then
  echo "App bundle does not exist: $APP_BUNDLE" >&2
  echo "Run without --skip-build first." >&2
  exit 1
fi

echo "==> Resetting Screen Recording permission for $BUNDLE_ID"
if ! tccutil reset ScreenCapture "$BUNDLE_ID"; then
  echo "Warning: tccutil could not reset Screen Recording for $BUNDLE_ID" >&2
  echo "You may need to remove GIFt manually from System Settings > Privacy & Security > Screen & System Audio Recording." >&2
fi

if [[ "$reset_defaults" == true ]]; then
  echo "==> Resetting GIFt UserDefaults"
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  rm -rf "$HOME/Library/Saved Application State/${BUNDLE_ID}.savedState"
fi

if [[ "$launch_app" == true ]]; then
  echo "==> Launching $APP_BUNDLE"
  open -n "$APP_BUNDLE"
fi

echo "Done."

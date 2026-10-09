#!/usr/bin/env bash
# Builds a guest app (an xcodegen project under GuestApps/) as an arm64
# simulator .ipa that Hermex installs into its embedded LiveContainer.
#
#   scripts/build-guest-ipa.sh GuestApps/LiftLog [output.ipa]
set -euo pipefail

APP_DIR="$(cd "${1:?usage: build-guest-ipa.sh GuestApps/<App> [output.ipa]}" && pwd)"
NAME="$(basename "$APP_DIR")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_PATH="${2:-$ROOT/.build/guest-apps/$NAME.ipa}"
DERIVED="$ROOT/.build/guest-apps/DerivedData-$NAME"

command -v xcodegen >/dev/null || { echo "xcodegen is required (brew install xcodegen)" >&2; exit 1; }
xcodegen generate --quiet --spec "$APP_DIR/project.yml" --project "$APP_DIR"

xcodebuild -quiet \
  -project "$APP_DIR/$NAME.xcodeproj" \
  -scheme "$NAME" \
  -configuration Release \
  -sdk iphonesimulator \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath "$DERIVED" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  build

APP="$(find "$DERIVED/Build/Products/Release-iphonesimulator" -maxdepth 1 -name '*.app' | head -n 1)"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/hermex-guest.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload" "$(dirname "$OUTPUT_PATH")"
cp -R "$APP" "$STAGE/Payload/"
rm -f "$OUTPUT_PATH"
(cd "$STAGE" && /usr/bin/zip -qry "$OUTPUT_PATH" Payload)
printf '%s\n' "$OUTPUT_PATH"

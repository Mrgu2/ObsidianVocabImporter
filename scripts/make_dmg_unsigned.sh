#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Build an unsigned Release .app via xcodebuild archive, then wrap it into a drag-install DMG.
# This does NOT codesign or notarize. Gatekeeper will likely warn on other machines.
#
# Usage:
#   ./scripts/make_dmg_unsigned.sh
#   ./scripts/make_dmg_unsigned.sh --out /path/to/dist
#

PROJECT_REL="ObsidianVocabImporter.xcodeproj"
SCHEME="ObsidianVocabImporter"
CONFIG="Release"
VOLNAME="Obsidian Vocab Importer"
OUT_DIR=""

usage() {
  cat <<'EOF'
Usage:
  ./scripts/make_dmg_unsigned.sh [--out /path/to/dist]
EOF
}

die() { echo "Error: $*" >&2; exit 2; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing tool: $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT_DIR="${2:-}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) die "Unknown arg: $1";;
  esac
done

need_cmd xcodebuild
need_cmd hdiutil
need_cmd find

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT/$PROJECT_REL"
[[ -d "$PROJECT_PATH" ]] || die "Project not found: $PROJECT_PATH"

if [[ -z "$OUT_DIR" ]]; then
  TS="$(date +%Y%m%d-%H%M%S)"
  OUT_DIR="$ROOT/dist/unsigned-$TS"
fi
mkdir -p "$OUT_DIR"

WORK="$(mktemp -d "/tmp/ovi-unsigned-dmg-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

ARCHIVE_PATH="$WORK/ObsidianVocabImporter.xcarchive"

echo "== Build archive (unsigned) =="
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -archivePath "$ARCHIVE_PATH" \
  archive \
  SKIP_INSTALL=NO \
  BUILD_LIBRARY_FOR_DISTRIBUTION=NO

APP_SRC_DIR="$ARCHIVE_PATH/Products/Applications"
APP_PATH="$(find "$APP_SRC_DIR" -maxdepth 1 -name '*.app' -print -quit || true)"
[[ -n "$APP_PATH" ]] || die "Failed to find .app inside archive: $APP_SRC_DIR"

APP_NAME="$(basename "$APP_PATH")"

echo "== Stage DMG =="
STAGE="$WORK/dmg-stage"
mkdir -p "$STAGE"
cp -R "$APP_PATH" "$STAGE/$APP_NAME"
ln -s /Applications "$STAGE/Applications"

DMG_PATH="$OUT_DIR/${APP_NAME%.app}-unsigned.dmg"

echo "== Create DMG: $DMG_PATH =="
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGE" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "$DMG_PATH" >/dev/null

echo "== Output =="
echo "DMG: $DMG_PATH"


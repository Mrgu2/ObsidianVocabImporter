#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# One-click packaging + notarization for Obsidian Vocab Importer.
#
# This script is intentionally defensive (fail-fast) to avoid producing unusable artifacts.
#
# What it does (normal mode):
# 1) Build a Release archive via xcodebuild
# 2) Extract the .app from the archive
# 3) (Re)sign the .app with Hardened Runtime (Developer ID)
# 4) Create ZIP and/or DMG
# 5) Submit to Apple notarization (notarytool) and wait
# 6) Staple the ticket to the .app (and DMG when requested)
# 7) spctl -a -vv checks
# 8) Write dist/build-info.txt for support/debugging
#
# Dry run mode:
# - Only does archive + extract + (optional) resign + verify.
# - No packaging, no notarization, no stapling.
#
# Usage:
#   ./scripts/release_notarize.sh --format dmg
#   ./scripts/release_notarize.sh --dry-run
#
# Credentials:
#   Recommended (keychain profile):
#     export OVI_NOTARY_PROFILE="ovi-notary"
#     xcrun notarytool store-credentials "ovi-notary" --apple-id "you@example.com" --team-id "TEAMID" --password "xxxx-xxxx-xxxx-xxxx"
#
#   Optional (no profile):
#     export OVI_APPLE_ID="you@example.com"
#     export OVI_TEAM_ID="TEAMID"
#     export OVI_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"
#
# Signing:
#   export OVI_SIGN_ID="Developer ID Application: Your Name (TEAMID)"
#
# Notes:
# - Notarization requires a Developer ID-signed app with Hardened Runtime enabled.
# - This script assumes you do not ship through the Mac App Store.

FORMAT="zip" # zip|dmg|both
CONFIG="Release"
PROJECT_REL="ObsidianVocabImporter.xcodeproj"
SCHEME="ObsidianVocabImporter"
OUT_DIR=""
SKIP_NOTARIZE="0"
DRY_RUN="0"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/release_notarize.sh [--format zip|dmg|both] [--out /path/to/dist] [--skip-notarize] [--dry-run]

Environment (normal mode):
  Required:
    OVI_SIGN_ID            Developer ID Application identity for codesign
    OVI_NOTARY_PROFILE     notarytool keychain profile name
    OR OVI_APPLE_ID + OVI_TEAM_ID + OVI_APP_PASSWORD

Environment (dry run mode):
  Optional:
    OVI_SIGN_ID            If set, will re-sign; otherwise only verifies existing signature.

Examples:
  export OVI_SIGN_ID="Developer ID Application: Your Name (TEAMID)"
  export OVI_NOTARY_PROFILE="ovi-notary"
  ./scripts/release_notarize.sh --format dmg

  ./scripts/release_notarize.sh --dry-run
EOF
}

die() { echo "Error: $*" >&2; exit 2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing tool: $1"
}

need_xcrun_tool() {
  xcrun --find "$1" >/dev/null 2>&1 || die "Missing xcrun tool: $1"
}

timestamp() { date +"%Y-%m-%d %H:%M:%S"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --format) FORMAT="${2:-}"; shift 2;;
    --out) OUT_DIR="${2:-}"; shift 2;;
    --skip-notarize) SKIP_NOTARIZE="1"; shift 1;;
    --dry-run) DRY_RUN="1"; shift 1;;
    -h|--help) usage; exit 0;;
    *) die "Unknown arg: $1";;
  esac
done

case "$FORMAT" in zip|dmg|both) ;; *) die "Invalid --format: $FORMAT";; esac

# Tools (fail-fast).
need_cmd xcodebuild
need_cmd codesign
need_cmd spctl
need_cmd ditto
need_cmd hdiutil
need_cmd xcrun
need_xcrun_tool notarytool
need_xcrun_tool stapler

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT/$PROJECT_REL"
[[ -d "$PROJECT_PATH" ]] || die "Project not found: $PROJECT_PATH"

if [[ -z "$OUT_DIR" ]]; then
  TS="$(date +%Y%m%d-%H%M%S)"
  OUT_DIR="$ROOT/dist/$TS"
fi
mkdir -p "$OUT_DIR"

BUILD_INFO="$OUT_DIR/build-info.txt"

{
  echo "Obsidian Vocab Importer build info"
  echo "time: $(timestamp)"
  echo "root: $ROOT"
  echo "project: $PROJECT_REL"
  echo "scheme: $SCHEME"
  echo "configuration: $CONFIG"
  echo "format: $FORMAT"
  echo "dry_run: $DRY_RUN"
  echo "skip_notarize: $SKIP_NOTARIZE"
  echo
  echo "xcodebuild:"
  (xcodebuild -version || true) | sed 's/^/  /'
  echo
  echo "git:"
  if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "  commit: $(git -C "$ROOT" rev-parse HEAD)"
    echo "  status:"
    (git -C "$ROOT" status -sb || true) | sed 's/^/    /'
  else
    echo "  (not a git repo)"
  fi
  echo
  echo "signing:"
  echo "  OVI_SIGN_ID: ${OVI_SIGN_ID:-"(unset)"}"
  echo "notarization:"
  echo "  OVI_NOTARY_PROFILE: ${OVI_NOTARY_PROFILE:-"(unset)"}"
  echo "  OVI_APPLE_ID: ${OVI_APPLE_ID:-"(unset)"}"
  echo "  OVI_TEAM_ID: ${OVI_TEAM_ID:-"(unset)"}"
  echo "  OVI_APP_PASSWORD: ${OVI_APP_PASSWORD:+(set)}${OVI_APP_PASSWORD:-(unset)}"
  echo
} >"$BUILD_INFO"

WORK="$(mktemp -d "/tmp/ovi-release-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

ARCHIVE_PATH="$WORK/ObsidianVocabImporter.xcarchive"

echo "== Build archive ==" | tee -a "$BUILD_INFO"
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -archivePath "$ARCHIVE_PATH" \
  archive \
  SKIP_INSTALL=NO \
  BUILD_LIBRARY_FOR_DISTRIBUTION=NO | tee -a "$BUILD_INFO"

APP_SRC_DIR="$ARCHIVE_PATH/Products/Applications"
APP_PATH="$(find "$APP_SRC_DIR" -maxdepth 1 -name '*.app' -print -quit || true)"
[[ -n "$APP_PATH" ]] || die "Failed to find .app inside archive: $APP_SRC_DIR"

APP_NAME="$(basename "$APP_PATH")"
APP_STAGING="$WORK/$APP_NAME"
cp -R "$APP_PATH" "$APP_STAGING"

echo "app_name: $APP_NAME" >>"$BUILD_INFO"
echo "app_staging: $APP_STAGING" >>"$BUILD_INFO"

verify_signature() {
  local app="$1"
  echo "== Verify signature ==" | tee -a "$BUILD_INFO"
  if codesign --verify --deep --strict "$app" >/dev/null 2>&1; then
    echo "codesign_verify: ok" >>"$BUILD_INFO"
  else
    echo "codesign_verify: failed" >>"$BUILD_INFO"
    return 1
  fi
}

require_hardened_runtime() {
  local app="$1"
  # codesign -dv prints to stderr; we capture and search for "runtime" in options.
  local out
  out="$(codesign -dv --verbose=4 "$app" 2>&1 || true)"
  echo "codesign_details:" >>"$BUILD_INFO"
  echo "$out" | sed 's/^/  /' >>"$BUILD_INFO"
  echo "$out" | rg -q "Runtime Version|runtime" || return 1
}

if [[ "$DRY_RUN" == "0" && "$SKIP_NOTARIZE" == "0" ]]; then
  [[ -n "${OVI_SIGN_ID:-}" ]] || die "OVI_SIGN_ID is required for notarization."
  if [[ -z "${OVI_NOTARY_PROFILE:-}" ]]; then
    [[ -n "${OVI_APPLE_ID:-}" && -n "${OVI_TEAM_ID:-}" && -n "${OVI_APP_PASSWORD:-}" ]] || die "Notarization creds missing. Set OVI_NOTARY_PROFILE or OVI_APPLE_ID+OVI_TEAM_ID+OVI_APP_PASSWORD."
  fi
fi

if [[ -n "${OVI_SIGN_ID:-}" ]]; then
  echo "== Sign app (Hardened Runtime) ==" | tee -a "$BUILD_INFO"
  codesign --force --deep --options runtime --timestamp --sign "$OVI_SIGN_ID" "$APP_STAGING" | tee -a "$BUILD_INFO"
  verify_signature "$APP_STAGING" || die "codesign verify failed after signing."
else
  # In dry-run mode we allow verifying without resigning.
  if ! verify_signature "$APP_STAGING"; then
    echo "Warning: extracted app is not verifiable-signed. Set OVI_SIGN_ID to re-sign." | tee -a "$BUILD_INFO" >&2
    if [[ "$DRY_RUN" == "0" && "$SKIP_NOTARIZE" == "0" ]]; then
      die "Notarization requires a signed app. Set OVI_SIGN_ID."
    fi
  fi
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "== Dry run complete ==" | tee -a "$BUILD_INFO"
  echo "Output: $OUT_DIR"
  exit 0
fi

# Ensure Hardened Runtime is on before notarization.
if [[ "$SKIP_NOTARIZE" == "0" ]]; then
  require_hardened_runtime "$APP_STAGING" || die "Hardened Runtime not detected. Ensure codesign uses --options runtime and Xcode target enables Hardened Runtime."
fi

ZIP_PATH=""
DMG_PATH=""

make_zip() {
  local out="$1"
  echo "== Create ZIP ==" | tee -a "$BUILD_INFO"
  # Apple recommends ditto for zipping apps.
  ditto -c -k --sequesterRsrc --keepParent "$APP_STAGING" "$out" | tee -a "$BUILD_INFO"
  ZIP_PATH="$out"
}

make_dmg() {
  local out="$1"
  echo "== Create DMG ==" | tee -a "$BUILD_INFO"
  local vol="Obsidian Vocab Importer"
  local stage="$WORK/dmg-stage"
  mkdir -p "$stage"
  cp -R "$APP_STAGING" "$stage/$APP_NAME"
  ln -s /Applications "$stage/Applications"

  hdiutil create \
    -volname "$vol" \
    -srcfolder "$stage" \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$out" >/dev/null

  if [[ -n "${OVI_SIGN_ID:-}" ]]; then
    echo "== Sign DMG ==" | tee -a "$BUILD_INFO"
    codesign --force --timestamp --sign "$OVI_SIGN_ID" "$out" | tee -a "$BUILD_INFO"
  fi

  DMG_PATH="$out"
}

notarize() {
  local artifact="$1"
  [[ "$SKIP_NOTARIZE" == "0" ]] || return 0

  echo "== Notarize: $(basename "$artifact") ==" | tee -a "$BUILD_INFO"

  local json
  if [[ -n "${OVI_NOTARY_PROFILE:-}" ]]; then
    json="$(xcrun notarytool submit "$artifact" --keychain-profile "$OVI_NOTARY_PROFILE" --wait --output-format json)"
  else
    json="$(xcrun notarytool submit "$artifact" --apple-id "$OVI_APPLE_ID" --team-id "$OVI_TEAM_ID" --password "$OVI_APP_PASSWORD" --wait --output-format json)"
  fi

  echo "notarytool_submit_json:" >>"$BUILD_INFO"
  echo "$json" | sed 's/^/  /' >>"$BUILD_INFO"

  local id status
  id="$(python3 - <<PY\nimport json,sys\nj=json.load(sys.stdin)\nprint(j.get('id',''))\nPY\n<<<\"$json\")"
  status="$(python3 - <<PY\nimport json,sys\nj=json.load(sys.stdin)\nprint(j.get('status',''))\nPY\n<<<\"$json\")"
  echo "notary_submission_id: $id" >>"$BUILD_INFO"
  echo "notary_status: $status" >>"$BUILD_INFO"

  [[ "$status" == "Accepted" ]] || die "Notarization failed (status=$status). See $BUILD_INFO"
}

staple_app() {
  [[ "$SKIP_NOTARIZE" == "0" ]] || return 0
  echo "== Staple app ==" | tee -a "$BUILD_INFO"
  xcrun stapler staple "$APP_STAGING" | tee -a "$BUILD_INFO"
}

staple_dmg() {
  local dmg="$1"
  [[ "$SKIP_NOTARIZE" == "0" ]] || return 0
  echo "== Staple dmg ==" | tee -a "$BUILD_INFO"
  xcrun stapler staple "$dmg" | tee -a "$BUILD_INFO"
}

gatekeeper_assess() {
  local app="$1"
  echo "== Gatekeeper assess ==" | tee -a "$BUILD_INFO"
  (spctl -a -vv "$app" || true) | tee -a "$BUILD_INFO"
}

# Correct order:
# - Sign app
# - Package (zip/dmg)
# - Notarize packaged artifact
# - Staple app (+ dmg)
# - spctl verify
if [[ "$FORMAT" == "zip" || "$FORMAT" == "both" ]]; then
  make_zip "$OUT_DIR/ObsidianVocabImporter.zip"
  notarize "$ZIP_PATH"
  staple_app
fi

if [[ "$FORMAT" == "dmg" || "$FORMAT" == "both" ]]; then
  make_dmg "$OUT_DIR/ObsidianVocabImporter.dmg"
  notarize "$DMG_PATH"
  staple_app
  staple_dmg "$DMG_PATH"
fi

gatekeeper_assess "$APP_STAGING"

{
  echo
  echo "outputs:"
  echo "  out_dir: $OUT_DIR"
  echo "  build_info: $BUILD_INFO"
  [[ -n "$ZIP_PATH" ]] && echo "  zip: $ZIP_PATH"
  [[ -n "$DMG_PATH" ]] && echo "  dmg: $DMG_PATH"
} >>"$BUILD_INFO"

echo "== Output =="
echo "Dist: $OUT_DIR"
echo "build-info: $BUILD_INFO"
[[ -n "$ZIP_PATH" ]] && echo "ZIP: $ZIP_PATH"
[[ -n "$DMG_PATH" ]] && echo "DMG: $DMG_PATH"
echo "Done."


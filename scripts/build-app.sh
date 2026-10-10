#!/usr/bin/env bash
# build-app.sh — builds ScaleKit with SwiftPM and packages it as build/ScaleKit.app.
#
# Usage: scripts/build-app.sh [--debug] [--zip] [--install]
#
#   --debug     Build the debug configuration instead of release.
#   --zip       Also create build/ScaleKit-<version>.zip (ditto, signature-preserving).
#   --install   Copy the app to ~/Applications/ScaleKit.app, replacing any existing copy.
#
# Environment:
#   SCALEKIT_SCRATCH_PATH   SwiftPM scratch (build) directory. Default: <repo>/.build
#
# Only Command Line Tools are needed (no Xcode). The app is ad-hoc signed, which
# is all a locally built app needs; distributing it to other Macs without
# warnings requires a Developer ID signature and notarization.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="${SCALEKIT_SCRATCH_PATH:-$ROOT/.build}"
OUT="$ROOT/build"
APP="$OUT/ScaleKit.app"
PLIST="$ROOT/Resources/Info.plist"
ICON="$ROOT/Resources/AppIcon.icns"
BUNDLE_ID="com.shimantoneer.ScaleKit"

CONFIG="release"
DO_ZIP=0
DO_INSTALL=0

usage() { sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

for arg in "$@"; do
    case "$arg" in
        --debug) CONFIG="debug" ;;
        --zip) DO_ZIP=1 ;;
        --install) DO_INSTALL=1 ;;
        -h | --help) usage; exit 0 ;;
        *) echo "error: unknown option '$arg'" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ -t 1 ]]; then BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'; else BOLD=""; DIM=""; RESET=""; fi
step() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RESET"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- Preflight -------------------------------------------------------------

for tool in swift codesign plutil ditto; do
    command -v "$tool" >/dev/null 2>&1 || fail "'$tool' not found. Install the Command Line Tools: xcode-select --install"
done
[[ -f "$PLIST" ]] || fail "missing $PLIST"
[[ -f "$ICON" ]] || fail "missing $ICON (generate it with: swift scripts/make-icon.swift <work-dir> --icns Resources/AppIcon.icns)"
plutil -lint "$PLIST" >/dev/null || fail "Info.plist is not valid: $(plutil -lint "$PLIST")"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"

SWIFT_ARGS=(--package-path "$ROOT" --scratch-path "$SCRATCH" -c "$CONFIG")

echo "${BOLD}ScaleKit $VERSION ($BUILD_NUMBER)${RESET} — $CONFIG build"
echo "${DIM}package: $ROOT${RESET}"
echo "${DIM}scratch: $SCRATCH${RESET}"

# --- Build -----------------------------------------------------------------

for product in ScaleKit ScaleKitGuard scalekit-diag; do
    step "Building $product ($CONFIG)"
    swift build "${SWIFT_ARGS[@]}" --product "$product"
done

BIN="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"
for product in ScaleKit ScaleKitGuard scalekit-diag; do
    [[ -x "$BIN/$product" ]] || fail "expected executable not found: $BIN/$product"
done

# --- Assemble --------------------------------------------------------------

step "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"

cp "$BIN/ScaleKit" "$APP/Contents/MacOS/ScaleKit"
# The app looks for the watchdog next to its own executable.
cp "$BIN/ScaleKitGuard" "$APP/Contents/MacOS/ScaleKitGuard"
cp "$BIN/scalekit-diag" "$APP/Contents/Helpers/scalekit-diag"
cp "$PLIST" "$APP/Contents/Info.plist"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' >"$APP/Contents/PkgInfo"

# SwiftPM resource bundles (if a target ever declares resources).
shopt -s nullglob
for bundle in "$BIN"/ScaleKit_*.bundle; do
    echo "copying resource bundle $(basename "$bundle") into Contents/Resources"
    echo "${DIM}note: Bundle.module in a SwiftPM-built executable may not search Contents/Resources; verify resource loading.${RESET}"
    ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
done
shopt -u nullglob

# Extended attributes (Finder info, quarantine) break code signing.
xattr -cr "$APP" 2>/dev/null || true

# --- Sign ------------------------------------------------------------------

# Ad-hoc signature ("-"), hardened runtime, no secure timestamp (ad-hoc cannot have one).
# Nested executables are signed first, then the bundle, which seals everything inside.
SIGN=(codesign --force --sign - --timestamp=none --options runtime)

step "Signing (ad-hoc)"
"${SIGN[@]}" --identifier "$BUNDLE_ID.Guard" "$APP/Contents/MacOS/ScaleKitGuard"
"${SIGN[@]}" --identifier "$BUNDLE_ID.diag" "$APP/Contents/Helpers/scalekit-diag"
"${SIGN[@]}" --identifier "$BUNDLE_ID" "$APP"

step "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -E '^(Executable|Identifier|Format|CodeDirectory|Signature|Info.plist|Sealed Resources|Runtime Version)' || true

# A signed copy of the CLI for terminal use.
cp "$APP/Contents/Helpers/scalekit-diag" "$OUT/scalekit-diag"
# The CLI looks for the watchdog next to itself; without it, trials run unguarded.
cp "$APP/Contents/MacOS/ScaleKitGuard" "$OUT/ScaleKitGuard"

# --- Optional: zip ---------------------------------------------------------

ZIP=""
if ((DO_ZIP)); then
    ZIP="$OUT/ScaleKit-$VERSION.zip"
    step "Creating $(basename "$ZIP")"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "$ZIP ($(du -h "$ZIP" | cut -f1 | tr -d ' '))"
fi

# --- Optional: install -----------------------------------------------------

INSTALLED=""
if ((DO_INSTALL)); then
    DEST="$HOME/Applications/ScaleKit.app"
    step "Installing to $DEST"
    if pgrep -x ScaleKit >/dev/null 2>&1; then
        echo "warning: ScaleKit is running; quit it before opening the new copy." >&2
    fi
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    codesign --verify --deep --strict "$DEST"
    INSTALLED="$DEST"
fi

# --- Summary ---------------------------------------------------------------

step "Done"
cat <<EOF
App:      $APP
CLI:      $OUT/scalekit-diag   (also inside the app at Contents/Helpers/scalekit-diag)
EOF
[[ -n "$ZIP" ]] && echo "Zip:      $ZIP"
[[ -n "$INSTALLED" ]] && echo "Installed: $INSTALLED"

OPEN_TARGET="${INSTALLED:-$APP}"
cat <<EOF

Next steps
  Open the app:        open "$OPEN_TARGET"
  Run diagnostics:     "$OUT/scalekit-diag" --help
  Install for you:     scripts/build-app.sh --install   (copies to ~/Applications)

Gatekeeper
  This build is ad-hoc signed. Built and run on this Mac it opens normally.
  Copied to another Mac (zip, AirDrop, download) it is quarantined and macOS will
  refuse to open it. Try to open it once, then allow it in System Settings ▸
  Privacy & Security ▸ Open Anyway (since macOS 15, right-click ▸ Open no longer
  bypasses Gatekeeper), or sign it with a Developer ID certificate and notarize it
  with notarytool for warning-free distribution.
EOF

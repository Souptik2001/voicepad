#!/bin/bash
# Direct Swift compiler packaging; Python 3 configures the staged plist.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
  printf 'This script requires macOS and Apple command-line developer tools. No Mac app was built.\n' >&2
  exit 1
fi
if [[ "$#" -ne 0 ]]; then
  printf 'Usage: bash scripts/build.sh (no extra build flags accepted)\n' >&2
  exit 1
fi
if ! command -v python3 >/dev/null; then
  printf 'Python 3 is required for safe bundle configuration. Install Xcode Command Line Tools or Python 3.\n' >&2
  exit 1
fi
# Validate before compiling or touching any previous app; an explicitly empty value is invalid.
VOICEPAD_SERVER_URL="$(python3 "$ROOT/scripts/configure_bundle.py")"
export VOICEPAD_SERVER_URL
if ! command -v xcrun >/dev/null || ! xcrun --find swiftc >/dev/null 2>&1; then
  printf 'Apple Swift compiler is missing. Install compatible Xcode or Command Line Tools.\n' >&2
  exit 1
fi
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
case "$ARCH" in
  arm64|x86_64) ;;
  *) printf 'Unsupported Mac architecture: %s\n' "$ARCH" >&2; exit 1 ;;
esac
TARGET="$ARCH-apple-macosx13.0"
cd "$ROOT"
mkdir -p "$ROOT/dist"
WORK="$(mktemp -d "$ROOT/dist/.compile.XXXXXXXX")"
trap 'rm -rf "$WORK"' EXIT
CORE_SOURCES=("$ROOT"/Sources/VoicepadCore/*.swift)
APP_SOURCES=("$ROOT"/Sources/Voicepad/*.swift)
printf 'Building shared Swift code directly (bypassing SwiftPM manifest)…\n'
xcrun swiftc -swift-version 5 -sdk "$SDK" -target "$TARGET" -O \
  -parse-as-library -module-name VoicepadCore -emit-library -static -emit-module \
  -emit-module-path "$WORK/VoicepadCore.swiftmodule" \
  "${CORE_SOURCES[@]}" -o "$WORK/libVoicepadCore.a"
printf 'Building native Voicepad app for this Mac…\n'
xcrun swiftc -swift-version 5 -sdk "$SDK" -target "$TARGET" -O \
  -parse-as-library -module-name Voicepad -I "$WORK" \
  "${APP_SOURCES[@]}" "$WORK/libVoicepadCore.a" \
  -framework AppKit -framework AVFoundation -framework Carbon -framework ApplicationServices \
  -o "$WORK/Voicepad"
if [[ ! -f "$WORK/Voicepad" ]]; then
  printf 'Compiler did not produce the Voicepad executable.\n' >&2; exit 1
fi
STAGING="$WORK/Voicepad.app"
APP="$ROOT/dist/Voicepad.app"
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Resources"
cp "$WORK/Voicepad" "$STAGING/Contents/MacOS/Voicepad"
chmod 755 "$STAGING/Contents/MacOS/Voicepad"
cp "$ROOT/Resources/Info.plist" "$STAGING/Contents/Info.plist"
python3 "$ROOT/scripts/configure_bundle.py" "$STAGING/Contents/Info.plist"
plutil -lint "$STAGING/Contents/Info.plist"
# Local ad-hoc signing is not Developer ID signing/notarization.
codesign --force --sign - --identifier dev.voicepad.mac --entitlements "$ROOT/Resources/Voicepad.entitlements" "$STAGING"
codesign --verify --strict --verbose=2 "$STAGING"
if [[ -e "$APP" ]]; then
  mv "$APP" "$ROOT/dist/Voicepad.previous.$(date +%Y%m%d-%H%M%S).app"
fi
mv "$STAGING" "$APP"
printf '\nBuilt: %s\n' "$APP"
printf 'Local ad-hoc signature only; not notarized. Nothing installed automatically.\n'
printf 'SwiftPM tests are separate; bundle packaging compiles directly with swiftc.\n'
printf 'Next: quit any running Voicepad, drag this app into Applications, then open it.\n'

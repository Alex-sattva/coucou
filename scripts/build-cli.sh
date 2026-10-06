#!/bin/bash
# Builds Coucou without Xcode: one swiftc invocation + a hand-assembled .app bundle + ad-hoc signing.
# For machines with only the Command Line Tools. CI and releases still use xcodegen + xcodebuild.
#
# Limits (Xcode-only pieces): no compiled Assets.car (no app icon), no entitlements,
# no Developer ID signing, no notarization. TCC grants (Accessibility…) may need re-approving
# for this copy.
#
# Usage: scripts/build-cli.sh            → .tmp/build/Coucou.app
#        scripts/build-cli.sh --typecheck → type-check only (fast, no output binary)
set -euo pipefail
cd "$(dirname "$0")/.."

# SwiftUI in the macOS 27 SDK turns @State into a macro whose plugin ships only with Xcode,
# so pin the newest 26.x SDK the Command Line Tools provide.
SDK="${COUCOU_SDK:-$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1)}"
if [ -z "$SDK" ] || [ ! -d "$SDK" ]; then
  echo "No MacOSX26.x SDK found in the Command Line Tools. Set COUCOU_SDK=/path/to/MacOSX26.x.sdk" >&2
  exit 1
fi

ARCH="$(uname -m)"
FLAGS=(-parse-as-library -swift-version 6 -strict-concurrency=complete
       -module-name NotchBuddy -target "${ARCH}-apple-macos15.0"
       -sdk "$SDK" -module-cache-path "$PWD/.tmp/mc")

if [ "${1:-}" = "--typecheck" ]; then
  swiftc -typecheck "${FLAGS[@]}" NotchBuddy/Sources/App/*.swift
  echo "Typecheck OK ($SDK)"
  exit 0
fi

APP=.tmp/build/Coucou.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc "${FLAGS[@]}" NotchBuddy/Sources/App/*.swift -o "$APP/Contents/MacOS/Coucou"

cp NotchBuddy/Resources/Info.plist "$APP/Contents/Info.plist"
# The source plist keeps $(EXECUTABLE_NAME); Xcode expands it, we do it by hand.
plutil -replace CFBundleExecutable -string Coucou "$APP/Contents/Info.plist"
cp -R NotchBuddy/Resources/sounds "$APP/Contents/Resources/sounds"
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP ($SDK)"

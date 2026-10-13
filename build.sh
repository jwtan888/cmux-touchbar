#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOME_DIR=${HOME:?HOME is required}
APP="$HOME_DIR/Applications/cmux Touch Bar.app"
cd "$ROOT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp /Applications/cmux.app/Contents/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp codex.svg "$APP/Contents/Resources/codex.svg"
cp claude.svg "$APP/Contents/Resources/claude.svg"
xcrun clang -fobjc-arc -c TouchBarBridge.m -o TouchBarBridge.o
xcrun swiftc main.swift CodexLifecycle.swift TouchBarBridge.o -import-objc-header TouchBarBridge.h -framework AppKit -o "$APP/Contents/MacOS/cmux-touchbar"
/usr/libexec/PlistBuddy -c 'Clear dict' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string local.cmux-touchbar' -c 'Add :CFBundleExecutable string cmux-touchbar' -c 'Add :CFBundleName string cmux Touch Bar' -c 'Add :CFBundleDisplayName string cmux Touch Bar' -c 'Add :CFBundlePackageType string APPL' -c 'Add :CFBundleVersion string 1' -c 'Add :CFBundleShortVersionString string 1.0' -c 'Add :CFBundleIconFile string AppIcon.icns' -c 'Add :CFBundleIconName string AppIcon' -c 'Add :LSMinimumSystemVersion string 14.0' -c 'Add :LSUIElement bool true' "$APP/Contents/Info.plist"
xattr -cr "$APP"
codesign --force --sign - "$APP"

# launchd does not provide a login-shell environment; cmux's CLI needs these
# values to find the user's socket and session files.
PLIST="$HOME_DIR/Library/LaunchAgents/local.cmux-touchbar.plist"
/usr/libexec/PlistBuddy -c 'Clear dict' "$PLIST"
/usr/libexec/PlistBuddy -c 'Add :Label string local.cmux-touchbar.v3' \
  -c 'Add :ProgramArguments array' \
  -c 'Add :ProgramArguments:0 string /bin/sh' \
  -c "Add :ProgramArguments:1 string $ROOT/run-helper.sh" \
  -c 'Add :RunAtLoad bool true' \
  -c 'Add :KeepAlive dict' \
  -c 'Add :KeepAlive:SuccessfulExit bool false' \
  -c 'Add :ThrottleInterval integer 10' \
  -c "Add :StandardErrorPath string $HOME_DIR/Library/Logs/cmux-touchbar.log" \
  -c 'Add :EnvironmentVariables dict' \
  -c "Add :EnvironmentVariables:HOME string $HOME_DIR" \
  -c "Add :EnvironmentVariables:USER string $(id -un)" \
  -c "Add :EnvironmentVariables:PATH string $HOME_DIR/.local/bin:/Applications/cmux.app/Contents/Resources/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  "$PLIST"

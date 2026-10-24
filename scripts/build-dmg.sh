#!/bin/bash
# Builds a Release "ASCII Wallpaper.app" and packs it into a drag-to-Applications DMG.
#
# Signing: uses a "Developer ID Application" certificate when one is in the keychain,
# otherwise the project's automatic (Apple Development) signing.
# Notarization: set NOTARY_PROFILE to a notarytool keychain profile (requires Developer ID):
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team>
#   NOTARY_PROFILE=<profile> scripts/build-dmg.sh
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="ASCII Wallpaper"
BUILD_DIR="build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
STAGE="$BUILD_DIR/dmg-stage"

VERSION=$(xcodebuild -project ASC2.xcodeproj -scheme ASC2 -configuration Release -showBuildSettings 2>/dev/null \
    | awk '$1 == "MARKETING_VERSION" { print $3; exit }')
DMG="$BUILD_DIR/ASCII-Wallpaper-$VERSION.dmg"

DEV_ID=$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application[^"]*\)".*/\1/p' | head -1)

# Hardened runtime is required for notarization and harmless otherwise.
# (Xcode adds get-task-allow only for development certificates, never for Developer ID.)
SIGN_ARGS=(ENABLE_HARDENED_RUNTIME=YES)
if [[ -n "$DEV_ID" ]]; then
    echo "==> Signing with $DEV_ID"
    SIGN_ARGS+=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$DEV_ID" "OTHER_CODE_SIGN_FLAGS=--timestamp")
else
    echo "==> No Developer ID certificate found; using Apple Development signing (not notarizable)"
fi

echo "==> Building $APP_NAME $VERSION"
xcodebuild -project ASC2.xcodeproj -scheme ASC2 -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath "$DERIVED_DATA" "${SIGN_ARGS[@]}" clean build -quiet
APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
codesign --verify --deep --strict "$APP"

echo "==> Packing $DMG"
if [[ -d "/Volumes/$APP_NAME" ]]; then
    echo "Eject the mounted \"$APP_NAME\" volume first." >&2
    exit 1
fi
RW_DMG="$BUILD_DIR/rw.dmg"
rm -rf "$STAGE" "$RW_DMG" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW_DMG"
rm -rf "$STAGE"

# Finder window layout: app on the left, Applications link on the right, no toolbar.
hdiutil attach -quiet -noautoopen "$RW_DMG"
VOLUME="/Volumes/$APP_NAME"
osascript - "$APP_NAME" <<'APPLESCRIPT'
on run {appName}
    tell application "Finder"
        tell disk appName
            -- First pass sets up the window itself; icon options changed on a freshly
            -- mounted volume's first open are not saved, so they go in a second pass.
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set bounds of container window to {200, 120, 740, 500}
            close

            open
            set opts to the icon view options of container window
            set arrangement of opts to not arranged
            set icon size of opts to 112
            set text size of opts to 13
            set position of item (appName & ".app") of container window to {140, 170}
            set position of item "Applications" of container window to {400, 170}
            set extension hidden of item (appName & ".app") to true
            -- Finder writes .DS_Store lazily; reopening the window forces the flush.
            close
            open
            update without registering applications
            delay 1
            close
        end tell
    end tell
end run
APPLESCRIPT
for _ in $(seq 1 20); do
    grep -q "none" "$VOLUME/.DS_Store" 2>/dev/null && break
    sleep 0.5
done
grep -q "none" "$VOLUME/.DS_Store" || { echo "Finder did not save the window layout" >&2; exit 1; }
sync
hdiutil detach -quiet "$VOLUME"

hdiutil convert -quiet "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -f "$RW_DMG"

if [[ -n "$DEV_ID" ]]; then
    codesign --sign "$DEV_ID" --timestamp "$DMG"
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        echo "==> Notarizing"
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
    fi
fi

echo "==> Done: $DMG"

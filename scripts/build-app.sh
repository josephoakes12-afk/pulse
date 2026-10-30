#!/bin/bash
set -euo pipefail

PULSE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PULSE_CONFIGURATION="${1:-release}"
if [[ "$PULSE_CONFIGURATION" != release && "$PULSE_CONFIGURATION" != debug ]]; then
    echo "Usage: $0 [release|debug]" >&2
    exit 2
fi
cd "$PULSE_ROOT"
PULSE_OUTPUT_DIR="${PULSE_OUTPUT_DIR:-$PULSE_ROOT/build}"
PULSE_VERSION="${PULSE_VERSION:-0.1.0}"
PULSE_BUILD_NUMBER="${PULSE_BUILD_NUMBER:-1}"
PULSE_SIGN_IDENTITY="${PULSE_SIGN_IDENTITY:--}"
[[ "$PULSE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version must be major.minor.patch." >&2; exit 2; }
[[ "$PULSE_BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "Build number must be numeric." >&2; exit 2; }
PULSE_BUILD_OPTIONS=(--configuration "$PULSE_CONFIGURATION")
case "${PULSE_ARCHITECTURES:-native}" in
    native) ;;
    universal) PULSE_BUILD_OPTIONS+=(--arch arm64 --arch x86_64) ;;
    *) echo "PULSE_ARCHITECTURES must be native or universal." >&2; exit 2 ;;
esac
swift build "${PULSE_BUILD_OPTIONS[@]}"
PULSE_BIN_DIR="$(swift build "${PULSE_BUILD_OPTIONS[@]}" --show-bin-path)"
mkdir -p "$PULSE_OUTPUT_DIR"
PULSE_STAGE="$(mktemp -d "$PULSE_OUTPUT_DIR/.pulse-build.XXXXXX")"
trap 'rm -rf "$PULSE_STAGE"' EXIT
PULSE_APP="$PULSE_STAGE/Pulse.app"
mkdir -p "$PULSE_APP/Contents/MacOS" "$PULSE_APP/Contents/Resources"
cp "$PULSE_BIN_DIR/Pulse" "$PULSE_APP/Contents/MacOS/Pulse"
find "$PULSE_BIN_DIR" -maxdepth 1 -type d -name '*.bundle' -exec cp -R {} "$PULSE_APP/Contents/Resources/" \;
# Swift back-deployment libraries may resolve through Xcode on a developer Mac.
# Bundle them so the download also launches on Macs without developer tools.
mkdir -p "$PULSE_APP/Contents/Frameworks"
xcrun swift-stdlib-tool --copy --scan-executable "$PULSE_APP/Contents/MacOS/Pulse" \
    --platform macosx --destination "$PULSE_APP/Contents/Frameworks"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$PULSE_APP/Contents/MacOS/Pulse"
while IFS= read -r PULSE_RPATH; do
    if [[ "$PULSE_RPATH" == /* && "$PULSE_RPATH" != /usr/lib/swift ]]; then
        install_name_tool -delete_rpath "$PULSE_RPATH" "$PULSE_APP/Contents/MacOS/Pulse"
    fi
done < <(otool -l "$PULSE_APP/Contents/MacOS/Pulse" | awk '
    /cmd LC_RPATH/ { getline; getline; sub(/^[[:space:]]*path /, ""); sub(/ \(offset.*$/, ""); print }
' | sort -u)
PULSE_LICENSES="$PULSE_APP/Contents/Resources/Licenses"
mkdir -p "$PULSE_LICENSES/Pulse"
# Earlier builds may have preserved read-only checkout permissions. These are
# generated bundle copies only; upstream checkout files remain untouched.
find "$PULSE_LICENSES" -type f -exec chmod u+w {} +
install -m 644 "$PULSE_ROOT/LICENSE" "$PULSE_LICENSES/Pulse/LICENSE"
for PULSE_DEPENDENCY in "$PULSE_ROOT"/.build/checkouts/*; do
    [[ -d "$PULSE_DEPENDENCY" ]] || continue
    PULSE_DEPENDENCY_NAME="$(basename "$PULSE_DEPENDENCY")"
    while IFS= read -r -d '' PULSE_NOTICE; do
        mkdir -p "$PULSE_LICENSES/$PULSE_DEPENDENCY_NAME"
        install -m 644 "$PULSE_NOTICE" "$PULSE_LICENSES/$PULSE_DEPENDENCY_NAME/$(basename "$PULSE_NOTICE")"
    done < <(find "$PULSE_DEPENDENCY" -maxdepth 1 -type f \( -iname 'LICENSE*' -o -iname 'NOTICE*' -o -iname 'COPYING*' \) -print0)
done
swift "$PULSE_ROOT/scripts/generate-icon.swift" "$PULSE_STAGE"
iconutil --convert icns "$PULSE_STAGE/AppIcon.iconset" --output "$PULSE_APP/Contents/Resources/AppIcon.icns"
cat > "$PULSE_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>local.pulse.app</string>
    <key>CFBundleExecutable</key><string>Pulse</string>
    <key>CFBundleName</key><string>Pulse</string>
    <key>CFBundleDisplayName</key><string>Pulse</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Joseph Oakes</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $PULSE_VERSION" "$PULSE_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $PULSE_BUILD_NUMBER" "$PULSE_APP/Contents/Info.plist"
sign_code() {
    if [[ "$PULSE_SIGN_IDENTITY" == - ]]; then
        codesign --force --sign - "$1"
    else
        codesign --force --options runtime --timestamp --sign "$PULSE_SIGN_IDENTITY" "$1"
    fi
}
while IFS= read -r -d '' PULSE_LIBRARY; do
    sign_code "$PULSE_LIBRARY"
done < <(find "$PULSE_APP/Contents/Frameworks" -type f -name '*.dylib' -print0)
sign_code "$PULSE_APP"
codesign --verify --deep --strict "$PULSE_APP"
if [[ "${PULSE_ARCHITECTURES:-native}" == universal ]]; then
    for PULSE_ARCHITECTURE in arm64 x86_64; do
        lipo "$PULSE_APP/Contents/MacOS/Pulse" -verify_arch "$PULSE_ARCHITECTURE"
    done
fi
rm -rf "$PULSE_OUTPUT_DIR/Pulse.app"
mv "$PULSE_APP" "$PULSE_OUTPUT_DIR/Pulse.app"
echo "Built $PULSE_OUTPUT_DIR/Pulse.app"

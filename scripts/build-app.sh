#!/bin/bash
set -euo pipefail

PULSE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PULSE_CONFIGURATION="${1:-release}"
if [[ "$PULSE_CONFIGURATION" != release && "$PULSE_CONFIGURATION" != debug ]]; then
    echo "Usage: $0 [release|debug]" >&2
    exit 2
fi
cd "$PULSE_ROOT"
swift build --configuration "$PULSE_CONFIGURATION"
PULSE_BIN_DIR="$(swift build --configuration "$PULSE_CONFIGURATION" --show-bin-path)"
PULSE_APP="$PULSE_ROOT/build/Pulse.app"
mkdir -p "$PULSE_APP/Contents/MacOS" "$PULSE_APP/Contents/Resources"
cp "$PULSE_BIN_DIR/Pulse" "$PULSE_APP/Contents/MacOS/Pulse"
find "$PULSE_BIN_DIR" -maxdepth 1 -type d -name '*.bundle' -exec cp -R {} "$PULSE_APP/Contents/Resources/" \;
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
swift "$PULSE_ROOT/scripts/generate-icon.swift" "$PULSE_ROOT/build"
iconutil --convert icns "$PULSE_ROOT/build/AppIcon.iconset" --output "$PULSE_APP/Contents/Resources/AppIcon.icns"
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
codesign --force --deep --sign - "$PULSE_APP"
echo "Built $PULSE_APP"

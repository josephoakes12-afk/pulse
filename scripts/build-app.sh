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
PULSE_BUNDLE_IDENTIFIER="${PULSE_BUNDLE_IDENTIFIER:-uk.co.builtby2.pulse}"
[[ "$PULSE_BUNDLE_IDENTIFIER" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ \
   && ${#PULSE_BUNDLE_IDENTIFIER} -le 247 ]] || {
    echo "PULSE_BUNDLE_IDENTIFIER must be a reverse-DNS identifier with letters, numbers, periods and internal hyphens." >&2; exit 2;
}
PULSE_DISTRIBUTION_CHANNEL="${PULSE_DISTRIBUTION_CHANNEL:-direct}"
[[ "$PULSE_DISTRIBUTION_CHANNEL" == direct || "$PULSE_DISTRIBUTION_CHANNEL" == app-store ]] || {
    echo "PULSE_DISTRIBUTION_CHANNEL must be direct or app-store." >&2; exit 2;
}
PULSE_SIGN_IDENTITY="${PULSE_SIGN_IDENTITY:--}"
PULSE_SIGNING_KEYCHAIN="${PULSE_SIGNING_KEYCHAIN:-}"
PULSE_SIGNING_OPTIONS=()
PULSE_PROFILE_SIGNING_OPTIONS=()
if [[ -n "$PULSE_SIGNING_KEYCHAIN" ]]; then
    [[ -f "$PULSE_SIGNING_KEYCHAIN" ]] || { echo "PULSE_SIGNING_KEYCHAIN does not exist." >&2; exit 2; }
    PULSE_SIGNING_OPTIONS+=(--keychain "$PULSE_SIGNING_KEYCHAIN")
    PULSE_PROFILE_SIGNING_OPTIONS+=(--signing-keychain "$PULSE_SIGNING_KEYCHAIN")
fi
PULSE_DEVELOPMENT_TEAM="${PULSE_DEVELOPMENT_TEAM:-}"
if [[ -z "$PULSE_DEVELOPMENT_TEAM" && "$PULSE_SIGN_IDENTITY" =~ \(([A-Z0-9]{10})\)$ ]]; then
    PULSE_DEVELOPMENT_TEAM="${BASH_REMATCH[1]}"
fi
PULSE_BUILD_WIDGETS="${PULSE_BUILD_WIDGETS:-auto}"
PULSE_CLOUDKIT_CONTAINER="${PULSE_CLOUDKIT_CONTAINER:-}"
PULSE_CLOUDKIT_PROFILE="${PULSE_CLOUDKIT_PROFILE:-}"
PULSE_APP_STORE_PROFILE="${PULSE_APP_STORE_PROFILE:-}"
PULSE_WIDGET_PROFILE="${PULSE_WIDGET_PROFILE:-}"
if [[ "$PULSE_DISTRIBUTION_CHANNEL" == app-store ]]; then
    [[ "$PULSE_SIGN_IDENTITY" == 'Apple Distribution:'* || "$PULSE_SIGN_IDENTITY" == '3rd Party Mac Developer Application:'* ]] || {
        echo "App Store builds require an Apple Distribution or Mac App Distribution identity." >&2; exit 2;
    }
    [[ "$PULSE_DEVELOPMENT_TEAM" =~ ^[A-Z0-9]{10}$ && -f "$PULSE_APP_STORE_PROFILE" ]] || {
        echo "App Store builds require PULSE_DEVELOPMENT_TEAM and PULSE_APP_STORE_PROFILE." >&2; exit 2;
    }
    [[ -z "$PULSE_CLOUDKIT_PROFILE" || "$PULSE_CLOUDKIT_PROFILE" == "$PULSE_APP_STORE_PROFILE" ]] || {
        echo "App Store builds use PULSE_APP_STORE_PROFILE for the main app, including CloudKit." >&2; exit 2;
    }
    [[ -z "$PULSE_CLOUDKIT_CONTAINER" ]] || PULSE_CLOUDKIT_PROFILE="$PULSE_APP_STORE_PROFILE"
fi
PULSE_BUILD_CLOUDKIT=0
if [[ -n "$PULSE_CLOUDKIT_CONTAINER" || -n "$PULSE_CLOUDKIT_PROFILE" ]]; then
    [[ "$PULSE_CLOUDKIT_CONTAINER" =~ ^iCloud\.[A-Za-z0-9][A-Za-z0-9.-]+$ \
       && -f "$PULSE_CLOUDKIT_PROFILE" \
       && "$PULSE_DEVELOPMENT_TEAM" =~ ^[A-Z0-9]{10}$ \
       && ( "$PULSE_SIGN_IDENTITY" == 'Developer ID Application:'* || "$PULSE_DISTRIBUTION_CHANNEL" == app-store ) ]] || {
        echo "Private iCloud sync needs a container, profile and matching distribution signing team." >&2; exit 2;
    }
    PULSE_BUILD_CLOUDKIT=1
fi
if [[ "$PULSE_BUILD_WIDGETS" == auto ]]; then
    if [[ -n "$PULSE_DEVELOPMENT_TEAM" ]]; then PULSE_BUILD_WIDGETS=1; else PULSE_BUILD_WIDGETS=0; fi
fi
[[ "$PULSE_BUILD_WIDGETS" == 0 || "$PULSE_BUILD_WIDGETS" == 1 ]] || { echo "PULSE_BUILD_WIDGETS must be auto, 0 or 1." >&2; exit 2; }
if [[ "$PULSE_BUILD_WIDGETS" == 1 ]]; then
    [[ "$PULSE_DEVELOPMENT_TEAM" =~ ^[A-Z0-9]{10}$ && "$PULSE_SIGN_IDENTITY" != - ]] || {
        echo "Live widgets need a real signing identity and PULSE_DEVELOPMENT_TEAM." >&2; exit 2;
    }
    PULSE_APP_GROUP_IDENTIFIER="${PULSE_APP_GROUP_IDENTIFIER:-$PULSE_DEVELOPMENT_TEAM.local.pulse.shared}"
    [[ "$PULSE_APP_GROUP_IDENTIFIER" =~ ^[A-Za-z0-9][A-Za-z0-9.-]+$ ]] || {
        echo "PULSE_APP_GROUP_IDENTIFIER contains invalid characters." >&2; exit 2;
    }
    if [[ "$PULSE_DISTRIBUTION_CHANNEL" == app-store && ! -f "$PULSE_WIDGET_PROFILE" ]]; then
        echo "App Store widgets require their own PULSE_WIDGET_PROFILE." >&2; exit 2;
    fi
fi
[[ "$PULSE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version must be major.minor.patch." >&2; exit 2; }
[[ "$PULSE_BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "Build number must be numeric." >&2; exit 2; }
PULSE_BUILD_OPTIONS=(--configuration "$PULSE_CONFIGURATION" --sdk "$(xcrun --sdk macosx --show-sdk-path)")
if [[ "$PULSE_CONFIGURATION" == release ]]; then
    # Keep developer home paths out of debug records and C/C++ __FILE__ strings.
    # These flags are supported by the Swift 6.2 / Clang toolchain baseline.
    PULSE_BUILD_OPTIONS+=(
        -Xswiftc -file-prefix-map -Xswiftc "$PULSE_ROOT=."
        -Xcc "-ffile-prefix-map=$PULSE_ROOT=."
        -Xcxx "-ffile-prefix-map=$PULSE_ROOT=."
        -Xcc "-ffile-prefix-map=$PULSE_ROOT/.build/checkouts=Dependencies"
        -Xcxx "-ffile-prefix-map=$PULSE_ROOT/.build/checkouts=Dependencies"
    )
fi
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
PULSE_APP_ENTITLEMENTS=""
mkdir -p "$PULSE_APP/Contents/MacOS" "$PULSE_APP/Contents/Resources"
cp "$PULSE_BIN_DIR/Pulse" "$PULSE_APP/Contents/MacOS/Pulse"
find "$PULSE_BIN_DIR" -maxdepth 1 -type d -name '*.bundle' -exec cp -R {} "$PULSE_APP/Contents/Resources/" \;
# Swift back-deployment libraries may resolve through Xcode on a developer Mac.
# Bundle them so the download also launches on Macs without developer tools.
mkdir -p "$PULSE_APP/Contents/Frameworks"
xcrun swift-stdlib-tool --copy --scan-executable "$PULSE_APP/Contents/MacOS/Pulse" \
    --platform macosx --destination "$PULSE_APP/Contents/Frameworks"
"$PULSE_ROOT/scripts/trim-runtime-architectures.sh" "$PULSE_APP/Contents/MacOS/Pulse" "$PULSE_APP/Contents/Frameworks"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$PULSE_APP/Contents/MacOS/Pulse"
while IFS= read -r PULSE_RPATH; do
    if [[ "$PULSE_RPATH" == /* && "$PULSE_RPATH" != /usr/lib/swift ]]; then
        install_name_tool -delete_rpath "$PULSE_RPATH" "$PULSE_APP/Contents/MacOS/Pulse"
    fi
done < <(otool -l "$PULSE_APP/Contents/MacOS/Pulse" | awk '
    /cmd LC_RPATH/ { getline; getline; sub(/^[[:space:]]*path /, ""); sub(/ \(offset.*$/, ""); print }
' | sort -u)
if [[ "$PULSE_CONFIGURATION" == release ]]; then
    if [[ -n "${PULSE_DSYM_OUTPUT_DIR:-}" ]]; then
        mkdir -p "$PULSE_DSYM_OUTPUT_DIR"
        dsymutil "$PULSE_BIN_DIR/Pulse" --out "$PULSE_DSYM_OUTPUT_DIR/Pulse.app.dSYM"
    fi
    strip -S -x "$PULSE_APP/Contents/MacOS/Pulse"
    if LC_ALL=C /usr/bin/grep -aFq "$PULSE_ROOT/" "$PULSE_APP/Contents/MacOS/Pulse" \
        || LC_ALL=C /usr/bin/grep -aFq "$HOME/" "$PULSE_APP/Contents/MacOS/Pulse"; then
        echo "Release executable still contains a local home or build path." >&2
        exit 1
    fi
fi
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
    <key>CFBundleIdentifier</key><string>uk.co.builtby2.pulse</string>
    <key>CFBundleExecutable</key><string>Pulse</string>
    <key>CFBundleName</key><string>Pulse</string>
    <key>CFBundleDisplayName</key><string>Pulse</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleURLTypes</key><array><dict>
        <key>CFBundleURLName</key><string>local.pulse.project</string>
        <key>CFBundleURLSchemes</key><array><string>pulse-metrics</string></array>
    </dict></array>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Joseph Oakes</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $PULSE_BUNDLE_IDENTIFIER" "$PULSE_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $PULSE_VERSION" "$PULSE_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $PULSE_BUILD_NUMBER" "$PULSE_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :PulseDistributionChannel string $PULSE_DISTRIBUTION_CHANNEL" "$PULSE_APP/Contents/Info.plist"
# App Store validation expects the platform/toolchain metadata normally written
# by Xcode. SwiftPM builds the executable; these values come from that same SDK.
/usr/libexec/PlistBuddy -c "Add :DTPlatformName string macosx" "$PULSE_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :DTPlatformVersion string $(xcrun --sdk macosx --show-sdk-version)" "$PULSE_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :DTSDKName string macosx$(xcrun --sdk macosx --show-sdk-version)" "$PULSE_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :DTSDKBuild string $(xcrun --sdk macosx --show-sdk-build-version)" "$PULSE_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :DTXcodeBuild string $(xcodebuild -version | awk '/Build version/ {print $3}')" "$PULSE_APP/Contents/Info.plist"
if [[ "$PULSE_BUILD_WIDGETS" == 1 ]]; then
    /usr/libexec/PlistBuddy -c "Add :PulseAppGroupIdentifier string $PULSE_APP_GROUP_IDENTIFIER" "$PULSE_APP/Contents/Info.plist"
    PULSE_APP_GROUP_IDENTIFIER="$PULSE_APP_GROUP_IDENTIFIER" \
        PULSE_BUNDLE_IDENTIFIER="$PULSE_BUNDLE_IDENTIFIER" \
        PULSE_DSYM_OUTPUT_DIR="${PULSE_DSYM_OUTPUT_DIR:-}" \
        "$PULSE_ROOT/scripts/build-widget.sh" "$PULSE_APP/Contents/PlugIns" "$PULSE_CONFIGURATION"
    cat > "$PULSE_STAGE/app.entitlements" <<ENTITLEMENTS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>com.apple.security.application-groups</key><array><string>$PULSE_APP_GROUP_IDENTIFIER</string></array>
</dict></plist>
ENTITLEMENTS
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.app-sandbox bool true" "$PULSE_STAGE/app.entitlements"
    cp "$PULSE_STAGE/app.entitlements" "$PULSE_STAGE/widget.entitlements"
    if [[ "$PULSE_DISTRIBUTION_CHANNEL" == direct ]]; then
        /usr/libexec/PlistBuddy -c "Delete :com.apple.security.app-sandbox" "$PULSE_STAGE/app.entitlements"
    fi
    PULSE_APP_ENTITLEMENTS="$PULSE_STAGE/app.entitlements"
fi
if [[ "$PULSE_DISTRIBUTION_CHANNEL" == app-store ]]; then
    # No server/listening entitlement: every connector makes outgoing requests.
    [[ -f "$PULSE_STAGE/app.entitlements" ]] || plutil -create xml1 "$PULSE_STAGE/app.entitlements"
    /usr/libexec/PlistBuddy -c "Delete :com.apple.security.app-sandbox" "$PULSE_STAGE/app.entitlements" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.app-sandbox bool true" "$PULSE_STAGE/app.entitlements"
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.network.client bool true" "$PULSE_STAGE/app.entitlements"
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.files.user-selected.read-only bool true" "$PULSE_STAGE/app.entitlements"
    PULSE_PROFILE_ARGUMENTS=(--distribution app-store --profile "$PULSE_APP_STORE_PROFILE"
        --team "$PULSE_DEVELOPMENT_TEAM" --bundle-id "$PULSE_BUNDLE_IDENTIFIER"
        --sign-identity "$PULSE_SIGN_IDENTITY" --entitlements "$PULSE_STAGE/app.entitlements")
    if [[ "$PULSE_BUILD_WIDGETS" == 1 ]]; then
        PULSE_PROFILE_ARGUMENTS+=(--app-group "$PULSE_APP_GROUP_IDENTIFIER")
        python3 "$PULSE_ROOT/scripts/configure-cloudkit.py" --distribution app-store \
            --profile "$PULSE_WIDGET_PROFILE" --team "$PULSE_DEVELOPMENT_TEAM" \
            --bundle-id "$PULSE_BUNDLE_IDENTIFIER.widgets" --app-group "$PULSE_APP_GROUP_IDENTIFIER" \
            --sign-identity "$PULSE_SIGN_IDENTITY" --entitlements "$PULSE_STAGE/widget.entitlements" "${PULSE_PROFILE_SIGNING_OPTIONS[@]}"
        install -m 644 "$PULSE_WIDGET_PROFILE" "$PULSE_APP/Contents/PlugIns/PulseWidgets.appex/Contents/embedded.provisionprofile"
    fi
    if [[ "$PULSE_BUILD_CLOUDKIT" == 1 ]]; then PULSE_PROFILE_ARGUMENTS+=(--container "$PULSE_CLOUDKIT_CONTAINER"); fi
    python3 "$PULSE_ROOT/scripts/configure-cloudkit.py" "${PULSE_PROFILE_ARGUMENTS[@]}" "${PULSE_PROFILE_SIGNING_OPTIONS[@]}"
    install -m 644 "$PULSE_APP_STORE_PROFILE" "$PULSE_APP/Contents/embedded.provisionprofile"
    PULSE_APP_ENTITLEMENTS="$PULSE_STAGE/app.entitlements"
fi
if [[ "$PULSE_BUILD_CLOUDKIT" == 1 && "$PULSE_DISTRIBUTION_CHANNEL" == direct ]]; then
    python3 "$PULSE_ROOT/scripts/configure-cloudkit.py" \
        --profile "$PULSE_CLOUDKIT_PROFILE" --team "$PULSE_DEVELOPMENT_TEAM" \
        --container "$PULSE_CLOUDKIT_CONTAINER" --sign-identity "$PULSE_SIGN_IDENTITY" \
        --bundle-id "$PULSE_BUNDLE_IDENTIFIER" \
        --entitlements "$PULSE_STAGE/app.entitlements" "${PULSE_PROFILE_SIGNING_OPTIONS[@]}"
    install -m 644 "$PULSE_CLOUDKIT_PROFILE" "$PULSE_APP/Contents/embedded.provisionprofile"
    /usr/libexec/PlistBuddy -c "Add :PulseCloudContainerIdentifier string $PULSE_CLOUDKIT_CONTAINER" "$PULSE_APP/Contents/Info.plist"
    PULSE_APP_ENTITLEMENTS="$PULSE_STAGE/app.entitlements"
fi
if [[ "$PULSE_BUILD_CLOUDKIT" == 1 && "$PULSE_DISTRIBUTION_CHANNEL" == app-store ]]; then
    /usr/libexec/PlistBuddy -c "Add :PulseCloudContainerIdentifier string $PULSE_CLOUDKIT_CONTAINER" "$PULSE_APP/Contents/Info.plist"
fi
sign_code() {
    local PULSE_CODE_PATH="$1"
    local PULSE_CODE_ENTITLEMENTS="${2:-}"
    if [[ "$PULSE_SIGN_IDENTITY" == - ]]; then
        codesign --force --sign - "$PULSE_CODE_PATH"
    elif [[ -n "$PULSE_CODE_ENTITLEMENTS" ]]; then
        codesign --force --options runtime --timestamp --sign "$PULSE_SIGN_IDENTITY" "${PULSE_SIGNING_OPTIONS[@]}" --entitlements "$PULSE_CODE_ENTITLEMENTS" "$PULSE_CODE_PATH"
    else
        codesign --force --options runtime --timestamp --sign "$PULSE_SIGN_IDENTITY" "${PULSE_SIGNING_OPTIONS[@]}" "$PULSE_CODE_PATH"
    fi
}
while IFS= read -r -d '' PULSE_LIBRARY; do
    sign_code "$PULSE_LIBRARY"
done < <(find "$PULSE_APP/Contents/Frameworks" -type f -name '*.dylib' -print0)
if [[ "$PULSE_BUILD_WIDGETS" == 1 ]]; then
    PULSE_WIDGET="$PULSE_APP/Contents/PlugIns/PulseWidgets.appex"
    while IFS= read -r -d '' PULSE_LIBRARY; do sign_code "$PULSE_LIBRARY"; done \
        < <(find "$PULSE_WIDGET/Contents/Frameworks" -type f -name '*.dylib' -print0)
    sign_code "$PULSE_WIDGET" "$PULSE_STAGE/widget.entitlements"
fi
sign_code "$PULSE_APP" "$PULSE_APP_ENTITLEMENTS"
if [[ "$PULSE_BUILD_WIDGETS" == 1 || "$PULSE_BUILD_CLOUDKIT" == 1 ]]; then
    PULSE_ACTUAL_TEAM="$(codesign -d --verbose=4 "$PULSE_APP" 2>&1 | awk -F= '$1 == "TeamIdentifier" { print $2 }')"
    [[ "$PULSE_ACTUAL_TEAM" == "$PULSE_DEVELOPMENT_TEAM" ]] || {
        echo "The signing certificate team does not match the configured capabilities." >&2; exit 1;
    }
fi
codesign --verify --deep --strict "$PULSE_APP"
if [[ "${PULSE_ARCHITECTURES:-native}" == universal ]]; then
    for PULSE_ARCHITECTURE in arm64 x86_64; do
        lipo "$PULSE_APP/Contents/MacOS/Pulse" -verify_arch "$PULSE_ARCHITECTURE"
    done
fi
rm -rf "$PULSE_OUTPUT_DIR/Pulse.app"
mv "$PULSE_APP" "$PULSE_OUTPUT_DIR/Pulse.app"
echo "Built $PULSE_OUTPUT_DIR/Pulse.app"

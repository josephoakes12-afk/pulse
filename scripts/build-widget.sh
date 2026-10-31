#!/bin/bash
set -euo pipefail

PULSE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PULSE_WIDGET_OUTPUT="${1:-}"
PULSE_CONFIGURATION="${2:-release}"
[[ -n "$PULSE_WIDGET_OUTPUT" && ( "$PULSE_CONFIGURATION" == release || "$PULSE_CONFIGURATION" == debug ) ]] || {
    echo "Usage: $0 output-directory [release|debug]" >&2; exit 2;
}
PULSE_VERSION="${PULSE_VERSION:-0.1.0}"
PULSE_BUILD_NUMBER="${PULSE_BUILD_NUMBER:-1}"
PULSE_BUNDLE_IDENTIFIER="${PULSE_BUNDLE_IDENTIFIER:-uk.co.builtby2.pulse}"
[[ "$PULSE_BUNDLE_IDENTIFIER" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ \
   && ${#PULSE_BUNDLE_IDENTIFIER} -le 247 ]] || {
    echo "PULSE_BUNDLE_IDENTIFIER must be a reverse-DNS identifier with letters, numbers, periods and internal hyphens." >&2; exit 2;
}
PULSE_APP_GROUP_IDENTIFIER="${PULSE_APP_GROUP_IDENTIFIER:-}"
[[ "$PULSE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version must be major.minor.patch." >&2; exit 2; }
[[ "$PULSE_BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "Build number must be numeric." >&2; exit 2; }
[[ -z "$PULSE_APP_GROUP_IDENTIFIER" || "$PULSE_APP_GROUP_IDENTIFIER" =~ ^[A-Za-z0-9][A-Za-z0-9.-]+$ ]] || {
    echo "The app group identifier must contain letters, numbers, periods or hyphens." >&2; exit 2;
}
case "$PULSE_CONFIGURATION" in
    release) PULSE_XCODE_CONFIGURATION=Release ;;
    debug) PULSE_XCODE_CONFIGURATION=Debug ;;
esac
case "${PULSE_ARCHITECTURES:-native}" in
    native) PULSE_WIDGET_ARCHITECTURES="$(uname -m)" ;;
    universal) PULSE_WIDGET_ARCHITECTURES="arm64 x86_64" ;;
    *) echo "PULSE_ARCHITECTURES must be native or universal." >&2; exit 2 ;;
esac

mkdir -p "$PULSE_WIDGET_OUTPUT"
PULSE_WIDGET_OUTPUT="$(cd "$PULSE_WIDGET_OUTPUT" && pwd)"
PULSE_WIDGET_STAGE="$(mktemp -d "$PULSE_WIDGET_OUTPUT/.widget-build.XXXXXX")"
trap 'rm -rf "$PULSE_WIDGET_STAGE"' EXIT
PULSE_WIDGET_BUILD_ROOT="$PULSE_ROOT/.build/widgets"
PULSE_WIDGET_FLAGS='$(inherited)'
if [[ "$PULSE_CONFIGURATION" == release ]]; then
    PULSE_WIDGET_FLAGS+=" -file-prefix-map \"$PULSE_ROOT=.\""
fi

# The main bundle builder signs the extension after embedding it, with the same
# team and App Group as Pulse. Xcode still generates its App Intents metadata.
xcodebuild -quiet \
    -project "$PULSE_ROOT/Widgets/PulseWidgets.xcodeproj" \
    -target PulseWidgets -configuration "$PULSE_XCODE_CONFIGURATION" -sdk macosx \
    "ARCHS=$PULSE_WIDGET_ARCHITECTURES" ONLY_ACTIVE_ARCH=NO \
    "SYMROOT=$PULSE_WIDGET_BUILD_ROOT/Products" "OBJROOT=$PULSE_WIDGET_BUILD_ROOT/Intermediates" \
    "PULSE_APP_GROUP_IDENTIFIER=$PULSE_APP_GROUP_IDENTIFIER" \
    "PRODUCT_BUNDLE_IDENTIFIER=$PULSE_BUNDLE_IDENTIFIER.widgets" \
    "MARKETING_VERSION=$PULSE_VERSION" "CURRENT_PROJECT_VERSION=$PULSE_BUILD_NUMBER" \
    "OTHER_SWIFT_FLAGS=$PULSE_WIDGET_FLAGS" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build

PULSE_WIDGET="$PULSE_WIDGET_STAGE/PulseWidgets.appex"
ditto "$PULSE_WIDGET_BUILD_ROOT/Products/$PULSE_XCODE_CONFIGURATION/PulseWidgets.appex" "$PULSE_WIDGET"
PULSE_WIDGET_BINARY="$PULSE_WIDGET/Contents/MacOS/PulseWidgets"
[[ -s "$PULSE_WIDGET/Contents/Resources/Metadata.appintents/extract.actionsdata" ]] || {
    echo "The widget is missing its configuration metadata." >&2; exit 1;
}
mkdir -p "$PULSE_WIDGET/Contents/Frameworks"
xcrun swift-stdlib-tool --copy --scan-executable "$PULSE_WIDGET_BINARY" \
    --platform macosx --destination "$PULSE_WIDGET/Contents/Frameworks"
"$PULSE_ROOT/scripts/trim-runtime-architectures.sh" "$PULSE_WIDGET_BINARY" "$PULSE_WIDGET/Contents/Frameworks"
while IFS= read -r PULSE_WIDGET_RPATH; do
    if [[ "$PULSE_WIDGET_RPATH" == /* && "$PULSE_WIDGET_RPATH" != /usr/lib/swift ]]; then
        install_name_tool -delete_rpath "$PULSE_WIDGET_RPATH" "$PULSE_WIDGET_BINARY"
    fi
done < <(otool -l "$PULSE_WIDGET_BINARY" | awk '
    /cmd LC_RPATH/ { getline; getline; sub(/^[[:space:]]*path /, ""); sub(/ \(offset.*$/, ""); print }
' | sort -u)
if [[ "$PULSE_CONFIGURATION" == release ]]; then
    if [[ -n "${PULSE_DSYM_OUTPUT_DIR:-}" ]]; then
        mkdir -p "$PULSE_DSYM_OUTPUT_DIR"
        dsymutil "$PULSE_WIDGET_BINARY" --out "$PULSE_DSYM_OUTPUT_DIR/PulseWidgets.appex.dSYM"
    fi
    strip -S -x "$PULSE_WIDGET_BINARY"
    while IFS= read -r -d '' PULSE_WIDGET_FILE; do
        if LC_ALL=C /usr/bin/grep -aFq "$PULSE_ROOT/" "$PULSE_WIDGET_FILE" \
            || LC_ALL=C /usr/bin/grep -aFq "$HOME/" "$PULSE_WIDGET_FILE"; then
            echo "Widget release bundle still contains a local home or build path." >&2
            exit 1
        fi
    done < <(find "$PULSE_WIDGET" -type f -print0)
fi
for PULSE_WIDGET_ARCHITECTURE in $PULSE_WIDGET_ARCHITECTURES; do
    lipo "$PULSE_WIDGET_BINARY" -verify_arch "$PULSE_WIDGET_ARCHITECTURE"
done
rm -rf "$PULSE_WIDGET_OUTPUT/PulseWidgets.appex"
mv "$PULSE_WIDGET" "$PULSE_WIDGET_OUTPUT/PulseWidgets.appex"
echo "Built $PULSE_WIDGET_OUTPUT/PulseWidgets.appex (ready for bundle signing)"

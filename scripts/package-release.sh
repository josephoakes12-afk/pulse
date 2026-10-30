#!/bin/bash
set -euo pipefail

PULSE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PULSE_VERSION="${1:-}"
PULSE_MODE="${2:-}"
if [[ ! "$PULSE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ -n "$PULSE_MODE" && "$PULSE_MODE" != --unsigned ]]; then
    echo "Usage: $0 major.minor.patch [--unsigned]" >&2
    exit 2
fi
if [[ "$PULSE_MODE" != --unsigned ]]; then
    [[ "${PULSE_SIGN_IDENTITY:-}" == 'Developer ID Application:'* ]] || {
        echo "Set PULSE_SIGN_IDENTITY to a Developer ID Application identity." >&2; exit 2;
    }
    [[ -n "${PULSE_NOTARY_PROFILE:-}" ]] || {
        echo "Set PULSE_NOTARY_PROFILE to an existing notarytool Keychain profile." >&2; exit 2;
    }
    [[ -z "$(git -C "$PULSE_ROOT" status --porcelain)" ]] || {
        echo "Commit the reviewed source before packaging a public release." >&2; exit 2;
    }
fi

PULSE_RELEASE_DIR="${PULSE_RELEASE_DIR:-$PULSE_ROOT/build/releases/$PULSE_VERSION}"
mkdir -p "$PULSE_RELEASE_DIR"
PULSE_PACKAGE_STAGE="$(mktemp -d "$PULSE_RELEASE_DIR/.package.XXXXXX")"
trap 'rm -rf "$PULSE_PACKAGE_STAGE"' EXIT
PULSE_NAME="Pulse-$PULSE_VERSION-macOS"
if [[ "$PULSE_MODE" == --unsigned ]]; then
    PULSE_NAME+="-unsigned-preview"
    export PULSE_SIGN_IDENTITY=-
fi
PULSE_DMG="$PULSE_RELEASE_DIR/$PULSE_NAME.dmg"
PULSE_ZIP="$PULSE_RELEASE_DIR/$PULSE_NAME.zip"
[[ ! -e "$PULSE_DMG" && ! -e "$PULSE_ZIP" ]] || { echo "Release files already exist; choose a new output directory." >&2; exit 2; }

PULSE_VERSION="$PULSE_VERSION" PULSE_ARCHITECTURES=universal \
    PULSE_OUTPUT_DIR="$PULSE_PACKAGE_STAGE/app" "$PULSE_ROOT/scripts/build-app.sh" release
PULSE_APP="$PULSE_PACKAGE_STAGE/app/Pulse.app"

notarize() {
    local artifact="$1" receipt="$2"
    xcrun notarytool submit "$artifact" --keychain-profile "$PULSE_NOTARY_PROFILE" \
        --wait --output-format json > "$receipt"
    [[ "$(/usr/bin/plutil -extract status raw "$receipt")" == Accepted ]] || {
        echo "Notarization was not accepted. See $receipt." >&2; exit 1;
    }
}

if [[ "$PULSE_MODE" != --unsigned ]]; then
    PULSE_RECEIPTS="$PULSE_ROOT/.local/releases/$PULSE_VERSION"
    mkdir -p "$PULSE_RECEIPTS"
    chmod 700 "$PULSE_RECEIPTS"
    ditto -c -k --sequesterRsrc --keepParent "$PULSE_APP" "$PULSE_PACKAGE_STAGE/notarize.zip"
    notarize "$PULSE_PACKAGE_STAGE/notarize.zip" "$PULSE_RECEIPTS/app-notarization.json"
    xcrun stapler staple "$PULSE_APP"
    xcrun stapler validate "$PULSE_APP"
    spctl --assess --type execute --verbose=2 "$PULSE_APP"
fi

mkdir "$PULSE_PACKAGE_STAGE/disk"
ditto "$PULSE_APP" "$PULSE_PACKAGE_STAGE/disk/Pulse.app"
ln -s /Applications "$PULSE_PACKAGE_STAGE/disk/Applications"
hdiutil create -volname Pulse -srcfolder "$PULSE_PACKAGE_STAGE/disk" \
    -fs HFS+ -format UDZO "$PULSE_DMG"
if [[ "$PULSE_MODE" != --unsigned ]]; then
    codesign --force --timestamp --sign "$PULSE_SIGN_IDENTITY" "$PULSE_DMG"
    notarize "$PULSE_DMG" "$PULSE_RECEIPTS/dmg-notarization.json"
    xcrun stapler staple "$PULSE_DMG"
    xcrun stapler validate "$PULSE_DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$PULSE_DMG"
fi
ditto -c -k --sequesterRsrc --keepParent "$PULSE_APP" "$PULSE_ZIP"
(cd "$PULSE_RELEASE_DIR" && shasum -a 256 "$PULSE_NAME.dmg" "$PULSE_NAME.zip" > SHA256SUMS)
echo "Packaged $PULSE_DMG"
echo "Packaged $PULSE_ZIP"
if [[ "$PULSE_MODE" == --unsigned ]]; then
    echo "Unsigned local preview only. Do not publish as the standard download."
fi

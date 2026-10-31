#!/bin/bash
set -euo pipefail

PULSE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PULSE_VERSION="${1:-}"
[[ "$PULSE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "Usage: $0 major.minor.patch" >&2; exit 2;
}
[[ "${PULSE_SIGN_IDENTITY:-}" == 'Apple Distribution:'* || "${PULSE_SIGN_IDENTITY:-}" == '3rd Party Mac Developer Application:'* ]] || {
    echo "Set PULSE_SIGN_IDENTITY to an Apple Distribution or Mac App Distribution identity." >&2; exit 2;
}
[[ "${PULSE_INSTALLER_SIGN_IDENTITY:-}" == '3rd Party Mac Developer Installer:'* || "${PULSE_INSTALLER_SIGN_IDENTITY:-}" == 'Mac Installer Distribution:'* ]] || {
    echo "Set PULSE_INSTALLER_SIGN_IDENTITY to a Mac Installer Distribution identity." >&2; exit 2;
}
[[ -f "${PULSE_APP_STORE_PROFILE:-}" && -f "${PULSE_WIDGET_PROFILE:-}" ]] || {
    echo "Set PULSE_APP_STORE_PROFILE and PULSE_WIDGET_PROFILE to explicit Mac App Store profiles." >&2; exit 2;
}
[[ -z "$(git -C "$PULSE_ROOT" status --porcelain)" ]] || {
    echo "Commit the reviewed source before packaging an App Store upload." >&2; exit 2;
}
PULSE_STORE_DIR="${PULSE_STORE_DIR:-$PULSE_ROOT/build/app-store/$PULSE_VERSION}"
PULSE_BUILD_NUMBER="${PULSE_BUILD_NUMBER:-1}"
PULSE_BUNDLE_IDENTIFIER="${PULSE_BUNDLE_IDENTIFIER:-uk.co.builtby2.pulse}"
PULSE_ARCHIVE="$PULSE_STORE_DIR/Pulse.xcarchive"
PULSE_PACKAGE="$PULSE_STORE_DIR/Pulse-$PULSE_VERSION-AppStore.pkg"
[[ ! -e "$PULSE_ARCHIVE" && ! -e "$PULSE_PACKAGE" ]] || {
    echo "Store artifacts already exist; choose a new PULSE_STORE_DIR." >&2; exit 2;
}
mkdir -p "$PULSE_STORE_DIR"
PULSE_STORE_STAGE="$(mktemp -d "$PULSE_STORE_DIR/.store-package.XXXXXX")"
trap 'rm -rf "$PULSE_STORE_STAGE"' EXIT
PULSE_STAGED_ARCHIVE="$PULSE_STORE_STAGE/Pulse.xcarchive"
PULSE_ARCHIVE_APPS="$PULSE_STAGED_ARCHIVE/Products/Applications"
mkdir -p "$PULSE_ARCHIVE_APPS"
PULSE_DISTRIBUTION_CHANNEL=app-store PULSE_VERSION="$PULSE_VERSION" \
    PULSE_BUILD_NUMBER="$PULSE_BUILD_NUMBER" PULSE_BUILD_WIDGETS=1 PULSE_ARCHITECTURES=universal \
    PULSE_OUTPUT_DIR="$PULSE_ARCHIVE_APPS" PULSE_DSYM_OUTPUT_DIR="$PULSE_STAGED_ARCHIVE/dSYMs" \
    "$PULSE_ROOT/scripts/build-app.sh" release
PULSE_APP="$PULSE_ARCHIVE_APPS/Pulse.app"
codesign --verify --deep --strict "$PULSE_APP"
# Mac App Store packages go through Apple's processing and review; they are not
# Developer ID downloads and must not be sent to notarytool or stapler.
PULSE_INSTALLER_OPTIONS=()
if [[ -n "${PULSE_SIGNING_KEYCHAIN:-}" ]]; then
    PULSE_INSTALLER_OPTIONS+=(--keychain "$PULSE_SIGNING_KEYCHAIN")
fi
productbuild --component "$PULSE_APP" /Applications \
    --sign "$PULSE_INSTALLER_SIGN_IDENTITY" "${PULSE_INSTALLER_OPTIONS[@]}" "$PULSE_STORE_STAGE/Pulse.pkg"
pkgutil --check-signature "$PULSE_STORE_STAGE/Pulse.pkg"
python3 - "$PULSE_STAGED_ARCHIVE" "$PULSE_ROOT" "$PULSE_SIGN_IDENTITY" <<'PY'
from datetime import datetime, timezone
from pathlib import Path
import json
import plistlib
import subprocess
import sys

archive, root, identity = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
app_info = plistlib.loads((archive / "Products/Applications/Pulse.app/Contents/Info.plist").read_bytes())
info = {
    "ArchiveVersion": 2,
    "CreationDate": datetime.now(timezone.utc).replace(tzinfo=None),
    "Name": "Pulse",
    "SchemeName": "Pulse",
    "ApplicationProperties": {
        "ApplicationPath": "Applications/Pulse.app",
        "CFBundleIdentifier": app_info["CFBundleIdentifier"],
        "CFBundleShortVersionString": app_info["CFBundleShortVersionString"],
        "CFBundleVersion": app_info["CFBundleVersion"],
        "SigningIdentity": identity,
    },
}
(archive / "Info.plist").write_bytes(plistlib.dumps(info))
receipt = {
    "channel": "app-store",
    "sourceRevision": subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip(),
    "version": app_info["CFBundleShortVersionString"],
    "build": app_info["CFBundleVersion"],
    "bundleIdentifier": app_info["CFBundleIdentifier"],
    "architectures": ["arm64", "x86_64"],
    "submitted": False,
}
(archive.parent / "build-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
PY
mv "$PULSE_STAGED_ARCHIVE" "$PULSE_ARCHIVE"
mv "$PULSE_STORE_STAGE/Pulse.pkg" "$PULSE_PACKAGE"
mv "$PULSE_STORE_STAGE/build-receipt.json" "$PULSE_STORE_DIR/build-receipt.json"
(cd "$PULSE_STORE_DIR" && shasum -a 256 "$(basename "$PULSE_PACKAGE")" > SHA256SUMS)
echo "Prepared $PULSE_ARCHIVE"
echo "Prepared $PULSE_PACKAGE"
echo "Ready for validation/upload. Nothing has been submitted for review or released."

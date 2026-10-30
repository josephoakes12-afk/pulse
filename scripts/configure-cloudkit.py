#!/usr/bin/env python3
"""Validate a private CloudKit distribution profile and merge minimal entitlements."""

import argparse
import base64
from datetime import datetime, timezone
from fnmatch import fnmatchcase
from pathlib import Path
import plistlib
import re
import subprocess
import sys


def cloudkit_entitlements(profile, team, container, bundle_id, certificates, now=None):
    """Select only the privileges Pulse needs from an Apple-issued Mac profile."""
    now = now or datetime.now(timezone.utc)
    expires = profile.get("ExpirationDate")
    if not isinstance(expires, datetime) or expires.replace(tzinfo=timezone.utc) <= now:
        raise ValueError("The CloudKit provisioning profile has expired.")
    if profile.get("TeamIdentifier") != [team]:
        raise ValueError("The CloudKit provisioning profile belongs to a different team.")
    if "OSX" not in profile.get("Platform", []):
        raise ValueError("CloudKit needs a macOS provisioning profile.")
    if profile.get("ProvisionsAllDevices") is not True or profile.get("ProvisionedDevices"):
        raise ValueError("Use a Developer ID distribution profile, not a device-limited profile.")
    if not certificates or not set(certificates).intersection(profile.get("DeveloperCertificates", [])):
        raise ValueError("The CloudKit profile does not include the selected signing certificate.")
    allowed = profile.get("Entitlements", {})
    app_id = f"{team}.{bundle_id}"
    if allowed.get("com.apple.application-identifier") != app_id:
        raise ValueError("The CloudKit profile must match Pulse's explicit Mac App ID.")
    if allowed.get("com.apple.developer.team-identifier") != team:
        raise ValueError("The profile's team entitlement does not match the signing team.")
    if allowed.get("get-task-allow") or allowed.get("com.apple.security.get-task-allow"):
        raise ValueError("A development profile cannot authorize a CloudKit release.")
    services = allowed.get("com.apple.developer.icloud-services", [])
    if services != "*" and "CloudKit" not in services:
        raise ValueError("The provisioning profile does not enable CloudKit.")
    containers = allowed.get("com.apple.developer.icloud-container-identifiers", [])
    if not any(fnmatchcase(container, pattern) for pattern in containers):
        raise ValueError("The profile does not authorize the selected iCloud container.")
    environment = allowed.get("com.apple.developer.icloud-container-environment")
    if environment != "Production" and not (
        isinstance(environment, list) and "Production" in environment
    ):
        raise ValueError("The CloudKit profile must authorize the Production environment.")
    return {
        "com.apple.application-identifier": app_id,
        "com.apple.developer.team-identifier": team,
        "com.apple.developer.icloud-services": ["CloudKit"],
        "com.apple.developer.icloud-container-identifiers": [container],
        "com.apple.developer.icloud-container-environment": "Production",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--team", required=True)
    parser.add_argument("--container", required=True)
    parser.add_argument("--bundle-id", default="uk.co.builtby2.pulse")
    parser.add_argument("--sign-identity", required=True)
    parser.add_argument("--entitlements", type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Z0-9]{10}", args.team):
        parser.error("A real signing team is required.")
    if not re.fullmatch(r"iCloud\.[A-Za-z0-9][A-Za-z0-9.-]+", args.container):
        parser.error("Use a registered iCloud container identifier.")
    if not args.sign_identity.startswith("Developer ID Application:"):
        parser.error("Private CloudKit distribution needs a Developer ID Application identity.")
    try:
        profile = plistlib.loads(subprocess.check_output(
            ["security", "cms", "-D", "-i", str(args.profile)], stderr=subprocess.DEVNULL))
        pem = subprocess.check_output(
            ["security", "find-certificate", "-a", "-c", args.sign_identity, "-p"],
            stderr=subprocess.DEVNULL, text=True)
        certificates = [base64.b64decode(value) for value in re.findall(
            r"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", pem, re.S)]
        additions = cloudkit_entitlements(profile, args.team, args.container,
                                         args.bundle_id, certificates)
        existing = plistlib.loads(args.entitlements.read_bytes()) if args.entitlements.exists() else {}
        existing.update(additions)
        args.entitlements.write_bytes(plistlib.dumps(existing))
    except (OSError, ValueError, TypeError, plistlib.InvalidFileException, subprocess.CalledProcessError):
        print("CloudKit profile validation failed. Use an unexpired Developer ID profile for this "
              "Mac App ID, signing certificate, team and Production iCloud container.", file=sys.stderr)
        return 2
    print("Validated private CloudKit distribution profile.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

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


def distribution_entitlements(profile, team, bundle_id, certificates, distribution="developer-id", now=None):
    """Validate the channel, exact app and certificate before selecting privileges."""
    now = now or datetime.now(timezone.utc)
    expires = profile.get("ExpirationDate")
    if not isinstance(expires, datetime) or expires.replace(tzinfo=timezone.utc) <= now:
        raise ValueError("The distribution provisioning profile has expired.")
    if profile.get("TeamIdentifier") != [team]:
        raise ValueError("The distribution provisioning profile belongs to a different team.")
    if "OSX" not in profile.get("Platform", []):
        raise ValueError("Use a macOS provisioning profile.")
    if distribution == "developer-id":
        if profile.get("ProvisionsAllDevices") is not True or profile.get("ProvisionedDevices"):
            raise ValueError("Use a Developer ID distribution profile, not a device-limited profile.")
    elif distribution == "app-store":
        if profile.get("ProvisionsAllDevices") or profile.get("ProvisionedDevices"):
            raise ValueError("Use a Mac App Store distribution profile, not Developer ID or development.")
    else:
        raise ValueError("Unknown distribution channel.")
    if not certificates or not set(certificates).intersection(profile.get("DeveloperCertificates", [])):
        raise ValueError("The profile does not include the selected signing certificate.")
    allowed = profile.get("Entitlements", {})
    app_id = f"{team}.{bundle_id}"
    if allowed.get("com.apple.application-identifier") != app_id:
        raise ValueError("The profile must match Pulse's explicit Mac App ID.")
    if allowed.get("com.apple.developer.team-identifier") != team:
        raise ValueError("The profile's team entitlement does not match the signing team.")
    if allowed.get("get-task-allow") or allowed.get("com.apple.security.get-task-allow"):
        raise ValueError("A development profile cannot authorize a distribution release.")
    result = {
        "com.apple.application-identifier": app_id,
        "com.apple.developer.team-identifier": team,
    }
    if distribution == "app-store" and allowed.get("beta-reports-active") is True:
        result["beta-reports-active"] = True
    return result


def cloudkit_entitlements(profile, team, container, bundle_id, certificates, now=None, distribution="developer-id"):
    """Select only the privileges Pulse needs from an Apple-issued Mac profile."""
    result = distribution_entitlements(profile, team, bundle_id, certificates, distribution, now)
    allowed = profile.get("Entitlements", {})
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
    result.update({
        "com.apple.developer.icloud-services": ["CloudKit"],
        "com.apple.developer.icloud-container-identifiers": [container],
        "com.apple.developer.icloud-container-environment": "Production",
    })
    return result


def validate_app_group(profile, team, app_group):
    """Mac team-prefixed groups need no portal registration; registered groups do."""
    allowed = profile.get("Entitlements", {}).get("com.apple.security.application-groups", [])
    if not app_group:
        return
    if allowed and any(fnmatchcase(app_group, pattern) for pattern in allowed):
        return
    if app_group.startswith(team + "."):
        return
    raise ValueError("The profile does not authorize the selected App Group.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--team", required=True)
    parser.add_argument("--container")
    parser.add_argument("--distribution", choices=["developer-id", "app-store"], default="developer-id")
    parser.add_argument("--app-group")
    parser.add_argument("--bundle-id", default="uk.co.builtby2.pulse")
    parser.add_argument("--sign-identity", required=True)
    parser.add_argument("--signing-keychain", type=Path)
    parser.add_argument("--entitlements", type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Z0-9]{10}", args.team):
        parser.error("A real signing team is required.")
    if args.container is not None and not re.fullmatch(r"iCloud\.[A-Za-z0-9][A-Za-z0-9.-]+", args.container):
        parser.error("Use a registered iCloud container identifier.")
    if args.distribution == "developer-id":
        if not args.container or not args.sign_identity.startswith("Developer ID Application:"):
            parser.error("Private CloudKit distribution needs a container and Developer ID Application identity.")
    elif not args.sign_identity.startswith(("Apple Distribution:", "3rd Party Mac Developer Application:")):
        parser.error("App Store builds need an Apple Distribution or Mac App Distribution identity.")
    try:
        profile = plistlib.loads(subprocess.check_output(
            ["security", "cms", "-D", "-i", str(args.profile)], stderr=subprocess.DEVNULL))
        certificate_command = ["security", "find-certificate", "-a", "-c", args.sign_identity, "-p"]
        if args.signing_keychain:
            certificate_command.append(str(args.signing_keychain))
        pem = subprocess.check_output(certificate_command, stderr=subprocess.DEVNULL, text=True)
        certificates = [base64.b64decode(value) for value in re.findall(
            r"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", pem, re.S)]
        additions = cloudkit_entitlements(profile, args.team, args.container,
                                         args.bundle_id, certificates, distribution=args.distribution) if args.container else distribution_entitlements(
                                             profile, args.team, args.bundle_id, certificates, args.distribution)
        validate_app_group(profile, args.team, args.app_group)
        existing = plistlib.loads(args.entitlements.read_bytes()) if args.entitlements.exists() else {}
        existing.update(additions)
        args.entitlements.write_bytes(plistlib.dumps(existing))
    except (OSError, ValueError, TypeError, plistlib.InvalidFileException, subprocess.CalledProcessError):
        print("Distribution profile validation failed. Use an unexpired profile for this "
              "channel, explicit Mac App ID, signing certificate, team, App Group and Production iCloud container.", file=sys.stderr)
        return 2
    print("Validated " + args.distribution + " distribution profile.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

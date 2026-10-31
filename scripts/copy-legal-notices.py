#!/usr/bin/env python3
"""Copy verified, pinned third-party notices without network access."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys


def copy_notices(legal_directory, checkouts_directory, destination):
    entries = json.loads((legal_directory / "manifest.json").read_text())
    if {entry["component"] for entry in entries} != {"CNIOBoringSSL", "CCryptoBoringSSL"} or len(entries) != 2:
        raise ValueError("The legal manifest must cover both bundled BoringSSL components.")
    # Validate every entry before writing output, so a dependency update cannot
    # leave a partially refreshed set of notices that looks complete.
    for entry in entries:
        revision = entry["revision"]
        if not re.fullmatch(r"[0-9a-f]{40}", revision):
            raise ValueError("Invalid notice source revision.")
        source = legal_directory / entry["licenseFile"]
        if source.parent.resolve() != legal_directory.resolve():
            raise ValueError("Notice files must be stored in the legal directory.")
        content = source.read_bytes()
        if not content.strip() or hashlib.sha256(content).hexdigest() != entry["sha256"]:
            raise ValueError("Pinned notice text is missing or has changed.")
        expected_url = "https://raw.githubusercontent.com/google/boringssl/" + revision + "/LICENSE"
        if entry["sourceURL"] != expected_url:
            raise ValueError("Notice provenance must identify the exact upstream revision.")
        revision_file = checkouts_directory / entry["dependency"] / entry["revisionFile"]
        vendor_revision = re.search(r"at revision ([0-9a-f]{40})", revision_file.read_text())
        if not vendor_revision or vendor_revision[1] != revision:
            raise ValueError("A vendored BoringSSL revision changed; update its upstream notice before packaging.")
    destination.mkdir(parents=True, exist_ok=True)
    for entry in entries:
        output = destination / entry["licenseFile"]
        shutil.copyfile(legal_directory / entry["licenseFile"], output)
        output.chmod(0o644)
    for name in ("manifest.json", "README.md"):
        shutil.copyfile(legal_directory / name, destination / name)
        (destination / name).chmod(0o644)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--legal-directory", type=Path, required=True)
    parser.add_argument("--checkouts-directory", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    try:
        copy_notices(args.legal_directory, args.checkouts_directory, args.destination)
    except (OSError, ValueError, KeyError, TypeError):
        print("Required third-party notices could not be verified. Check Resources/Legal and the resolved BoringSSL revisions.", file=sys.stderr)
        return 2
    print("Copied verified BoringSSL notices.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

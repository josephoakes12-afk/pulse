"""Synthetic checks for restricted CloudKit release signing privileges."""

from copy import deepcopy
from datetime import datetime, timedelta, timezone
import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location(
    "cloudkit_profile", Path(__file__).parents[2] / "scripts/configure-cloudkit.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CloudKitProfileTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 1, 1, tzinfo=timezone.utc)
        self.team = "ABCDEFGHIJ"
        self.container = "iCloud.example.pulse"
        self.certificate = b"synthetic public certificate"
        self.profile = {
            "ExpirationDate": self.now + timedelta(days=365),
            "TeamIdentifier": [self.team],
            "Platform": ["OSX"],
            "ProvisionsAllDevices": True,
            "DeveloperCertificates": [self.certificate],
            "Entitlements": {
                "com.apple.application-identifier": self.team + ".uk.co.builtby2.pulse",
                "com.apple.developer.team-identifier": self.team,
                "com.apple.developer.icloud-services": ["CloudKit", "CloudDocuments"],
                "com.apple.developer.icloud-container-identifiers": [self.container, "iCloud.other"],
                "com.apple.developer.icloud-container-environment": "Production",
                "keychain-access-groups": [self.team + ".*"],
            },
        }

    def validate(self, profile=None, certificates=None):
        return module.cloudkit_entitlements(
            profile or self.profile, self.team, self.container, "uk.co.builtby2.pulse",
            [self.certificate] if certificates is None else certificates, self.now)

    def test_only_required_privileges_are_emitted(self):
        entitlements = self.validate()
        self.assertEqual(entitlements["com.apple.developer.icloud-services"], ["CloudKit"])
        self.assertEqual(entitlements["com.apple.developer.icloud-container-identifiers"], [self.container])
        self.assertNotIn("keychain-access-groups", entitlements)
        self.assertNotIn("com.apple.security.get-task-allow", entitlements)

    def test_profile_must_authorize_team_app_platform_and_all_devices(self):
        for key, value in [
            ("TeamIdentifier", ["OTHERTEAM1"]), ("Platform", ["iOS"]),
            ("ProvisionsAllDevices", False), ("ProvisionedDevices", ["a-device"]),
            ("ExpirationDate", self.now),
        ]:
            with self.subTest(key=key):
                profile = deepcopy(self.profile)
                profile[key] = value
                with self.assertRaises(ValueError):
                    self.validate(profile)

    def test_development_and_wrong_cloud_authorizations_are_rejected(self):
        for key, value in [
            ("com.apple.application-identifier", self.team + ".*"),
            ("com.apple.developer.team-identifier", "OTHERTEAM1"),
            ("com.apple.security.get-task-allow", True),
            ("get-task-allow", True),
            ("com.apple.developer.icloud-services", ["CloudDocuments"]),
            ("com.apple.developer.icloud-container-identifiers", ["iCloud.other"]),
            ("com.apple.developer.icloud-container-environment", "Development"),
        ]:
            with self.subTest(key=key):
                profile = deepcopy(self.profile)
                profile["Entitlements"][key] = value
                with self.assertRaises(ValueError):
                    self.validate(profile)

    def test_selected_certificate_must_be_in_profile(self):
        for certificates in [[], [b"another public certificate"]]:
            with self.subTest(certificates=certificates):
                with self.assertRaises(ValueError):
                    self.validate(certificates=certificates)

    def test_fork_identifier_must_match_its_own_profile(self):
        identifier = "com.example.pulse-fork"
        self.profile["Entitlements"]["com.apple.application-identifier"] = self.team + "." + identifier
        entitlements = module.cloudkit_entitlements(
            self.profile, self.team, self.container, identifier, [self.certificate], self.now)
        self.assertEqual(entitlements["com.apple.application-identifier"], self.team + "." + identifier)
        with self.assertRaises(ValueError):
            self.validate()

    def test_profile_wildcards_still_emit_narrow_actual_entitlements(self):
        self.profile["Entitlements"]["com.apple.developer.icloud-services"] = "*"
        self.profile["Entitlements"]["com.apple.developer.icloud-container-identifiers"] = ["iCloud.example.*"]
        self.profile["Entitlements"]["com.apple.developer.icloud-container-environment"] = ["Development", "Production"]
        entitlements = self.validate()
        self.assertEqual(entitlements["com.apple.developer.icloud-services"], ["CloudKit"])
        self.assertEqual(entitlements["com.apple.developer.icloud-container-identifiers"], [self.container])
        self.assertEqual(entitlements["com.apple.developer.icloud-container-environment"], "Production")


if __name__ == "__main__":
    unittest.main()

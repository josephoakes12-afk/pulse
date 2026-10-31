"""Store release profiles cannot accidentally reuse Developer ID/development access."""

from copy import deepcopy
from datetime import datetime, timedelta, timezone
import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location(
    "store_profile", Path(__file__).parents[2] / "scripts/configure-cloudkit.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class AppStoreProfileTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 1, 1, tzinfo=timezone.utc)
        self.team = "ABCDEFGHIJ"
        self.bundle = "com.example.pulse"
        self.certificate = b"synthetic store public certificate"
        self.profile = {
            "ExpirationDate": self.now + timedelta(days=365),
            "TeamIdentifier": [self.team],
            "Platform": ["OSX"],
            "DeveloperCertificates": [self.certificate],
            "Entitlements": {
                "com.apple.application-identifier": self.team + "." + self.bundle,
                "com.apple.developer.team-identifier": self.team,
                "com.apple.developer.icloud-services": ["CloudKit"],
                "com.apple.developer.icloud-container-identifiers": ["iCloud.com.example.pulse"],
                "com.apple.developer.icloud-container-environment": "Production",
                "beta-reports-active": True,
            },
        }

    def validate(self, profile=None):
        return module.distribution_entitlements(
            profile or self.profile, self.team, self.bundle,
            [self.certificate], "app-store", self.now)

    def test_store_profile_emits_only_exact_identity_and_testflight_privilege(self):
        self.assertEqual(self.validate(), {
            "com.apple.application-identifier": self.team + "." + self.bundle,
            "com.apple.developer.team-identifier": self.team,
            "beta-reports-active": True,
        })

    def test_developer_id_and_device_profiles_are_rejected_for_store(self):
        for key, value in [("ProvisionsAllDevices", True), ("ProvisionedDevices", ["mac-udid"])]:
            with self.subTest(key=key):
                profile = deepcopy(self.profile)
                profile[key] = value
                with self.assertRaises(ValueError):
                    self.validate(profile)
        with self.assertRaises(ValueError):
            module.distribution_entitlements(
                self.profile, self.team, self.bundle, [self.certificate], "developer-id", self.now)

    def test_store_cloudkit_still_requires_production_exact_container(self):
        result = module.cloudkit_entitlements(
            self.profile, self.team, "iCloud.com.example.pulse", self.bundle,
            [self.certificate], self.now, "app-store")
        self.assertEqual(result["com.apple.developer.icloud-container-environment"], "Production")
        with self.assertRaises(ValueError):
            module.cloudkit_entitlements(
                self.profile, self.team, "iCloud.someone.else", self.bundle,
                [self.certificate], self.now, "app-store")

    def test_widget_requires_its_own_explicit_app_profile(self):
        with self.assertRaises(ValueError):
            module.distribution_entitlements(
                self.profile, self.team, self.bundle + ".widgets",
                [self.certificate], "app-store", self.now)

    def test_team_prefixed_mac_group_and_registered_group_are_scoped(self):
        module.validate_app_group(self.profile, self.team, self.team + ".local.pulse.shared")
        with self.assertRaises(ValueError):
            module.validate_app_group(self.profile, self.team, "OTHERTEAM1.local.pulse.shared")
        with self.assertRaises(ValueError):
            module.validate_app_group(self.profile, self.team, "group.com.example.pulse")
        self.profile["Entitlements"]["com.apple.security.application-groups"] = ["group.com.example.pulse"]
        module.validate_app_group(self.profile, self.team, "group.com.example.pulse")
        with self.assertRaises(ValueError):
            module.validate_app_group(self.profile, self.team, "group.com.example.other")


if __name__ == "__main__":
    unittest.main()

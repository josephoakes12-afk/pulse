"""Check public build identity validation without invoking Swift or Xcode builds."""

import os
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
import unittest


class BundleIdentifierTests(unittest.TestCase):
    def run_builder(self, script, identifier):
        root = Path(__file__).parents[2]
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for name in ("swift", "xcodebuild"):
                command = directory / name
                command.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$PULSE_TEST_BUILD_ARGS"\nexit 93\n')
                command.chmod(0o700)
            environment = {key: value for key, value in os.environ.items() if not key.startswith("PULSE_")}
            environment.update({
                "PATH": str(directory) + os.pathsep + environment["PATH"],
                "PULSE_BUNDLE_IDENTIFIER": identifier,
                "PULSE_TEST_BUILD_ARGS": str(directory / "arguments"),
                "PULSE_BUILD_WIDGETS": "0",
            })
            arguments = [str(root / "scripts" / script)]
            arguments += ["release"] if script == "build-app.sh" else [str(directory / "widget"), "release"]
            result = subprocess.run(arguments, cwd=root, env=environment, capture_output=True, text=True, timeout=10)
            recorded = (directory / "arguments").read_text().splitlines() if (directory / "arguments").exists() else []
            return result, recorded

    def test_invalid_identifiers_fail_before_any_build(self):
        for identifier in ("pulse", ".com.example", "com..example", "com.example-", "com.exam_ple.pulse", "com.example.pulse;echo", "com." + "a" * 244):
            for script in ("build-app.sh", "build-widget.sh"):
                with self.subTest(identifier=identifier, script=script):
                    result, arguments = self.run_builder(script, identifier)
                    self.assertEqual(result.returncode, 2)
                    self.assertIn("reverse-DNS", result.stderr)
                    self.assertEqual(arguments, [])

    def test_own_fork_identifier_reaches_build_and_names_widget(self):
        identifier = "com.example.pulse-fork"
        for script in ("build-app.sh", "build-widget.sh"):
            with self.subTest(script=script):
                result, arguments = self.run_builder(script, identifier)
                self.assertEqual(result.returncode, 93)  # Only our stub builder ran.
                if script == "build-widget.sh":
                    self.assertIn("PRODUCT_BUNDLE_IDENTIFIER=" + identifier + ".widgets", arguments)


if __name__ == "__main__":
    unittest.main()

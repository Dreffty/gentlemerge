#!/usr/bin/env python3
"""Exercise build/install entry points without installing into the user's home."""
import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent


class BuildContractTests(unittest.TestCase):
    def make_plan(self, *args):
        return subprocess.run(['make', '-n', *args], cwd=ROOT,
                              text=True, capture_output=True, timeout=10)

    def test_linux_install_uses_local_bin_and_no_bundle(self):
        result = self.make_plan('install', 'UNAME_S=Linux')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('/.local/bin', result.stdout)
        self.assertIn('swift build -c release', result.stdout)
        self.assertNotIn('bundle.sh', result.stdout)

    def test_mac_install_uses_usr_local_bin(self):
        result = self.make_plan('install', 'UNAME_S=Darwin')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('/usr/local/bin', result.stdout)

    def test_linux_hooks_are_headless(self):
        result = self.make_plan('install-hooks', 'UNAME_S=Linux')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('bundle.sh', result.stdout)
        self.assertIn('gentlemerge install', result.stdout)


if __name__ == '__main__':
    unittest.main()

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

    def test_mac_install_needs_no_sudo(self):
        """macOS installs into the home prefix, exactly as Linux does.

        It used to be /usr/local/bin, which is root-owned on a stock macOS: the
        install command the README leads with failed on its first line for
        anyone who had not already made that directory writable. Pinned here so
        the default cannot drift back to a path that needs sudo.
        """
        result = self.make_plan('install', 'UNAME_S=Darwin')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('/.local/bin', result.stdout)
        self.assertNotIn('install -d "/usr/local/bin"', result.stdout)

    def test_prefix_is_still_the_way_to_choose_somewhere_else(self):
        for platform in ('Darwin', 'Linux'):
            result = self.make_plan('install', f'UNAME_S={platform}', 'PREFIX=/opt/gm')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('/opt/gm/bin', result.stdout)

    def test_linux_hooks_are_headless(self):
        result = self.make_plan('install-hooks', 'UNAME_S=Linux')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('bundle.sh', result.stdout)
        self.assertIn('gentlemerge install', result.stdout)


if __name__ == '__main__':
    unittest.main()

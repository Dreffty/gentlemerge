#!/usr/bin/env python3
"""Exercise build/install entry points without installing into the user's home."""
import os
import pathlib
import stat
import subprocess
import tempfile
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

    def test_the_app_installs_outside_the_protected_folders_without_sudo(self):
        """It used to run from build/, inside ~/Downloads when the repo lives there.

        That folder is protected: every launch of a freshly built app asked for
        it again, and the app hung until somebody answered.
        """
        result = self.make_plan('install-app', 'UNAME_S=Darwin')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(pathlib.Path.home() / 'Applications'), result.stdout)
        self.assertNotIn('sudo', result.stdout)

    def test_app_dir_chooses_somewhere_else(self):
        result = self.make_plan('install-app', 'UNAME_S=Darwin', 'APP_DIR=/Applications')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('install-app.sh "/Applications"', result.stdout)

    def test_make_run_opens_the_installed_app_not_the_build_folder(self):
        result = self.make_plan('run', 'UNAME_S=Darwin')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('install-app', ROOT.joinpath('Makefile').read_text().split('\nrun:')[1].split('\n')[0])
        self.assertNotIn('open build/GentleMerge.app', result.stdout)


class SigningIdentityTests(unittest.TestCase):
    """A rebuilt app must keep its identity, or macOS asks for every permission again."""

    SCRIPT = ROOT / 'Scripts' / 'signing-identity.sh'

    def pick(self, identities, **environment):
        with tempfile.TemporaryDirectory() as directory:
            fake = pathlib.Path(directory) / 'security'
            fake.write_text('#!/bin/sh\ncat <<LIST\n' + identities + '\nLIST\n')
            fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
            env = {k: v for k, v in os.environ.items() if k != 'CODESIGN_IDENTITY'}
            env['PATH'] = directory + os.pathsep + env['PATH']
            env.update(environment)
            return subprocess.run(['sh', str(self.SCRIPT)], text=True,
                                  capture_output=True, timeout=10, env=env)

    def test_it_finds_an_apple_development_identity_by_itself(self):
        result = self.pick('  1) AA8E "Apple Development: someone@example.invalid (M4GZ37V5M2)"\n     1 valid identities found')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'Apple Development: someone@example.invalid (M4GZ37V5M2)')
        self.assertEqual(result.stderr, '')

    def test_without_one_it_signs_ad_hoc_and_says_what_that_costs(self):
        result = self.pick('     0 valid identities found')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '-')
        self.assertIn('every rebuild', result.stderr)

    def test_an_explicit_identity_wins(self):
        result = self.pick('  1) AA8E "Apple Development: someone@example.invalid (M4GZ37V5M2)"',
                           CODESIGN_IDENTITY='Developer ID Application: X')
        self.assertEqual(result.stdout.strip(), 'Developer ID Application: X')

    def test_ad_hoc_can_be_asked_for_by_name(self):
        result = self.pick('  1) AA8E "Apple Development: someone@example.invalid (M4GZ37V5M2)"',
                           CODESIGN_IDENTITY='-')
        self.assertEqual(result.stdout.strip(), '-')
        self.assertEqual(result.stderr, '', 'asked for on purpose: nothing to warn about')


if __name__ == '__main__':
    unittest.main()

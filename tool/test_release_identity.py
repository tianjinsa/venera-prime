import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('check_release_identity.py').resolve()


class ReleaseIdentityTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.env = dict(os.environ, GIT_AUTHOR_NAME='Anonymous',
                        GIT_AUTHOR_EMAIL='anonymous@users.noreply.github.com',
                        GIT_COMMITTER_NAME='Anonymous',
                        GIT_COMMITTER_EMAIL='anonymous@users.noreply.github.com',
                        RELEASE_ACTOR='release-app[bot]',
                        RELEASE_TRIGGERING_ACTOR='release-app[bot]',
                        RELEASE_TAG='v2.4.2')
        self.git('init', '-q')
        self.git('-c', 'commit.gpgsign=false', 'commit', '--allow-empty', '-qm', 'Fixture')

    def git(self, *args):
        return subprocess.run(['git', *args], cwd=self.directory.name,
                              env=self.env, check=True, capture_output=True)

    def check(self):
        return subprocess.run(['python3', str(SCRIPT)], cwd=self.directory.name,
                              env=self.env, capture_output=True).returncode

    def test_bot_with_anonymous_commit(self):
        self.assertEqual(self.check(), 0)

    def test_personal_actor_rejected(self):
        self.env['RELEASE_ACTOR'] = 'personal-fixture'
        self.assertNotEqual(self.check(), 0)

    def test_personal_rerun_rejected(self):
        self.env['RELEASE_TRIGGERING_ACTOR'] = 'personal-fixture'
        self.assertNotEqual(self.check(), 0)

    def test_missing_tag_rejected(self):
        self.env['RELEASE_TAG'] = ''
        self.assertNotEqual(self.check(), 0)

    def test_personal_committer_rejected(self):
        self.env['GIT_COMMITTER_NAME'] = 'Personal Fixture'
        self.env['GIT_COMMITTER_EMAIL'] = 'fixture@example.test'
        self.git('-c', 'commit.gpgsign=false', 'commit', '--allow-empty', '-qm', 'Fixture')
        self.assertNotEqual(self.check(), 0)


if __name__ == '__main__':
    unittest.main()

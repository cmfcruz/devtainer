"""Host account binding is atomic, session-specific, and never saves tokens."""

import json
import subprocess
import unittest

import test_host_gh_config as fixtures


class GitHubSetupTest(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.HostGhConfigTest()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)

    def setup_account(self, session="dev", account=None, overrides=None):
        f = self.fixture
        args = ["bash", "-x", str(f.home / "bin/dev"), "--session", session, "setup-github"]
        if account is not None:
            args.append(account)
        return subprocess.run(args, cwd=f.work, env=dict(f.env, **(overrides or {})),
                              capture_output=True, text=True)

    def test_setup_defaults_to_active_host_account_without_pasting_or_docker(self):
        f = self.fixture
        result = self.setup_account()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(f.credential.read_text(), "office-user\n")
        self.assertEqual(f.credential.stat().st_mode & 0o777, 0o600)
        self.assertEqual(f.store.stat().st_mode & 0o777, 0o700)
        self.assertFalse(f.calls.exists())
        self.assertNotIn(fixtures.TOKEN, result.stdout + result.stderr)
        self.assertNotIn("Paste", result.stdout + result.stderr)
        self.assertEqual(list(f.store.glob(".account.*")), [])

    def test_explicit_account_does_not_switch_host_active_account(self):
        f = self.fixture
        before = f.host_accounts.read_bytes()
        result = self.setup_account("personal", "personal-user")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((f.profile_dir("personal") / "github.account").read_text(), "personal-user\n")
        self.assertEqual(f.host_accounts.read_bytes(), before)
        calls = [json.loads(line)["args"] for line in f.gh_calls.read_text().splitlines()]
        self.assertEqual(calls, [["auth", "token", "--hostname", "github.com", "--user", "personal-user"]])
        self.assertEqual(f.credential.read_text(), "office-user\n")
        self.assertNotIn(fixtures.PERSONAL_TOKEN, result.stdout + result.stderr)
        self.assertFalse(f.calls.exists())

    def test_failed_lookup_preserves_previous_binding(self):
        f = self.fixture
        original = f.credential.read_bytes()
        for account, overrides in (("unknown-user", {}), ("bad: user", {}),
                                   ("office-user", {"TEST_GH_EXIT": "1"}),
                                   ("office-user", {"TEST_TOKEN": ""}),
                                   ("office-user", {"TEST_TOKEN": "bad;yaml"})):
            result = self.setup_account(account=account, overrides=overrides)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(f.credential.read_bytes(), original)
            self.assertNotIn(fixtures.TOKEN, result.stdout + result.stderr)
            self.assertFalse(f.calls.exists())
            self.assertEqual(list(f.store.glob(".account.*")), [])

    def test_extra_arguments_are_rejected(self):
        f = self.fixture
        result = subprocess.run([str(f.home / "bin/dev"), "setup-github", "one", "two"],
                                cwd=f.work, env=f.env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(f.calls.exists())
        self.assertFalse(f.gh_calls.exists())


if __name__ == "__main__":
    unittest.main()

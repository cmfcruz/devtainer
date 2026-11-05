"""Exercise host-only setup through a PTY with fake gh and browsers."""

import os
from pathlib import Path
import pty
import select
import subprocess
import time
import unittest

import test_host_gh_config as fixtures


class GitHubSetupTest(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.HostGhConfigTest()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.home = self.fixture.home
        self.env = dict(self.fixture.env)
        # Never open the real browser in tests.
        for name in ("xdg-open", "gio"):
            browser = self.home / "fake-bin" / name
            browser.write_text(
                '#!/bin/sh\nprintf "%s\\n" "$*" >> "$HOME/browser.log"\n'
                'exit "${TEST_BROWSER_EXIT:-0}"\n'
            )
            browser.chmod(0o755)

    def setup_token(self, launcher, token, name="default", overrides=None):
        master, slave = pty.openpty()
        process = subprocess.Popen(
            ["bash", "-x", str(self.home / "bin" / launcher), "setup-github", name],
            cwd=self.fixture.work, env=dict(self.env, **(overrides or {})),
            stdin=slave, stdout=slave, stderr=slave,
        )
        os.close(slave)
        output = b""
        try:
            deadline = time.monotonic() + 5
            while b"Paste token" not in output:
                if time.monotonic() > deadline:
                    self.fail("setup did not prompt for a token")
                if select.select([master], [], [], 0.05)[0]:
                    output += os.read(master, 4096)
            os.write(master, (token + "\n").encode())
            process.wait(timeout=5)
            while select.select([master], [], [], 0.05)[0]:
                try:
                    chunk = os.read(master, 4096)
                except OSError:
                    break
                if not chunk:
                    break
                output += chunk
            return process.returncode, output.decode()
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)

    def test_hidden_setup_named_selection_and_replacement(self):
        for launcher in ("dev", "devil"):
            token = fixtures.TOKEN + "_REPLACED"
            status, output = self.setup_token(launcher, token, "office")
            self.assertEqual(status, 0, output)
            self.assertNotIn(token, output)
            credential = self.fixture.store / "office.credential"
            self.assertEqual(credential.read_text(), f"test-user\n{token}\n")
            self.assertEqual(credential.stat().st_mode & 0o777, 0o600)
            self.assertEqual(self.fixture.store.stat().st_mode & 0o777, 0o700)
            self.assertEqual(list(self.fixture.store.glob(".setup.*")), [])
            self.assertFalse(self.fixture.log.exists(), "setup must not run Docker")
            for permission in ("contents=read", "actions=read", "pull_requests=read", "expires_in=30"):
                self.assertIn(permission, (self.home / "browser.log").read_text())

    def test_invalid_cancelled_and_failed_validation_preserve_saved_token(self):
        original = self.fixture.credential.read_bytes()
        for token, overrides, expected in (
            ("", {}, 0), ("ghp_CLASSIC", {}, 1),
            ("github_pat_BAD;yaml", {}, 1),
            (fixtures.TOKEN, {"TEST_GH_EXIT": "1"}, 1),
            (fixtures.TOKEN, {"TEST_USER": "bad: user"}, 1),
        ):
            status, output = self.setup_token("dev", token, overrides=overrides)
            self.assertEqual(status, expected, output)
            if token:
                self.assertNotIn(token, output)
            self.assertEqual(self.fixture.credential.read_bytes(), original)
            self.assertEqual(list(self.fixture.store.glob(".setup.*")), [])
            self.assertFalse(self.fixture.log.exists())

    def test_browser_failure_still_allows_setup(self):
        status, output = self.setup_token("devil", fixtures.TOKEN,
                                         overrides={"TEST_BROWSER_EXIT": "1"})
        self.assertEqual(status, 0, output)
        self.assertIn("Open the URL above manually", output)

    def test_noninteractive_setup_and_invalid_names(self):
        for launcher in ("dev", "devil"):
            for args in (("setup-github",), ("setup-github", "../escape"),
                         ("--github-token",), ("--github-token", "../escape")):
                result = subprocess.run(
                    [str(self.home / "bin" / launcher), *args],
                    cwd=self.fixture.work, env=self.env, capture_output=True, text=True,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.fixture.log.exists())


if __name__ == "__main__":
    unittest.main()

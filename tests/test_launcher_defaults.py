"""Check session parsing, command forwarding, and installation behavior."""

import json
import subprocess
import unittest

import test_host_gh_config as fixtures


class LauncherDefaultsTest(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.HostGhConfigTest()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)

    def test_tmux_names_and_command_override(self):
        f = self.fixture
        for name, tmux in (("my-project", "my-project"), ("my.app:work", "my_app_work"),
                           ("project with spaces", "project with spaces")):
            work = f.home / name
            work.mkdir()
            for options in ([], ["--session", "dev"], ["--session", "personal"]):
                for command in ([], ["nvim", "."], ["bash", "-lc", "printf test"]):
                    with self.subTest(name=name, options=options, command=command):
                        result = subprocess.run(
                            [str(f.home / "bin/dev"), *options, *command], cwd=work,
                            env=f.env, capture_output=True, text=True,
                        )
                        self.assertEqual(result.returncode, 0, result.stderr)
                        args = json.loads(f.log.read_text())["args"]
                        expected = command or ["tmux", "new-session", "-A", "-s", tmux, "-c", "/workspace"]
                        self.assertEqual(args[-len(expected):], expected)
                        session = options[-1] if options else "dev"
                        self.assertIn(f"{f.volume(session)}:/home", args)

    def test_invalid_session_names_and_options_do_not_call_docker(self):
        f = self.fixture
        for args in (["--session"], ["--session", ""], ["--session", "../dev"],
                     ["--session", "personal/dev"], ["--session", "a" * 49],
                     ["--github-token", "personal"]):
            result = subprocess.run([str(f.home / "bin/dev"), *args], cwd=f.work,
                                    env=f.env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(f.calls.exists())
        result = subprocess.run([str(f.home / "bin/dev"), "--help"], env=f.env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("--session", result.stdout)
        self.assertFalse(f.calls.exists())

    def test_setup_github_is_no_longer_required_or_supported(self):
        f = self.fixture
        result = subprocess.run([str(f.home / "bin/dev"), "setup-github"], cwd=f.work,
                                env=f.env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no longer needed", result.stderr)
        self.assertFalse(f.calls.exists())
        self.assertFalse(f.gh_calls.exists())

    def test_install_retires_only_generated_legacy_launcher(self):
        f = self.fixture
        legacy = f.home / "bin/devil"
        legacy.write_text('#!/bin/bash\nvolume_name="devil-test"\ndocker_args=()\n')
        subprocess.run(["bash", "install.sh", "--skip-build"], cwd=fixtures.ROOT,
                       env=f.env, check=True, capture_output=True)
        self.assertFalse(legacy.exists())
        legacy.write_text('#!/bin/bash\necho my-own-command\n')
        subprocess.run(["bash", "install.sh", "--skip-build"], cwd=fixtures.ROOT,
                       env=f.env, check=True, capture_output=True)
        self.assertTrue(legacy.exists())
        self.assertFalse(f.state_file.exists(), "installation must not modify old volumes")


if __name__ == "__main__":
    unittest.main()

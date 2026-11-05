"""Exercise entrypoint authentication with a real gh CLI, without API requests."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class GitHubAuthTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which("gh"), "GitHub CLI is required")
    def test_stale_environment_cannot_override_stored_login(self):
        dockerfile = (ROOT / "Dockerfile").read_text()
        entrypoint = dockerfile.split(
            "cat > /usr/local/bin/devtainer-entrypoint <<'SCRIPT'\n", 1
        )[1].split("\nSCRIPT\n", 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            config = home / ".config/gh"
            config.mkdir(parents=True)
            stored = "gho_STORED_TEST_CREDENTIAL"
            hosts = config / "hosts.yml"
            original = (f"github.com:\n    user: test-user\n    oauth_token: {stored}\n"
                        f"    git_protocol: https\n    users:\n        test-user:\n"
                        f"            oauth_token: {stored}\n")
            hosts.write_text(original)
            (config / "config.yml").write_text("version: 1\n")
            # A persistent session home can reload tokens after Docker starts.
            (home / ".devtainer-env").write_text(
                "export GH_TOKEN=stale-home-token\nexport GITHUB_TOKEN=stale-home-token\nexport GH_CONFIG_DIR=/wrong/config\n"
            )
            env = dict(os.environ, HOME=directory, GH_CONFIG_DIR=str(config),
                       CODEX_HOME=str(home / ".codex"),
                       GH_TOKEN="stale-inherited-token", GITHUB_TOKEN="stale-inherited-token")
            result = subprocess.run(
                ["bash", "-c", entrypoint, "entrypoint", "gh", "auth", "token",
                 "--hostname", "github.com"],
                cwd=home, env=env, capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), stored)
            self.assertEqual(hosts.read_text(), original)


    @unittest.skipUnless(shutil.which("gh"), "GitHub CLI is required")
    def test_isolated_setup_config_exposes_only_its_synthetic_token(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory)
            token = "github_pat_FAKE_SETUP_CREDENTIAL"
            (config / "hosts.yml").write_text(f'github.com:\n    oauth_token: "{token}"\n')
            (config / "config.yml").write_text("version: 1\n")
            env = dict(os.environ, GH_CONFIG_DIR=directory)
            env.pop("GH_TOKEN", None)
            env.pop("GITHUB_TOKEN", None)
            before = {p.name: p.read_bytes() for p in config.iterdir()}
            result = subprocess.run(
                ["gh", "auth", "token", "--hostname", "github.com"],
                env=env, capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), token)
            self.assertEqual({p.name: p.read_bytes() for p in config.iterdir()}, before)

    @unittest.skipUnless(shutil.which("gh"), "GitHub CLI is required")
    @unittest.skipIf(os.geteuid() == 0, "root bypasses file permission restrictions")
    def test_auth_status_accepts_config_without_write_permission(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "gh"
            config.mkdir()
            hosts = config / "hosts.yml"
            hosts.write_text(
                'github.com:\n    user: test-user\n'
                '    oauth_token: gho_FAKE_TEST_CREDENTIAL\n'
                '    git_protocol: https\n    users:\n        test-user:\n'
                '            oauth_token: gho_FAKE_TEST_CREDENTIAL\n'
            )
            env = dict(os.environ, GH_CONFIG_DIR=str(config),
                       HTTP_PROXY="http://127.0.0.1:9", HTTPS_PROXY="http://127.0.0.1:9",
                       ALL_PROXY="http://127.0.0.1:9", NO_PROXY="")
            for key in ("GH_TOKEN", "GITHUB_TOKEN", "GH_DEBUG"):
                env.pop(key, None)
            hosts.chmod(0o400)
            schema = config / "config.yml"
            schema.write_text("version: 1\n")
            schema.chmod(0o400)
            original = {p.name: p.read_bytes() for p in config.iterdir()}
            config.chmod(0o500)
            try:
                result = subprocess.run(
                    ["gh", "auth", "status", "--hostname", "github.com"],
                    env=env, capture_output=True, text=True, timeout=10,
                )
                # The fake token cannot authenticate; config loading must still work.
                self.assertNotIn("migration", result.stderr)
                self.assertNotIn("permission denied", result.stderr)
                self.assertEqual({p.name: p.read_bytes() for p in config.iterdir()}, original)
            finally:
                config.chmod(0o700)


if __name__ == "__main__":
    unittest.main()

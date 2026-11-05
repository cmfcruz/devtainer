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
            config = home / "gh"
            config.mkdir()
            stored = "gho_STORED_TEST_CREDENTIAL"
            hosts = config / "hosts.yml"
            original = (f"github.com:\n    user: test-user\n    oauth_token: {stored}\n"
                        f"    git_protocol: https\n    users:\n        test-user:\n"
                        f"            oauth_token: {stored}\n")
            hosts.write_text(original)
            # A persistent devil home can reload tokens after Docker starts.
            (home / ".devtainer-env").write_text(
                "export GH_TOKEN=stale-home-token\nexport GITHUB_TOKEN=stale-home-token\n"
            )
            env = dict(os.environ, HOME=directory, GH_CONFIG_DIR=str(config),
                       CODEX_HOME=str(home / ".codex"), DEVIL_MODE="",
                       GH_TOKEN="stale-inherited-token", GITHUB_TOKEN="stale-inherited-token")
            result = subprocess.run(
                ["bash", "-c", entrypoint, "entrypoint", "gh", "auth", "token",
                 "--hostname", "github.com"],
                cwd=home, env=env, capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), stored)
            self.assertEqual(hosts.read_text(), original)


if __name__ == "__main__":
    unittest.main()

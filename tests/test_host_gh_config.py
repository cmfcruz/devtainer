"""Verify generated launchers without Docker or real GitHub credentials."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class HostGhConfigTest(unittest.TestCase):
    def test_host_config_selection(self):
        with tempfile.TemporaryDirectory(prefix="devtainer gh ") as directory:
            home = Path(directory)
            fake_bin = home / "fake-bin"
            fake_bin.mkdir()
            docker = fake_bin / "docker"
            docker.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, sys\n"
                "from pathlib import Path\n"
                "Path(os.environ['HOME'], 'docker.json').write_text(json.dumps(sys.argv[1:]))\n"
            )
            docker.chmod(0o755)
            env = dict(os.environ, HOME=directory,
                       PATH=f"{fake_bin}:{os.environ['PATH']}")
            for name in ("GH_CONFIG_DIR", "XDG_CONFIG_HOME", "WAYLAND_DISPLAY"):
                env.pop(name, None)
            # Old token files must never shadow the mounted host config.
            token_dir = home / ".config/devtainer/github"
            token_dir.mkdir(parents=True)
            (token_dir / "default.token").write_text("github_pat_STALE_TEST_TOKEN\n")
            env.update(GH_TOKEN="stale-gh-token", GITHUB_TOKEN="stale-github-token")
            subprocess.run(["bash", "install.sh"], cwd=ROOT, env=env,
                           check=True, capture_output=True)
            for source, overrides in (
                (home / ".config/gh", {}),
                (home / "custom config/gh", {"XDG_CONFIG_HOME": str(home / "custom config")}),
                (home / "explicit gh", {"GH_CONFIG_DIR": str(home / "explicit gh")}),
            ):
                source.mkdir(parents=True, exist_ok=True)
                for launcher in ("dev", "devil"):
                    with self.subTest(source=source, launcher=launcher):
                        result = subprocess.run(
                            [str(home / "bin" / launcher), "gh", "auth", "status"],
                            cwd=home, env=dict(env, **overrides), capture_output=True, text=True,
                        )
                        self.assertEqual(result.returncode, 0, result.stderr)
                        args = json.loads((home / "docker.json").read_text())
                        self.assertIn(f"{source}:{home}/.config/gh:ro", args)
                        self.assertIn(f"GH_CONFIG_DIR={home}/.config/gh", args)
                        self.assertEqual(args[-3:], ["gh", "auth", "status"])
                        self.assertNotIn("/run/devtainer/github-token", " ".join(args))
                        self.assertFalse(any(arg.split("=", 1)[0] in
                                             ("GH_TOKEN", "GITHUB_TOKEN", "DEVTAINER_GITHUB_TOKEN_FILE")
                                             for arg in args))
                source.rmdir()
            for launcher in ("dev", "devil"):
                result = subprocess.run(
                    [str(home / "bin" / launcher), "gh", "auth", "status"],
                    cwd=home, env=env, capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                args = json.loads((home / "docker.json").read_text())
                self.assertNotIn("/run/devtainer/github-token", " ".join(args))
                self.assertFalse(any(arg.startswith("GH_CONFIG_DIR=") for arg in args))


if __name__ == "__main__":
    unittest.main()

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
                source.rmdir()


if __name__ == "__main__":
    unittest.main()

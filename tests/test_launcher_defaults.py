"""Check launcher defaults using a fake Docker CLI."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class LauncherDefaultsTest(unittest.TestCase):
    def test_tmux_session_names_and_command_override(self):
        with tempfile.TemporaryDirectory() as directory:
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
            gh = fake_bin / "gh"
            gh.write_text("#!/bin/sh\nif [ \"$1\" = config ]; then echo test-user; else echo gho_FAKE_TEST_CREDENTIAL; fi\n")
            gh.chmod(0o755)
            store = home / ".config/devtainer/github"
            store.mkdir(parents=True, mode=0o700)
            credential = store / "default.credential"
            credential.write_text("test-user\ngithub_pat_FAKE_TEST_CREDENTIAL\n")
            credential.chmod(0o600)
            env = dict(os.environ, HOME=directory,
                       PATH=f"{fake_bin}:{os.environ['PATH']}")
            for key in ("GH_CONFIG_DIR", "XDG_CONFIG_HOME", "WAYLAND_DISPLAY"):
                env.pop(key, None)
            subprocess.run(["bash", "install.sh"], cwd=ROOT, env=env,
                           check=True, capture_output=True)
            for name, session in (("my-project", "my-project"),
                                  ("my.app:work", "my_app_work"),
                                  ("project with spaces", "project with spaces")):
                work = home / name
                work.mkdir()
                for launcher in ("dev", "devil"):
                    for command in ([], ["nvim", "."]):
                        with self.subTest(name=name, launcher=launcher, command=command):
                            result = subprocess.run(
                                [str(home / "bin" / launcher), *command],
                                cwd=work, env=env, capture_output=True, text=True,
                            )
                            self.assertEqual(result.returncode, 0, result.stderr)
                            args = json.loads((home / "docker.json").read_text())
                            expected = command or ["tmux", "new-session", "-A", "-s",
                                                   session, "-c", "/workspace"]
                            self.assertEqual(args[-len(expected):], expected)


if __name__ == "__main__":
    unittest.main()

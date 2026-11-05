"""Check credential snapshots and their lifecycle without real credentials/Docker."""

import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOKEN = "gho_FAKE_TEST_CREDENTIAL"


class HostGhConfigTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="devtainer gh ")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name) / "home"
        self.home.mkdir()
        self.tmp_root = Path(self.temp.name) / "tmp"
        self.tmp_root.mkdir()
        fake_bin = self.home / "fake-bin"
        fake_bin.mkdir()
        gh = fake_bin / "gh"
        gh.write_text(
            '#!/usr/bin/env python3\n'
            'import json, os, sys\n'
            'from pathlib import Path\n'
            'assert "GH_TOKEN" not in os.environ and "GITHUB_TOKEN" not in os.environ\n'
            'Path(os.environ["HOME"], "gh.json").write_text(json.dumps({k: os.environ.get(k) '
            'for k in ("GH_CONFIG_DIR", "XDG_CONFIG_HOME")}))\n'
            'if sys.argv[1:] == ["config", "get", "user", "--host", "github.com"]:\n'
            '    print(os.environ.get("TEST_USER", "test-user"))\n'
            'else:\n'
            '    assert sys.argv[1:] == ["auth", "token", "--hostname", "github.com", "--user", "test-user"]\n'
            '    print(os.environ.get("TEST_TOKEN", "gho_FAKE_TEST_CREDENTIAL"))\n'
            'sys.exit(int(os.environ.get("TEST_GH_EXIT", "0")))\n'
        )
        gh.chmod(0o755)
        docker = fake_bin / "docker"
        docker.write_text(
            '#!/usr/bin/env python3\n'
            'import json, os, sys, time\n'
            'from pathlib import Path\n'
            'if sys.argv[1] != "run": sys.exit(0)\n'
            'args = sys.argv[1:]\n'
            'mount = next(x for x in args if x.startswith("type=bind,source="))\n'
            'source = Path(mount.split("source=", 1)[1].split(",target=", 1)[0])\n'
            'hosts = source / "hosts.yml"\n'
            'data = {"args": args, "source": str(source), "config": hosts.read_text(), '
            '"dir_mode": source.stat().st_mode & 0o777, '
            '"file_mode": hosts.stat().st_mode & 0o777}\n'
            'Path(os.environ["HOME"], "docker.json").write_text(json.dumps(data))\n'
            'if os.environ.get("TEST_WAIT"): time.sleep(30)\n'
            'sys.exit(int(os.environ.get("TEST_DOCKER_EXIT", "0")))\n'
        )
        docker.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home),
                        PATH=f"{fake_bin}:{os.environ['PATH']}", TMPDIR=str(self.tmp_root),
                        GH_TOKEN="stale-env-token", GITHUB_TOKEN="stale-env-token")
        for key in ("GH_CONFIG_DIR", "XDG_CONFIG_HOME", "WAYLAND_DISPLAY"):
            self.env.pop(key, None)
        subprocess.run(["bash", "install.sh"], cwd=ROOT, env=self.env,
                       check=True, capture_output=True)
        self.log = self.home / "docker.json"

    def launch(self, launcher, overrides=None):
        return subprocess.run(
            ["bash", "-x", str(self.home / "bin" / launcher), "gh", "auth", "status"],
            cwd=self.home, env=dict(self.env, **(overrides or {})), capture_output=True, text=True,
        )

    def assert_clean(self):
        self.assertEqual(list(self.tmp_root.glob("devtainer-gh.*")), [])

    def test_snapshot_mount_permissions_overrides_and_cleanup(self):
        host_config = self.home / "host gh"
        host_config.mkdir()
        sentinel = host_config / "hosts.yml"
        sentinel.write_text("host config must remain untouched")
        for launcher in ("dev", "devil"):
            for override in ({}, {"GH_CONFIG_DIR": str(host_config)},
                             {"XDG_CONFIG_HOME": str(self.home / "xdg")}):
                with self.subTest(launcher=launcher, override=override):
                    result = self.launch(launcher, override)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    data = json.loads(self.log.read_text())
                    target = f"/home/{subprocess.check_output(['id', '-un'], text=True).strip()}/.config/gh"
                    self.assertIn(f"type=bind,source={data['source']},target={target},readonly", data["args"])
                    self.assertIn(f"GH_CONFIG_DIR={target}", data["args"])
                    self.assertEqual(data["dir_mode"], 0o700)
                    self.assertEqual(data["file_mode"], 0o600)
                    self.assertEqual(data["config"], f'github.com:\n    user: "test-user"\n    oauth_token: "{TOKEN}"\n    git_protocol: https\n    users:\n        "test-user":\n            oauth_token: "{TOKEN}"\n')
                    self.assertNotIn(str(host_config), " ".join(data["args"]))
                    self.assertNotIn(TOKEN, result.stdout + result.stderr + " ".join(data["args"]))
                    gh_env = json.loads((self.home / "gh.json").read_text())
                    for key, value in override.items():
                        self.assertEqual(gh_env[key], value)
                    self.assertEqual(sentinel.read_text(), "host config must remain untouched")
                    self.assert_clean()

    def test_unavailable_and_malformed_credentials_fail_closed(self):
        for launcher in ("dev", "devil"):
            for overrides in ({"TEST_GH_EXIT": "1"}, {"TEST_TOKEN": ""},
                              {"TEST_TOKEN": "bad\n    injected: yaml"}, {"TEST_USER": "bad: user"}):
                with self.subTest(launcher=launcher, overrides=overrides):
                    result = self.launch(launcher, overrides)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(self.log.exists())
                    self.assertNotIn(TOKEN, result.stdout + result.stderr)
                    self.assert_clean()

    def test_credentials_cannot_be_exposed_through_workspace(self):
        for launcher in ("dev", "devil"):
            result = self.launch(launcher, {"TMPDIR": str(self.home)})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("exposed through a host directory mount", result.stderr)
            self.assertFalse(self.log.exists())
            self.assertFalse((self.home / "gh.json").exists())
            self.assertEqual(list(self.home.glob("devtainer-gh.*")), [])

    def test_credentials_cannot_be_exposed_through_other_host_mounts(self):
        for relative in (".claude", ".cache/devtainer", ".config/nvim"):
            root = self.home / relative
            result = self.launch("dev", {"TMPDIR": str(root)})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("exposed through a host directory mount", result.stderr)
            self.assertFalse(self.log.exists())
            self.assertFalse((self.home / "gh.json").exists())
            self.assertEqual(list(root.glob("devtainer-gh.*")), [])

    def test_container_failure_preserves_status_and_cleans_up(self):
        for launcher in ("dev", "devil"):
            result = self.launch(launcher, {"TEST_DOCKER_EXIT": "42"})
            self.assertEqual(result.returncode, 42, result.stderr)
            self.assert_clean()

    def test_termination_cleans_up(self):
        for launcher in ("dev", "devil"):
            self.log.unlink(missing_ok=True)
            with subprocess.Popen(
                [str(self.home / "bin" / launcher), "gh", "auth", "status"],
                cwd=self.home, env=dict(self.env, TEST_WAIT="1"),
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
            ) as process:
                try:
                    deadline = time.monotonic() + 5
                    while not self.log.exists():
                        if time.monotonic() > deadline:
                            self.fail("launcher did not start Docker")
                        time.sleep(0.02)
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=5)
                    self.assertEqual(process.returncode, 143)
                    self.assert_clean()
                finally:
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()


if __name__ == "__main__":
    unittest.main()

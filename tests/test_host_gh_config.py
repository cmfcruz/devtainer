"""Session and credential tests using fake Docker and gh, with no real secrets."""

import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOKEN = "gho_FAKE_OFFICE_CREDENTIAL"
PERSONAL_TOKEN = "gho_FAKE_PERSONAL_CREDENTIAL"

DOCKER = r'''#!/usr/bin/env python3
import json, os, re, sys, time
from pathlib import Path
home = Path(os.environ['HOME'])
args = sys.argv[1:]
with (home / 'docker-calls.jsonl').open('a') as f:
    f.write(json.dumps(args) + '\n')
state_file = home / 'docker-state.json'
state = json.loads(state_file.read_text()) if state_file.exists() else {'volumes': {}}
if args[:2] == ['volume', 'create']:
    name = args[-1]
    labels = dict(args[i+1].split('=', 1) for i, a in enumerate(args) if a == '--label')
    state['volumes'].setdefault(name, {'labels': labels, 'marker': name})
    state_file.write_text(json.dumps(state))
    print(name)
elif args[:2] == ['volume', 'inspect']:
    labels = state['volumes'][args[-1]]['labels']
    print(':'.join(labels.get(k, '') for k in ('devtainer.managed', 'devtainer.uid', 'devtainer.session')))
elif args[:2] == ['volume', 'ls']:
    pattern = args[-1].split('=', 1)[1]
    print('\n'.join(n for n in state['volumes'] if re.fullmatch(pattern, n)))
elif args[:2] == ['volume', 'rm']:
    if os.environ.get('TEST_REMOVE_FAIL'):
        sys.exit(1)
    del state['volumes'][args[-1]]
    state_file.write_text(json.dumps(state))
    print(args[-1])
elif args[0] == 'ps':
    print(os.environ.get('TEST_ATTACHED', ''))
elif args[0] == 'run':
    mount = next(a for a in args if a.startswith('type=bind,source='))
    source = Path(mount.split('source=', 1)[1].split(',target=', 1)[0])
    hosts = source / 'hosts.yml'
    schema = source / 'config.yml'
    data = {'args': args, 'source': str(source), 'config': hosts.read_text(),
            'dir_mode': source.stat().st_mode & 0o777,
            'file_mode': hosts.stat().st_mode & 0o777,
            'schema': schema.read_text(), 'schema_mode': schema.stat().st_mode & 0o777}
    (home / 'docker.json').write_text(json.dumps(data))
    if os.environ.get('TEST_WAIT'):
        time.sleep(30)
    sys.exit(int(os.environ.get('TEST_DOCKER_EXIT', '0')))
else:
    raise SystemExit('unexpected Docker command: ' + repr(args))
'''


class HostGhConfigTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="devtainer session ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "host home"
        self.home.mkdir()
        self.work = self.home / "project"
        self.work.mkdir()
        self.tmp_root = self.root / "tmp"
        self.tmp_root.mkdir()
        self.fake_bin = self.home / "fake-bin"
        self.fake_bin.mkdir()
        gh = self.fake_bin / "gh"
        gh.write_text(
            '#!/usr/bin/env python3\n'
            'import json, os, sys\nfrom pathlib import Path\n'
            'assert not any(k in os.environ for k in ("GH_TOKEN", "GITHUB_TOKEN", "GH_DEBUG"))\n'
            'home = Path(os.environ["HOME"])\n'
            'with (home / "gh-calls.jsonl").open("a") as log:\n'
            '    log.write(json.dumps({"args": sys.argv[1:], "config": os.environ.get("GH_CONFIG_DIR")}) + "\\n")\n'
            'if os.environ.get("TEST_GH_EXIT"): sys.exit(int(os.environ["TEST_GH_EXIT"]))\n'
            'state = json.loads((home / "host-accounts.json").read_text())\n'
            'if sys.argv[1:] == ["config", "get", "user", "--host", "github.com"]:\n'
            '    print(state["active"])\n'
            'else:\n'
            '    assert sys.argv[1:5] == ["auth", "token", "--hostname", "github.com"]\n'
            '    assert sys.argv[5] == "--user"\n'
            '    token = state["tokens"].get(sys.argv[6])\n'
            '    if token is None: sys.exit(1)\n'
            '    print(os.environ.get("TEST_TOKEN", token))\n'
        )
        gh.chmod(0o755)
        docker = self.fake_bin / "docker"
        docker.write_text(DOCKER)
        docker.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home),
                        PATH=f"{self.fake_bin}:{os.environ['PATH']}", TMPDIR=str(self.tmp_root),
                        GH_TOKEN="stale-env-token", GITHUB_TOKEN="stale-env-token")
        for key in ("GH_CONFIG_DIR", "XDG_CONFIG_HOME", "WAYLAND_DISPLAY"):
            self.env.pop(key, None)
        subprocess.run(["bash", "install.sh", "--skip-build"], cwd=ROOT, env=self.env,
                       check=True, capture_output=True)
        self.log = self.home / "docker.json"
        self.calls = self.home / "docker-calls.jsonl"
        self.state_file = self.home / "docker-state.json"
        self.store = self.profile_dir("dev")
        self.credential = self.seed_profile("dev", "office-user")
        self.seed_profile("personal", "personal-user")
        self.gh_calls = self.home / "gh-calls.jsonl"
        self.host_accounts = self.home / "host-accounts.json"
        self.host_accounts.write_text(json.dumps({"active": "office-user", "tokens": {
            "office-user": TOKEN, "personal-user": PERSONAL_TOKEN,
        }}))

    def profile_dir(self, session):
        return self.home / ".config/devtainer/sessions" / session

    def seed_profile(self, session, account):
        store = self.profile_dir(session)
        store.mkdir(parents=True, mode=0o700, exist_ok=True)
        path = store / "github.account"
        path.write_text(account + "\n")
        path.chmod(0o600)
        return path

    def volume(self, session):
        return f"devtainer-{os.getuid()}-{session}-home"

    def launch(self, session="dev", overrides=None, command=("gh", "auth", "status")):
        return subprocess.run(
            ["bash", "-x", str(self.home / "bin/dev"), "--session", session, *command],
            cwd=self.work, env=dict(self.env, **(overrides or {})), capture_output=True, text=True,
        )

    def assert_clean(self):
        self.assertEqual(list(self.tmp_root.glob("devtainer-gh.*")), [])

    def test_sessions_have_distinct_homes_and_credentials(self):
        for session, token in (("dev", TOKEN), ("personal", PERSONAL_TOKEN)):
            with self.subTest(session=session):
                result = self.launch(session)
                self.assertEqual(result.returncode, 0, result.stderr)
                data = json.loads(self.log.read_text())
                target = f"/home/{subprocess.check_output(['id', '-un'], text=True).strip()}/.config/gh"
                self.assertIn(f"type=bind,source={data['source']},target={target},readonly", data["args"])
                self.assertIn(f"GH_CONFIG_DIR={target}", data["args"])
                self.assertIn(f"{self.volume(session)}:/home", data["args"])
                self.assertIn(f"DEVTAINER_SESSION={session}", data["args"])
                self.assertIn(f"devtainer.session={session}", data["args"])
                self.assertEqual(data["dir_mode"], 0o700)
                self.assertEqual(data["file_mode"], 0o600)
                self.assertEqual(data["schema_mode"], 0o600)
                self.assertEqual(data["schema"], "version: 1\n")
                self.assertIn(token, data["config"])
                other = PERSONAL_TOKEN if session == "dev" else TOKEN
                self.assertNotIn(other, data["config"])
                self.assertNotIn(token, result.stdout + result.stderr + " ".join(data["args"]))
                account = "office-user" if session == "dev" else "personal-user"
                calls = [json.loads(line)["args"] for line in self.gh_calls.read_text().splitlines()]
                self.assertEqual(calls[-1], ["auth", "token", "--hostname", "github.com", "--user", account])
                self.assertEqual((self.profile_dir(session) / "github.account").read_text(), account + "\n")
                mounts = [data['args'][i+1] for i, a in enumerate(data['args']) if a == '-v']
                self.assertEqual(mounts, [f"{self.volume(session)}:/home", f"{self.work}:/workspace"])
                self.assert_clean()
        self.assertFalse((self.home / "bin/devil").exists())
        self.assertFalse((self.home / ".claude").exists())

    def test_missing_profile_never_uses_other_session_or_host_login(self):
        legacy = self.home / ".config/devtainer/github"
        legacy.mkdir(mode=0o700)
        (legacy / "default.credential").write_text(f"test-user\n{TOKEN}\n")
        (legacy / "default.credential").chmod(0o600)
        (legacy / "default.token").write_text(TOKEN + "\n")
        for session in ("dev", "personal"):
            path = self.profile_dir(session) / "github.account"
            original = path.read_bytes()
            path.unlink()
            result = self.launch(session)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(f"--session {session} setup-github", result.stderr)
            self.assertFalse(self.log.exists())
            self.assertFalse(self.gh_calls.exists())
            path.write_bytes(original)
            path.chmod(0o600)
            self.assert_clean()

    def test_malformed_binding_and_unsafe_permissions_fail_closed(self):
        for content in ("", "office-user\npersonal-user\n", "bad: user\n", TOKEN + "\n"):
            self.credential.write_text(content)
            result = self.launch()
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(self.log.exists())
            self.assertFalse(self.gh_calls.exists())
            self.assert_clean()
        self.seed_profile("dev", "office-user").chmod(0o644)
        self.assertNotEqual(self.launch().returncode, 0)
        self.assertFalse(self.log.exists())

    def test_failed_token_retrieval_never_falls_back(self):
        for overrides in ({"TEST_GH_EXIT": "1"}, {"TEST_TOKEN": ""},
                          {"TEST_TOKEN": "bad\n    yaml: injection"}):
            result = self.launch(overrides=overrides)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(self.log.exists())
            self.assertNotIn(TOKEN, result.stdout + result.stderr)
            self.assert_clean()
        state = json.loads(self.host_accounts.read_text())
        del state["tokens"]["office-user"]
        state["active"] = "personal-user"
        self.host_accounts.write_text(json.dumps(state))
        self.assertNotEqual(self.launch().returncode, 0)
        self.assertFalse(self.log.exists())

    def test_host_switch_and_rotation_preserve_session_account(self):
        state = json.loads(self.host_accounts.read_text())
        state["active"] = "personal-user"
        state["tokens"]["office-user"] = TOKEN + "_ROTATED"
        self.host_accounts.write_text(json.dumps(state))
        result = self.launch(overrides={"GH_CONFIG_DIR": str(self.home / "custom gh config")})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(TOKEN + "_ROTATED", json.loads(self.log.read_text())["config"])
        calls = [json.loads(line) for line in self.gh_calls.read_text().splitlines()]
        self.assertEqual(calls[-1]["args"][-1], "office-user")
        self.assertEqual(calls[-1]["config"], str(self.home / "custom gh config"))
        self.assertEqual(self.credential.read_text(), "office-user\n")
        self.assertNotIn(TOKEN, result.stdout + result.stderr)
        self.assert_clean()

    def test_workspace_cannot_expose_credentials(self):
        result = self.launch(overrides={"TMPDIR": str(self.work)})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exposed through a host directory mount", result.stderr)
        self.assertEqual(list(self.work.glob("devtainer-gh.*")), [])
        result = subprocess.run([str(self.home / "bin/dev"), "true"], cwd=self.home,
                                env=self.env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("host GitHub configuration", result.stderr)
        self.assertFalse(self.log.exists())

    def test_container_failure_preserves_status_and_cleans_up(self):
        result = self.launch(overrides={"TEST_DOCKER_EXIT": "42"})
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assert_clean()

    def test_termination_cleans_up(self):
        with subprocess.Popen(
            [str(self.home / "bin/dev"), "true"], cwd=self.work,
            env=dict(self.env, TEST_WAIT="1"), stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, start_new_session=True,
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

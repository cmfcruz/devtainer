"""Exercise destructive home reset against synthetic volumes only."""

import json
import os
import pty
import select
import signal
import subprocess
import time
import unittest

import test_host_gh_config as fixtures


class ResetHomeTest(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.HostGhConfigTest()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)

    def run_reset(self, session="dev", overrides=None):
        f = self.fixture
        return subprocess.run(
            [str(f.home / "bin/dev"), "--session", session, "reset-home"], cwd=f.work,
            env=dict(f.env, **(overrides or {})), capture_output=True, text=True,
        )

    def interactive_reset(self, session, confirmation):
        f = self.fixture
        master, slave = pty.openpty()
        process = subprocess.Popen(
            [str(f.home / "bin/dev"), "--session", session, "reset-home"],
            cwd=f.work, env=f.env, stdin=slave, stdout=slave, stderr=slave,
        )
        os.close(slave)
        output = b""
        try:
            deadline = time.monotonic() + 5
            while b"Type the session name" not in output:
                if time.monotonic() > deadline:
                    self.fail("reset did not prompt")
                if select.select([master], [], [], 0.02)[0]:
                    output += os.read(master, 4096)
            os.write(master, (confirmation + "\n").encode())
            process.wait(timeout=5)
            return process.returncode, output.decode()
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)

    def test_reset_deletes_only_selected_home_and_keeps_host_login(self):
        f = self.fixture
        self.assertEqual(f.launch("dev").returncode, 0)
        self.assertEqual(f.launch("personal").returncode, 0)
        state = json.loads(f.state_file.read_text())
        state["volumes"]["devil-old-user"] = {"labels": {}, "marker": "legacy personal data"}
        f.state_file.write_text(json.dumps(state))
        host_login = f.host_accounts.read_bytes()
        code, output = self.interactive_reset("personal", "personal")
        self.assertEqual(code, 0, output)
        remaining = json.loads(f.state_file.read_text())["volumes"]
        self.assertEqual(set(remaining), {f.volume("dev"), "devil-old-user"})
        self.assertEqual(f.host_accounts.read_bytes(), host_login)
        self.assertEqual(f.launch("personal").returncode, 0)
        recreated = json.loads(f.state_file.read_text())["volumes"]
        self.assertIn(f.volume("personal"), recreated)

    def test_missing_volume_and_noninteractive_reset(self):
        f = self.fixture
        result = self.run_reset()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no home volume", result.stdout)
        self.assertFalse(f.state_file.exists())
        self.assertEqual(f.launch().returncode, 0)
        before = f.state_file.read_bytes()
        result = self.run_reset()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("interactive terminal", result.stderr)
        self.assertEqual(f.state_file.read_bytes(), before)

    def test_cancel_attached_and_foreign_volumes_are_preserved(self):
        f = self.fixture
        self.assertEqual(f.launch().returncode, 0)
        before = f.state_file.read_bytes()
        code, output = self.interactive_reset("dev", "wrong-session")
        self.assertEqual(code, 0, output)
        self.assertEqual(f.state_file.read_bytes(), before)
        result = self.run_reset(overrides={"TEST_ATTACHED": "external-container"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("attached", result.stderr)
        self.assertEqual(f.state_file.read_bytes(), before)
        state = json.loads(before)
        state["volumes"][f.volume("dev")]["labels"]["devtainer.uid"] = "someone-else"
        f.state_file.write_text(json.dumps(state))
        result = self.run_reset()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ownership labels", result.stderr)
        self.assertEqual(json.loads(f.state_file.read_text()), state)

    def test_active_session_refuses_reset_but_allows_another_container(self):
        f = self.fixture
        with subprocess.Popen(
            [str(f.home / "bin/dev"), "true"], cwd=f.work,
            env=dict(f.env, TEST_WAIT="1"), stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, start_new_session=True,
        ) as process:
            try:
                deadline = time.monotonic() + 5
                while not f.log.exists():
                    if time.monotonic() > deadline:
                        self.fail("container did not start")
                    time.sleep(0.02)
                result = self.run_reset()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("in use", result.stderr)
                self.assertEqual(f.launch().returncode, 0)
                self.assertEqual(f.launch("personal").returncode, 0)
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()

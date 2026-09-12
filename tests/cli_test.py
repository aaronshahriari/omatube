#!/usr/bin/python3
"""The bounds in bin/omatube, exercised rather than asserted.

  python3 tests/cli_test.py

Model.js has the node suite next door; this covers the half of the plugin
that holds the credentials and opens the sockets. Each test names a thing a
remote endpoint, a same-UID process, or a stuck run could otherwise do.
"""

import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = os.path.join(ROOT, "bin", "omatube")


def load_cli():
    loader = importlib.machinery.SourceFileLoader("omatube", CLI)
    spec = importlib.util.spec_from_loader("omatube", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


omatube = load_cli()


class Body:
    """Enough of an HTTP response to read one."""

    def __init__(self, payload, declared=None):
        self.payload = payload
        self.headers = {} if declared is None else {"Content-Length": str(declared)}

    def read(self, count):
        return self.payload[:count]


class Network(unittest.TestCase):
    def test_only_three_hosts_over_https(self):
        omatube.check_url("https://www.googleapis.com/youtube/v3/playlists")
        omatube.check_url("https://oauth2.googleapis.com/token")
        for url in ("http://www.googleapis.com/youtube/v3",
                    "https://evil.example/youtube/v3",
                    "https://www.googleapis.com.evil.example/x",
                    "file:///etc/passwd",
                    "https://user@accounts.google.com.evil.example/x"):
            with self.assertRaises(RuntimeError, msg=url):
                omatube.check_url(url)

    def test_a_redirect_is_checked_too(self):
        handler = omatube.StrictRedirect()
        self.assertEqual(handler.max_redirections, omatube.MAX_REDIRECTS)
        with self.assertRaises(RuntimeError):
            handler.redirect_request(None, None, 302, "Found", {},
                                     "https://evil.example/")

    def test_a_body_is_read_against_a_ceiling(self):
        self.assertEqual(omatube.read_capped(Body(b"x" * 100), 1000), b"x" * 100)
        # Over the limit by one byte is still over the limit.
        with self.assertRaises(RuntimeError):
            omatube.read_capped(Body(b"x" * 1001), 1000)
        # And a server is free to lie about how much it is about to send.
        with self.assertRaises(RuntimeError):
            omatube.read_capped(Body(b"x" * 10, declared=10 ** 9), 1000)

    def test_an_error_body_never_becomes_the_error(self):
        text = omatube.read_capped_text(Body(b"y" * (10 ** 6)),
                                        omatube.MAX_ERROR_BYTES)
        self.assertLess(len(text), omatube.MAX_ERROR_BYTES)


class Pagination(unittest.TestCase):
    def setUp(self):
        self.real_api = omatube.api
        self.calls = 0

    def tearDown(self):
        omatube.api = self.real_api

    def test_an_endless_feed_still_ends(self):
        def endless(_path, _params):
            self.calls += 1
            return {"items": [{"id": self.calls}] * 50,
                    "nextPageToken": "page%d" % self.calls}

        omatube.api = endless
        items = omatube.paged("/playlistItems", {})
        self.assertLessEqual(self.calls, omatube.MAX_PAGES)
        self.assertLessEqual(len(items), omatube.MAX_ITEMS)

    def test_a_repeated_page_token_is_not_followed_twice(self):
        def stuck(_path, _params):
            self.calls += 1
            return {"items": [{"id": 1}], "nextPageToken": "always-the-same"}

        omatube.api = stuck
        omatube.paged("/playlistItems", {})
        self.assertEqual(self.calls, 2)

    def test_a_caller_cap_is_still_honoured(self):
        omatube.api = lambda _p, _q: {"items": [{"id": 1}] * 50,
                                      "nextPageToken": "more"}
        self.assertEqual(len(omatube.paged("/x", {}, cap=10)), 10)


class State(unittest.TestCase):
    def setUp(self):
        self.box = tempfile.mkdtemp()
        self.dir = omatube.SafeDir(os.path.join(self.box, "state"))

    def tearDown(self):
        os.close(self.dir.fd)
        shutil.rmtree(self.box, ignore_errors=True)

    def path(self, name):
        return os.path.join(self.box, "state", name)

    def mode(self, name):
        return stat.S_IMODE(os.stat(self.path(name)).st_mode)

    def test_a_credential_lands_private_and_leaves_nothing_behind(self):
        self.dir.write_json("token.json", {"refresh_token": "s3cret"}, mode=0o600)
        self.assertEqual(self.mode("token.json"), 0o600)
        self.assertEqual(self.dir.read_json("token.json", private=True),
                         {"refresh_token": "s3cret"})
        leftovers = [n for n in os.listdir(os.path.join(self.box, "state"))
                     if n.endswith(".tmp")]
        self.assertEqual(leftovers, [])

    def test_the_temporary_name_is_not_predictable(self):
        names = set()
        real_open = os.open

        def watching(path, *args, **kwargs):
            if isinstance(path, str) and path.endswith(".tmp"):
                names.add(path)
            return real_open(path, *args, **kwargs)

        os.open = watching
        try:
            for _ in range(5):
                self.dir.write_json("data.json", {"n": 1})
        finally:
            os.open = real_open
        self.assertEqual(len(names), 5)

    def test_a_planted_symlink_is_neither_read_nor_written_through(self):
        elsewhere = os.path.join(self.box, "elsewhere.json")
        with io.open(elsewhere, "w") as handle:
            handle.write('{"theirs": 1}')
        os.symlink(elsewhere, self.path("data.json"))

        self.assertEqual(self.dir.read_json("data.json"), {})
        self.dir.write_json("data.json", {"ours": 1})
        with io.open(elsewhere) as handle:
            self.assertEqual(json.load(handle), {"theirs": 1})
        self.assertFalse(os.path.islink(self.path("data.json")))
        self.assertEqual(self.dir.read_json("data.json"), {"ours": 1})

    def test_an_existing_file_cannot_stand_in_for_the_temporary(self):
        # O_EXCL means the write either creates its own file or fails; it
        # never inherits one that was waiting there.
        self.dir.write_json("data.json", {"ours": 1})
        self.assertEqual(self.dir.read_json("data.json"), {"ours": 1})

    def test_a_loosened_credential_mode_is_closed_back_down(self):
        self.dir.write_json("token.json", {"refresh_token": "s3cret"}, mode=0o600)
        os.chmod(self.path("token.json"), 0o644)
        self.dir.read_json("token.json", private=True)
        self.assertEqual(self.mode("token.json"), 0o600)

    def test_an_oversized_state_file_is_ignored_rather_than_loaded(self):
        with io.open(self.path("data.json"), "w") as handle:
            handle.write(" " * 4096)
        self.assertEqual(self.dir.read_json("data.json", limit=1024), {})

    def test_a_directory_where_a_file_should_be_is_refused(self):
        os.mkdir(self.path("data.json"))
        self.assertEqual(self.dir.read_json("data.json"), {})

    def test_a_named_file_is_read_and_removed_by_descriptor(self):
        blob = os.path.join(self.box, "client.json")
        with io.open(blob, "w") as handle:
            handle.write('{"client_id": "a", "client_secret": "b"}')
        self.assertEqual(
            omatube.read_json_at(blob, omatube.MAX_CLIENT_FILE_BYTES)["client_id"], "a")
        omatube.unlink_at(blob)
        self.assertFalse(os.path.exists(blob))

        linked = os.path.join(self.box, "linked.json")
        os.symlink("/etc/passwd", linked)
        self.assertEqual(omatube.read_json_at(linked, 1024), {})


class Execution(unittest.TestCase):
    def test_defaults_resolve_to_an_absolute_system_path(self):
        for name in ("xdg-open",):
            resolved = omatube.trusted_binary(name)
            self.assertTrue(os.path.isabs(resolved))
            self.assertIn(os.path.dirname(resolved), omatube.TRUSTED_BIN_DIRS)
        with self.assertRaises(RuntimeError):
            omatube.trusted_binary("definitely-not-installed-xyz")

    def test_nothing_is_ever_executed_by_bare_name(self):
        with self.assertRaises(RuntimeError) as caught:
            omatube.launch(["mpv", "https://example.invalid"])
        self.assertIn("absolute", str(caught.exception))

    def test_the_child_environment_is_built_not_inherited(self):
        os.environ["OMATUBE_TEST_LEAK"] = "1"
        os.environ["LD_PRELOAD"] = "/tmp/evil.so"
        os.environ["BROWSER"] = "/tmp/evil"
        try:
            env = omatube.child_env()
        finally:
            for name in ("OMATUBE_TEST_LEAK", "LD_PRELOAD", "BROWSER"):
                os.environ.pop(name, None)
        self.assertEqual(env["PATH"], omatube.SAFE_PATH)
        for name in ("OMATUBE_TEST_LEAK", "LD_PRELOAD", "BROWSER"):
            self.assertNotIn(name, env)

    def test_the_interpreter_is_named_and_isolated(self):
        with io.open(CLI, encoding="utf-8") as handle:
            first = handle.readline().strip()
        self.assertTrue(first.startswith("#!/usr/bin/python3"), first)
        self.assertIn("-I", first)


WATCHDOG_CHILD = r'''
import importlib.machinery, importlib.util, os, subprocess, sys, time
loader = importlib.machinery.SourceFileLoader("omatube", sys.argv[1])
spec = importlib.util.spec_from_loader("omatube", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
m.record_failure = lambda error: None
m.KILL_GRACE = 1.0
m.start_watchdog(1.0)
# A child in our group that refuses to go on TERM: only the KILL ends it.
stubborn = subprocess.Popen([sys.executable, "-c",
    "import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(60)"])
# A player, started the way launch() starts one: a session of its own.
player = subprocess.Popen([sys.executable, "-c", "import time;time.sleep(30)"],
                          start_new_session=True)
print("%d %d" % (stubborn.pid, player.pid), flush=True)
time.sleep(60)
'''


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


class Watchdog(unittest.TestCase):
    def test_a_deadline_takes_the_group_but_not_the_player(self):
        script = os.path.join(tempfile.mkdtemp(), "child.py")
        with io.open(script, "w") as handle:
            handle.write(WATCHDOG_CHILD)
        run = subprocess.Popen([sys.executable, script, CLI],
                               stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, text=True)
        stubborn, player = (int(x) for x in run.stdout.readline().split())
        started = time.monotonic()
        try:
            run.wait(timeout=20)
            run.stdout.close()
            elapsed = time.monotonic() - started

            # One second of deadline, one of grace, then it is gone.
            self.assertLess(elapsed, 10, "the deadline did not end the run")
            deadline = time.monotonic() + 5
            while alive(stubborn) and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertFalse(alive(stubborn),
                             "a TERM-ignoring child outlived the deadline")
            self.assertTrue(alive(player),
                            "the detached player was taken down with the group")
        finally:
            for pid in (stubborn, player):
                try:
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass


class EndToEnd(unittest.TestCase):
    """The CLI as the shell actually invokes it, against a scratch state dir."""

    def run_cli(self, *args, **kwargs):
        env = dict(os.environ)
        env["XDG_STATE_HOME"] = self.box
        env["XDG_CONFIG_HOME"] = os.path.join(self.box, "config")
        return subprocess.run([CLI] + list(args), capture_output=True,
                              text=True, timeout=30, env=env, **kwargs)

    def setUp(self):
        self.box = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.box, ignore_errors=True)

    def test_status_on_a_cold_machine(self):
        done = self.run_cli("--deadline", "20", "status")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(json.loads(done.stdout)["signedIn"], False)

    def test_a_state_directory_is_created_private(self):
        self.run_cli("status")
        made = os.path.join(self.box, "omarchy", "omatube")
        self.assertEqual(stat.S_IMODE(os.stat(made).st_mode), 0o700)

    def test_a_command_that_needs_credentials_says_so_and_stops(self):
        done = self.run_cli("--deadline", "20", "sync")
        self.assertEqual(done.returncode, 2, done.stderr)
        self.assertIn("not signed in", done.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)

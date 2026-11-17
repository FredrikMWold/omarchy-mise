import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from mise_dashboard import (Client, DashboardError, MAX_OUTPUT, conflict_entries, parse_log,
                            parse_patch, run, sanitize)

SCRIPT = Path(__file__).with_name("mise_dashboard.py")


class ParsingTests(unittest.TestCase):
    def test_git_patch_splits_files_maps_paths_and_hides_internal_metadata(self):
        client = Client()
        text = "\n".join([
            "diff --git a/.mise-history/manifest.json b/.mise-history/manifest.json",
            "--- a/.mise-history/manifest.json", "+++ b/.mise-history/manifest.json",
            "@@ -1 +1 @@", "-x", "+y",
            "diff --git a/home@laptop/.bashrc b/home@laptop/.bashrc",
            "new file mode 100644", "--- /dev/null", "+++ b/home@laptop/.bashrc",
            "@@ -0,0 +1,2 @@", "+alias ll='ls -l'", "+-- not a header",
            "diff --git a/config/config.desktop.toml b/config/config.desktop.toml",
            "--- a/config/config.desktop.toml", "+++ b/config/config.desktop.toml",
            "@@ -1,2 +1,1 @@", " [tools]", "-node = 'latest'",
        ])
        parsed = parse_patch(text, client.repo_display)
        self.assertEqual(parsed["hidden"], 1)
        bashrc, config = parsed["files"]
        self.assertEqual((bashrc["path"], bashrc["scope"], bashrc["status"]), ("~/.bashrc", "laptop", "added"))
        self.assertEqual((bashrc["additions"], bashrc["deletions"]), (2, 0))
        self.assertEqual(bashrc["lines"][-1], {"t": "+", "s": "-- not a header"})
        self.assertEqual((config["path"], config["scope"]), ("~/.config/mise/config.desktop.toml", "desktop"))
        self.assertEqual([line["t"] for line in config["lines"]], ["@", " ", "-"])

    def test_conflict_patch_keeps_live_path_and_reason(self):
        text = "\n".join([
            "Conflict: ~/clash.txt (both sides changed the same lines)",
            "diff --git a~/clash.txt (local) b~/clash.txt (remote)",
            "index 1..2 100644", "--- a~/clash.txt (local)", "+++ b~/clash.txt (remote)",
            "@@ -1 +1 @@", "-mine", "+theirs",
        ])
        (conflict,) = parse_patch(text, Client().repo_display)["files"]
        self.assertEqual(conflict["path"], "~/clash.txt")
        self.assertEqual(conflict["reason"], "both sides changed the same lines")
        self.assertEqual((conflict["additions"], conflict["deletions"]), (1, 1))
        self.assertEqual(conflict_entries({"conflicts": [["~/clash.txt", "why"]]}),
                         [{"path": "~/clash.txt", "reason": "why"}])

    def test_conflict_review_falls_back_to_status_when_mise_has_no_patch(self):
        client = Client()
        client.json = lambda *args, **kwargs: {
            "history": {"sync": {"conflicts": [
                ["~/.config/mise/config.toml", "incoming configuration is invalid"],
            ]}},
        }
        client.call = lambda *args, **kwargs: ("", "mise no sharing conflicts\n")

        review = client.review("conflicts")

        self.assertEqual([(item["path"], item["reason"]) for item in review["files"]], [
            ("~/.config/mise/config.toml", "incoming configuration is invalid"),
        ])

    def test_patch_limits_and_untrusted_text(self):
        long = "+" + "x" * 2000
        text = "diff --git a/home/a b/home/a\n@@ -0,0 +1 @@\n" + "\n".join([long] * 700)
        (item,) = parse_patch(text, Client().repo_display)["files"]
        self.assertEqual(item["additions"], 700)
        self.assertEqual(len(item["lines"]) + item["omitted"], 701)
        self.assertTrue(item["lines"][1]["s"].endswith("…"))
        markup = '<img src="https://example.invalid/tracker">'
        self.assertEqual(sanitize({"name": markup})["name"], markup)
        self.assertEqual(sanitize("\x1b[31mred\x1b[0m\x00"), "red")

    def test_bootstrap_log_classifies_stages(self):
        lines = parse_log("mise bootstrap: running `bootstrap` task\nmise pacman: 17 package(s) already installed\n"
                          "sh -o errexit -c 'omarchy plugin add x'\n[bootstrap] $ omarchy font set y\n"
                          "mise repos: cloning y\n")
        self.assertEqual([line["t"] for line in lines], ["stage", "ok", "run", "run", "info"])
        self.assertEqual([lines[0]["s"], lines[2]["s"], lines[3]["s"]],
                         ["running bootstrap task", "omarchy plugin add x", "omarchy font set y"])

    def test_bootstrap_log_keeps_multiline_hook_scripts_together(self):
        lines = parse_log("mise bootstrap: post-repos hooks\nsh -o errexit -c 'set -eu\n\n"
                          "install_plugin() {\n  id=\"$1\"\n}\ninstall_plugin a b'\nmise bootstrap: dotfiles\n")
        self.assertEqual([line["t"] for line in lines], ["stage"] + ["script"] * 5 + ["stage"])
        self.assertEqual([line["s"] for line in lines[1:6]],
                         ["set -eu", "install_plugin() {", '  id="$1"', "}", "install_plugin a b"])

    def test_bootstrap_plan_hooks_are_always_run_not_pending(self):
        names = ["pre-repos:1", "post-repos:1", "post-repos:2"]
        plan = {"resources": [
            {"id": {"kind": "hook", "name": name}, "action": "run",
             "current": "not run", "desired": "true"}
            for name in names
        ]}

        rows = Client().bootstrap_rows({}, plan, {})

        self.assertEqual([(row["name"], row["action"], row["state"]) for row in rows],
                         [(name, "run", "always") for name in names])

    def test_bootstrap_plan_preserves_resource_drift_and_unknown_hooks(self):
        plan = {"resources": [
            {"id": {"kind": "package", "name": "pacman:git"}, "action": "create"},
            {"id": {"kind": "user-service", "name": "mise-history"}, "action": "start"},
            {"id": {"kind": "repo", "name": "~/project"}, "action": "noop"},
            {"id": {"kind": "hook", "name": "post-repos:1"}, "action": "unknown"},
        ]}

        rows = Client().bootstrap_rows({}, plan, {})

        self.assertEqual([row["state"] for row in rows], ["pending", "pending", "ok", "unknown"])

    def test_profiles_come_from_mise_selected_configs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "etc").mkdir()
            common, profile, system = root / "config.toml", root / "config.train.toml", root / "etc/tools.toml"
            common.write_text('[tools]\nnode = "latest"\n')
            profile.write_text('[bootstrap.repos]\n"~/work" = {url = "https://example.invalid/repo"}\n')
            system.write_text('[tools]\nnode = {version = "latest", lazy = true}\namp = {version = "latest", lazy = true}\n')
            client = Client()
            client.system_dirs = (str(root / "etc") + "/",)
            client.json = lambda *args, **kwargs: [{"path": str(profile)}, {"path": str(common)}, {"path": str(system)}]
            configs, origins = client.sources()
            self.assertEqual(client.active_profiles, ["train"])
            self.assertEqual([item["scope"] for item in configs], ["train", "common"])
            self.assertEqual(origins[("tool", "node")][0], "common")
            self.assertEqual(origins[("repo", "~/work")][0], "train")
            rows = client.bootstrap_rows({"tools": [
                {"tool": "node", "state": "missing", "requested_version": "latest"},
                {"tool": "amp", "state": "missing", "requested_version": "latest"},
                {"tool": "undeclared", "state": "installed", "requested_version": "1"},
            ]}, {"resources": []}, origins)
            # node is declared by common config too, so it stays; amp exists only in the defaults.
            self.assertEqual([(row["name"], row["state"], row["scope"]) for row in rows],
                             [("node", "pending", "common"), ("undeclared", "ok", "")])
            self.assertNotIn("-E", client.command)


class SafetyTests(unittest.TestCase):
    def test_bounded_commands_report_timeout_overflow_and_failure(self):
        self.assertEqual(run([sys.executable, "-c", "print('ok')"])[0], "ok\n")
        with self.assertRaisesRegex(DashboardError, "timed out"):
            run([sys.executable, "-c", "import time; time.sleep(2)"], timeout=0.1)
        with self.assertRaisesRegex(DashboardError, "safety limit"):
            run([sys.executable, "-c", f"print('x' * {MAX_OUTPUT + 1})"])
        with self.assertRaisesRegex(DashboardError, "failed"):
            run([sys.executable, "-c", "import sys; sys.exit('failed')"])

    def test_review_and_actions_reject_unknown_or_unsafe_arguments(self):
        client = Client()
        for kind, argument in (("checkpoint", "1; rm -rf ~"), ("checkpoint", "3 --exec=x"),
                               ("path-history", "--output=/tmp/x"), ("nope", None)):
            with self.subTest(kind=kind, argument=argument), self.assertRaises(DashboardError):
                client.review(kind, argument)
        with self.assertRaises(DashboardError):
            client.act("undo", "latest")
        with self.assertRaises(DashboardError):
            client.act("rm", None)

    def test_bootstrap_requires_terminal_and_cancel_runs_nothing(self):
        client = Client()
        with patch("sys.stdin", io.StringIO("y\n")), self.assertRaisesRegex(DashboardError, "terminal"):
            client.terminal("bootstrap")
        client.call = lambda *args, **kwargs: ("mise bootstrap: tools\n", "")
        with patch("sys.stdin.isatty", return_value=True), patch("builtins.input", return_value="n"), \
                patch("subprocess.call") as apply, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(client.terminal("bootstrap"), 0)
        apply.assert_not_called()


@unittest.skipUnless(shutil.which("mise") and shutil.which("git"), "mise and git are required")
class MiseFixtureTests(unittest.TestCase):
    """Two machines sharing an origin, driven through the real CLI."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="mise-dashboard-test-")
        self.root = Path(self.directory.name)
        config = self.root / ".config/mise"
        config.mkdir(parents=True)
        (config / "config.toml").write_text(
            '[dotfiles]\n"~/demo.txt" = {mode = "track"}\n"~/other.txt" = {mode = "track"}\n'
            '"~/clash.txt" = {mode = "track"}\n')
        for name, body in (("demo.txt", "line1\nline2\n"), ("other.txt", "a\n"), ("clash.txt", "base\n")):
            (self.root / name).write_text(body)
        home = str(self.root)
        self.env = {
            **os.environ, "HOME": home, "MISE_ENV": "", "MISE_YES": "1", "NO_COLOR": "1",
            "XDG_CONFIG_HOME": home + "/.config", "XDG_DATA_HOME": home + "/.local/share",
            "XDG_STATE_HOME": home + "/.local/state", "XDG_CACHE_HOME": home + "/.cache",
            "MISE_CONFIG_DIR": str(config), "MISE_GLOBAL_CONFIG_FILE": str(config / "config.toml"),
            "MISE_DATA_DIR": home + "/.local/share/mise", "MISE_STATE_DIR": home + "/.local/state/mise",
            "MISE_CACHE_DIR": home + "/.cache/mise", "MISE_SYSTEM_CONFIG_DIR": home + "/etc/mise",
            "PATH": os.environ["PATH"],
        }
        self.mise("dot", "save")
        self.command("git", "init", "--bare", self.root / "origin.git")
        self.mise("dot", "origin", "set", self.root / "origin.git", "--sync", "manual", "--yes")
        state = self.root / ".local/state/mise"
        shutil.copytree(state, self.root / "machine-a", symlinks=True)
        # The other machine changes two files and publishes them.
        self.write("demo.txt", 'line1\nCHANGED <img src="https://example.invalid/x">\nline3\n')
        self.write("clash.txt", "theirs\n")
        self.mise("dot", "save")
        self.mise("dot", "sync")
        shutil.rmtree(state)
        shutil.copytree(self.root / "machine-a", state, symlinks=True)
        self.write("demo.txt", "line1\nline2\n")
        self.write("clash.txt", "base\n")
        self.write("other.txt", "a\nlocal addition\n")
        self.mise("dot", "save")

    def tearDown(self):
        self.directory.cleanup()

    def write(self, name, text):
        (self.root / name).write_text(text)

    def read(self, name):
        return (self.root / name).read_text()

    def command(self, *args):
        result = subprocess.run([str(arg) for arg in args], cwd=self.root, env=self.env,
                                text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        return result.stdout

    def mise(self, *args):
        return self.command("mise", *args)

    def dash(self, *args):
        result = subprocess.run([sys.executable, SCRIPT, *map(str, args)], env=self.env,
                                text=True, capture_output=True, timeout=120)
        return json.loads(result.stdout)

    def data(self, *args):
        result = self.dash(*args)
        self.assertTrue(result["ok"], result)
        return result["data"]

    def test_fetch_partitions_incoming_and_outgoing_without_writing(self):
        snapshot = self.data("fetch")
        changes = snapshot["changes"]
        self.assertIsNone(snapshot["fetch_error"])
        self.assertEqual(sorted(item["path"] for item in changes["incoming"]), ["~/clash.txt", "~/demo.txt"])
        self.assertEqual([item["path"] for item in changes["outgoing"]], ["~/other.txt"])
        self.assertEqual(changes["outgoing"][0]["additions"], 1)
        self.assertEqual(self.read("demo.txt"), "line1\nline2\n")

        review = self.data("review", "incoming")
        demo = next(item for item in review["files"] if item["path"] == "~/demo.txt")
        self.assertIn({"t": "+", "s": 'CHANGED <img src="https://example.invalid/x">'}, demo["lines"])
        self.assertIn({"t": "-", "s": "line2"}, demo["lines"])
        outgoing = self.data("review", "outgoing")["files"][0]
        self.assertIn({"t": "+", "s": "local addition"}, outgoing["lines"])
        self.assertEqual(self.read("demo.txt"), "line1\nline2\n")

    def test_pull_requires_the_reviewed_set_and_can_be_undone(self):
        pending = self.data("fetch")["history"]["sync"]["pending_applications"]
        stale = self.dash("act", "pull", json.dumps(pending[:1]))
        self.assertFalse(stale["ok"])
        self.assertIn("Review them again", stale["error"])
        self.assertEqual(self.read("demo.txt"), "line1\nline2\n")

        pulled = self.data("act", "pull", json.dumps(pending))
        self.assertEqual(pulled["state"], "succeeded")
        self.assertIn("CHANGED", self.read("demo.txt"))
        self.assertEqual(self.data("snapshot")["last_action"]["action"], "pull")

        self.assertEqual(self.data("act", "undo", pulled["undo"])["state"], "succeeded")
        self.assertEqual(self.read("demo.txt"), "line1\nline2\n")

    def test_conflicts_block_pull_and_resolve_with_every_side_chosen(self):
        self.write("clash.txt", "mine\n")
        self.mise("dot", "save")
        snapshot = self.data("fetch")
        pending = snapshot["history"]["sync"]["pending_applications"]
        self.assertEqual(snapshot["changes"]["conflicts"][0]["path"], "~/clash.txt")
        self.assertNotIn("~/clash.txt", [item["path"] for item in snapshot["changes"]["incoming"]])
        self.assertFalse(self.dash("act", "pull", json.dumps(pending))["ok"])

        (conflict,) = self.data("review", "conflicts")["files"]
        self.assertEqual(conflict["path"], "~/clash.txt")
        self.assertIn({"t": "-", "s": "mine"}, conflict["lines"])

        wrong = self.dash("act", "resolve", json.dumps({"expected": pending, "choices": {}}))
        self.assertFalse(wrong["ok"])
        resolved = self.data("act", "resolve", json.dumps(
            {"expected": pending, "choices": {"~/clash.txt": "local"}}))
        self.assertEqual(resolved["state"], "succeeded")
        self.assertEqual(self.read("clash.txt"), "mine\n")
        self.assertIn("CHANGED", self.read("demo.txt"))

    def test_publish_is_verified_and_waits_for_incoming_changes(self):
        pending = self.data("fetch")["history"]["sync"]["pending_applications"]
        held = self.data("act", "publish")
        self.assertEqual((held["state"], held["message"]), ("failed", "Pull incoming changes first"))
        self.data("act", "pull", json.dumps(pending))
        self.assertEqual(self.data("act", "publish")["state"], "succeeded")
        self.assertEqual(self.data("snapshot")["changes"]["outgoing"], [])


if __name__ == "__main__":
    unittest.main()

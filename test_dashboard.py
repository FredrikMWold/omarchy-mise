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

from mise_dashboard import Client, DashboardError, MAX_OUTPUT, run, sanitize


class DashboardTests(unittest.TestCase):
    def test_uses_mise_selected_configs_including_common_and_arbitrary_profile(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            common = root / "config.toml"
            profile = root / "config.train.toml"
            inactive = root / "config.unselected.toml"
            common.write_text('[tools]\nnode = "latest"\n')
            profile.write_text('[bootstrap.repos]\n"~/work" = {url = "https://example.invalid/repo"}\n')
            inactive.write_text('[tools]\nwrong = "latest"\n')
            client = Client()
            client.json = lambda *args: [{"path": str(profile)}, {"path": str(common)}]
            configs, origins = client.sources()
            self.assertEqual(client.active_profiles, ["train"])
            self.assertEqual([item["scope"] for item in configs], ["train", "common"])
            self.assertEqual(origins[("tool", "node")][0], "common")
            self.assertEqual(origins[("repo", "~/work")][0], "train")
            self.assertNotIn(("tool", "wrong"), origins)
            self.assertNotIn("-E", client.command)

    def test_lazy_tools_are_not_pending_bootstrap_changes_and_common_override_wins(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            common = root / "config.toml"
            system = root / "omarchy-tools.toml"
            common.write_text('[tools]\nnode = "latest"\n')
            system.write_text('[tools]\nnode = {version = "latest", lazy = true}\namp = {version = "latest", lazy = true}\n')
            client = Client()
            client.json = lambda *args: [{"path": str(common)}, {"path": str(system)}]
            _, origins = client.sources()
            status = {"tools": [
                {"tool": "node", "state": "missing", "requested_version": "latest"},
                {"tool": "amp", "state": "missing", "requested_version": "latest"},
            ]}
            actual = client.bootstrap_rows(status, {"resources": []}, origins)
            self.assertEqual([item["action"] for item in actual], ["missing", "on-demand"])

    def test_fetch_is_fetch_only_and_preserves_a_visible_failure(self):
        client = Client()
        calls = []
        client.snapshot = lambda: {"errors": []}
        client.operation_lock = contextlib.nullcontext
        client.call = lambda *args: calls.append(args)
        self.assertIsNone(client.fetch()["fetch_error"])
        self.assertEqual(calls, [("dot", "sync", "--fetch-only")])
        with patch.object(client, "call", side_effect=DashboardError("offline")):
            self.assertEqual(client.fetch()["fetch_error"], "offline")

    def test_preview_includes_stderr_and_never_uses_apply_commands(self):
        client = Client()
        client.call = lambda *args, **kwargs: ("", "would run a bootstrap hook\n")
        result = client.preview("bootstrap")
        self.assertIn("--dry-run", result["text"])
        self.assertIn("would run a bootstrap hook", result["text"])
        self.assertFalse(result["truncated"])
        with self.assertRaises(DashboardError):
            client.preview("bootstrap; touch /tmp/wrong")

    def test_partial_status_failure_is_not_reported_as_healthy(self):
        client = Client()
        client.sources = lambda: ([], {})
        client.json = lambda *args: (_ for _ in ()).throw(DashboardError("status unavailable"))
        with patch.object(Path, "exists", return_value=False):
            result = client.snapshot()
        self.assertEqual(len(result["errors"]), 4)
        self.assertIn("Dotfiles: status unavailable", result["errors"])

    def test_markup_stays_literal_and_controls_are_removed(self):
        markup = '<img src="https://example.invalid/tracker"> & <b>name</b>'
        self.assertEqual(sanitize({"name": markup})["name"], markup)
        self.assertEqual(sanitize("\x1b[31mred\x1b[0m\x00"), "red")
        qml = Path(__file__).with_name("PlainText.qml").read_text()
        self.assertIn("textFormat: Text.PlainText", qml)
        panel = Path(__file__).with_name("Panel.qml").read_text()
        self.assertIn("textFormat: TextEdit.PlainText", panel)
        self.assertNotIn("tooltipText:", panel)

    def test_bounded_commands_report_timeout_overflow_and_failure(self):
        self.assertEqual(run([sys.executable, "-c", "print('ok')"])[0], "ok\n")
        with self.assertRaisesRegex(DashboardError, "timed out"):
            run([sys.executable, "-c", "import time; time.sleep(2)"], timeout=0.1)
        with self.assertRaisesRegex(DashboardError, "safety limit"):
            run([sys.executable, "-c", f"print('x' * {MAX_OUTPUT + 1})"])
        with self.assertRaisesRegex(DashboardError, "failed"):
            run([sys.executable, "-c", "import sys; sys.exit('failed')"])

    def test_apply_requires_terminal_and_never_accepts_arbitrary_commands(self):
        client = Client()
        with patch("sys.stdin", io.StringIO("yes\n")):
            with self.assertRaisesRegex(DashboardError, "interactive terminal"):
                client.apply("pull")
        with self.assertRaisesRegex(DashboardError, "Unknown action"):
            client.apply("pull --take-remote-all")

    def test_cancelled_confirmation_never_runs_an_action(self):
        client = Client()
        client.preview = lambda kind: {"text": "fresh preview"}
        with patch("sys.stdin.isatty", return_value=True), \
                patch("builtins.input", return_value="no"), \
                patch("subprocess.call") as apply, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(client.apply("pull"), 0)
        apply.assert_not_called()

    def test_confirmed_action_records_failure_without_force_flags(self):
        client = Client()
        client.preview = lambda kind: {"text": "fresh preview"}
        client.operation_lock = contextlib.nullcontext
        with patch("sys.stdin.isatty", return_value=True), \
                patch("builtins.input", side_effect=["yes", ""]), \
                patch("subprocess.call", return_value=3) as apply, \
                patch.object(client, "record_action") as record, \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(client.apply("bootstrap"), 3)
        self.assertEqual(apply.call_args.args[0], client.command + ["bootstrap"])
        self.assertEqual(record.call_args_list[-1].args, ("bootstrap", "failed", 3))


@unittest.skipUnless(shutil.which("mise"), "mise is required")
class MiseIntegrationTests(unittest.TestCase):
    def test_real_incoming_preview_leaves_live_file_unchanged(self):
        with tempfile.TemporaryDirectory(prefix="mise-dashboard-test-") as directory:
            root = Path(directory)
            config = root / ".config/mise"
            config.mkdir(parents=True)
            (config / "config.toml").write_text('[dotfiles]\n"~/demo.txt" = {mode = "track"}\n')
            target = root / "demo.txt"
            target.write_text("before\n")
            env = {
                **os.environ, "HOME": directory, "MISE_ENV": "", "MISE_YES": "1",
                "XDG_CONFIG_HOME": directory + "/.config",
                "XDG_DATA_HOME": directory + "/.local/share",
                "XDG_STATE_HOME": directory + "/.local/state",
                "XDG_CACHE_HOME": directory + "/.cache",
                "MISE_CONFIG_DIR": str(config),
                "MISE_GLOBAL_CONFIG_FILE": str(config / "config.toml"),
                "MISE_DATA_DIR": directory + "/.local/share/mise",
                "MISE_STATE_DIR": directory + "/.local/state/mise",
                "MISE_CACHE_DIR": directory + "/.cache/mise",
                "MISE_SYSTEM_CONFIG_DIR": directory + "/etc/mise",
            }

            def command(*args):
                result = subprocess.run(args, cwd=directory, env=env, text=True,
                                        capture_output=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                return result.stdout

            command("mise", "dot", "save")
            command("git", "init", "--bare", str(root / "origin.git"))
            command("mise", "dot", "origin", "set", str(root / "origin.git"), "--sync", "manual", "--yes")
            state = root / ".local/state/mise"
            shutil.copytree(state, root / "saved-state", symlinks=True)
            target.write_text('after <img src="https://example.invalid/tracker">\n')
            command("mise", "dot", "save")
            command("mise", "dot", "sync")
            state.rename(root / "remote-state")
            shutil.copytree(root / "saved-state", state, symlinks=True)
            target.write_text("before\n")
            with patch.dict(os.environ, env, clear=True):
                client = Client()
                fetched = client.fetch()
                self.assertIsNone(fetched["fetch_error"])
                self.assertIn("~/demo.txt", fetched["history"]["sync"]["pending_applications"])
                self.assertEqual(fetched["errors"], [])
                preview = client.preview("incoming")
                self.assertIn("~/demo.txt", preview["text"])
                self.assertEqual(target.read_text(), "before\n")
                self.assertEqual(client.snapshot()["dotfiles"][0]["scope"], "common")


if __name__ == "__main__":
    unittest.main()

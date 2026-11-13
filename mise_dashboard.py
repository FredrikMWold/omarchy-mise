#!/usr/bin/env python3
"""Bounded mise CLI adapter. No shell evaluation and no implicit applies."""

import argparse
import contextlib
import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import sys
import time
import tomllib

MAX_OUTPUT = 2 * 1024 * 1024
MAX_ROWS = 3000
MAX_PREVIEW = 240000
ANSI = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))")
ACTIONS = {
    "pull": ["dot", "pull"],
    "publish": ["dot", "sync"],
    "bootstrap": ["bootstrap"],
}
PREVIEWS = {
    "incoming": ["dot", "pull", "--dry-run"],
    "local": ["dot", "history", "diff", "--patch"],
    "deployment": ["dot", "diff"],
    "conflicts": ["dot", "conflicts"],
    "bootstrap": ["bootstrap", "--dry-run"],
    "publish": ["dot", "status"],
}


class DashboardError(Exception):
    pass


def clean(value, limit=12000):
    value = ANSI.sub("", str(value))
    return "".join(c for c in value if c in "\n\t" or ord(c) >= 32)[:limit]


def rows(value, name):
    if not isinstance(value, list) or len(value) > MAX_ROWS:
        raise DashboardError(f"Invalid or oversized {name} list")
    return value


def sanitize(value, depth=0):
    if depth > 16:
        raise DashboardError("Mise response nesting exceeded the safety limit")
    if isinstance(value, str):
        return clean(value)
    if isinstance(value, list):
        return [sanitize(item, depth + 1) for item in rows(value, "response")]
    if isinstance(value, dict):
        if len(value) > MAX_ROWS:
            raise DashboardError("Mise response object exceeded the safety limit")
        return {clean(key, 2048): sanitize(item, depth + 1) for key, item in value.items()}
    return value


def run(command, *, env=None, timeout=60):
    with subprocess.Popen(
        command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env=env, stdin=subprocess.DEVNULL, start_new_session=True,
    ) as process:
        output = [bytearray(), bytearray()]
        deadline = time.monotonic() + timeout
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ, 0)
                selector.register(process.stderr, selectors.EVENT_READ, 1)
                while selector.get_map():
                    if time.monotonic() >= deadline:
                        raise DashboardError(f"Command timed out after {timeout}s: {command[0]}")
                    for key, _ in selector.select(0.2):
                        chunk = os.read(key.fileobj.fileno(), 65536)
                        if not chunk:
                            selector.unregister(key.fileobj)
                            continue
                        output[key.data].extend(chunk)
                        if sum(map(len, output)) > MAX_OUTPUT:
                            raise DashboardError("Command output exceeded the 2 MiB safety limit")
                remaining = max(0.01, deadline - time.monotonic())
                process.wait(timeout=remaining)
        except (DashboardError, subprocess.TimeoutExpired):
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise
        stdout, stderr = (part.decode("utf-8", errors="replace") for part in output)
        if process.returncode:
            raise DashboardError(clean(stderr.strip() or stdout.strip()
                                       or f"Command exited with {process.returncode}"))
        return stdout, stderr


class Client:
    def __init__(self):
        self.home = Path.home()
        self.env = {**os.environ, "NO_COLOR": "1", "CLICOLOR": "0",
                    "MISE_COLOR": "0", "GIT_TERMINAL_PROMPT": "0", "PAGER": "cat"}
        self.command = ["mise", "-C", str(self.home)]
        self.active_profiles = []
        self.lazy_tools = set()
        self.state_dir = Path(self.env.get("XDG_STATE_HOME", self.home / ".local/state")) / "omarchy-mise"

    def call(self, *args, timeout=60):
        return run(self.command + list(args), env=self.env, timeout=timeout)

    def json(self, *args):
        raw, _ = self.call(*args)
        try:
            return sanitize(json.loads(raw))
        except json.JSONDecodeError as error:
            raise DashboardError(f"Invalid JSON from mise: {error}") from error

    def scope(self, config):
        path = Path(config)
        if path.name.endswith(".local.toml"):
            return "local"
        match = re.fullmatch(r"(?:config|mise)\.([A-Za-z0-9_-]+)\.toml", path.name)
        if match:
            return match.group(1)
        if str(path).startswith("/etc/"):
            return "system"
        return "common"

    def sources(self):
        entries = rows(self.json("config", "ls", "--json"), "config")
        declarations = {}
        configs = []
        # mise lists highest precedence first.
        for entry in entries:
            path = Path(entry["path"])
            if path.stat().st_size > MAX_OUTPUT:
                raise DashboardError(f"Config too large: {path}")
            with path.open("rb") as stream:
                config = tomllib.load(stream)
            scope = self.scope(str(path))
            if scope not in ("common", "local", "system") and scope not in self.active_profiles:
                self.active_profiles.append(scope)
            configs.append({"name": str(path).replace(str(self.home), "~", 1),
                            "scope": scope, "state": "loaded"})
            bootstrap = config.get("bootstrap", {})
            for kind, table in (
                ("tool", config.get("tools", {})),
                ("repo", bootstrap.get("repos", {})),
                ("package", bootstrap.get("packages", {})),
                ("service", bootstrap.get("services", {})),
            ):
                for name in table:
                    if kind == "tool" and (kind, name) not in declarations:
                        spec = table[name]
                        if isinstance(spec, dict) and spec.get("lazy") is True:
                            self.lazy_tools.add(name)
                    declarations.setdefault((kind, name), (scope, str(path)))
            for name in bootstrap.get("hooks", {}):
                declarations.setdefault(("hook", name), (scope, str(path)))
            if "bootstrap" in config.get("tasks", {}):
                declarations.setdefault(("task", "bootstrap"), (scope, str(path)))
        return configs, declarations

    def bootstrap_rows(self, status, plan, declarations):
        result = []

        def append(kind, name, current, desired, action, scope=None, config=None):
            source_kind = "service" if kind in ("user-service", "user_service", "user_services") else kind
            source = declarations.get((source_kind, name))
            if source:
                scope, config = source
            result.append({
                "kind": clean(kind, 100), "name": clean(name, 2048),
                "current": clean(current, 2048), "desired": clean(desired, 2048),
                "action": clean(action, 100), "scope": scope or "unclassified",
                "config": clean(config or "", 2048),
            })

        for item in rows(plan.get("resources"), "bootstrap resources"):
            identity = item["id"]
            append(identity["kind"], identity["name"], item.get("current", ""),
                   item.get("desired", ""), item["action"])
        for item in rows(status.get("repos", []), "repositories"):
            name = item.get("path_raw", item["path"])
            append("repo", name, item.get("current_ref") or item.get("reason", ""),
                   item.get("ref") or item.get("url", ""),
                   "noop" if item["state"] == "current" else item["state"])
        for item in rows(status.get("tools", []), "tools"):
            append("tool", item["tool"], item.get("resolved_version") or item["state"],
                   item.get("requested_version", ""),
                   "noop" if item["state"] == "installed"
                   else "on-demand" if item["tool"] in self.lazy_tools else item["state"])
        dot = status.get("dotfiles", {})
        for item in rows(dot.get("files", []) + dot.get("edits", []), "bootstrap dotfiles"):
            append("dotfile", item.get("target", item.get("file", "")),
                   item["state"], item.get("mode", "edit"),
                   "noop" if item["state"] in ("applied", "tracked", "absent", "not_on_this_machine")
                   else item["state"])
        for (kind, name), (scope, config) in declarations.items():
            if kind in ("hook", "task"):
                append(kind, name, "", "runs on every bootstrap", "always", scope, config)
        # The resource plan deliberately omits these; retain their reported states.
        for section in ("accounts", "files", "services", "user_services", "firewall",
                        "compose", "mise_shell_activate", "plugin_deps", "secrets"):
            values = status.get(section, [])
            if not isinstance(values, list):
                continue
            for item in rows(values, section):
                name = item.get("name", item.get("path", item.get("key", section)))
                if any(row["name"] == name for row in result):
                    continue
                action = item.get("action")
                state = item.get("state", item.get("current", "unknown"))
                append(section, name, state, item.get("desired", ""),
                       action or ("noop" if state in ("applied", "installed", "available",
                                                     "present", "running", "set") else state))
        for section, key in (("systemd", "units"), ("mise_shell_activate", "entries")):
            values = status.get(section, {})
            if not isinstance(values, dict):
                continue
            for item in rows(values.get(key, []), section):
                name = item.get("name", item.get("path", section))
                state = item.get("state", item.get("current", "unknown"))
                append(section, name, state, item.get("desired", ""),
                       item.get("action") or ("noop" if state in ("applied", "enabled", "current") else state))
        shell = status.get("login_shell")
        if isinstance(shell, dict):
            append("login_shell", "login shell", shell.get("current", "unknown"),
                   shell.get("desired", ""), shell.get("action", "unknown"))
        return rows(result, "dashboard resources")

    def snapshot(self):
        data = {"checked_at": datetime.datetime.now().astimezone().isoformat(),
                "errors": [], "configs": [], "dotfiles": [], "resources": [],
                "history": {}, "checkpoints": [], "profiles": [], "last_action": None}

        def collect(label, function):
            try:
                return function()
            except (DashboardError, OSError, ValueError, KeyError, TypeError) as error:
                data["errors"].append(f"{label}: {clean(error)}")
                return None

        source_data = collect("Config origins", self.sources)
        data["profiles"] = self.active_profiles
        declarations = {}
        if source_data:
            data["configs"], declarations = source_data
        dot = collect("Dotfiles", lambda: self.json("dot", "status", "--json"))
        if dot is not None:
            data["history"] = dot.get("history") or {}
            for item in rows(dot.get("files", []) + dot.get("edits", []) + dot.get("orphaned", []), "dotfiles"):
                origin = item.get("origin") or {}
                config = origin.get("config", "")
                environments = origin.get("environment", [])
                data["dotfiles"].append({
                    "name": clean(item.get("target", item.get("file", "")), 2048),
                    "state": clean(item.get("state", "unknown"), 100),
                    "mode": clean(item.get("mode", "edit"), 100),
                    "scope": ",".join(environments) if environments else self.scope(config),
                    "config": clean(config, 2048),
                })
        status = collect("Bootstrap status", lambda: self.json("bootstrap", "status", "--json"))
        plan = collect("Bootstrap plan", lambda: self.json("bootstrap", "plan", "--json"))
        if status is not None and plan is not None:
            result = collect("Bootstrap resources", lambda: self.bootstrap_rows(status, plan, declarations))
            if result is not None:
                dot_origins = {item["name"]: item for item in data["dotfiles"]}
                for resource in result:
                    if resource["kind"] == "dotfile" and resource["name"] in dot_origins:
                        resource.update({key: dot_origins[resource["name"]][key] for key in ("scope", "config")})
                data["resources"] = result
        checkpoints = collect("Checkpoints", lambda: self.json("dot", "history", "--json", "--limit", "8"))
        if checkpoints is not None:
            data["checkpoints"] = [
                {key: item.get(key) for key in ("id", "created_at", "trigger", "description")}
                for item in rows(checkpoints, "checkpoints")
            ]
        result_path = self.state_dir / "last-action.json"
        if result_path.exists():
            def read_result():
                if result_path.stat().st_size > 32768:
                    raise DashboardError("Action result is too large")
                return json.loads(result_path.read_text())
            data["last_action"] = collect("Last action", read_result)
        return data

    @contextlib.contextmanager
    def operation_lock(self):
        self.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (self.state_dir / "operation.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise DashboardError("Another dashboard fetch or apply is still running") from error
            yield

    def fetch(self):
        error = None
        try:
            with self.operation_lock():
                self.call("dot", "sync", "--fetch-only")
        except (DashboardError, OSError) as failure:
            error = clean(failure)
        data = self.snapshot()
        data["fetch_error"] = error
        return data

    def preview(self, kind):
        if kind not in PREVIEWS:
            raise DashboardError("Unknown preview")
        stdout, stderr = self.call(*PREVIEWS[kind], timeout=90)
        text = " ".join(self.command + PREVIEWS[kind]) + "\n\n" + stdout
        if stderr.strip():
            text += "\n" + stderr
        truncated = len(text) > MAX_PREVIEW
        return {"text": clean(text, MAX_PREVIEW), "truncated": truncated, "kind": kind}

    def record_action(self, action, state, code=None):
        self.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        result = {"action": action, "state": state, "exit_code": code,
                  "at": datetime.datetime.now().astimezone().isoformat()}
        temporary = self.state_dir / f"last-action.{os.getpid()}.tmp"
        with temporary.open("x", opener=lambda path, flags: os.open(path, flags, 0o600)) as stream:
            json.dump(result, stream)
        temporary.replace(self.state_dir / "last-action.json")
        # A terminal action may reload shell.json. Refresh whichever instance is now alive.
        try:
            result = subprocess.run(["omarchy-shell", "fredrik.mise.control", "refresh"],
                                    capture_output=True, timeout=5, check=False)
            if result.returncode:
                print("Dashboard refresh failed: " + clean((result.stderr or result.stdout).decode()),
                      file=sys.stderr)
        except (OSError, subprocess.TimeoutExpired) as error:
            print(f"Dashboard refresh failed: {error}", file=sys.stderr)

    def apply(self, action):
        if action not in ACTIONS:
            raise DashboardError("Unknown action")
        if not sys.stdin.isatty():
            raise DashboardError("Apply actions require an interactive terminal")
        preview = {"pull": "incoming", "publish": "publish", "bootstrap": "bootstrap"}[action]
        print(self.preview(preview)["text"])
        print("\nPull writes fetched tracked files. Publish pushes saved history.")
        print("Bootstrap may install packages, change services, and run hooks and tasks.")
        print("Trusted templates may execute configured functions even during inspection.")
        if input(f"\nType yes to run {' '.join(self.command + ACTIONS[action])}: ").strip() != "yes":
            print("Cancelled; no action was run.")
            return 0
        with self.operation_lock():
            self.record_action(action, "running")
            try:
                code = subprocess.call(self.command + ACTIONS[action], env=self.env, cwd=self.home)
            except OSError:
                self.record_action(action, "failed", 127)
                raise
            self.record_action(action, "succeeded" if code == 0 else "failed", code)
        print(f"\nCommand exited with {code}.")
        input("Press Enter to close.")
        return code


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("snapshot", "fetch", "preview", "apply"))
    parser.add_argument("kind", nargs="?")
    args = parser.parse_args()
    try:
        client = Client()
        if args.command == "apply":
            return client.apply(args.kind)
        if args.command == "preview":
            data = client.preview(args.kind)
        else:
            data = getattr(client, args.command)()
        print(json.dumps({"ok": True, "data": data}, ensure_ascii=True))
        return 0
    except (DashboardError, OSError, ValueError, KeyError, TypeError,
            subprocess.TimeoutExpired) as error:
        print(json.dumps({"ok": False, "error": clean(error)}, ensure_ascii=True))
        return 1


if __name__ == "__main__":
    sys.exit(main())

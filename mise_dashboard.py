#!/usr/bin/env python3
"""Bounded adapter between the Omarchy panel and mise.

State is read through mise's JSON interfaces and read-only git plumbing on
mise's local history repository. Files change only through the explicit pull,
publish, undo, and bootstrap actions the user confirms.
"""

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

MAX_OUTPUT = 4 * 1024 * 1024
MAX_ROWS = 3000
MAX_FILES = 200
MAX_FILE_LINES = 600
MAX_TOTAL_LINES = 4000
MAX_LINE = 500
MAX_LOG_LINES = 1500
ANSI = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))")
SCOPE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}")
OK_STATES = ("applied", "tracked", "absent", "not_on_this_machine", "installed",
             "available", "present", "running", "set", "enabled", "current")


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


def run(command, *, env=None, timeout=60, cwd=None, merge=False):
    with subprocess.Popen(
        command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT if merge else subprocess.PIPE,
        cwd=cwd, env=env, stdin=subprocess.DEVNULL, start_new_session=True,
    ) as process:
        output = [bytearray(), bytearray()]
        deadline = time.monotonic() + timeout
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ, 0)
                if process.stderr is not None:
                    selector.register(process.stderr, selectors.EVENT_READ, 1)
                while selector.get_map():
                    if time.monotonic() >= deadline:
                        raise DashboardError(f"{command[0]} timed out after {timeout}s")
                    for key, _ in selector.select(0.2):
                        chunk = os.read(key.fileobj.fileno(), 65536)
                        if not chunk:
                            selector.unregister(key.fileobj)
                            continue
                        output[key.data].extend(chunk)
                        if sum(map(len, output)) > MAX_OUTPUT:
                            raise DashboardError("Command output exceeded the 4 MiB safety limit")
                process.wait(timeout=max(0.01, deadline - time.monotonic()))
        except (DashboardError, subprocess.TimeoutExpired):
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise
        stdout, stderr = (part.decode("utf-8", errors="replace") for part in output)
        if process.returncode:
            raise DashboardError(clean(stderr.strip() or stdout.strip()
                                       or f"{command[0]} exited with {process.returncode}"))
        return stdout, stderr


def conflict_entries(sync):
    """mise reports each conflict as [path, reason]."""
    result = []
    for item in rows((sync or {}).get("conflicts") or [], "conflicts"):
        if isinstance(item, list) and item:
            result.append({"path": str(item[0]), "reason": str(item[1]) if len(item) > 1 else ""})
        elif isinstance(item, dict):
            result.append({"path": str(item.get("path", "")), "reason": str(item.get("reason", ""))})
        else:
            result.append({"path": str(item), "reason": ""})
    return result


def first_line(text):
    lines = [line.strip() for line in str(text).splitlines() if line.strip()]
    # mise prefixes failures with "mise ERROR"; the version footer is noise.
    lines = [line for line in lines if not line.startswith("mise ERROR Version")
             and "MISE_VERBOSE" not in line]
    return re.sub(r"^mise (ERROR|WARN)\s*", "", lines[0]) if lines else ""


def parse_patch(text, display=None):
    """Split a git-format patch into per-file records the panel can render."""
    files, notes = [], []
    current = None
    header = False
    total = 0
    hidden = 0
    reason = ""

    def start(path):
        nonlocal current, header, hidden
        header = True
        shown = display(path) if display else (path, "")
        if shown is None:
            hidden += 1
            current = {"skip": True}
            return
        if len(files) >= MAX_FILES:
            current = {"skip": True}
            return
        current = {"path": shown[0], "scope": shown[1], "repo_path": path, "status": "modified",
                   "additions": 0, "deletions": 0, "binary": False, "lines": [], "omitted": 0,
                   "reason": reason}
        files.append(current)

    for raw in str(text).splitlines():
        line = clean(raw, MAX_LINE * 4)
        conflict = re.match(r"Conflict: (~/.*) \((.*)\)$", line)
        if conflict:
            reason = conflict.group(2)
            continue
        # `mise dot conflicts` labels both sides with the live path.
        match = re.match(r"diff --git a(~/.*) \(local\) b~/.* \(remote\)$", line) \
            or re.match(r"diff --git a/(.*) b/(.*)$", line)
        if match:
            start(match.group(match.lastindex))
            reason = ""
            continue
        if current is None:
            if line.startswith("--- "):
                start(re.sub(r"^--- (a/)?", "", line).split("\t")[0])
            elif line.strip():
                notes.append(first_line(line) or line.strip())
            continue
        if header and not line.startswith("@@"):
            if current.get("skip"):
                continue
            if line.startswith("new file mode"):
                current["status"] = "added"
            elif line.startswith("deleted file mode"):
                current["status"] = "deleted"
            elif line.startswith("Binary files"):
                current["binary"] = True
            continue
        header = False
        if current.get("skip"):
            continue
        kind = line[:1] if line[:1] in "+-@\\" else " "
        if kind == "+":
            current["additions"] += 1
        elif kind == "-":
            current["deletions"] += 1
        if len(current["lines"]) >= MAX_FILE_LINES or total >= MAX_TOTAL_LINES:
            current["omitted"] += 1
            continue
        body = line if kind == "@" else line[1:]
        if len(body) > MAX_LINE:
            body = body[:MAX_LINE] + "…"
        current["lines"].append({"t": kind, "s": body})
        total += 1
    return {"files": files, "notes": notes[:20], "hidden": hidden}


def parse_log(text):
    lines = []
    script = False
    for raw in clean(text, MAX_OUTPUT).splitlines()[:MAX_LOG_LINES]:
        stripped = raw.strip()
        # A multi-line hook prints as one quoted `sh -c` script; keep it together.
        if script:
            body = stripped[:-1] if stripped.endswith("'") else stripped
            if body:
                lines.append({"t": "script", "s": raw.rstrip().rstrip("'")})
            script = not stripped.endswith("'")
            continue
        if stripped.startswith("sh -o errexit -c '") and not stripped.endswith("'"):
            script = True
            body = stripped[len("sh -o errexit -c '"):]
            if body:
                lines.append({"t": "script", "s": body})
            continue
        if not stripped:
            continue
        stage = re.match(r"mise bootstrap: (.+)$", stripped)
        wrapped = re.match(r"sh -o errexit -c '(.*)'$", stripped)
        task = re.match(r"\[[^\]]+\] \$ (.*)$", stripped)
        if stage:
            lines.append({"t": "stage", "s": stage.group(1).replace("`", "")})
        elif re.search(r"already|all (files|tools) are|no changes|up to date", stripped):
            lines.append({"t": "ok", "s": re.sub(r"^mise ", "", stripped)})
        elif wrapped or task or stripped.startswith("$ "):
            command = (wrapped or task).group(1) if (wrapped or task) else stripped[2:]
            lines.append({"t": "run", "s": command})
        else:
            lines.append({"t": "info", "s": re.sub(r"^mise ", "", stripped)})
    return lines


class Client:
    def __init__(self):
        self.home = Path.home()
        self.env = {**os.environ, "NO_COLOR": "1", "CLICOLOR": "0", "MISE_COLOR": "0",
                    "GIT_TERMINAL_PROMPT": "0", "PAGER": "cat"}
        self.command = ["mise", "-C", str(self.home)]
        self.active_profiles = []
        self.lazy_tools = set()
        # Package-managed defaults (Omarchy's /etc/mise/conf.d) load for precedence but stay hidden.
        self.system_dirs = ("/etc/",)
        self.state_dir = Path(self.env.get("XDG_STATE_HOME", self.home / ".local/state")) / "omarchy-mise"

    def call(self, *args, timeout=60, merge=False):
        return run(self.command + [str(arg) for arg in args], env=self.env, timeout=timeout,
                   cwd=self.home, merge=merge)

    def json(self, *args, timeout=60):
        raw, _ = self.call(*args, timeout=timeout)
        try:
            return sanitize(json.loads(raw))
        except json.JSONDecodeError as error:
            raise DashboardError(f"Invalid JSON from mise: {error}") from error

    def tilde(self, path):
        path = str(path)
        home = str(self.home)
        return "~" + path[len(home):] if path == home or path.startswith(home + "/") else path

    def scope(self, config):
        name = Path(config).name
        if name.endswith(".local.toml"):
            return "local"
        match = re.fullmatch(r"(?:config|mise)\.([A-Za-z0-9_-]+)\.toml", name)
        if match:
            return match.group(1)
        if str(config).startswith(self.system_dirs):
            return "system"
        return "common"

    def applies_here(self, scope):
        return scope in ("common", "local", "system") or scope in self.active_profiles

    def repo_display(self, repo_path):
        """Map a history-repository path to the live path and its scope."""
        if str(repo_path).startswith("~/"):
            return str(repo_path), ""
        top, _, rest = str(repo_path).partition("/")
        if not rest or top.startswith(".mise-history"):
            return None
        if top == "home":
            return "~/" + rest, "common"
        if top.startswith("home@") and SCOPE_NAME.fullmatch(top[5:]):
            return "~/" + rest, top[5:]
        if top == "config":
            return "~/.config/mise/" + rest, self.scope(rest)
        return repo_path, "other"

    # Configuration and bootstrap ------------------------------------------------

    def sources(self):
        entries = rows(self.json("config", "ls", "--json"), "config")
        declarations = {}
        configs = []
        # mise lists the highest precedence first, which is what wins a declaration.
        for entry in entries:
            path = Path(entry["path"])
            if path.stat().st_size > MAX_OUTPUT:
                raise DashboardError(f"Config too large: {path}")
            with path.open("rb") as stream:
                config = tomllib.load(stream)
            scope = self.scope(str(path))
            if scope not in ("common", "local", "system") and scope not in self.active_profiles:
                self.active_profiles.append(scope)
            bootstrap = config.get("bootstrap", {})
            tables = {
                "tool": config.get("tools", {}),
                "repo": bootstrap.get("repos", {}),
                "package": bootstrap.get("packages", {}),
                "service": bootstrap.get("services", {}),
                "hook": bootstrap.get("hooks", {}),
                "dotfile": config.get("dotfiles", {}),
            }
            counts = {kind: len(table) for kind, table in tables.items() if isinstance(table, dict) and table}
            if "bootstrap" in config.get("tasks", {}):
                counts["task"] = 1
                declarations.setdefault(("task", "bootstrap"), (scope, str(path)))
            if scope != "system":
                configs.append({"name": self.tilde(path), "scope": scope, "counts": counts})
            for kind, table in tables.items():
                if not isinstance(table, dict):
                    continue
                for name, spec in table.items():
                    if kind == "tool" and (kind, name) not in declarations \
                            and isinstance(spec, dict) and spec.get("lazy") is True:
                        self.lazy_tools.add(name)
                    declarations.setdefault((kind, self.tilde(name) if kind == "repo" else name),
                                            (scope, str(path)))
        return configs, declarations

    def bootstrap_rows(self, status, plan, declarations):
        result = []
        seen = set()
        repos = {self.tilde(item["path"]): item
                 for item in rows(status.get("repos", []), "repositories")}

        def append(kind, name, current, desired, action, scope=None, config=None):
            source_kind = "service" if kind in ("user_services", "services") else kind
            source = declarations.get((source_kind, name))
            if source:
                scope, config = source
            action = clean(action, 100)
            state = ("ok" if action == "noop"
                     else "always" if source_kind == "hook" and action == "run"
                     else action if action in ("on-demand", "always")
                     else "unknown" if action == "unknown" else "pending")
            seen.add((source_kind, name))
            result.append({
                "kind": source_kind, "name": clean(name, 2048),
                "current": clean(current, 2048), "desired": clean(desired, 2048),
                "action": action, "state": state, "scope": scope or "",
                "config": self.tilde(clean(config or "", 2048)),
            })

        def append_repo(name, item, planned=None):
            name = self.tilde(item.get("path_raw") or name)
            current = item.get("current_ref") or item.get("reason", "")
            desired = item.get("ref") or item.get("url", "")
            state = item["state"]
            action = planned["action"] if planned else ("noop" if state == "current" else state)
            # A checkout at the declared origin and ref already meets bootstrap's goal; mise never manages its edits.
            if (state == "dirty" and item.get("ref") in (None, "", item.get("current_ref")) and item.get("url")
                    and item.get("origin") == item["url"] and action in ("dirty", "unknown", "noop")):
                append("repo", name, "present (local edits)", desired, "noop")
            elif planned:
                append("repo", name, planned.get("current", current), planned.get("desired", desired), action)
            else:
                append("repo", name, current, desired, action)

        for item in rows(plan.get("resources"), "bootstrap resources"):
            identity = item["id"]
            kind, name = identity["kind"], identity["name"]
            if kind == "repo":
                name = self.tilde(name)
                repo = repos.pop(name, None)
                if repo is not None:
                    append_repo(name, repo, item)
                    continue
            append(kind, name, item.get("current", ""), item.get("desired", ""), item["action"])
        for name, item in repos.items():
            append_repo(name, item)
        for item in rows(status.get("tools", []), "tools"):
            append("tool", item["tool"], item.get("resolved_version") or item["state"],
                   item.get("requested_version", ""),
                   "noop" if item["state"] == "installed"
                   else "on-demand" if item["tool"] in self.lazy_tools else item["state"])
        for (kind, name), (scope, config) in declarations.items():
            if kind in ("hook", "task"):
                append(kind, name, "", "", "always", scope, config)
        for section in ("accounts", "files", "services", "user_services", "firewall",
                        "compose", "mise_shell_activate", "plugin_deps", "secrets"):
            values = status.get(section, [])
            if not isinstance(values, list):
                continue
            for item in rows(values, section):
                name = item.get("name", item.get("path", item.get("key", section)))
                kind = "service" if section in ("services", "user_services") else section
                if (kind, name) in seen:
                    continue
                state = item.get("state", item.get("current", "unknown"))
                append(kind, name, state, item.get("desired", ""),
                       item.get("action") or ("noop" if state in OK_STATES else state))
        systemd = status.get("systemd", {})
        if isinstance(systemd, dict):
            for item in rows(systemd.get("units", []), "systemd units"):
                state = item.get("state", item.get("current", "unknown"))
                append("systemd", item.get("name", "unit"), state, item.get("desired", ""),
                       item.get("action") or ("noop" if state in OK_STATES else state))
        shell = status.get("login_shell")
        if isinstance(shell, dict):
            append("login_shell", "login shell", shell.get("current", ""),
                   shell.get("desired", ""), shell.get("action", "unknown"))
        return rows([row for row in result if row["scope"] != "system"], "dashboard resources")

    # History repository -----------------------------------------------------------

    def git(self, repo, *args, timeout=30):
        env = {**self.env, "GIT_DIR": str(repo), "GIT_LITERAL_PATHSPECS": "1",
               "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
               "GIT_OPTIONAL_LOCKS": "0", "GIT_PAGER": "cat", "LC_ALL": "C"}
        return run(["git", "--no-pager", "-c", "core.quotepath=off", *args],
                   env=env, timeout=timeout)[0]

    def history_refs(self, history):
        repo_value = (history or {}).get("history_repo")
        if not repo_value:
            return None
        repo = Path(os.path.expanduser(repo_value))
        if not repo.is_dir():
            return None
        refs = self.git(repo, "for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes").split()
        try:
            local = self.git(repo, "symbolic-ref", "-q", "HEAD").strip()
        except DashboardError:
            local = ""
        if local not in refs:
            local = "refs/heads/main" if "refs/heads/main" in refs else ""
        branch = ((history.get("sync") or {}).get("branch")) or ""
        remotes = [ref for ref in refs if ref.startswith("refs/remotes/origin/")]
        remote = next((ref for ref in (f"refs/remotes/origin/{branch}", "refs/remotes/origin/setup")
                       if ref in remotes), remotes[0] if len(remotes) == 1 else "")
        if not local or not remote:
            return None
        return repo, local, remote

    def tree_changes(self, refs):
        repo, local, remote = refs
        names = self.git(repo, "diff", "--no-ext-diff", "--no-textconv", "--no-renames",
                         "--name-status", "-z", local, remote).split("\0")
        statuses = {}
        for index in range(0, len(names) - 1, 2):
            if names[index]:
                statuses[names[index + 1]] = names[index][:1]
        counts = {}
        for record in self.git(repo, "diff", "--no-ext-diff", "--no-textconv", "--no-renames",
                               "--numstat", "-z", local, remote).split("\0"):
            parts = record.split("\t", 2)
            if len(parts) == 3:
                counts[parts[2]] = (parts[0], parts[1])
        changes = []
        for repo_path, letter in list(statuses.items())[:MAX_FILES * 4]:
            shown = self.repo_display(repo_path)
            if shown is None:
                continue
            added, deleted = counts.get(repo_path, ("-", "-"))
            changes.append({"repo_path": repo_path, "path": shown[0], "scope": shown[1],
                            "status": {"A": "added", "D": "deleted"}.get(letter, "modified"),
                            "additions": int(added) if added.isdigit() else 0,
                            "deletions": int(deleted) if deleted.isdigit() else 0,
                            "binary": added == "-"})
        return changes

    def sync_changes(self, history):
        """Partition what differs from origin into incoming, outgoing, and other profiles."""
        sync = (history or {}).get("sync") or {}
        pending_raw = [str(item) for item in rows(sync.get("pending_applications") or [], "pending")]
        pending = {item for item in pending_raw if item.startswith(("~/", "/"))}
        entries = conflict_entries(sync)
        conflicts = {item["path"] for item in entries}
        result = {"available": False, "incoming": [], "outgoing": [], "other": [],
                  "conflicts": entries,
                  "notes": [item for item in pending_raw if item not in pending]}
        refs = self.history_refs(history)
        changes = self.tree_changes(refs) if refs else []
        result["available"] = refs is not None
        listed = set()
        for change in changes:
            if change["path"] in conflicts:
                continue
            if change["path"] in pending:
                result["incoming"].append(change)
                listed.add(change["path"])
            elif self.applies_here(change["scope"]):
                # The tree diff runs local -> origin; outgoing reads the other way.
                change = dict(change, additions=change["deletions"], deletions=change["additions"],
                              status={"added": "deleted", "deleted": "added"}.get(change["status"], "modified"))
                result["outgoing"].append(change)
            else:
                result["other"].append(change)
        for path in sorted(pending - listed):
            result["incoming"].append({"repo_path": "", "path": path, "scope": "common",
                                       "status": "modified", "additions": 0, "deletions": 0,
                                       "binary": False})
        for key in ("incoming", "outgoing", "other"):
            result[key] = result[key][:MAX_FILES]
        return result

    # Snapshot -----------------------------------------------------------------------

    def dotfile_row(self, item, unsaved=()):
        origin = item.get("origin") or {}
        config = origin.get("config", "")
        environments = origin.get("environment") or []
        # Whole-file entries name a `target` or `file`; partial edits such as merges name a `path`.
        name = clean(item.get("target") or item.get("file") or item.get("path") or "", 2048)
        return {
            "name": name,
            "state": clean(item.get("state", "unknown"), 100),
            "mode": clean(item.get("mode") or item.get("edit") or "edit", 100),
            "scope": ",".join(environments) if environments else self.scope(config),
            "config": self.tilde(clean(config, 2048)),
            "files": item.get("nested") or 0,
            "unsaved": bool(name) and any(path == name or path.startswith(name.rstrip("/") + "/")
                                          for path in unsaved),
        }

    @staticmethod
    def dotfile_resources(dotfiles, resources):
        """Bootstrap's dotfile stages fix entries out of their desired state; its plan omits them."""
        listed = {(row["kind"], row["name"]) for row in resources}
        return [{"kind": "dotfile", "name": item["name"], "current": item["state"],
                 "desired": item["mode"], "action": "update", "state": "pending",
                 "scope": item["scope"], "config": item["config"]}
                for item in dotfiles
                if item["name"] and item["state"] not in ("tracked", "applied", "absent", "orphaned")
                and ("dotfile", item["name"]) not in listed]

    def snapshot(self):
        data = {"checked_at": datetime.datetime.now().astimezone().isoformat(),
                "errors": [], "configs": [], "dotfiles": [], "resources": [],
                "history": {}, "checkpoints": [], "profiles": [], "changes": None,
                "last_action": None}

        def collect(label, function):
            try:
                return function()
            except (DashboardError, OSError, ValueError, KeyError, TypeError) as error:
                data["errors"].append(f"{label}: {first_line(clean(error)) or clean(error)}")
                return None

        source_data = collect("Configuration", self.sources)
        declarations = {}
        if source_data:
            data["configs"], declarations = source_data
        data["profiles"] = self.active_profiles
        dot = collect("Dotfiles", lambda: self.json("dot", "status", "--json"))
        if dot is not None:
            history = dot.get("history") or {}
            data["history"] = history
            unsaved = {str(item.get("path", item)) if isinstance(item, dict) else str(item)
                       for item in history.get("unsaved") or []}
            for item in rows(dot.get("files", []) + dot.get("edits", []) + dot.get("orphaned", []), "dotfiles"):
                data["dotfiles"].append(self.dotfile_row(item, unsaved))
            data["changes"] = collect("Origin comparison", lambda: self.sync_changes(history))
        status = collect("Bootstrap status", lambda: self.json("bootstrap", "status", "--json"))
        plan = collect("Bootstrap plan", lambda: self.json("bootstrap", "plan", "--json"))
        if status is not None and plan is not None:
            result = collect("Bootstrap resources", lambda: self.bootstrap_rows(status, plan, declarations))
            if result is not None:
                origins = {item["name"]: item for item in data["dotfiles"]}
                for resource in result:
                    if resource["kind"] == "dotfile" and resource["name"] in origins:
                        resource.update(scope=origins[resource["name"]]["scope"],
                                        config=origins[resource["name"]]["config"])
                data["resources"] = result + self.dotfile_resources(data["dotfiles"], result)
        checkpoints = collect("History", lambda: self.checkpoints())
        if checkpoints is not None:
            data["checkpoints"] = checkpoints
        data["fetch_interval"] = collect("Settings", lambda: first_line(
            self.call("settings", "get", "history.fetch_interval")[0]))
        result_path = self.state_dir / "last-action.json"
        if result_path.exists():
            def read_result():
                if result_path.stat().st_size > 32768:
                    raise DashboardError("Action result is too large")
                return json.loads(result_path.read_text())
            data["last_action"] = collect("Last action", read_result)
        return data

    def checkpoints(self, path=None, limit=30):
        args = ["dot", "history", "--json", "--limit", str(limit)]
        if path:
            args += ["--path", self.tracked_path(path)]
        result = []
        for item in rows(self.json(*args), "checkpoints"):
            operation = item.get("operation") or {}
            result.append({
                "id": item.get("id"), "created_at": item.get("created_at"),
                "trigger": item.get("trigger"),
                "description": item.get("description") or item.get("summary") or "",
                "affected": len(operation.get("affected") or []),
                "operation": operation.get("kind") or "",
            })
        result.sort(key=lambda item: (item.get("created_at") or "", item.get("id") or 0), reverse=True)
        return result

    def tracked_path(self, path):
        path = str(path)
        if not path.startswith("~/") or "\n" in path or "/../" in path + "/":
            raise DashboardError("Invalid tracked path")
        return path

    # Fetch, review, and actions -----------------------------------------------------

    @contextlib.contextmanager
    def operation_lock(self):
        self.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (self.state_dir / "operation.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise DashboardError("Another mise action from this panel is still running") from error
            yield

    def fetch(self):
        error = None
        try:
            with self.operation_lock():
                self.call("dot", "sync", "--fetch-only", timeout=90)
        except (DashboardError, OSError) as failure:
            error = first_line(clean(failure)) or clean(failure)
        data = self.snapshot()
        data["fetch_error"] = error
        return data

    def review(self, kind, argument=None):
        if kind in ("incoming", "outgoing", "other"):
            status = self.json("dot", "status", "--json")
            history = status.get("history") or {}
            refs = self.history_refs(history)
            if refs is None:
                raise DashboardError("No origin has been fetched yet")
            changes = self.sync_changes(history)[kind]
            paths = [item["repo_path"] for item in changes if item["repo_path"]]
            repo, local, remote = refs
            older, newer = (remote, local) if kind == "outgoing" else (local, remote)
            text = self.git(repo, "diff", "--no-ext-diff", "--no-textconv", "--no-renames",
                            "--no-color", older, newer, "--", *paths) if paths else ""
            parsed = parse_patch(text, self.repo_display)
            known = {item["path"] for item in parsed["files"]}
            for item in changes:
                if item["path"] not in known:
                    parsed["files"].append(dict(item, lines=[], omitted=0))
            return dict(parsed, kind=kind)
        if kind == "local":
            text, _ = self.call("dot", "history", "diff", "--patch", timeout=90)
        elif kind == "conflicts":
            status = self.json("dot", "status", "--json")
            entries = conflict_entries((status.get("history") or {}).get("sync") or {})
            text, _ = self.call("dot", "conflicts", timeout=90)
            parsed = parse_patch(text, self.repo_display)
            known = {item["path"] for item in parsed["files"]}
            for item in entries:
                if item["path"] not in known:
                    parsed["files"].append({
                        "path": item["path"], "scope": "", "repo_path": "",
                        "status": "modified", "additions": 0, "deletions": 0,
                        "binary": False, "lines": [], "omitted": 0,
                        "reason": item["reason"],
                    })
            return dict(parsed, kind=kind)
        elif kind == "deployment":
            text, _ = self.call("dot", "diff", timeout=90)
        elif kind == "checkpoint":
            identifier, _, path = str(argument or "").partition(" ")
            if not identifier.isdigit():
                raise DashboardError("Invalid checkpoint")
            args = ["dot", "history", "diff", identifier, "--patch"]
            if path:
                args += ["--path", self.tracked_path(path)]
            text, _ = self.call(*args, timeout=90)
        elif kind == "path-history":
            return {"kind": kind, "checkpoints": self.checkpoints(argument, 50)}
        elif kind == "bootstrap":
            output, _ = self.call("bootstrap", "--skip-dirty", "--dry-run", timeout=180, merge=True)
            return {"kind": kind, "log": parse_log(output)}
        else:
            raise DashboardError("Unknown review")
        return dict(parse_patch(text, self.repo_display), kind=kind)

    def record_action(self, action, state, message="", undo=None):
        self.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        result = {"action": action, "state": state, "message": clean(message, 2000), "undo": undo,
                  "at": datetime.datetime.now().astimezone().isoformat()}
        temporary = self.state_dir / f"last-action.{os.getpid()}.tmp"
        with open(temporary, "w", opener=lambda path, flags: os.open(path, flags, 0o600)) as stream:
            json.dump(result, stream)
        temporary.replace(self.state_dir / "last-action.json")
        return result

    def notify_shell(self):
        with contextlib.suppress(OSError, subprocess.TimeoutExpired):
            subprocess.run(["omarchy-shell", "-q", "fredrik.mise.control", "refresh"],
                           capture_output=True, timeout=5, check=False)

    def act(self, action, argument=None):
        """Run a confirmed non-interactive action and report the outcome."""
        with self.operation_lock():
            if action in ("pull", "resolve"):
                request = json.loads(argument or "{}")
                if action == "pull":
                    request = {"expected": request}
                expected = sorted(str(item) for item in request.get("expected") or [])
                history = self.json("dot", "status", "--json").get("history") or {}
                sync = history.get("sync") or {}
                conflicts = [item["path"] for item in conflict_entries(sync)]
                current = sorted(str(item) for item in sync.get("pending_applications") or [])
                flags = []
                if action == "resolve":
                    choices = request.get("choices") or {}
                    if not isinstance(choices, dict) or sorted(choices) != sorted(conflicts) \
                            or any(side not in ("local", "remote") for side in choices.values()):
                        raise DashboardError("Conflicts changed since you reviewed them. Review them again.")
                    for path in sorted(choices):
                        flags += ["--keep-local" if choices[path] == "local" else "--take-remote", path]
                elif conflicts:
                    raise DashboardError("Resolve conflicts before pulling")
                if current != expected:
                    raise DashboardError("Incoming changes changed since you reviewed them. Review them again.")
                started = datetime.datetime.now().astimezone()
                try:
                    self.call("dot", "pull", *flags, timeout=120)
                except DashboardError as error:
                    return self.record_action(action, "failed", first_line(clean(error)))
                undo = None
                for item in self.checkpoints(limit=10):
                    created = item.get("created_at") or ""
                    with contextlib.suppress(ValueError):
                        if item["operation"] == "apply" and \
                                datetime.datetime.fromisoformat(created) >= started.replace(microsecond=0):
                            undo = item["id"]
                            break
                count = len([item for item in expected if item.startswith(("~/", "/"))])
                return self.record_action(action, "succeeded", f"{count}", undo)
            if action == "publish":
                try:
                    self.call("dot", "sync", timeout=120)
                except DashboardError as error:
                    return self.record_action("publish", "failed", first_line(clean(error)))
                # mise holds local history back while origin has unpulled changes.
                history = self.json("dot", "status", "--json").get("history") or {}
                if self.sync_changes(history)["outgoing"]:
                    return self.record_action("publish", "failed", "Pull incoming changes first")
                return self.record_action("publish", "succeeded")
            if action == "undo":
                if not str(argument or "").isdigit():
                    raise DashboardError("Invalid checkpoint")
                match = [item for item in self.checkpoints(limit=30) if str(item["id"]) == str(argument)]
                if not match or match[0]["operation"] != "apply":
                    raise DashboardError("That pull can no longer be undone from here")
                try:
                    self.call("dot", "undo", argument, "--yes", timeout=120)
                except DashboardError as error:
                    return self.record_action("undo", "failed", first_line(clean(error)))
                return self.record_action("undo", "succeeded")
        raise DashboardError("Unknown action")

    def terminal(self, action):
        if action != "bootstrap":
            raise DashboardError("Unknown terminal action")
        if not sys.stdin.isatty():
            raise DashboardError("Bootstrap requires an interactive terminal")
        bold, dim, reset = "\033[1m", "\033[2m", "\033[0m"
        print(f"{bold}mise bootstrap{reset} {dim}(common + {', '.join(self.active_profiles) or 'no profile'}){reset}\n")
        print(f"{dim}Fresh preview:{reset}")
        output, _ = self.call("bootstrap", "--skip-dirty", "--dry-run", timeout=180, merge=True)
        for line in parse_log(output):
            prefix = {"stage": "\n▸ ", "ok": "  ✓ ", "run": "  $ "}.get(line["t"], "  · ")
            print(prefix + line["s"])
        print(f"\n{dim}Bootstrap may install packages, change services, and run hooks and tasks.{reset}")
        if input("Run it now? [y/N] ").strip().lower() not in ("y", "yes"):
            print("Cancelled; nothing was run.")
            return 0
        with self.operation_lock():
            self.record_action("bootstrap", "running")
            self.notify_shell()
            code = subprocess.call(self.command + ["bootstrap", "--skip-dirty"], env=self.env, cwd=self.home)
            self.record_action("bootstrap", "succeeded" if code == 0 else "failed",
                               "" if code == 0 else f"exit {code}")
            self.notify_shell()
        input(f"\n{'Done' if code == 0 else 'Bootstrap failed'}. Press Enter to close.")
        return code


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("snapshot", "fetch", "review", "act", "terminal"))
    parser.add_argument("kind", nargs="?")
    parser.add_argument("argument", nargs="?")
    args = parser.parse_args()
    try:
        client = Client()
        if args.command == "terminal":
            client.sources()
            return client.terminal(args.kind)
        if args.command == "review":
            client.sources()
            data = client.review(args.kind, args.argument)
        elif args.command == "act":
            client.sources()
            data = client.act(args.kind, args.argument)
        else:
            data = getattr(client, args.command)()
        print(json.dumps({"ok": True, "data": data}, ensure_ascii=True))
        return 0
    except (DashboardError, OSError, ValueError, KeyError, TypeError,
            subprocess.TimeoutExpired) as error:
        print(json.dumps({"ok": False, "error": first_line(clean(error)) or clean(error)}, ensure_ascii=True))
        return 1


if __name__ == "__main__":
    sys.exit(main())

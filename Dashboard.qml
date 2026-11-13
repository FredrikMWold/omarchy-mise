pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property var snapshot: null
  property bool autoFetch: true
  property bool configured: false
  property bool busy: process.running
  property string request: ""
  property string errorMessage: ""
  property string fetchError: ""
  property string detailKind: ""
  property string detailText: ""
  property bool previewReady: false
  property bool previewTruncated: false
  property bool queuedFetch: false
  property bool queuedRefresh: false
  property string output: ""
  property string diagnostics: ""
  readonly property string script: decodeURIComponent(String(Qt.resolvedUrl("mise_dashboard.py")).replace(/^file:\/\//, ""))
  readonly property var history: snapshot && snapshot.history ? snapshot.history : ({})
  readonly property var sync: history.sync || ({})
  readonly property int incomingCount: (sync.pending_applications || []).length
  readonly property int conflictCount: (sync.conflicts || []).length
  readonly property int bootstrapCount: snapshot ? snapshot.resources.filter(function (row) {
    return row.action !== "noop" && row.action !== "always" && row.action !== "on-demand";
  }).length : 0
  readonly property bool needsAttention: errorMessage !== "" || fetchError !== "" || (snapshot && snapshot.errors.length > 0) || incomingCount > 0 || conflictCount > 0 || bootstrapCount > 0 || sync.declarations_changed === true || !!sync.last_error || !!sync.application_failure || !!sync.validation_error

  function configure(settings) {
    var changed = !configured;
    autoFetch = settings.autoFetch !== false;
    configured = true;
    if (changed) {
      snapshot = null;
      fetchError = "";
      clearPreview();
      execute(autoFetch ? "fetch" : "snapshot");
    }
  }

  function clearPreview() {
    detailKind = "";
    detailText = "";
    previewReady = false;
    previewTruncated = false;
  }

  function execute(command, kind) {
    if (busy) {
      if (command === "fetch")
        queuedFetch = true;
      else if (command === "snapshot")
        queuedRefresh = true;
      return;
    }
    request = command;
    errorMessage = "";
    output = "";
    diagnostics = "";
    var argv = ["python3", script, command];
    if (kind)
      argv.push(kind);
    process.command = argv;
    process.running = true;
  }

  function refresh() {
    execute("snapshot");
  }
  function fetch() {
    execute("fetch");
  }

  function preview(kind) {
    if (busy)
      return;
    detailKind = kind;
    detailText = "";
    previewReady = false;
    previewTruncated = false;
    execute("preview", kind);
  }

  function setSetting(key, value) {
    if (settingsProcess.running)
      return;
    settingsProcess.command = ["omarchy", "bar", "set", "fredrik.mise", key, value, "--json"];
    settingsProcess.running = true;
  }

  function launch(action) {
    if (!previewReady || previewTruncated || busy || launcher.running)
      return;
    launcher.command = ["omarchy", "launch", "terminal", "python3", script, "apply", action];
    launcher.running = true;
    previewReady = false;
  }

  function finish(code) {
    try {
      var payload = JSON.parse(output);
      if (!payload.ok || code !== 0)
        throw new Error(payload.error || diagnostics || "Backend failed");
      if (request === "preview") {
        detailText = payload.data.text;
        previewTruncated = payload.data.truncated;
        previewReady = true;
      } else {
        snapshot = payload.data;
        if (request === "fetch")
          fetchError = snapshot.fetch_error || "";
      }
    } catch (error) {
      errorMessage = String(error.message || error);
      console.warn("fredrik.mise:", errorMessage);
    }
    if (queuedFetch || queuedRefresh) {
      var next = queuedFetch ? "fetch" : "snapshot";
      queuedFetch = false;
      queuedRefresh = false;
      Qt.callLater(function () {
        root.execute(next);
      });
    }
  }

  Process {
    id: process
    stdout: StdioCollector {
      onStreamFinished: root.output = text
    }
    stderr: StdioCollector {
      onStreamFinished: root.diagnostics = text
    }
    onExited: function (code) {
      root.finish(code);
    }
  }

  Process {
    id: settingsProcess
    stderr: StdioCollector {}
    onExited: function (code) {
      if (code !== 0)
        root.errorMessage = stderr.text || "Could not save dashboard settings";
    }
  }

  Process {
    id: launcher
    stderr: StdioCollector {}
    onExited: function (code) {
      if (code !== 0)
        root.errorMessage = stderr.text || "Could not open the action terminal";
    }
  }

  Timer {
    interval: 60000
    running: root.configured
    repeat: true
    onTriggered: if (!root.busy && !root.detailKind)
      root.refresh()
  }

  Timer {
    interval: 300000
    running: root.configured && root.autoFetch
    repeat: true
    onTriggered: if (!root.busy)
      root.fetch()
  }

  IpcHandler {
    target: "fredrik.mise.control"
    function refresh(): void {
      root.refresh();
    }
    function state(): string {
      return JSON.stringify({
        busy: root.busy,
        autoFetch: root.autoFetch,
        error: root.errorMessage,
        fetchError: root.fetchError,
        data: root.snapshot,
        previewReady: root.previewReady,
        detailKind: root.detailKind
      });
    }
    function preview(kind: string): void {
      root.preview(kind);
    }
  }
}

pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Shared state for every bar instance. Each request runs the bounded Python
// adapter; snapshots and reviews are read-only, actions are explicit.
Item {
  id: root

  property var snapshot: null
  property bool autoFetch: true
  property bool configured: false
  property string errorMessage: ""
  property string fetchError: ""
  property bool fetching: false
  property bool queuedFetch: false
  property bool queuedRefresh: false

  property string reviewKind: ""
  property string reviewArg: ""
  property var reviewData: null
  property string reviewError: ""

  property string acting: ""
  property var actionResult: null
  property string dismissedAt: ""

  readonly property bool busy: stateProcess.running
  readonly property bool reviewing: reviewProcess.running
  readonly property string script: decodeURIComponent(String(Qt.resolvedUrl("mise_dashboard.py")).replace(/^file:\/\//, ""))

  readonly property var history: snapshot && snapshot.history ? snapshot.history : ({})
  readonly property var sync: history.sync || ({})
  readonly property var changes: snapshot && snapshot.changes ? snapshot.changes
    : ({ available: false, incoming: [], outgoing: [], other: [], conflicts: [], notes: [] })
  readonly property var resources: snapshot ? snapshot.resources : []
  readonly property int incomingCount: changes.incoming.length
  readonly property int outgoingCount: changes.outgoing.length
  readonly property int otherCount: changes.other.length
  readonly property int conflictCount: changes.conflicts.length
  readonly property int unsavedCount: (history.unsaved || []).length
  readonly property int bootstrapPending: resources.filter(function(row) {
    return row.state === "pending" || row.state === "unknown"
  }).length
  readonly property bool declarationsChanged: sync.declarations_changed === true
  readonly property var syncProblems: [sync.last_error, sync.application_failure, sync.validation_error, history.unavailable]
    .filter(function(value) { return !!value }).map(function(value) {
      return typeof value === "object" ? JSON.stringify(value) : String(value)
    })
  readonly property var problems: [errorMessage, fetchError].filter(function(value) { return !!value })
    .concat(snapshot ? snapshot.errors : []).concat(syncProblems)
  readonly property int reviewCount: incomingCount + conflictCount + bootstrapPending
  readonly property string severity: conflictCount > 0 || problems.length > 0 ? "error"
    : reviewCount > 0 || outgoingCount > 0 ? "attention" : "ok"
  // The newest outcome from this panel or a terminal run, until dismissed or stale.
  readonly property var recentAction: {
    var candidates = [actionResult, snapshot ? snapshot.last_action : null].filter(function(item) { return !!item })
    candidates.sort(function(a, b) { return new Date(b.at).getTime() - new Date(a.at).getTime() })
    var result = candidates.length > 0 ? candidates[0] : null
    if (!result || result.at === dismissedAt) return null
    return isRecent(result.at, result.state === "running" ? 120 : 15) ? result : null
  }

  function isRecent(value, minutes) {
    var at = new Date(value)
    return !isNaN(at.getTime()) && Date.now() - at.getTime() < minutes * 60000
  }

  function configure(settings) {
    autoFetch = !settings || settings.autoFetch !== false
    if (configured) return
    configured = true
    run(autoFetch ? "fetch" : "snapshot")
  }

  function run(command) {
    if (stateProcess.running) {
      if (command === "fetch") queuedFetch = true
      else queuedRefresh = true
      return
    }
    fetching = command === "fetch"
    stateProcess.request = command
    stateProcess.command = ["python3", script, command]
    stateProcess.running = true
  }

  function refresh() { run("snapshot") }
  function fetch() { run("fetch") }

  function loadReview(kind, argument) {
    reviewKind = kind
    reviewArg = argument || ""
    reviewData = null
    reviewError = ""
    if (reviewProcess.running) reviewProcess.running = false
    var argv = ["python3", script, "review", kind]
    if (argument) argv.push(String(argument))
    reviewProcess.command = argv
    reviewProcess.running = true
  }

  function clearReview() {
    reviewKind = ""
    reviewData = null
    reviewError = ""
  }

  function act(action, argument) {
    if (acting !== "") return
    acting = action
    actionResult = { action: action, state: "running", at: new Date().toISOString() }
    var argv = ["python3", script, "act", action]
    if (argument !== undefined && argument !== null) argv.push(String(argument))
    actProcess.command = argv
    actProcess.running = true
  }

  function openTerminal(action) {
    terminalProcess.command = ["omarchy", "launch", "terminal", "python3", script, "terminal", action]
    terminalProcess.running = true
  }

  function dismissAction() { if (recentAction) dismissedAt = recentAction.at }

  function setAutoFetch(enabled) {
    autoFetch = enabled
    settingsProcess.command = ["omarchy", "bar", "set", "fredrik.mise", "autoFetch", enabled ? "true" : "false", "--json"]
    settingsProcess.running = true
  }

  function parse(text) {
    var payload = JSON.parse(text)
    if (!payload.ok) throw new Error(payload.error || "mise overview failed")
    return payload.data
  }

  Process {
    id: stateProcess
    property string request: ""
    property string output: ""
    stdout: StdioCollector { onStreamFinished: stateProcess.output = text }
    stderr: StdioCollector {}
    onExited: function(code) {
      try {
        var data = root.parse(stateProcess.output)
        root.snapshot = data
        root.errorMessage = ""
        if (stateProcess.request === "fetch") root.fetchError = data.fetch_error || ""
      } catch (error) {
        root.errorMessage = String(error.message || error)
      }
      root.fetching = false
      if (root.queuedFetch || root.queuedRefresh) {
        var next = root.queuedFetch ? "fetch" : "snapshot"
        root.queuedFetch = false
        root.queuedRefresh = false
        Qt.callLater(function() { root.run(next) })
      }
    }
  }

  Process {
    id: reviewProcess
    property string output: ""
    stdout: StdioCollector { onStreamFinished: reviewProcess.output = text }
    stderr: StdioCollector {}
    onExited: function(code) {
      try {
        root.reviewData = root.parse(reviewProcess.output)
      } catch (error) {
        root.reviewError = String(error.message || error)
      }
    }
  }

  Process {
    id: actProcess
    property string output: ""
    stdout: StdioCollector { onStreamFinished: actProcess.output = text }
    stderr: StdioCollector {}
    onExited: function(code) {
      try {
        root.actionResult = root.parse(actProcess.output)
      } catch (error) {
        root.actionResult = { action: root.acting, state: "failed", message: String(error.message || error),
          at: new Date().toISOString() }
      }
      root.acting = ""
      root.refresh()
    }
  }

  Process {
    id: terminalProcess
    stderr: StdioCollector { id: terminalErrors }
    onExited: function(code) {
      if (code !== 0) root.errorMessage = terminalErrors.text || "Could not open a terminal"
    }
  }

  Process {
    id: settingsProcess
    stderr: StdioCollector { id: settingsErrors }
    onExited: function(code) {
      if (code !== 0) root.errorMessage = settingsErrors.text || "Could not save the setting"
    }
  }

  // Local state is cheap to re-read; reaching origin is not, so it is paced.
  Timer {
    interval: 60000
    running: root.configured
    repeat: true
    onTriggered: if (!root.busy && root.acting === "") root.refresh()
  }

  Timer {
    interval: 300000
    running: root.configured && root.autoFetch
    repeat: true
    onTriggered: if (!root.busy && root.acting === "") root.fetch()
  }

  IpcHandler {
    target: "fredrik.mise.control"
    function refresh(): void { root.refresh() }
    function fetch(): void { root.fetch() }
    function state(): string {
      return JSON.stringify({ busy: root.busy, autoFetch: root.autoFetch, severity: root.severity,
        reviewCount: root.reviewCount, problems: root.problems, acting: root.acting,
        profiles: root.snapshot ? root.snapshot.profiles : null })
    }
  }
}

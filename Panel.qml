import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "."

Panel {
  id: root
  moduleName: "fredrik.mise"
  ipcTarget: "fredrik.mise"

  property var anchorItem: null
  property var hostWidget: null

  // Navigation: one view at a time, with a back stack for drill-ins.
  property string view: "home"
  property string viewArg: ""
  property var stack: []
  property var expanded: ({})
  property var choices: ({})
  property bool showAllResources: false

  // A single highlight shared by keyboard and mouse, as in the built-in panels.
  property bool cursorActive: false
  property Item cursorItem: null

  property bool confirmOpen: false
  property string confirmMessage: ""
  property string confirmLabel: ""
  property var confirmAction: null
  // 0 = cancel, 1 = confirm; the dialog lives in lazily built content.
  property int confirmIndex: 1

  property double clock: Date.now()

  readonly property Item panelFlick: panel.loadedContent ? panel.loadedContent.panelFlick : null
  readonly property Item viewRoot: panel.loadedContent ? panel.loadedContent.viewRoot : null
  readonly property var barIdentity: hostWidget || root

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var snapshot: Dashboard.snapshot
  readonly property var sync: Dashboard.sync
  readonly property var history: Dashboard.history
  readonly property var changes: Dashboard.changes
  readonly property var profiles: snapshot ? snapshot.profiles : []
  readonly property var review: Dashboard.reviewData
  readonly property var reviewFiles: review && review.files ? review.files : []

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // Formatting -------------------------------------------------------------------

  function n(value) { return Commons.I18n.formatNumber(value) }
  function count(key, value) { return strings.tn(key, value).arg(n(value)) }

  function plain(text) {
    return String(text).replace(/[\u202f\u00a0]/g, " ")
  }

  function relTime(value) {
    var now = root.clock
    var date = new Date(value)
    if (!value || isNaN(date.getTime())) return strings.t("time.never")
    var seconds = (now - date.getTime()) / 1000
    if (seconds < 45) return strings.t("time.now")
    if (seconds < 3600) return count("time.minutes", Math.max(1, Math.round(seconds / 60)))
    var locale = Qt.locale(Commons.I18n.formatLocale)
    var time = plain(date.toLocaleTimeString(locale, Locale.ShortFormat))
    if (date.toDateString() === new Date(now).toDateString()) return time
    if (date.toDateString() === new Date(now - 86400000).toDateString()) return strings.t("time.yesterday").arg(time)
    return plain(date.toLocaleDateString(locale, Locale.ShortFormat))
  }

  function shortOrigin(url) {
    var text = String(url || "")
    if (text === "") return strings.t("sync.noOrigin")
    var match = text.match(/[:/]([^/:]+\/[^/]+?)(?:\.git)?\/?$/)
    return match ? match[1] : text
  }

  function baseName(path) {
    var parts = String(path).replace(/\/$/, "").split("/")
    return parts[parts.length - 1] || String(path)
  }

  function dirName(path) {
    var text = String(path).replace(/\/$/, "")
    var index = text.lastIndexOf("/")
    return index > 0 ? text.slice(0, index) : ""
  }

  function folderLabel(path) {
    var folder = dirName(path)
    return folder === "~" ? strings.t("path.home") : folder
  }

  function modeLabel(mode) {
    var key = "mode." + mode
    var label = strings.t(key)
    return label === key ? String(mode || strings.t("none")) : label
  }

  function scopeLabel(scope) {
    return ["common", "local", "system", "other"].indexOf(scope) >= 0 ? strings.t("scope." + scope) : scope
  }

  function isProfile(scope) {
    return profiles.indexOf(scope) >= 0
  }

  readonly property string profileLabel: profiles.length > 0
    ? strings.t("profile.withProfiles").arg(profiles.join(", ")) : strings.t("profile.commonOnly")

  function pathsCaption(items) {
    var names = items.map(function(item) { return baseName(item.path || item) })
    var shown = names.slice(0, 3).join(", ")
    return names.length > 3 ? strings.t("more").arg(shown).arg(n(names.length - 3)) : shown
  }

  function countsText(file) {
    if (file.binary) return strings.t("diff.binary")
    var parts = []
    if (file.additions > 0) parts.push("+" + n(file.additions))
    if (file.deletions > 0) parts.push("−" + n(file.deletions))
    return parts.join(" ")
  }

  // Navigation -------------------------------------------------------------------

  readonly property var reviewKinds: ({
    incoming: "incoming", outgoing: "outgoing", other: "other", local: "local",
    conflicts: "conflicts", checkpoint: "checkpoint", pathHistory: "path-history", bootstrapRun: "bootstrap"
  })

  function go(target, argument) {
    stack = stack.concat([{ view: view, arg: viewArg }])
    enter(target, argument)
  }

  function enter(target, argument) {
    view = target
    viewArg = argument === undefined || argument === null ? "" : String(argument)
    expanded = ({})
    if (target === "conflicts") choices = ({})
    cursorItem = null
    if (panelFlick) panelFlick.contentY = 0
    if (reviewKinds[target]) Dashboard.loadReview(reviewKinds[target], viewArg)
    else Dashboard.clearReview()
    if (cursorActive) Qt.callLater(selectFirst)
  }

  function back() {
    if (stack.length === 0) return false
    var previous = stack[stack.length - 1]
    stack = stack.slice(0, -1)
    enter(previous.view, previous.arg)
    return true
  }

  function home() {
    stack = []
    enter("home")
  }

  onOpenedChanged: {
    if (!opened) {
      cancelConfirm()
      return
    }
    cursorActive = false
    home()
    clock = Date.now()
    if (!Dashboard.busy) Dashboard.refresh()
    Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.forceActiveFocus() })
  }

  // Cursor -----------------------------------------------------------------------

  function targets() {
    var found = []
    function walk(item) {
      if (!item || !item.visible) return
      if (item.cursorTarget === true) found.push(item)
      for (var i = 0; i < item.children.length; i++) walk(item.children[i])
    }
    walk(viewRoot)
    return found
  }

  function setCursor(item) {
    cursorActive = true
    cursorItem = item
  }

  function selectFirst() {
    var list = targets()
    cursorItem = list.length > 0 ? list[0] : null
    if (cursorItem) scrollIntoView(cursorItem)
  }

  function moveCursor(dy) {
    var list = targets()
    if (list.length === 0) {
      if (panelFlick) panelFlick.contentY = Math.max(0, Math.min(panelFlick.contentHeight - panelFlick.height,
        panelFlick.contentY + dy * Style.space(60)))
      return
    }
    var index = list.indexOf(cursorItem)
    if (!cursorActive || index < 0) index = dy < 0 ? list.length - 1 : 0
    else index = Math.max(0, Math.min(list.length - 1, index + dy))
    cursorActive = true
    cursorItem = list[index]
    scrollIntoView(cursorItem)
  }

  function activateCursor() {
    if (cursorActive && cursorItem && typeof cursorItem.activate === "function") cursorItem.activate()
  }

  function scrollIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item || !panelFlick) return
      var margin = Style.space(8)
      var top = item.mapToItem(panelFlick.contentItem, 0, 0).y
      var bottom = top + item.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > panelFlick.contentY + panelFlick.height - margin)
        panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function toggleExpanded(path) {
    var next = Object.assign({}, expanded)
    next[path] = !next[path]
    expanded = next
  }

  function choose(path, side) {
    var next = Object.assign({}, choices)
    next[path] = side
    choices = next
  }

  // Actions ----------------------------------------------------------------------

  function ask(message, label, action) {
    confirmMessage = message
    confirmLabel = label
    confirmAction = action
    confirmIndex = 1
    confirmOpen = true
  }

  function runConfirm() {
    var action = confirmAction
    cancelConfirm()
    if (action) action()
  }

  function cancelConfirm() {
    confirmOpen = false
    confirmAction = null
  }

  function pull() {
    ask(count("confirm.pull", Dashboard.incomingCount), strings.t("confirmButton.pull"), function() {
      Dashboard.act("pull", JSON.stringify(root.sync.pending_applications || []))
      root.home()
    })
  }

  function resolve() {
    var others = Dashboard.incomingCount
    var message = others > 0 ? count("confirm.resolveAndPull", others) : strings.t("confirm.resolve")
    ask(message, strings.t("confirmButton.resolve"), function() {
      Dashboard.act("resolve", JSON.stringify({ expected: root.sync.pending_applications || [], choices: root.choices }))
      root.home()
    })
  }

  function publish() {
    ask(strings.t("confirm.publish").arg(shortOrigin(sync.origin)), strings.t("confirmButton.publish"), function() {
      Dashboard.act("publish")
      root.home()
    })
  }

  function undo(id) {
    ask(strings.t("confirm.undo"), strings.t("confirmButton.undo"), function() { Dashboard.act("undo", String(id)) })
  }

  // Opens a tracked file or folder with the editor chosen under Omarchy defaults.
  function openInEditor(path) {
    var home = Quickshell.env("HOME")
    var target = String(path).replace(/^~(?=\/|$)/, home)
    if (target.indexOf(home + "/") !== 0 && target !== home) return
    Quickshell.execDetached(["omarchy-launch-editor", target])
    close()
  }

  function runBootstrap() {
    Dashboard.openTerminal("bootstrap")
    close()
  }

  // Derived content --------------------------------------------------------------

  readonly property var hero: {
    if (!snapshot) return { icon: "󰓦", color: dim, title: strings.t("hero.loading") }
    if (Dashboard.conflictCount > 0) return { icon: "󰓧", color: urgent, title: count("hero.conflicts", Dashboard.conflictCount) }
    if (Dashboard.problems.length > 0) return { icon: "󰓧", color: urgent, title: strings.t("hero.problem") }
    if (Dashboard.incomingCount > 0) return { icon: "󰅢", color: accent, title: count("hero.incoming", Dashboard.incomingCount) }
    if (Dashboard.bootstrapPending > 0) return { icon: "󰏗", color: accent, title: count("hero.bootstrap", Dashboard.bootstrapPending) }
    if (Dashboard.outgoingCount > 0) return { icon: "󰅧", color: foreground, title: count("hero.outgoing", Dashboard.outgoingCount) }
    return { icon: "󰓦", color: foreground, title: strings.t("hero.inSync") }
  }

  readonly property string heroMeta: Dashboard.fetching ? strings.t("hero.checking")
    : profileLabel + " · " + strings.t("hero.checked").arg(relTime(sync.last_fetch))

  readonly property bool hasChanges: Dashboard.conflictCount + Dashboard.incomingCount + Dashboard.outgoingCount
    + Dashboard.unsavedCount + Dashboard.bootstrapPending + Dashboard.otherCount > 0 || Dashboard.declarationsChanged

  readonly property var dotfileGroups: {
    if (!snapshot) return []
    var order = ["common"].concat(profiles).concat(["local", "system"])
    snapshot.dotfiles.forEach(function(item) { if (order.indexOf(item.scope) < 0) order.push(item.scope) })
    return order.map(function(scope) {
      return { scope: scope, items: snapshot.dotfiles.filter(function(item) { return item.scope === scope }) }
    }).filter(function(group) { return group.items.length > 0 })
  }

  readonly property var dotfileSummary: dotfileGroups.map(function(group) {
    return n(group.items.length) + " " + scopeLabel(group.scope)
  }).join(" · ")

  readonly property var kindOrder: ["package", "tool", "repo", "dotfile", "service", "systemd", "files", "accounts",
    "compose", "firewall", "login_shell", "hook", "task"]

  readonly property var resourceGroups: {
    var rows = Dashboard.resources.filter(function(row) {
      return root.showAllResources || ["pending", "unknown", "always"].indexOf(row.state) >= 0
    })
    var order = kindOrder.slice()
    rows.forEach(function(row) { if (order.indexOf(row.kind) < 0) order.push(row.kind) })
    return order.map(function(kind) {
      var all = Dashboard.resources.filter(function(row) { return row.kind === kind })
      return { kind: kind, total: all.length, items: rows.filter(function(row) { return row.kind === kind }) }
    }).filter(function(group) { return group.items.length > 0 })
  }

  readonly property int resourcesMatching: Dashboard.resources.filter(function(row) { return row.state === "ok" }).length
  readonly property int resourcesOnDemand: Dashboard.resources.filter(function(row) { return row.state === "on-demand" }).length
  readonly property int resourcesAlways: Dashboard.resources.filter(function(row) { return row.state === "always" }).length

  readonly property var visibleCheckpoints: (view === "pathHistory" ? (review && review.checkpoints) || []
    : snapshot ? snapshot.checkpoints : [])
    .filter(function(item) { return !/-before$/.test(String(item.trigger || "")) })

  function kindLabel(kind) {
    var key = "kind." + kind
    var label = strings.t(key)
    return label === key ? String(kind).replace(/_/g, " ") : label
  }

  function triggerIcon(trigger) {
    return { apply: "󰅢", bootstrap: "󰏗", undo: "󰕌", rollback: "󰕌", save: "󰏫", edit: "󰏫" }[trigger] || "󰋚"
  }

  function triggerLabel(trigger) {
    var key = "trigger." + trigger
    var label = strings.t(key)
    return label === key ? String(trigger || "") : label
  }

  readonly property var actionInfo: {
    var result = Dashboard.recentAction
    if (!result) return null
    var ok = result.state === "succeeded"
    var running = result.state === "running"
    var title = running ? strings.t("result.running." + result.action)
      : result.action === "pull" && ok ? count("result.pulled", parseInt(result.message, 10) || 0)
      : strings.t("result." + result.action + "." + result.state)
    return {
      running: running, ok: ok, title: title,
      caption: !ok && !running && result.message ? result.message : relTime(result.at),
      undo: ok && (result.action === "pull" || result.action === "resolve") && result.undo ? result.undo : null
    }
  }

  readonly property var reviewHeading: {
    var titles = {
      incoming: [strings.t("review.incoming"), strings.t("review.incomingCaption").arg(relTime(sync.last_fetch))],
      outgoing: [strings.t("review.outgoing"), strings.t("review.outgoingCaption").arg(shortOrigin(sync.origin))],
      other: [strings.t("review.other"), strings.t("review.otherCaption")],
      local: [strings.t("review.local"), strings.t("review.localCaption")],
      conflicts: [strings.t("review.conflicts"), strings.t("review.conflictsCaption")],
      checkpoint: [strings.t("review.checkpoint").arg(viewArg.split(" ")[0]), checkpointCaption]
    }
    return titles[view] || ["", ""]
  }

  readonly property string checkpointCaption: {
    var id = viewArg.split(" ")[0]
    var path = viewArg.indexOf(" ") > 0 ? viewArg.slice(viewArg.indexOf(" ") + 1) : ""
    var match = (snapshot ? snapshot.checkpoints : []).filter(function(item) { return String(item.id) === id })[0]
    var parts = match ? [triggerLabel(match.trigger), relTime(match.created_at)] : []
    if (path) parts.push(path)
    return parts.join(" · ")
  }

  readonly property var reviewTotals: {
    var additions = 0, deletions = 0
    reviewFiles.forEach(function(file) { additions += file.additions; deletions += file.deletions })
    return { files: reviewFiles.length, additions: additions, deletions: deletions }
  }

  readonly property bool allChosen: view === "conflicts" && reviewFiles.length > 0
    && reviewFiles.every(function(file) { return !!root.choices[file.path] })

  // Expand short diffs on arrival; long ones wait for a click.
  Connections {
    target: Dashboard
    function onReviewDataChanged() {
      if (!Dashboard.reviewData || !Dashboard.reviewData.files) return
      var files = Dashboard.reviewData.files
      var lines = files.reduce(function(sum, file) { return sum + (file.lines || []).length }, 0)
      var next = ({})
      files.forEach(function(file, index) {
        if (lines <= 160 || index === 0 && (file.lines || []).length <= 120) next[file.path] = true
      })
      root.expanded = next
      if (root.cursorActive) Qt.callLater(root.selectFirst)
    }
  }

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.clock = Date.now()
  }

  // Opens straight onto a view, e.g. `omarchy-shell fredrik.mise.view open incoming`.
  ShellIpc {
    target: "fredrik.mise.view"
    function open(name: string): void {
      var separator = name.indexOf(":")
      var target = separator > 0 ? name.slice(0, separator) : name
      var argument = separator > 0 ? name.slice(separator + 1) : ""
      var views = ["home", "incoming", "outgoing", "other", "local", "conflicts", "dotfiles", "history", "bootstrap", "bootstrapRun", "configs", "checkpoint", "pathHistory"]
      if (views.indexOf(target) < 0) return
      if (!root.opened) root.controller.show()
      Qt.callLater(function() {
        root.home()
        if (target !== "home") root.go(target, argument)
      })
    }
  }

  // Layout -----------------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(640))

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias panelFlick: panelFlick
      property alias viewRoot: viewRoot
      anchors.fill: parent
      implicitHeight: viewRoot.implicitHeight

      onMoveRequested: function(dx, dy) {
        if (root.confirmOpen) {
          root.confirmIndex = root.confirmIndex === 0 ? 1 : 0
          return
        }
        if (dx < 0) root.back()
        else if (dx > 0) {
          if (root.cursorItem && typeof root.cursorItem.drill === "function") root.cursorItem.drill()
          else if (root.cursorItem && root.cursorItem.drillable === true) root.activateCursor()
        }
        else root.moveCursor(dy)
      }
      onActivateRequested: {
        if (!root.confirmOpen) root.activateCursor()
        else if (root.confirmIndex === 1) root.runConfirm()
        else root.cancelConfirm()
      }
      onCloseRequested: {
        if (root.confirmOpen) root.cancelConfirm()
        else if (!root.back()) root.close()
      }
      onTabRequested: function(direction) {
        if (root.confirmOpen) root.confirmIndex = root.confirmIndex === 0 ? 1 : 0
        else root.switchPanel(direction)
      }
      onTextKey: function(text) {
        if (root.confirmOpen) return
        if (text === "r" || text === "R") Dashboard.fetch()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: viewRoot.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: viewRoot
          width: panelFlick.width

          Loader { width: parent.width; active: root.view === "home"; visible: active; sourceComponent: homeView }
          Loader {
            width: parent.width
            active: ["incoming", "outgoing", "other", "local", "conflicts", "checkpoint"].indexOf(root.view) >= 0
            visible: active
            sourceComponent: reviewView
          }
          Loader { width: parent.width; active: root.view === "dotfiles"; visible: active; sourceComponent: dotfilesView }
          Loader { width: parent.width; active: root.view === "history" || root.view === "pathHistory"; visible: active; sourceComponent: historyView }
          Loader { width: parent.width; active: root.view === "bootstrap"; visible: active; sourceComponent: bootstrapView }
          Loader { width: parent.width; active: root.view === "bootstrapRun"; visible: active; sourceComponent: bootstrapRunView }
          Loader { width: parent.width; active: root.view === "configs"; visible: active; sourceComponent: configsView }
        }
      }

      ConfirmDialog {
        id: confirm
        anchors.fill: parent
        z: 10
        opened: root.confirmOpen
        selectedIndex: root.confirmIndex
        onSelectedIndexChanged: root.confirmIndex = selectedIndex
        message: root.confirmMessage
        confirmText: root.confirmLabel
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: root.cancelConfirm()
        onConfirmed: root.runConfirm()
      }
    }
  }

  // Views ------------------------------------------------------------------------

  Component {
    id: homeView

    Column {
      spacing: Style.space(12)

      Item {
        id: heroHost
        width: parent.width
        implicitHeight: heroItem.implicitHeight
        readonly property var heroState: root.hero
        readonly property color foreground: root.foreground
        readonly property string fontFamily: root.fontFamily

        PanelHero {
          id: heroItem
          width: parent.width
          title: heroHost.heroState.title
          meta: root.heroMeta
          foreground: heroHost.foreground
          fontFamily: heroHost.fontFamily
          iconComponent: Component {
            Text {
              textFormat: Text.PlainText
              text: heroHost.heroState.icon
              color: heroHost.heroState.color
              font.family: heroHost.fontFamily
              font.pixelSize: Style.font.display
            }
          }
          trailingControl: Component {
            ActionButton {
              iconText: "󰑐"
              iconSpinning: Dashboard.fetching
              cursorTarget: false
              bordered: false
              tooltipText: strings.t("hero.checkTooltip")
              onClicked: Dashboard.fetch()
            }
          }
        }
      }

      ResultBanner { visible: root.actionInfo !== null }

      Repeater {
        model: Dashboard.problems
        Notice {
          required property string modelData
          icon: "󰀨"
          tint: root.urgent
          textColor: root.urgent
          text: modelData
        }
      }

      PanelSeparator { visible: root.hasChanges; foreground: root.foreground }

      Section {
        visible: root.hasChanges
        title: strings.t("section.changes")

        NavRow {
          visible: Dashboard.conflictCount > 0
          icon: "󰀦"
          iconColor: root.urgent
          title: root.count("row.conflicts", Dashboard.conflictCount)
          caption: root.pathsCaption(root.changes.conflicts)
          onTriggered: root.go("conflicts")
        }
        NavRow {
          visible: Dashboard.incomingCount > 0
          icon: "󰅢"
          iconColor: root.accent
          title: root.count("row.incoming", Dashboard.incomingCount)
          caption: root.pathsCaption(root.changes.incoming)
          onTriggered: root.go("incoming")
        }
        NavRow {
          visible: Dashboard.bootstrapPending > 0 || Dashboard.declarationsChanged
          icon: "󰏗"
          iconColor: Dashboard.bootstrapPending > 0 ? root.accent : root.foreground
          title: Dashboard.bootstrapPending > 0 ? root.count("row.bootstrap", Dashboard.bootstrapPending) : strings.t("row.declarations")
          caption: Dashboard.bootstrapPending > 0 ? strings.t("row.bootstrapCaption") : strings.t("row.declarationsCaption")
          onTriggered: root.go("bootstrap")
        }
        NavRow {
          visible: Dashboard.outgoingCount > 0
          icon: "󰅧"
          title: root.count("row.outgoing", Dashboard.outgoingCount)
          caption: root.pathsCaption(root.changes.outgoing)
          onTriggered: root.go("outgoing")
        }
        NavRow {
          visible: Dashboard.unsavedCount > 0
          icon: "󰏫"
          title: root.count("row.unsaved", Dashboard.unsavedCount)
          caption: strings.t("row.unsavedCaption")
          onTriggered: root.go("local")
        }
        NavRow {
          visible: Dashboard.otherCount > 0
          icon: "󰌢"
          iconColor: root.dim
          title: root.count("row.other", Dashboard.otherCount)
          caption: root.pathsCaption(root.changes.other)
          onTriggered: root.go("other")
        }
      }

      PanelSeparator { foreground: root.foreground }

      Section {
        title: strings.t("section.sync")
        spacing: Style.space(6)

        Column {
          width: parent.width
          leftPadding: Style.space(10)
          rightPadding: Style.space(10)
          spacing: Style.space(5)

          InfoPair { label: strings.t("sync.origin"); value: root.shortOrigin(root.sync.origin) }
          InfoPair { label: strings.t("sync.branch"); value: root.sync.branch || strings.t("none") }
          InfoPair {
            label: strings.t("sync.mode")
            value: root.sync.mode !== "manual" && root.snapshot && root.snapshot.fetch_interval
              ? strings.t("mode." + root.sync.mode + "Every").arg(root.snapshot.fetch_interval)
              : root.modeLabel(root.sync.mode)
          }
          InfoPair { label: strings.t("sync.pulled"); value: root.relTime(root.sync.last_apply) }
          InfoPair { label: strings.t("sync.published"); value: root.relTime(root.sync.last_publish) }
          InfoPair {
            label: strings.t("sync.capture")
            value: root.history.watcher === "running" ? strings.t("capture.running") : strings.t("capture.stopped")
            valueColor: root.history.watcher === "running" ? root.foreground : root.urgent
          }
        }
      }

      PanelSeparator { foreground: root.foreground }

      Section {
        title: strings.t("section.browse")

        NavRow {
          icon: "󰈙"
          title: strings.t("browse.dotfiles")
          caption: root.snapshot ? root.count("browse.dotfilesCount", root.snapshot.dotfiles.length) + " · " + root.dotfileSummary : ""
          onTriggered: root.go("dotfiles")
        }
        NavRow {
          icon: "󰏗"
          title: strings.t("browse.bootstrap")
          caption: Dashboard.resources.length === 0 ? strings.t("browse.nothingDeclared")
            : Dashboard.bootstrapPending > 0 ? root.count("browse.pending", Dashboard.bootstrapPending)
            : root.count("browse.matching", root.resourcesMatching)
              + (root.resourcesOnDemand > 0 ? " · " + root.count("browse.onDemand", root.resourcesOnDemand) : "")
          onTriggered: root.go("bootstrap")
        }
        NavRow {
          icon: "󰋚"
          title: strings.t("browse.history")
          caption: root.history.checkpoints
            ? root.count("browse.checkpoints", root.history.checkpoints) + " · " + strings.t("browse.latest").arg(root.relTime(root.history.latest ? root.history.latest.created_at : null))
            : ""
          onTriggered: root.go("history")
        }
        NavRow {
          icon: "󰒓"
          title: strings.t("browse.config")
          caption: root.snapshot ? root.count("browse.configFiles", root.snapshot.configs.length) + " · " + root.profileLabel : ""
          onTriggered: root.go("configs")
        }
      }
    }
  }

  Component {
    id: reviewView

    Column {
      spacing: Style.space(12)

      ViewHeader { title: root.reviewHeading[0]; caption: root.reviewHeading[1] }

      LoadingRow { visible: Dashboard.reviewing }

      Notice {
        visible: Dashboard.reviewError !== ""
        icon: "󰀨"
        tint: root.urgent
        textColor: root.urgent
        text: Dashboard.reviewError
      }

      Item {
        visible: !Dashboard.reviewing && root.review !== null
        width: parent.width
        implicitHeight: summaryText.implicitHeight

        Text {
          id: summaryText
          textFormat: Text.PlainText
          width: parent.width - legend.implicitWidth - Style.space(8)
          text: root.reviewTotals.files === 0 ? strings.t("review.empty")
            : root.count("review.files", root.reviewTotals.files)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        Row {
          id: legend
          visible: root.reviewTotals.files > 0
          anchors.right: parent.right
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            visible: root.view === "conflicts" || root.reviewTotals.additions > 0
            text: root.view === "conflicts" ? strings.t("legend.remote") : "+" + root.n(root.reviewTotals.additions)
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          Text {
            textFormat: Text.PlainText
            visible: root.view === "conflicts" || root.reviewTotals.deletions > 0
            text: root.view === "conflicts" ? strings.t("legend.local") : "−" + root.n(root.reviewTotals.deletions)
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
      }

      Repeater {
        model: root.review && root.review.notes ? root.review.notes : []
        Notice {
          required property string modelData
          icon: "󰋽"
          tint: root.dim
          textColor: root.dim
          text: modelData
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(6)

        Repeater {
          model: root.reviewFiles
          FileRow {
            required property var modelData
            file: modelData
            conflict: root.view === "conflicts"
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: root.review !== null && (root.review.hidden || 0) > 0
        width: parent.width
        text: root.count("review.hidden", root.review ? root.review.hidden || 0 : 0)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      // What the reviewed changes lead to, with the reason when it is held back.
      Column {
        visible: !Dashboard.reviewing && root.review !== null && ["incoming", "outgoing", "conflicts"].indexOf(root.view) >= 0
          && root.reviewTotals.files > 0
        width: parent.width
        spacing: Style.space(8)

        PanelSeparator { foreground: root.foreground }

        Notice {
          visible: root.view === "incoming" && Dashboard.conflictCount > 0
          icon: "󰀦"
          tint: root.urgent
          text: root.count("hold.conflicts", Dashboard.conflictCount)
        }
        Notice {
          visible: root.view === "outgoing" && Dashboard.incomingCount > 0
          icon: "󰋽"
          tint: root.foreground
          text: strings.t("hold.pullFirst")
        }
        Notice {
          visible: root.view === "conflicts"
          icon: "󰋽"
          tint: root.foreground
          text: Dashboard.incomingCount > 0 ? root.count("hold.resolveAlsoPulls", Dashboard.incomingCount) : strings.t("hold.choose")
        }
        Notice {
          visible: root.view === "incoming" && Dashboard.conflictCount === 0
          icon: "󰕌"
          tint: root.dim
          textColor: root.dim
          text: strings.t("hold.undoable")
        }

        Row {
          anchors.right: parent.right
          spacing: Style.space(8)

          ActionButton {
            visible: root.view === "incoming" && Dashboard.conflictCount > 0
            text: strings.t("action.reviewConflicts")
            onClicked: root.go("conflicts")
          }
          ActionButton {
            visible: root.view === "outgoing" && Dashboard.incomingCount > 0
            text: strings.t("action.reviewIncoming")
            onClicked: root.go("incoming")
          }
          ActionButton {
            visible: root.view === "incoming"
            primary: true
            enabled: Dashboard.conflictCount === 0 && Dashboard.acting === ""
            iconText: "󰅢"
            text: root.count("action.pullCount", Dashboard.incomingCount)
            onClicked: root.pull()
          }
          ActionButton {
            visible: root.view === "outgoing"
            primary: true
            enabled: Dashboard.incomingCount === 0 && Dashboard.acting === ""
            iconText: "󰅧"
            text: strings.t("action.publish")
            onClicked: root.publish()
          }
          ActionButton {
            visible: root.view === "conflicts"
            primary: true
            enabled: root.allChosen && Dashboard.acting === ""
            text: strings.t("action.resolve")
            onClicked: root.resolve()
          }
        }
      }
    }
  }

  Component {
    id: dotfilesView

    Column {
      spacing: Style.space(12)

      ViewHeader {
        title: strings.t("browse.dotfiles")
        caption: root.count("browse.dotfilesCount", root.snapshot ? root.snapshot.dotfiles.length : 0)
          + " · " + root.count("dotfiles.caption", root.history.tracked_files || 0)
      }

      Repeater {
        model: root.dotfileGroups

        Section {
          required property var modelData
          title: root.scopeLabel(modelData.scope) + " · " + root.n(modelData.items.length)
          spacing: Style.space(1)

          Repeater {
            model: modelData.items
            PathRow {
              required property var modelData
              readonly property bool attention: ["tracked", "applied", "absent"].indexOf(modelData.state) < 0
              path: modelData.name
              detail: modelData.unsaved ? strings.t("state.unsaved") : attention ? modelData.state
                : modelData.files > 1 ? root.count("dotfiles.files", modelData.files) : ""
              detailColor: attention ? root.urgent : modelData.unsaved ? root.accent : root.dim
              onTriggered: root.openInEditor(modelData.name)
              onHistoryRequested: root.go("pathHistory", modelData.name)
            }
          }
        }
      }
    }
  }

  Component {
    id: historyView

    Column {
      spacing: Style.space(12)

      ViewHeader {
        title: root.view === "pathHistory" ? root.baseName(root.viewArg) : strings.t("browse.history")
        caption: root.view === "pathHistory" ? strings.t("history.pathCaption").arg(root.viewArg)
          : root.count("browse.checkpoints", root.history.checkpoints || 0)
      }

      LoadingRow { visible: root.view === "pathHistory" && Dashboard.reviewing }

      Text {
        textFormat: Text.PlainText
        visible: !Dashboard.reviewing && root.visibleCheckpoints.length === 0
        width: parent.width
        text: strings.t("history.empty")
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        horizontalAlignment: Text.AlignHCenter
      }

      Column {
        width: parent.width
        spacing: Style.space(4)

        Repeater {
          model: root.visibleCheckpoints
          NavRow {
            required property var modelData
            icon: root.triggerIcon(modelData.trigger)
            iconColor: modelData.trigger === "apply" ? root.accent : root.dim
            title: modelData.operation === "apply" && modelData.affected > 0 ? root.count("history.pulled", modelData.affected)
              : modelData.description || root.triggerLabel(modelData.trigger)
            caption: "#" + modelData.id + " · " + root.triggerLabel(modelData.trigger) + " · " + root.relTime(modelData.created_at)
              + (modelData.affected > 0 ? " · " + root.count("dotfiles.files", modelData.affected) : "")
            onTriggered: root.go("checkpoint", modelData.id + (root.view === "pathHistory" ? " " + root.viewArg : ""))
          }
        }
      }
    }
  }

  Component {
    id: bootstrapView

    Column {
      spacing: Style.space(12)

      ViewHeader { title: strings.t("browse.bootstrap"); caption: root.profileLabel }

      Row {
        width: parent.width
        spacing: Style.space(12)

        Text {
          id: bootstrapGlyph
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          text: Dashboard.bootstrapPending > 0 ? "󰏗" : "󰗠"
          color: Dashboard.bootstrapPending > 0 ? root.accent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.display
        }

        Column {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - bootstrapGlyph.width - parent.spacing
          spacing: Style.space(2)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: Dashboard.bootstrapPending > 0 ? root.count("bootstrap.pending", Dashboard.bootstrapPending)
              : root.count("bootstrap.allMatch", root.resourcesMatching + root.resourcesOnDemand)
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            wrapMode: Text.Wrap
          }
          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: [root.resourcesOnDemand > 0 ? root.count("bootstrap.onDemand", root.resourcesOnDemand) : "",
              root.resourcesAlways > 0 ? root.count("bootstrap.always", root.resourcesAlways) : ""]
              .filter(function(part) { return part !== "" }).join(" · ")
            visible: text !== ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }
        }
      }

      Notice {
        visible: Dashboard.declarationsChanged
        icon: "󰋽"
        tint: root.foreground
        text: strings.t("bootstrap.declarations")
      }

      ToggleRow {
        title: strings.t("bootstrap.showAll")
        caption: strings.t("bootstrap.showAllCaption")
        checked: root.showAllResources
        onToggled: root.showAllResources = !root.showAllResources
      }

      Repeater {
        model: root.resourceGroups

        Section {
          required property var modelData
          title: root.kindLabel(modelData.kind) + " · " + (root.showAllResources ? root.n(modelData.total)
            : strings.t("bootstrap.ofTotal").arg(root.n(modelData.items.length)).arg(root.n(modelData.total)))
          spacing: Style.space(2)

          Repeater {
            model: modelData.items
            ResourceRow { required property var modelData; resource: modelData }
          }
        }
      }

      PanelSeparator { foreground: root.foreground }

      Row {
        anchors.right: parent.right
        spacing: Style.space(8)

        ActionButton {
          primary: true
          iconText: "󰆍"
          text: strings.t("action.previewRun")
          onClicked: root.go("bootstrapRun")
        }
      }
    }
  }

  Component {
    id: bootstrapRunView

    Column {
      spacing: Style.space(10)

      ViewHeader { title: strings.t("run.title"); caption: strings.t("run.caption") }

      LoadingRow { visible: Dashboard.reviewing; text: strings.t("run.loading") }

      Notice {
        visible: Dashboard.reviewError !== ""
        icon: "󰀨"
        tint: root.urgent
        textColor: root.urgent
        text: Dashboard.reviewError
      }

      Column {
        width: parent.width
        spacing: Style.space(3)

        Repeater {
          model: root.review && root.review.log ? root.review.log : []

          Item {
            required property var modelData
            required property int index
            width: parent.width
            implicitHeight: lineText.implicitHeight + (modelData.t === "stage" && index > 0 ? Style.space(8) : 0)

            Text {
              textFormat: Text.PlainText
              y: lineText.y
              visible: modelData.t !== "stage"
              width: Style.space(18)
              text: modelData.t === "ok" ? "󰄬" : modelData.t === "run" ? "$" : modelData.t === "script" ? "" : "·"
              color: modelData.t === "run" ? root.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              id: lineText
              textFormat: Text.PlainText
              y: parent.height - implicitHeight
              x: modelData.t === "stage" ? 0 : Style.space(18)
              width: parent.width - x
              text: modelData.t === "stage" ? modelData.s.toUpperCase() : modelData.s
              color: modelData.t === "stage" || modelData.t === "ok" || modelData.t === "script" ? root.dim : root.foreground
              font.family: root.fontFamily
              font.pixelSize: modelData.t === "stage" ? Style.font.caption : Style.font.bodySmall
              font.bold: modelData.t === "stage"
              font.letterSpacing: modelData.t === "stage" ? 1.2 : 0
              wrapMode: Text.WrapAnywhere
            }
          }
        }
      }

      PanelSeparator { visible: root.review !== null; foreground: root.foreground }

      Notice {
        visible: root.review !== null
        icon: "󰋽"
        tint: root.dim
        textColor: root.dim
        text: strings.t("run.terminalNote")
      }

      Row {
        visible: root.review !== null
        anchors.right: parent.right

        ActionButton {
          primary: true
          iconText: "󰆍"
          text: strings.t("action.runTerminal")
          onClicked: root.runBootstrap()
        }
      }
    }
  }

  Component {
    id: configsView

    Column {
      spacing: Style.space(12)

      ViewHeader { title: strings.t("browse.config"); caption: strings.t("config.caption") }

      Column {
        width: parent.width
        spacing: Style.space(4)

        Repeater {
          model: root.snapshot ? root.snapshot.configs : []

          CursorSurface {
            required property var modelData
            width: parent.width
            implicitHeight: configLayout.implicitHeight + Style.spacing.rowPaddingX
            foreground: root.foreground

            RowLayout {
              id: configLayout
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(10)

              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(1)

                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: modelData.name
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideMiddle
                }
                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: {
                    var counts = modelData.counts || {}
                    var parts = Object.keys(counts).map(function(kind) { return root.count("config.count." + kind, counts[kind]) })
                    return parts.length > 0 ? parts.join(" · ") : strings.t("config.settingsOnly")
                  }
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.Wrap
                }
              }

              ScopeTag { scope: modelData.scope; Layout.alignment: Qt.AlignVCenter }
            }
          }
        }
      }
    }
  }

  // Building blocks --------------------------------------------------------------

  component Section: Column {
    property string title: ""
    width: parent ? parent.width : 0
    spacing: Style.space(4)

    PanelSectionHeader {
      text: parent.title
      foreground: root.foreground
      fontFamily: root.fontFamily
      bottomPadding: Style.space(4)
    }
  }

  component ViewHeader: Item {
    id: viewHeader
    property string title: ""
    property string caption: ""
    width: parent ? parent.width : 0
    implicitHeight: Math.max(backButton.implicitHeight, headerText.implicitHeight)

    ActionButton {
      id: backButton
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      cursorTarget: false
      bordered: false
      iconText: "󰁍"
      tooltipText: strings.t("back")
      onClicked: root.back()
    }

    Column {
      id: headerText
      anchors.left: backButton.right
      anchors.leftMargin: Style.space(8)
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: viewHeader.title
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        elide: Text.ElideRight
      }
      Text {
        textFormat: Text.PlainText
        visible: text !== ""
        width: parent.width
        text: viewHeader.caption
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideMiddle
      }
    }
  }

  component ActionButton: Button {
    id: actionButton
    property bool primary: false
    property bool cursorTarget: visible && enabled
    property bool drillable: false
    function activate() { actionButton.clicked() }

    hasCursor: root.cursorActive && root.cursorItem === actionButton
    bordered: true
    selected: primary
    foreground: root.foreground
    fontFamily: root.fontFamily
    opacity: enabled ? 1 : 0.4
    onHovered: function(isHovered) { if (isHovered && actionButton.enabled && actionButton.cursorTarget) root.setCursor(actionButton) }
  }

  component NavRow: CursorSurface {
    id: navRow
    property string icon: ""
    property color iconColor: root.foreground
    property string title: ""
    property string caption: ""
    property string trailing: ""
    property color trailingColor: root.dim
    property bool drillable: true
    property bool cursorTarget: true
    signal triggered()
    function activate() { navRow.triggered() }

    hasCursor: root.cursorActive && root.cursorItem === navRow
    foreground: root.foreground
    width: parent ? parent.width : 0
    implicitHeight: navLayout.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setCursor(navRow)
      onClicked: navRow.activate()
    }

    RowLayout {
      id: navLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(10)

      Text {
        textFormat: Text.PlainText
        text: navRow.icon
        color: navRow.iconColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        horizontalAlignment: Text.AlignHCenter
        Layout.preferredWidth: Style.space(18)
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: navRow.title
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          visible: navRow.caption !== ""
          text: navRow.caption
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: navRow.trailing !== ""
        text: navRow.trailing
        color: navRow.trailingColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        Layout.alignment: Qt.AlignVCenter
      }

      Text {
        textFormat: Text.PlainText
        visible: navRow.drillable
        text: "󰅂"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        Layout.alignment: Qt.AlignVCenter
      }
    }
  }

  component PathRow: CursorSurface {
    id: pathRow
    property string path: ""
    property string detail: ""
    property color detailColor: root.dim
    property bool cursorTarget: true
    property bool drillable: false
    signal triggered()
    signal historyRequested()
    function activate() { pathRow.triggered() }
    function drill() { pathRow.historyRequested() }

    readonly property string folder: root.dirName(path)
    hasCursor: root.cursorActive && root.cursorItem === pathRow
    foreground: root.foreground
    width: parent ? parent.width : 0
    implicitHeight: nameText.implicitHeight + Style.space(12)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setCursor(pathRow)
      onClicked: pathRow.activate()
    }

    Text {
      id: folderText
      textFormat: Text.PlainText
      x: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(implicitWidth, Math.max(0, detailText.x - x - nameText.implicitWidth - Style.space(12)))
      text: pathRow.folder !== "" ? pathRow.folder + "/" : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideLeft
      horizontalAlignment: Text.AlignRight
    }

    Text {
      id: nameText
      textFormat: Text.PlainText
      anchors.left: folderText.right
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(implicitWidth, Math.max(0, detailText.x - x - Style.space(12)))
      text: root.baseName(pathRow.path)
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    Text {
      id: detailText
      textFormat: Text.PlainText
      anchors.right: rowActions.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: pathRow.detail
      color: pathRow.detailColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    // Shown on the highlighted row only; the space stays reserved so names do not shift.
    Row {
      id: rowActions
      anchors.right: parent.right
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)
      opacity: pathRow.hasCursor ? 1 : 0
      enabled: pathRow.hasCursor

      PanelActionButton {
        iconText: "󰏫"
        tooltipText: strings.t("dotfiles.open")
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        onClicked: pathRow.activate()
        onHovered: function(isHovered) { if (isHovered) root.setCursor(pathRow) }
      }
      PanelActionButton {
        iconText: "󰋚"
        tooltipText: strings.t("dotfiles.history")
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        onClicked: pathRow.drill()
        onHovered: function(isHovered) { if (isHovered) root.setCursor(pathRow) }
      }
    }
  }

  component ToggleRow: CursorSurface {
    id: toggleRow
    property string title: ""
    property string caption: ""
    property bool checked: false
    property bool cursorTarget: true
    property bool drillable: false
    signal toggled()
    function activate() { toggleRow.toggled() }

    hasCursor: root.cursorActive && root.cursorItem === toggleRow
    foreground: root.foreground
    width: parent ? parent.width : 0
    implicitHeight: toggleLayout.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setCursor(toggleRow)
      onClicked: toggleRow.activate()
    }

    RowLayout {
      id: toggleLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(10)

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: toggleRow.title
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: toggleRow.caption
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }
      }

      ToggleSwitch {
        checked: toggleRow.checked
        foreground: root.foreground
        cursorRing: false
        Layout.alignment: Qt.AlignVCenter
        onToggled: toggleRow.activate()
        onHovered: function(isHovered) { if (isHovered) root.setCursor(toggleRow) }
      }
    }
  }

  component InfoPair: Item {
    property string label: ""
    property string value: ""
    property color valueColor: root.foreground
    width: parent ? parent.width - parent.leftPadding - parent.rightPadding : 0
    implicitHeight: Math.max(pairLabel.implicitHeight, pairValue.implicitHeight)

    Text {
      id: pairLabel
      textFormat: Text.PlainText
      text: parent.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      id: pairValue
      textFormat: Text.PlainText
      anchors.right: parent.right
      width: Math.min(implicitWidth, parent.width - pairLabel.implicitWidth - Style.space(16))
      text: parent.value
      color: parent.valueColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideMiddle
    }
  }

  component Notice: Item {
    id: notice
    property string icon: "󰋽"
    property color tint: root.foreground
    property color textColor: root.foreground
    property string text: ""
    width: parent ? parent.width : 0
    implicitHeight: Math.max(noticeIcon.implicitHeight, noticeText.implicitHeight)

    Text {
      id: noticeIcon
      textFormat: Text.PlainText
      text: notice.icon
      color: notice.tint
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      id: noticeText
      textFormat: Text.PlainText
      x: Style.space(22)
      width: parent.width - x
      text: notice.text
      color: notice.textColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.Wrap
    }
  }

  component LoadingRow: Row {
    property string text: strings.t("loading")
    spacing: Style.space(8)

    Text {
      id: spinner
      textFormat: Text.PlainText
      text: "󰑐"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      RotationAnimation on rotation {
        from: 0
        to: 360
        duration: Style.duration(900)
        loops: Animation.Infinite
        running: spinner.visible && !Style.reduceMotion
      }
    }

    Text {
      textFormat: Text.PlainText
      text: parent.text
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  component ScopeTag: BorderSurface {
    id: scopeTag
    property string scope: ""
    readonly property bool profile: root.isProfile(scope)
    visible: scope !== ""
    implicitWidth: scopeText.implicitWidth + Style.space(10)
    implicitHeight: scopeText.implicitHeight + Style.space(2)
    color: "transparent"
    radius: Style.cornerRadius
    borderSpec: Border.flat(Util.alpha(profile ? root.accent : root.foreground, 0.35), 1)

    Text {
      id: scopeText
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: scopeTag.scope
      color: scopeTag.profile ? root.accent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  component ResultBanner: BorderSurface {
    id: banner
    readonly property var info: root.actionInfo
    readonly property color tint: !info ? root.foreground : info.running ? root.foreground : info.ok ? root.accent : root.urgent
    width: parent ? parent.width : 0
    implicitHeight: bannerLayout.implicitHeight + Style.space(14)
    color: Util.alpha(tint, 0.08)
    borderSpec: Border.flat(Util.alpha(tint, 0.35), 1)
    radius: Style.cornerRadius

    RowLayout {
      id: bannerLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(10)

      Item {
        implicitWidth: Math.max(statusGlyph.implicitWidth, spinnerGlyph.implicitWidth)
        implicitHeight: Math.max(statusGlyph.implicitHeight, spinnerGlyph.implicitHeight)
        Layout.alignment: Qt.AlignVCenter

        Text {
          id: statusGlyph
          textFormat: Text.PlainText
          anchors.centerIn: parent
          visible: !!banner.info && !banner.info.running
          text: !banner.info ? "" : banner.info.ok ? "󰗠" : "󰀨"
          color: banner.tint
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon
        }

        Text {
          id: spinnerGlyph
          textFormat: Text.PlainText
          anchors.centerIn: parent
          visible: !!banner.info && banner.info.running
          text: "󰑐"
          color: banner.tint
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon
          RotationAnimation on rotation {
            from: 0
            to: 360
            duration: Style.duration(900)
            loops: Animation.Infinite
            running: spinnerGlyph.visible && !Style.reduceMotion
          }
        }
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: banner.info ? banner.info.title : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: banner.info ? banner.info.caption : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }
      }

      ActionButton {
        visible: !!banner.info && banner.info.undo !== null
        iconText: "󰕌"
        text: strings.t("action.undo")
        enabled: Dashboard.acting === ""
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.undo(banner.info.undo)
      }

      PanelActionButton {
        visible: !!banner.info && !banner.info.running
        iconText: "󰅖"
        tooltipText: strings.t("dismiss")
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: Dashboard.dismissAction()
      }
    }
  }

  component ResourceRow: Item {
    id: resourceRow
    property var resource: null
    readonly property string resourceState: resource ? resource.state : ""
    readonly property color tint: resourceState === "pending" ? root.accent : resourceState === "unknown" ? root.urgent : root.dim
    width: parent ? parent.width : 0
    implicitHeight: resourceLayout.implicitHeight + Style.space(8)

    RowLayout {
      id: resourceLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(10)

      Text {
        textFormat: Text.PlainText
        text: ({ ok: "󰄬", pending: "󰐕", unknown: "󰀦", always: "󰑐", "on-demand": "󰇚" })[resourceRow.resourceState] || "·"
        color: resourceRow.tint
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        horizontalAlignment: Text.AlignHCenter
        Layout.preferredWidth: Style.space(18)
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: resourceRow.resource ? resourceRow.resource.name : ""
          color: resourceRow.resourceState === "ok" || resourceRow.resourceState === "on-demand" ? root.dim : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideMiddle
        }
        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          visible: text !== ""
          text: {
            var item = resourceRow.resource
            if (!item) return ""
            if (item.state === "always") return strings.t("resource.always")
            if (item.state === "on-demand") return strings.t("resource.onDemand")
            if (item.state === "ok") return item.current
            var detail = item.current && item.desired ? strings.t("resource.change").arg(item.current).arg(item.desired)
              : item.current || item.desired
            return item.action + (detail ? " · " + detail : "")
          }
          color: resourceRow.resourceState === "pending" || resourceRow.resourceState === "unknown" ? resourceRow.tint : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      ScopeTag { scope: resourceRow.resource ? resourceRow.resource.scope : ""; Layout.alignment: Qt.AlignVCenter }
    }
  }

  component FileRow: Column {
    id: fileRow
    property var file: null
    property bool conflict: false
    readonly property bool open: !!file && !!root.expanded[file.path]
    readonly property string choice: file ? root.choices[file.path] || "" : ""
    readonly property color statusColor: !file ? root.foreground
      : file.status === "added" ? root.accent : file.status === "deleted" ? root.urgent : root.foreground
    width: parent ? parent.width : 0
    spacing: Style.space(4)

    CursorSurface {
      id: fileHeader
      property bool cursorTarget: true
      property bool drillable: false
      function activate() { if (fileRow.file) root.toggleExpanded(fileRow.file.path) }

      hasCursor: root.cursorActive && root.cursorItem === fileHeader
      foreground: root.foreground
      width: parent.width
      implicitHeight: fileLayout.implicitHeight + Style.spacing.rowPaddingX

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: root.setCursor(fileHeader)
        onClicked: fileHeader.activate()
      }

      RowLayout {
        id: fileLayout
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(8)
        spacing: Style.space(10)

        Text {
          textFormat: Text.PlainText
          text: fileRow.conflict ? "󰀦" : !fileRow.file ? "" : fileRow.file.status === "added" ? "󰐕" : fileRow.file.status === "deleted" ? "󰍴" : "󰏫"
          color: fileRow.conflict ? root.urgent : fileRow.statusColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          horizontalAlignment: Text.AlignHCenter
          Layout.preferredWidth: Style.space(18)
          Layout.alignment: Qt.AlignVCenter
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(1)

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: fileRow.file ? root.baseName(fileRow.file.path) : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }
          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: !fileRow.file ? "" : [root.folderLabel(fileRow.file.path), fileRow.file.reason || ""]
              .filter(function(part) { return part !== "" }).join(" · ")
            visible: text !== ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideMiddle
          }
        }

        ScopeTag {
          scope: fileRow.file && fileRow.file.scope && fileRow.file.scope !== "common" ? fileRow.file.scope : ""
          Layout.alignment: Qt.AlignVCenter
        }

        Row {
          spacing: Style.space(6)
          Layout.alignment: Qt.AlignVCenter

          Text {
            textFormat: Text.PlainText
            visible: !!fileRow.file && fileRow.file.additions > 0 && !fileRow.file.binary
            text: fileRow.file ? "+" + root.n(fileRow.file.additions) : ""
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            textFormat: Text.PlainText
            visible: !!fileRow.file && fileRow.file.deletions > 0 && !fileRow.file.binary
            text: fileRow.file ? "−" + root.n(fileRow.file.deletions) : ""
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            textFormat: Text.PlainText
            visible: !!fileRow.file && fileRow.file.binary
            text: strings.t("diff.binary")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          textFormat: Text.PlainText
          text: "󰅂"
          rotation: fileRow.open ? 90 : 0
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          Layout.alignment: Qt.AlignVCenter
          Behavior on rotation { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }
        }
      }
    }

    DiffBlock { visible: fileRow.open; file: fileRow.file }

    Row {
      visible: fileRow.conflict
      leftPadding: Style.space(38)
      spacing: Style.space(8)

      ActionButton {
        text: strings.t("conflict.keepLocal")
        selected: fileRow.choice === "local"
        onClicked: root.choose(fileRow.file.path, "local")
      }
      ActionButton {
        text: strings.t("conflict.takeRemote")
        selected: fileRow.choice === "remote"
        onClicked: root.choose(fileRow.file.path, "remote")
      }
    }
  }

  component DiffBlock: BorderSurface {
    id: diffBlock
    property var file: null
    readonly property var lines: file && file.lines ? file.lines : []
    width: parent ? parent.width : 0
    implicitHeight: diffColumn.implicitHeight + Style.space(8)
    color: Util.alpha(root.foreground, 0.03)
    borderSpec: Border.flat(Util.alpha(root.foreground, 0.12), 1)
    radius: Style.cornerRadius
    clip: true

    // Inset by the border so highlighted lines don't paint over it.
    Column {
      id: diffColumn
      x: diffBlock.borderLeft
      y: Style.space(4)
      width: parent.width - diffBlock.borderLeft - diffBlock.borderRight

      Text {
        textFormat: Text.PlainText
        visible: diffBlock.lines.length === 0
        x: Style.space(10)
        width: parent.width - Style.space(20)
        text: diffBlock.file && diffBlock.file.binary ? strings.t("diff.binaryNote") : strings.t("diff.noPreview")
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        topPadding: Style.space(4)
        bottomPadding: Style.space(4)
      }

      Repeater {
        model: diffBlock.lines

        Rectangle {
          required property var modelData
          readonly property string kind: modelData.t
          width: diffColumn.width
          height: diffLine.implicitHeight + Style.space(2)
          color: kind === "+" ? Util.alpha(root.accent, 0.12) : kind === "-" ? Util.alpha(root.urgent, 0.12) : "transparent"

          Text {
            id: gutter
            textFormat: Text.PlainText
            x: Style.space(6)
            y: Style.space(1)
            width: Style.space(12)
            text: kind === "+" || kind === "-" ? (kind === "-" ? "−" : "+") : ""
            color: kind === "+" ? root.accent : root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            id: diffLine
            textFormat: Text.PlainText
            x: gutter.x + gutter.width
            y: Style.space(1)
            width: parent.width - x - Style.space(6)
            text: modelData.s === "" ? " " : modelData.s
            color: kind === "@" || kind === "\\" ? root.dim : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WrapAnywhere
            topPadding: kind === "@" ? Style.space(3) : 0
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: !!diffBlock.file && (diffBlock.file.omitted || 0) > 0
        x: Style.space(10)
        width: parent.width - Style.space(20)
        text: root.count("diff.omitted", diffBlock.file ? diffBlock.file.omitted || 0 : 0)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        topPadding: Style.space(4)
      }
    }
  }
}

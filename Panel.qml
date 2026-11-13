import QtQuick
import QtQuick.Controls as Controls
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
  property string tab: "overview"
  property string scopeFilter: "all"
  property bool changesOnly: true
  property bool confirming: false
  readonly property var snapshot: Dashboard.snapshot
  readonly property var history: Dashboard.history
  readonly property var sync: Dashboard.sync
  readonly property string action: Dashboard.detailKind === "incoming" ? "pull" : Dashboard.detailKind === "bootstrap" ? "bootstrap" : Dashboard.detailKind === "publish" ? "publish" : ""
  readonly property var listedRows: {
    if (!snapshot || tab === "overview")
      return [];
    var rows = tab === "dotfiles" ? snapshot.dotfiles : tab === "bootstrap" ? snapshot.resources : snapshot.checkpoints;
    return rows.filter(function (row) {
      if (tab === "history")
        return true;
      if (scopeFilter !== "all" && row.scope !== scopeFilter)
        return false;
      if (tab === "bootstrap" && changesOnly && (row.action === "noop" || row.action === "on-demand"))
        return false;
      return true;
    });
  }

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  function date(value) {
    var parsed = new Date(value);
    return value && !isNaN(parsed.getTime()) ? parsed.toLocaleString(Qt.locale(Commons.I18n.formatLocale), Locale.ShortFormat) : strings.t("never");
  }

  function valueText(value) {
    if (value === undefined || value === null || value === "")
      return strings.t("none");
    return typeof value === "object" ? JSON.stringify(value) : String(value);
  }

  function showTab(value) {
    tab = value;
    confirming = false;
    Dashboard.clearPreview();
  }

  function preview(kind) {
    confirming = false;
    Dashboard.preview(kind);
  }

  function open() {
    root.controller.show();
    if (!Dashboard.snapshot && !Dashboard.busy)
      Dashboard.refresh();
  }

  onOpenedChanged: if (!opened)
    confirming = false

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(700))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(720))

    FocusScope {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: {
        if (root.confirming)
          root.confirming = false;
        else if (Dashboard.detailKind)
          Dashboard.clearPreview();
        else
          root.close();
      }
      Keys.onPressed: function (event) {
        if (event.key === Qt.Key_R && event.modifiers === Qt.NoModifier) {
          Dashboard.refresh();
          event.accepted = true;
        }
      }

      Controls.ScrollView {
        id: bodyScroll
        anchors.fill: parent
        contentWidth: availableWidth
        clip: true

        Column {
          id: contentColumn
          width: bodyScroll.availableWidth
          spacing: Style.space(10)

          Row {
            width: parent.width
            spacing: Style.space(8)
            PlainText {
              width: parent.width - refreshButton.width - fetchButton.width - parent.spacing * 2
              anchors.verticalCenter: parent.verticalCenter
              text: strings.t("title")
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Button {
              id: refreshButton
              focusable: true
              text: strings.t("refresh")
              enabled: !Dashboard.busy
              onClicked: Dashboard.refresh()
            }
            Button {
              id: fetchButton
              focusable: true
              text: Dashboard.busy ? strings.t("working") : strings.t("fetch")
              enabled: !Dashboard.busy
              onClicked: {
                root.confirming = false;
                Dashboard.clearPreview();
                Dashboard.fetch();
              }
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(8)
            PlainText {
              anchors.verticalCenter: parent.verticalCenter
              text: strings.t("scope")
              font.pixelSize: Style.font.bodySmall
            }
            PlainText {
              anchors.verticalCenter: parent.verticalCenter
              text: root.snapshot && root.snapshot.profiles.length > 0 ? strings.t("commonProfile").arg(root.snapshot.profiles.join(", ")) : strings.t("commonOnly")
              font.bold: true
            }
            Button {
              focusable: true
              text: Dashboard.autoFetch ? strings.t("autoOn") : strings.t("autoOff")
              selected: Dashboard.autoFetch
              onClicked: Dashboard.setSetting("autoFetch", Dashboard.autoFetch ? "false" : "true")
            }
          }

          PlainText {
            width: parent.width
            text: strings.t("fetchPolicy")
            font.pixelSize: Style.font.bodySmall
            opacity: 0.7
          }

          PlainText {
            visible: text !== ""
            width: parent.width
            color: Commons.Color.urgent
            text: [Dashboard.errorMessage, Dashboard.fetchError, root.snapshot ? root.snapshot.errors.join("\n") : ""].filter(function (v) {
              return !!v;
            }).join("\n")
          }

          Row {
            spacing: Style.space(6)
            Repeater {
              model: ["overview", "dotfiles", "bootstrap", "history"]
              Button {
                required property string modelData
                focusable: true
                text: strings.t("tab." + modelData)
                selected: root.tab === modelData && !Dashboard.detailKind
                onClicked: root.showTab(modelData)
              }
            }
          }

          PanelSeparator {
            foreground: Commons.Color.foreground
          }

          Column {
            visible: Dashboard.detailKind !== ""
            width: parent.width
            spacing: Style.space(8)

            Row {
              spacing: Style.space(8)
              Button {
                focusable: true
                text: strings.t("back")
                enabled: !Dashboard.busy
                onClicked: {
                  root.confirming = false;
                  Dashboard.clearPreview();
                }
              }
              PlainText {
                anchors.verticalCenter: parent.verticalCenter
                text: strings.t("preview." + Dashboard.detailKind)
                font.bold: true
              }
            }

            PlainText {
              width: parent.width
              text: strings.t("previewWarning")
              font.pixelSize: Style.font.bodySmall
              opacity: 0.7
            }

            Controls.ScrollView {
              width: parent.width
              height: Style.space(330)
              contentWidth: availableWidth
              clip: true
              Controls.TextArea {
                width: parent.width
                readOnly: true
                textFormat: TextEdit.PlainText
                selectByMouse: true
                wrapMode: TextEdit.WrapAnywhere
                text: Dashboard.busy ? strings.t("working") : Dashboard.detailText
                font.family: "monospace"
                font.pixelSize: Style.font.bodySmall
                color: Commons.Color.foreground
                background: Rectangle {
                  color: Qt.rgba(Commons.Color.foreground.r, Commons.Color.foreground.g, Commons.Color.foreground.b, 0.04)
                }
              }
            }

            PlainText {
              visible: Dashboard.previewTruncated
              width: parent.width
              text: strings.t("truncated")
              color: Commons.Color.urgent
            }

            PlainText {
              visible: root.confirming
              width: parent.width
              text: strings.t("confirm." + root.action)
              color: Commons.Color.urgent
            }

            Row {
              visible: root.action !== ""
              spacing: Style.space(8)
              Button {
                focusable: true
                text: root.confirming ? strings.t("openTerminal") : strings.t("action." + root.action)
                enabled: Dashboard.previewReady && !Dashboard.previewTruncated && !Dashboard.busy && !(root.action === "pull" && Dashboard.conflictCount > 0)
                onClicked: {
                  if (root.confirming) {
                    Dashboard.launch(root.action);
                    root.confirming = false;
                    root.close();
                  } else
                    root.confirming = true;
                }
              }
              Button {
                focusable: true
                visible: root.confirming
                text: strings.t("cancel")
                onClicked: root.confirming = false
              }
            }
          }

          Column {
            visible: !Dashboard.detailKind && root.tab === "overview"
            width: parent.width
            spacing: Style.space(10)

            Flow {
              width: parent.width
              spacing: Style.space(8)
              Repeater {
                model: [
                  {
                    key: "incoming",
                    count: Dashboard.incomingCount
                  },
                  {
                    key: "conflicts",
                    count: Dashboard.conflictCount
                  },
                  {
                    key: "bootstrap",
                    count: Dashboard.bootstrapCount
                  },
                  {
                    key: "tracked",
                    count: root.history.tracked_files || 0
                  }
                ]
                Rectangle {
                  required property var modelData
                  width: (parent.width - Style.space(24)) / 4
                  height: Style.space(68)
                  radius: Style.cornerRadius
                  color: Qt.rgba(Commons.Color.foreground.r, Commons.Color.foreground.g, Commons.Color.foreground.b, 0.06)
                  Column {
                    anchors.centerIn: parent
                    PlainText {
                      anchors.horizontalCenter: parent.horizontalCenter
                      text: Commons.I18n.formatNumber(modelData.count)
                      font.pixelSize: Style.font.title
                      color: modelData.count > 0 && modelData.key !== "tracked" ? Commons.Color.accent : Commons.Color.foreground
                    }
                    PlainText {
                      anchors.horizontalCenter: parent.horizontalCenter
                      text: strings.tn("count." + modelData.key, modelData.count)
                      font.pixelSize: Style.font.bodySmall
                    }
                  }
                }
              }
            }

            PlainText {
              width: parent.width
              text: strings.t("origin").arg(root.valueText(root.sync.origin)) + "\n" + strings.t("branchMode").arg(root.valueText(root.sync.branch)).arg(root.valueText(root.sync.mode)) + "\n" + strings.t("lastFetch").arg(root.date(root.sync.last_fetch)) + "\n" + strings.t("lastPublish").arg(root.date(root.sync.last_publish)) + "\n" + strings.t("lastPull").arg(root.date(root.sync.last_apply))
            }

            PlainText {
              width: parent.width
              text: strings.t("watcher").arg(root.valueText(root.history.watcher)) + "\n" + strings.tn("unsaved", (root.history.unsaved || []).length).arg(Commons.I18n.formatNumber((root.history.unsaved || []).length)) + "\n" + strings.t("checked").arg(root.date(root.snapshot ? root.snapshot.checked_at : null))
            }

            PlainText {
              visible: root.sync.declarations_changed === true
              width: parent.width
              text: strings.t("declarationsChanged")
              color: Commons.Color.accent
            }

            PlainText {
              visible: text !== ""
              width: parent.width
              color: Commons.Color.urgent
              text: [root.sync.last_error, root.sync.application_failure, root.sync.validation_error, root.history.unavailable, root.history.health && root.history.health.watcher ? (root.history.health.watcher.degraded || []).join("\n") : "", root.history.pending_operations ? strings.t("pendingOperations") : ""].filter(function (v) {
                return !!v;
              }).map(root.valueText).join("\n")
            }

            PlainText {
              visible: root.snapshot && root.snapshot.last_action !== null
              width: parent.width
              text: root.snapshot && root.snapshot.last_action ? strings.t("lastAction").arg(root.snapshot.last_action.action).arg(strings.t("result." + root.snapshot.last_action.state)).arg(root.date(root.snapshot.last_action.at)) : ""
            }

            Flow {
              width: parent.width
              spacing: Style.space(6)
              Repeater {
                model: ["incoming", "bootstrap", "publish", "local", "deployment", "conflicts"]
                Button {
                  required property string modelData
                  focusable: true
                  text: strings.t("preview." + modelData)
                  enabled: !Dashboard.busy
                  onClicked: root.preview(modelData)
                }
              }
            }

            PlainText {
              visible: Dashboard.incomingCount > 0 || Dashboard.conflictCount > 0
              width: parent.width
              text: (root.sync.pending_applications || []).concat(root.sync.conflicts || []).map(root.valueText).join("\n")
              font.pixelSize: Style.font.bodySmall
              maximumLineCount: 6
              elide: Text.ElideRight
            }

            PlainText {
              width: parent.width
              text: strings.t("loadedConfigs") + "\n" + (root.snapshot ? root.snapshot.configs.map(function (c) {
                  return c.scope + "  " + c.name;
                }).join("\n") : strings.t("working"))
              font.pixelSize: Style.font.bodySmall
              opacity: 0.7
            }
          }

          Column {
            visible: !Dashboard.detailKind && root.tab !== "overview"
            width: parent.width
            spacing: Style.space(8)

            Flow {
              visible: root.tab !== "history"
              width: parent.width
              spacing: Style.space(6)
              Repeater {
                model: ["all", "common"].concat(root.snapshot ? root.snapshot.profiles : []).concat(["system", "local", "unclassified"])
                Button {
                  required property string modelData
                  focusable: true
                  text: ["all", "common", "system", "local", "unclassified"].indexOf(modelData) >= 0 ? strings.t("scope." + modelData) : modelData
                  selected: root.scopeFilter === modelData
                  onClicked: root.scopeFilter = modelData
                }
              }
            }

            Row {
              visible: root.tab === "bootstrap"
              spacing: Style.space(8)
              Button {
                focusable: true
                text: root.changesOnly ? strings.t("showAll") : strings.t("changesOnly")
                onClicked: root.changesOnly = !root.changesOnly
              }
              Button {
                focusable: true
                text: strings.t("preview.bootstrap")
                enabled: !Dashboard.busy
                onClicked: root.preview("bootstrap")
              }
            }

            PlainText {
              visible: root.tab === "bootstrap"
              width: parent.width
              text: strings.t("planCoverage")
              font.pixelSize: Style.font.bodySmall
              opacity: 0.7
            }

            PlainText {
              visible: root.listedRows.length === 0
              width: parent.width
              text: Dashboard.busy ? strings.t("working") : strings.t("empty")
            }

            Controls.ScrollView {
              width: parent.width
              height: Style.space(350)
              contentWidth: availableWidth
              clip: true

              ListView {
                model: root.listedRows
                spacing: Style.space(6)
                delegate: Rectangle {
                  required property var modelData
                  width: ListView.view.width
                  height: rowColumn.implicitHeight + Style.space(16)
                  radius: Style.cornerRadius
                  color: Qt.rgba(Commons.Color.foreground.r, Commons.Color.foreground.g, Commons.Color.foreground.b, 0.04)
                  Column {
                    id: rowColumn
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Style.space(8)
                    spacing: Style.space(3)
                    PlainText {
                      width: parent.width
                      font.bold: true
                      text: root.tab === "history" ? "#" + Commons.I18n.formatNumber(modelData.id) + "  " + root.valueText(modelData.description) : (modelData.name || "")
                    }
                    PlainText {
                      width: parent.width
                      font.pixelSize: Style.font.bodySmall
                      text: root.tab === "history" ? root.date(modelData.created_at) + "  " + modelData.trigger : modelData.scope + "  /  " + (root.tab === "bootstrap" ? modelData.kind + "  /  " + modelData.action : modelData.mode + "  /  " + modelData.state)
                      color: root.tab === "bootstrap" && modelData.action !== "noop" ? Commons.Color.accent : Commons.Color.foreground
                    }
                  }
                  PlainText {
                    visible: root.tab === "bootstrap"
                    width: parent.width
                    font.pixelSize: Style.font.bodySmall
                    text: root.tab === "bootstrap" ? strings.t("currentDesired").arg(modelData.current || strings.t("none")).arg(modelData.desired || strings.t("none")) : ""
                    opacity: 0.8
                  }
                  PlainText {
                    visible: root.tab !== "history" && !!modelData.config
                    width: parent.width
                    font.pixelSize: Style.font.bodySmall
                    text: modelData.config || ""
                    opacity: 0.55
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

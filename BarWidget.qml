import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "."

BarWidget {
  id: root
  moduleName: "fredrik.mise"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property string summary: {
    if (!Dashboard.snapshot) return strings.t("bar.loading")
    var parts = []
    if (Dashboard.conflictCount > 0) parts.push(strings.tn("count.conflicts", Dashboard.conflictCount).arg(Commons.I18n.formatNumber(Dashboard.conflictCount)))
    if (Dashboard.incomingCount > 0) parts.push(strings.tn("count.incoming", Dashboard.incomingCount).arg(Commons.I18n.formatNumber(Dashboard.incomingCount)))
    if (Dashboard.bootstrapPending > 0) parts.push(strings.tn("count.bootstrap", Dashboard.bootstrapPending).arg(Commons.I18n.formatNumber(Dashboard.bootstrapPending)))
    if (Dashboard.outgoingCount > 0) parts.push(strings.tn("count.outgoing", Dashboard.outgoingCount).arg(Commons.I18n.formatNumber(Dashboard.outgoingCount)))
    if (Dashboard.problems.length > 0) parts.push(strings.t("bar.problem"))
    return parts.length > 0 ? strings.t("bar.title") + " · " + parts.join(" · ") : strings.t("bar.inSync")
  }

  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing : false
  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  onBarChanged: injectPanel()
  onSettingsChanged: Dashboard.configure(settings)
  Component.onCompleted: Dashboard.configure(settings)

  Loader {
    id: panelLoader
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // Muted when in sync, accent with something to review, urgent for conflicts and
  // failures, and hollow while an action runs, like the other plugins' status dots.
  readonly property color indicatorColor: Dashboard.severity === "error" ? Color.urgent
    : Dashboard.severity === "attention" ? Color.accent : Color.muted
  readonly property bool indicatorHollow: Dashboard.acting !== "" || !Dashboard.snapshot

  Component {
    id: miseStatusIcon

    Item {
      width: Style.bar.iconCanvas
      height: width

      MiseIcon {
        anchors.fill: parent
        iconSize: parent.width
        color: root.bar ? root.bar.foreground : Color.foreground
      }

      Rectangle {
        width: Style.space(6)
        height: width
        radius: width / 2
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        color: root.indicatorColor

        Rectangle {
          visible: root.indicatorHollow
          anchors.centerIn: parent
          width: Math.max(2, parent.width - 4)
          height: width
          radius: width / 2
          color: root.bar ? root.bar.background : Color.background
        }
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: miseStatusIcon
    slotSize: Style.bar.iconSlot
    tooltipText: root.opened ? "" : root.summary
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) Dashboard.fetch()
      else if (mouseButton === Qt.MiddleButton) Dashboard.refresh()
      else if (panelLoader.item) panelLoader.item.toggle()
    }
  }
}

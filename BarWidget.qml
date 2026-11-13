import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "."

BarWidget {
  id: root
  moduleName: "fredrik.mise"

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  function injectPanel() {
    if (!panelLoader.item)
      return;
    panelLoader.item.bar = root.bar;
    panelLoader.item.anchorItem = button;
    panelLoader.item.hostWidget = root;
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing : false
  function open() {
    if (panelLoader.item)
      panelLoader.item.open();
  }
  function close() {
    if (panelLoader.item)
      panelLoader.item.close();
  }
  function closeForPopoutSwitch() {
    if (panelLoader.item)
      panelLoader.item.closeForPopoutSwitch();
  }

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
      root.injectPanel();
      Qt.callLater(root.injectPanel);
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    active: Dashboard.needsAttention
    text: root.vertical ? "mise" : "mise" + (Dashboard.busy ? " ..." : Dashboard.conflictCount > 0 ? " !" : Dashboard.incomingCount > 0 ? " +" + Commons.I18n.formatNumber(Dashboard.incomingCount) : Dashboard.bootstrapCount > 0 ? " " + Commons.I18n.formatNumber(Dashboard.bootstrapCount) : Dashboard.needsAttention ? " !" : "")
    tooltipText: strings.t("title")
    onPressed: function (mouseButton) {
      if (mouseButton === Qt.RightButton || mouseButton === Qt.MiddleButton)
        Dashboard.fetch();
      else if (panelLoader.item)
        panelLoader.item.toggle();
    }
  }
}

import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Hourglass glyph + active time today. Pulses when it is time to stand up.
BarWidget {
  id: root
  moduleName: "nixfred.hourglass"
  property var anchorItem: button

  readonly property var svc: bar && bar.shell ? bar.shell.serviceFor(moduleName) : null
  readonly property var d: svc ? svc.data : ({})
  readonly property var live: svc ? svc.live : ({})
  readonly property bool stretch: svc ? svc.stretch : false

  function setting(name, fallback) {
    var v = settings ? settings[name] : undefined
    return v === undefined ? fallback : v
  }
  readonly property real goalSec: svc ? svc.goalHours * 3600 : 21600
  readonly property real goalFrac: svc && svc.total > 0 ? Math.min(1, svc.total / goalSec) : 0
  readonly property bool showApp: String(setting("showApp", false)) === "true"
  readonly property color foreground: bar ? bar.foreground : Color.foreground

  readonly property string label: (svc ? svc.fmt(svc.total) : "--")
    + (showApp && live.name ? "  " + live.name + " " + svc.fmt(live.run) : "")

  implicitWidth: vertical ? barSize : Math.max(Style.space(40), row.implicitWidth + Style.space(16))
  implicitHeight: vertical ? Style.space(40) : barSize

  function tip() {
    if (!svc || !svc.ready) return "Hourglass: starting"
    if (!svc.ok) return "Hourglass: " + svc.error
    var s = "Hourglass: " + svc.fmt(svc.total) + " active today, " + Math.round(100 * goalFrac) + "% of " + svc.fmt(goalSec)
    if (d.vsTypical !== null && d.vsTypical !== undefined) s += "\n" + svc.fmtD(d.vsTypical) + " vs typical by now"
    if (d.deep) s += "\nDeep focus " + svc.fmt(d.deep)
    var a = d.apps || []
    for (var i = 0; i < Math.min(3, a.length); i++) s += "\n" + a[i].name + "  " + svc.fmt(a[i].sec)
    if (live.name) s += "\nNow: " + live.name + ", " + svc.fmt(live.run) + " unbroken"
    if (root.stretch) s += "\nStretch. You have earned it."
    if (!d.tracking) s += "\nTracker not reporting"
    return s
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    labelVisible: false
    hasVisualContent: true
    active: false
    useActiveColor: false
    tooltipText: root.tip()

    Row {
      id: row
      anchors.centerIn: parent
      spacing: Style.space(5)
      Text {
        id: glyph
        anchors.verticalCenter: parent.verticalCenter
        text: String.fromCodePoint(0xF051F)
        color: root.stretch ? Color.urgent : (d.tracking ? Color.accent : Util.alpha(root.foreground, 0.45))
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall * 1.15
        SequentialAnimation on opacity {
          running: root.stretch
          loops: Animation.Infinite
          alwaysRunToEnd: true
          NumberAnimation { to: 0.25; duration: 900; easing.type: Easing.InOutSine }
          NumberAnimation { to: 1.0; duration: 900; easing.type: Easing.InOutSine }
        }
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.label
        color: root.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }

    Rectangle {  // progress toward the daily goal
      anchors.left: parent.left; anchors.bottom: parent.bottom
      anchors.leftMargin: Style.space(6); anchors.bottomMargin: Style.space(2)
      height: Style.space(2); radius: 1; border.width: 0
      width: Math.max(0, (parent.width - Style.space(12)) * root.goalFrac)
      color: root.goalFrac >= 1 ? Color.accent : Util.alpha(root.foreground, 0.55)
      visible: root.goalFrac > 0
    }

    onPressed: function(code) {
      if (root.bar) root.bar.hideTooltip(root)
      root.toggle()
    }
  }

  readonly property bool opened: panel.opened
  function open() { panel.controller.show(); if (svc) svc.refresh() }
  function close() { panel.controller.hide() }
  function toggle() { opened ? close() : open() }
  function closeForPopoutSwitch() { close() }
  readonly property bool popoutSwitchClosing: false

  HourPanel {
    id: panel
    widget: root
  }
}

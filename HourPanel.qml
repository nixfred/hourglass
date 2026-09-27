import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

// Where the day went. Law 17: no page scroller. Stats, the 24h ribbon, then
// ring + week on the left and the app list on the right. Only the list
// scrolls, inside its own fixed box.
Panel {
  id: panel
  moduleName: "nixfred.hourglass"
  manageIpc: false

  required property var widget
  readonly property var svc: widget.svc
  readonly property var d: svc ? svc.data : ({})

  readonly property color foreground: widget.bar ? widget.bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color faint: Util.alpha(foreground, 0.10)
  readonly property color accent: Color.accent
  readonly property string fontFamily: widget.bar ? widget.bar.fontFamily : Style.font.family
  readonly property int panelWidth: Style.space(1120)

  // Eight app hues walked around the wheel from the theme accent; grey
  // accents get a floor of saturation so apps stay tellable apart.
  readonly property real baseHue: accent.hslHue < 0 ? 0.55 : accent.hslHue
  readonly property real baseSat: Math.max(0.55, accent.hslSaturation)
  readonly property real baseLight: Math.min(0.68, Math.max(0.52, accent.hslLightness))
  function appColor(rank) {
    if (rank < 0) return Util.alpha(foreground, 0.06)
    if (rank >= 8) return Util.alpha(foreground, 0.35)
    if (rank === 0) return accent.hslSaturation > 0.25 ? accent : Qt.hsla(baseHue, baseSat, baseLight, 1)
    return Qt.hsla((baseHue + rank * 0.125) % 1, baseSat, baseLight, 1)
  }
  function fmt(s) { return svc ? svc.fmt(s) : "--" }
  function delta() {
    if (!d.avg) return "no history yet"
    var p = Math.round(100 * ((d.total || 0) - d.avg) / d.avg)
    return (p >= 0 ? "+" : "") + p + "% vs 6 day avg"
  }

  component Stat: Rectangle {
    property string label: ""
    property string value: ""
    property string sub: ""
    property string tip: ""
    property color valueColor: panel.foreground
    Layout.fillWidth: true
    implicitHeight: Style.space(66)
    radius: Style.space(6)
    color: panel.faint
    border.width: 1
    border.color: Util.alpha(panel.accent, 0.35)
    Column {
      anchors.centerIn: parent
      spacing: Style.space(1)
      Text { anchors.horizontalCenter: parent.horizontalCenter; text: parent.parent.value
             color: parent.parent.valueColor; font.family: panel.fontFamily
             font.pixelSize: Style.font.subtitle * 1.3; font.bold: true }
      Text { anchors.horizontalCenter: parent.horizontalCenter; text: parent.parent.label
             color: panel.dim; font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall
             font.letterSpacing: 1.5 }
      Text { anchors.horizontalCenter: parent.horizontalCenter; text: parent.parent.sub
             visible: text !== ""; color: panel.dim; font.family: panel.fontFamily
             font.pixelSize: Style.font.bodySmall * 0.82 }
    }
    MouseArea { id: sm; anchors.fill: parent; hoverEnabled: true }
    ToolTip.visible: sm.containsMouse && tip !== ""
    ToolTip.text: tip
  }

  component Caption: Text {
    color: panel.dim
    font.family: panel.fontFamily
    font.pixelSize: Style.font.bodySmall
    font.letterSpacing: 2
  }

  KeyboardPanel {
    id: kpanel
    anchorItem: panel.widget.anchorItem
    owner: panel.widget
    bar: panel.widget.bar
    open: panel.opened
    focusTarget: keyCatcher
    contentWidth: kpanel.fittedContentWidth(panel.panelWidth)
    contentHeight: kpanel.fittedContentHeight(content.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: panel.widget.close()

      ColumnLayout {
        id: content
        width: parent.width
        spacing: Style.space(12)

        // header
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(10)
          Text { text: String.fromCodePoint(0xF051F); color: panel.accent
                 font.family: panel.fontFamily; font.pixelSize: Style.font.subtitle }
          Text { text: "HOURGLASS"; color: panel.foreground; font.family: panel.fontFamily
                 font.pixelSize: Style.font.subtitle; font.bold: true; font.letterSpacing: 3 }
          Text {
            text: svc && !svc.ok ? ("error: " + svc.error)
                  : (d.date || "--") + "  //  " + (d.tracking ? "tracking" : "tracker idle")
                    + (d.live && d.live.name ? "  //  in " + d.live.name + " for " + panel.fmt(d.live.run) : "")
            color: svc && !svc.ok ? Color.urgent : panel.dim
            font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall
          }
          Item { Layout.fillWidth: true }
          Rectangle {
            visible: svc && svc.stretch
            implicitWidth: nudge.implicitWidth + Style.space(16); implicitHeight: nudge.implicitHeight + Style.space(6)
            radius: height / 2; color: Util.alpha(Color.urgent, 0.2); border.width: 1; border.color: Color.urgent
            Text { id: nudge; anchors.centerIn: parent; text: "STRETCH"; color: Color.urgent
                   font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true; font.letterSpacing: 2 }
          }
          Button {
            text: "Refresh"
            onClicked: if (svc) svc.refresh()
          }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: panel.faint; border.width: 0 }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)
          Stat { label: "TODAY"; value: panel.fmt(d.total); valueColor: panel.accent; sub: panel.delta()
                 tip: "Active time: screen unlocked and you touched something in the last 5 minutes" }
          Stat { label: "FOCUS"; value: String(d.sessions || 0)
                 sub: "runs of 25m+"; tip: "Unbroken runs of 25 minutes or more in one app" }
          Stat { label: "LONGEST"; value: panel.fmt(d.best ? d.best.sec : 0)
                 sub: d.best && d.best.name && d.best.sec ? d.best.name + " till " + d.best.end : ""
                 tip: "Longest unbroken stretch in a single app today" }
          Stat { label: "SWITCHES"; value: String(d.switches || 0); sub: (d.perHour || 0) + " / active hour"
                 tip: "Focus changes between apps. Lower means deeper work." }
          Stat { label: "PEAK"; value: d.peak >= 0 && d.peak !== undefined ? (String(d.peak).padStart(2, "0") + ":00") : "--"
                 sub: d.hours && d.peak >= 0 ? panel.fmt(d.hours[d.peak]) + " that hour" : ""
                 tip: "Your busiest hour today" }
          Stat { label: "SPAN"; value: d.first ? d.first + "-" + d.last : "--"
                 sub: "first to last"; tip: "First and latest active minute today" }
        }

        // 24h ribbon
        Caption { text: "TODAY  //  every 5 minutes, coloured by the app that owned it" }
        Item {
          Layout.fillWidth: true
          implicitHeight: Style.space(46)
          Row {
            id: rib
            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
            height: Style.space(30)
            readonly property real cw: width / 288
            Repeater {
              model: d.ribbon || []
              delegate: Rectangle {
                required property int modelData
                required property int index
                width: rib.cw; height: rib.height; border.width: 0
                color: panel.appColor(modelData)
                opacity: modelData < 0 ? 1 : 0.92
              }
            }
          }
          Rectangle {  // now marker
            readonly property int slot: { var t = new Date(); return Math.floor((t.getHours() * 60 + t.getMinutes()) / 5) }
            x: rib.x + slot * rib.cw; y: rib.y - 2; width: 2; height: rib.height + 4; color: panel.foreground; border.width: 0
          }
          Repeater {
            model: 9
            delegate: Text {
              required property int index
              x: rib.x + Math.min(rib.width - implicitWidth, Math.max(0, index * 3 * 12 * rib.cw - implicitWidth / 2))
              anchors.bottom: parent.bottom
              text: String(index * 3).padStart(2, "0") + ":00"
              color: panel.dim; font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall * 0.8
            }
          }
          MouseArea {
            id: ribm; anchors.fill: rib; hoverEnabled: true
            readonly property int slot: Math.max(0, Math.min(287, Math.floor(mouseX / rib.cw)))
          }
          ToolTip {
            parent: rib
            visible: ribm.containsMouse
            x: Math.min(rib.width - width, ribm.mouseX + 10); y: -height - 4
            text: {
              var s = ribm.slot, h = Math.floor(s * 5 / 60), m = (s * 5) % 60
              var r = (d.ribbon || [])[s]
              var who = r === undefined || r < 0 ? "idle" : ((d.legend || [])[r] || "?")
              return String(h).padStart(2, "0") + ":" + String(m).padStart(2, "0") + "  " + who
            }
          }
        }

        // legend
        Flow {
          Layout.fillWidth: true
          spacing: Style.space(14)
          Repeater {
            model: d.legend || []
            delegate: Row {
              required property string modelData
              required property int index
              spacing: Style.space(5)
              Rectangle { width: Style.space(10); height: width; radius: 2; border.width: 0
                          anchors.verticalCenter: parent.verticalCenter; color: panel.appColor(index) }
              Text { text: modelData; color: panel.foreground; font.family: panel.fontFamily
                     font.pixelSize: Style.font.bodySmall }
            }
          }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: panel.faint; border.width: 0 }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(18)

          // ring
          Item {
            Layout.preferredWidth: Style.space(210); Layout.preferredHeight: Style.space(210)
            Layout.alignment: Qt.AlignTop
            Canvas {
              id: ring
              anchors.fill: parent
              property var apps: d.apps || []
              onAppsChanged: requestPaint()
              onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                var cx = width / 2, cy = height / 2, r = Math.min(cx, cy) - 12, lw = Style.space(20)
                ctx.lineWidth = lw
                ctx.strokeStyle = panel.faint
                ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI * 2); ctx.stroke()
                var tot = 0
                for (var i = 0; i < apps.length; i++) tot += apps[i].sec
                if (!tot) return
                var a = -Math.PI / 2
                for (var j = 0; j < apps.length; j++) {
                  var sw = Math.PI * 2 * apps[j].sec / tot
                  ctx.strokeStyle = panel.appColor(Math.min(8, apps[j].rank))
                  ctx.beginPath(); ctx.arc(cx, cy, r, a, a + Math.max(0.001, sw - 0.02)); ctx.stroke()
                  a += sw
                }
              }
            }
            Column {
              anchors.centerIn: parent
              Text { anchors.horizontalCenter: parent.horizontalCenter; text: panel.fmt(d.total)
                     color: panel.foreground; font.family: panel.fontFamily
                     font.pixelSize: Style.font.subtitle * 1.5; font.bold: true }
              Text { anchors.horizontalCenter: parent.horizontalCenter
                     text: (d.apps || []).length + ((d.apps || []).length === 1 ? " app" : " apps")
                     color: panel.dim; font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall }
            }
          }

          // week
          ColumnLayout {
            Layout.preferredWidth: Style.space(330); Layout.maximumWidth: Style.space(330)
            Layout.alignment: Qt.AlignTop
            spacing: Style.space(6)
            Caption { text: "7 DAYS" }
            Row {
              id: wk
              Layout.fillWidth: true
              height: Style.space(180)
              spacing: Style.space(8)
              readonly property int peak: {
                var m = 1, w = d.week || []
                for (var i = 0; i < w.length; i++) m = Math.max(m, w[i].total)
                return m
              }
              readonly property real bw: (width - 6 * spacing) / 7
              Repeater {
                model: d.week || []
                delegate: Item {
                  id: dayCol
                  required property var modelData
                  required property int index
                  width: wk.bw; height: wk.height
                  Text { id: wt; anchors.top: parent.top; anchors.horizontalCenter: parent.horizontalCenter
                         text: modelData.total ? panel.fmt(modelData.total) : ""
                         color: panel.dim; font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall * 0.8 }
                  Column {
                    id: stack
                    anchors.bottom: dl.top; anchors.bottomMargin: 3
                    width: parent.width
                    readonly property real avail: parent.height - wt.height - dl.height - 8
                    Repeater {
                      model: 9
                      delegate: Rectangle {
                        required property int index
                        readonly property int rk: 8 - index   // biggest app sits at the bottom
                        width: stack.width; border.width: 0
                        height: stack.avail * (dayCol.modelData.seg[rk] || 0) / wk.peak
                        color: panel.appColor(rk)
                      }
                    }
                  }
                  Text { id: dl; anchors.bottom: parent.bottom; anchors.horizontalCenter: parent.horizontalCenter
                         text: modelData.dow
                         color: index === 6 ? panel.accent : panel.dim; font.bold: index === 6
                         font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall * 0.85 }
                  MouseArea { id: wm; anchors.fill: parent; hoverEnabled: true }
                  ToolTip.visible: wm.containsMouse
                  ToolTip.text: modelData.date + "  " + panel.fmt(modelData.total) + " active"
                }
              }
            }
          }

          // apps list, scrolls in place
          ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignTop
            spacing: Style.space(6)
            Caption { text: "APPS TODAY" }
            Rectangle {
              Layout.fillWidth: true
              Layout.preferredHeight: Style.space(186)
              radius: Style.space(6); color: panel.faint; border.width: 0
              clip: true
              ListView {
                id: list
                anchors.fill: parent; anchors.margins: Style.space(6)
                model: d.apps || []
                spacing: Style.space(3)
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar {}
                Text { anchors.centerIn: parent; visible: list.count === 0
                       text: "Nothing yet. The sand starts falling when you do."
                       color: panel.dim; font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall }
                delegate: Item {
                  required property var modelData
                  width: list.width - Style.space(10)
                  height: Style.space(22)
                  RowLayout {
                    anchors.fill: parent
                    spacing: Style.space(8)
                    Rectangle { Layout.preferredWidth: Style.space(10); Layout.preferredHeight: Style.space(10)
                                radius: 2; border.width: 0; color: panel.appColor(Math.min(8, modelData.rank)) }
                    Text { Layout.preferredWidth: Style.space(120); Layout.maximumWidth: Style.space(120)
                           text: modelData.name; elide: Text.ElideRight
                           color: panel.foreground; font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall }
                    Rectangle {
                      Layout.fillWidth: true; height: Style.space(7); radius: 2; color: panel.faint; border.width: 0
                      Rectangle { height: parent.height; radius: 2; border.width: 0
                                  color: panel.appColor(Math.min(8, modelData.rank))
                                  width: parent.width * modelData.sec / Math.max(1, (d.apps && d.apps[0]) ? d.apps[0].sec : 1) }
                    }
                    Text { Layout.preferredWidth: Style.space(52); horizontalAlignment: Text.AlignRight
                           text: panel.fmt(modelData.sec); color: panel.foreground
                           font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall }
                    Text { Layout.preferredWidth: Style.space(34); horizontalAlignment: Text.AlignRight
                           text: Math.round(100 * modelData.sec / Math.max(1, d.total || 1)) + "%"
                           color: panel.dim; font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall * 0.9 }
                  }
                  MouseArea { id: am; anchors.fill: parent; hoverEnabled: true }
                  ToolTip.visible: am.containsMouse
                  ToolTip.text: modelData.cls || "no window focused"
                }
              }
            }
          }
        }
      }
    }
  }
}

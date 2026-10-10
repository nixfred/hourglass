import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Where the day went, and where the weeks went. Law 17: no page scroller.
// Two tabs (DAY, TRENDS) share one fixed height; only the app lists scroll,
// each inside its own box.
Panel {
  id: panel
  moduleName: "nixfred.hourglass"
  manageIpc: false

  required property var widget
  readonly property var svc: widget.svc
  readonly property var d: svc ? svc.data : ({})
  property int tab: 0   // 0 DAY, 1 TRENDS

  readonly property color foreground: widget.bar ? widget.bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color faint: Util.alpha(foreground, 0.10)
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property string fontFamily: widget.bar ? widget.bar.fontFamily : Style.font.family
  readonly property int panelWidth: Style.space(1120)
  readonly property real goalSec: d.goal || 21600

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
  function fmtD(s) { return (s >= 0 ? "+" : "-") + fmt(Math.abs(s)) }
  function dlabel(s, f) {
    var p = String(s).split("-")
    return p.length === 3 ? Qt.formatDate(new Date(+p[0], +p[1] - 1, +p[2]), f) : ""
  }
  function rankName(r) { var lg = d.legend || []; return r < 8 ? (lg[r] || "?") : "Other" }
  function niceStep(mx) {
    var opts = [1, 2, 3, 4, 6, 8, 12]
    for (var i = 0; i < opts.length; i++) if (mx / opts[i] <= 5) return opts[i]
    return 12
  }
  function valueAt(pts, h) {
    if (!pts || pts.length === 0) return null
    if (h > pts[pts.length - 1][0] + 1e-6) return null
    for (var i = 1; i < pts.length; i++) {
      if (h <= pts[i][0]) {
        var a = pts[i - 1], b = pts[i]
        var f = b[0] === a[0] ? 0 : (h - a[0]) / (b[0] - a[0])
        return a[1] + (b[1] - a[1]) * f
      }
    }
    return pts[pts.length - 1][1]
  }

  // ranks present today, for the ribbon legend
  readonly property var legendToday: {
    var seen = {}, out = [], a = d.apps || []
    for (var i = 0; i < a.length; i++) seen[a[i].rank] = 1
    for (var k = 0; k <= 8; k++) if (seen[k]) out.push({ rank: k, name: rankName(k) })
    return out
  }
  readonly property var catsToday: {
    var c = (d.cats || []).filter(function(x) { return x.today > 0 })
    c.sort(function(a, b) { return b.today - a.today })
    return c.slice(0, 5)
  }

  // redraw canvases when the theme moves
  onAccentChanged: repaintAll()
  onForegroundChanged: repaintAll()
  signal repaintAll()

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
    PanelToolTip { visible: sm.containsMouse && parent.tip !== ""; text: parent.tip }
  }

  component Caption: Text {
    Layout.fillWidth: true
    elide: Text.ElideRight
    color: panel.dim
    font.family: panel.fontFamily
    font.pixelSize: Style.font.bodySmall
    font.letterSpacing: 2
  }

  component Chip: Rectangle {
    property string label: ""
    property bool on: false
    signal activated()
    implicitWidth: chipText.implicitWidth + Style.space(22)
    implicitHeight: chipText.implicitHeight + Style.space(8)
    radius: Style.space(4)
    color: on ? Util.alpha(panel.accent, 0.22) : "transparent"
    border.width: 1
    border.color: on ? panel.accent : Util.alpha(panel.foreground, 0.25)
    Text { id: chipText; anchors.centerIn: parent; text: parent.label
           color: parent.on ? panel.accent : panel.dim; font.bold: parent.on
           font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall; font.letterSpacing: 2 }
    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: parent.activated() }
  }

  // tiny line chart for one app's daily series
  component Spark: Canvas {
    id: sp
    property var values: []
    property color stroke: panel.accent
    implicitWidth: Style.space(84)
    implicitHeight: Style.space(18)
    onValuesChanged: requestPaint()
    onStrokeChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    Connections { target: panel; function onRepaintAll() { sp.requestPaint() } }
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var v = values || [], n = v.length
      if (n < 2) return
      var mx = 1
      for (var i = 0; i < n; i++) mx = Math.max(mx, v[i])
      var h = height - 3
      ctx.beginPath()
      for (var j = 0; j < n; j++) {
        var x = j * (width - 2) / (n - 1) + 1, y = height - 1.5 - (v[j] / mx) * h
        if (j === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
      }
      ctx.lineWidth = 1.4
      ctx.strokeStyle = stroke
      ctx.stroke()
      ctx.lineTo(width - 1, height)
      ctx.lineTo(1, height)
      ctx.closePath()
      ctx.fillStyle = Util.alpha(stroke, 0.16)
      ctx.fill()
      var lx = width - 1, ly = height - 1.5 - (v[n - 1] / mx) * h
      ctx.beginPath()
      ctx.arc(lx, ly, 1.8, 0, Math.PI * 2)
      ctx.fillStyle = stroke
      ctx.fill()
    }
  }

  KeyboardPanel {
    id: kpanel
    anchorItem: panel.widget.anchorItem
    owner: panel.widget
    bar: panel.widget.bar
    open: panel.opened
    focusTarget: keyCatcher
    // Hold Exclusive while open so Hyprland never hands the keys to the
    // window underneath (same fix as Burn Bar 2.3.1): without it Esc landed
    // in the terminal behind the panel and stopped the agent running there.
    WlrLayershell.keyboardFocus: panel.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    contentWidth: kpanel.fittedContentWidth(panel.panelWidth)
    contentHeight: kpanel.fittedContentHeight(content.implicitHeight, Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The close waits for the Esc RELEASE, so the terminal under the panel
      // is never handed a keyboard with Esc still held. A release that never
      // arrives lets go after a beat.
      property bool escHeld: false
      onCloseRequested: {
        if (!panel.opened) return
        escHeld = true
        escRelease.restart()
      }
      Keys.onReleased: function(event) {
        if (event.key !== Qt.Key_Escape || !keyCatcher.escHeld) return
        event.accepted = true
        keyCatcher.releaseEsc()
      }
      Timer { id: escRelease; interval: 400; onTriggered: keyCatcher.releaseEsc() }
      function releaseEsc() {
        escRelease.stop()
        if (!escHeld) return
        escHeld = false
        panel.widget.close()
      }
      onTabRequested: panel.tab = panel.tab === 0 ? 1 : 0
      onMoveRequested: function(dx, dy) { if (dx !== 0) panel.tab = dx > 0 ? 1 : 0 }
      onTextKey: function(t) {
        if (t === "r" || t === "R") { if (svc) svc.refresh() }
        else if (t === "1" || t === "d" || t === "D") panel.tab = 0
        else if (t === "2" || t === "t" || t === "T") panel.tab = 1
      }

      ColumnLayout {
        id: content
        width: parent.width
        spacing: Style.space(12)

        // ------------------------------------------------------------ header
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(10)
          Text { text: String.fromCodePoint(0xF051F); color: panel.accent
                 font.family: panel.fontFamily; font.pixelSize: Style.font.subtitle }
          Text { text: "HOURGLASS"; color: panel.foreground; font.family: panel.fontFamily
                 font.pixelSize: Style.font.subtitle; font.bold: true; font.letterSpacing: 3 }
          Chip { label: "DAY"; on: panel.tab === 0; onActivated: panel.tab = 0 }
          Chip { label: "TRENDS"; on: panel.tab === 1; onActivated: panel.tab = 1 }
          Text {
            text: svc && !svc.ok ? ("error: " + svc.error)
                  : (d.date || "--") + "  //  " + (d.tracking ? "tracking" : "tracker idle")
                    + (d.live && d.live.name ? "  //  in " + d.live.name + " for " + panel.fmt(d.live.run) : "")
            color: svc && !svc.ok ? panel.urgent : panel.dim
            font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall
          }
          Item { Layout.fillWidth: true }
          Rectangle {
            visible: svc && svc.stretch
            implicitWidth: nudge.implicitWidth + Style.space(16); implicitHeight: nudge.implicitHeight + Style.space(6)
            radius: height / 2; color: Util.alpha(panel.urgent, 0.2); border.width: 1; border.color: panel.urgent
            Text { id: nudge; anchors.centerIn: parent; text: "STRETCH"; color: panel.urgent
                   font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true; font.letterSpacing: 2 }
          }
          Button {
            text: "Refresh"
            onClicked: if (svc) svc.refresh()
          }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: panel.faint; border.width: 0 }

        StackLayout {
          id: pages
          Layout.fillWidth: true
          currentIndex: panel.tab

          // ================================================================ DAY
          ColumnLayout {
            spacing: Style.space(12)

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(8)
              Stat {
                label: "ACTIVE"; value: panel.fmt(d.total); valueColor: panel.accent
                sub: d.vsTypical === null || d.vsTypical === undefined ? "first day"
                     : panel.fmtD(d.vsTypical) + " vs typical by now"
                tip: "Active time: screen unlocked and you touched something in the last 5 minutes.\nTypical is the average of your earlier days at this same time."
              }
              Stat {
                label: "GOAL"; value: Math.round(100 * (d.total || 0) / panel.goalSec) + "%"
                valueColor: (d.total || 0) >= panel.goalSec ? panel.accent : panel.foreground
                sub: (d.total || 0) >= panel.goalSec ? "met, goal " + panel.fmt(panel.goalSec)
                     : panel.fmt(panel.goalSec - (d.total || 0)) + " to go of " + panel.fmt(panel.goalSec)
                tip: "Daily goal. Change it in the widget settings (goalHours)."
              }
              Stat {
                label: "DEEP"; value: panel.fmt(d.deep)
                sub: (d.sessions || 0) + (d.sessions === 1 ? " run, " : " runs, ") + (d.deepPct || 0) + "% of active"
                tip: "Time in 20 minute stretches on one app, back to back.\nMusic, video and the bare desktop never count.\nApproximated from per-minute data."
              }
              Stat {
                label: "LONGEST"; value: panel.fmt(d.best ? d.best.sec : 0)
                sub: d.best && d.best.name && d.best.sec ? d.best.name + " till " + d.best.end : ""
                tip: "Longest single-app stretch today (music, video and desktop excluded)."
              }
              Stat {
                label: "SWITCHES"; value: String(d.switches || 0); sub: (d.perHour || 0) + " / active hour"
                tip: "Focus changes between apps. Lower means deeper work."
              }
              Stat {
                label: "BREAKS"; value: String(d.breaks || 0)
                sub: d.breaks ? "longest " + panel.fmt((d.lbreak || 0) * 60) : "none yet"
                tip: "Gaps of 5 minutes or more with nothing counted. The clock stops after 5 idle minutes."
              }
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
                x: rib.x + Math.floor((d.now || 0) / 5) * rib.cw; y: rib.y - 2; width: 2; height: rib.height + 4
                color: panel.foreground; border.width: 0
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
              PanelToolTip {
                parent: rib
                visible: ribm.containsMouse
                x: Math.min(rib.width - width, ribm.mouseX + 10); y: -height - 4
                text: {
                  var s = ribm.slot, h = Math.floor(s * 5 / 60), m = (s * 5) % 60
                  var r = (d.ribbon || [])[s]
                  var who = r === undefined || r < 0 ? "idle" : panel.rankName(r)
                  return String(h).padStart(2, "0") + ":" + String(m).padStart(2, "0") + "  " + who
                }
              }
            }
            Flow {
              Layout.fillWidth: true
              spacing: Style.space(14)
              Repeater {
                model: panel.legendToday
                delegate: Row {
                  required property var modelData
                  spacing: Style.space(5)
                  Rectangle { width: Style.space(10); height: width; radius: 2; border.width: 0
                              anchors.verticalCenter: parent.verticalCenter; color: panel.appColor(modelData.rank) }
                  Text { text: modelData.name; color: panel.foreground; font.family: panel.fontFamily
                         font.pixelSize: Style.font.bodySmall }
                }
              }
            }

            Rectangle { Layout.fillWidth: true; height: 1; color: panel.faint; border.width: 0 }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(18)

              // ---- ring + categories
              ColumnLayout {
                Layout.preferredWidth: Style.space(250); Layout.maximumWidth: Style.space(250)
                Layout.alignment: Qt.AlignTop
                spacing: Style.space(6)
                Caption { text: "SHARE  //  goal ring inside" }
                Item {
                  Layout.alignment: Qt.AlignHCenter
                  Layout.preferredWidth: Style.space(150); Layout.preferredHeight: Style.space(150)
                  Canvas {
                    id: ring
                    anchors.fill: parent
                    property var apps: d.apps || []
                    property real total: d.total || 0
                    property real goal: panel.goalSec
                    onAppsChanged: requestPaint()
                    onTotalChanged: requestPaint()
                    onGoalChanged: requestPaint()
                    Connections { target: panel; function onRepaintAll() { ring.requestPaint() } }
                    onPaint: {
                      var ctx = getContext("2d")
                      ctx.reset()
                      var cx = width / 2, cy = height / 2, lw = Style.space(15), r = Math.min(cx, cy) - lw / 2 - 2
                      ctx.lineWidth = lw
                      ctx.strokeStyle = panel.faint
                      ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI * 2); ctx.stroke()
                      var tot = 0
                      for (var i = 0; i < apps.length; i++) tot += apps[i].sec
                      var a = -Math.PI / 2
                      if (tot) {
                        for (var j = 0; j < apps.length; j++) {
                          var sw = Math.PI * 2 * apps[j].sec / tot
                          ctx.strokeStyle = panel.appColor(Math.min(8, apps[j].rank))
                          ctx.beginPath(); ctx.arc(cx, cy, r, a, a + Math.max(0.001, sw - 0.02)); ctx.stroke()
                          a += sw
                        }
                      }
                      // goal arc, inside the share ring
                      var r2 = r - lw / 2 - Style.space(7)
                      ctx.lineWidth = Style.space(4)
                      ctx.lineCap = "round"
                      ctx.strokeStyle = panel.faint
                      ctx.beginPath(); ctx.arc(cx, cy, r2, 0, Math.PI * 2); ctx.stroke()
                      var pct = Math.min(1, total / goal)
                      if (pct > 0.003) {
                        ctx.strokeStyle = pct >= 1 ? panel.accent : Util.alpha(panel.foreground, 0.85)
                        ctx.beginPath(); ctx.arc(cx, cy, r2, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * pct); ctx.stroke()
                      }
                    }
                  }
                  Column {
                    anchors.centerIn: parent
                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: panel.fmt(d.total)
                           color: panel.foreground; font.family: panel.fontFamily
                           font.pixelSize: Style.font.subtitle * 1.25; font.bold: true }
                    Text { anchors.horizontalCenter: parent.horizontalCenter
                           text: (d.apps || []).length + ((d.apps || []).length === 1 ? " app" : " apps")
                           color: panel.dim; font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall * 0.9 }
                  }
                }
                Repeater {
                  model: panel.catsToday
                  delegate: RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: Style.space(6)
                    Text { Layout.preferredWidth: Style.space(64); text: modelData.name
                           color: panel.foreground; font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall }
                    Rectangle {
                      Layout.fillWidth: true; height: Style.space(6); radius: 2; color: panel.faint; border.width: 0
                      Rectangle { height: parent.height; radius: 2; border.width: 0; color: Util.alpha(panel.accent, 0.8)
                                  width: parent.width * modelData.today / Math.max(1, d.total || 1) }
                    }
                    Text { Layout.preferredWidth: Style.space(44); horizontalAlignment: Text.AlignRight
                           text: panel.fmt(modelData.today); color: panel.dim
                           font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall }
                  }
                }
              }

              // ---- pace chart + apps per hour
              ColumnLayout {
                Layout.preferredWidth: Style.space(400); Layout.maximumWidth: Style.space(400)
                Layout.alignment: Qt.AlignTop
                spacing: Style.space(6)
                Caption { text: "PACE  //  hours so far, today vs typical" }
                Item {
                  Layout.fillWidth: true
                  Layout.preferredHeight: Style.space(204)
                  Canvas {
                    id: pace
                    anchors.fill: parent
                    property var today: d.paceToday || []
                    property var typical: d.paceTypical || []
                    property real goalH: panel.goalSec / 3600
                    readonly property real padL: Style.space(28)
                    readonly property real padR: Style.space(8)
                    readonly property real padT: Style.space(8)
                    readonly property real padB: Style.space(16)
                    readonly property real ymax: {
                      var m = goalH
                      for (var i = 0; i < today.length; i++) m = Math.max(m, today[i][1])
                      for (var j = 0; j < typical.length; j++) m = Math.max(m, typical[j][1])
                      var step = panel.niceStep(m)
                      return Math.max(step, Math.ceil(m * 1.05 / step) * step)
                    }
                    onTodayChanged: requestPaint()
                    onTypicalChanged: requestPaint()
                    onGoalHChanged: requestPaint()
                    onWidthChanged: requestPaint()
                    onHeightChanged: requestPaint()
                    Connections { target: panel; function onRepaintAll() { pace.requestPaint() } }
                    function px(h) { return padL + h / 24 * (width - padL - padR) }
                    function py(v) { return padT + (height - padT - padB) * (1 - v / ymax) }
                    onPaint: {
                      var ctx = getContext("2d")
                      ctx.reset()
                      ctx.font = Math.round(Style.font.bodySmall * 0.8) + "px " + panel.fontFamily
                      ctx.textBaseline = "middle"
                      // grid + y labels
                      var step = panel.niceStep(ymax)
                      ctx.lineWidth = 1
                      for (var g = 0; g <= ymax + 0.001; g += step) {
                        ctx.strokeStyle = panel.faint
                        ctx.beginPath(); ctx.moveTo(padL, py(g)); ctx.lineTo(width - padR, py(g)); ctx.stroke()
                        ctx.fillStyle = panel.dim
                        ctx.textAlign = "right"
                        ctx.fillText(g + "h", padL - 4, py(g))
                      }
                      ctx.textAlign = "center"
                      ctx.textBaseline = "alphabetic"
                      for (var hx = 0; hx <= 24; hx += 6) {
                        ctx.fillStyle = panel.dim
                        ctx.fillText(String(hx).padStart(2, "0"), px(hx), height - 3)
                      }
                      // typical curve: faint area plus a dashed line
                      if (typical.length > 1 && typical[typical.length - 1][1] > 0) {
                        ctx.beginPath()
                        ctx.moveTo(px(typical[0][0]), py(0))
                        for (var t = 0; t < typical.length; t++) ctx.lineTo(px(typical[t][0]), py(typical[t][1]))
                        ctx.lineTo(px(24), py(0))
                        ctx.closePath()
                        ctx.fillStyle = Util.alpha(panel.foreground, 0.06)
                        ctx.fill()
                        ctx.beginPath()
                        for (var u = 0; u < typical.length; u++) {
                          if (u === 0) ctx.moveTo(px(typical[u][0]), py(typical[u][1]))
                          else ctx.lineTo(px(typical[u][0]), py(typical[u][1]))
                        }
                        ctx.setLineDash([4, 3])
                        ctx.lineWidth = 1.4
                        ctx.strokeStyle = Util.alpha(panel.foreground, 0.55)
                        ctx.stroke()
                        ctx.setLineDash([])
                      }
                      // goal line
                      ctx.setLineDash([2, 3])
                      ctx.lineWidth = 1
                      ctx.strokeStyle = Util.alpha(panel.accent, 0.7)
                      ctx.beginPath(); ctx.moveTo(padL, py(goalH)); ctx.lineTo(width - padR, py(goalH)); ctx.stroke()
                      ctx.setLineDash([])
                      ctx.fillStyle = panel.accent
                      ctx.textAlign = "right"
                      ctx.fillText("goal", width - padR - 2, py(goalH) - 5)
                      // today: area, line, end dot
                      if (today.length > 1) {
                        ctx.beginPath()
                        ctx.moveTo(px(today[0][0]), py(0))
                        for (var a = 0; a < today.length; a++) ctx.lineTo(px(today[a][0]), py(today[a][1]))
                        ctx.lineTo(px(today[today.length - 1][0]), py(0))
                        ctx.closePath()
                        ctx.fillStyle = Util.alpha(panel.accent, 0.18)
                        ctx.fill()
                        ctx.beginPath()
                        for (var b = 0; b < today.length; b++) {
                          if (b === 0) ctx.moveTo(px(today[b][0]), py(today[b][1]))
                          else ctx.lineTo(px(today[b][0]), py(today[b][1]))
                        }
                        ctx.lineWidth = 2.2
                        ctx.lineJoin = "round"
                        ctx.strokeStyle = panel.accent
                        ctx.stroke()
                        var last = today[today.length - 1]
                        ctx.beginPath()
                        ctx.arc(px(last[0]), py(last[1]), 3.4, 0, Math.PI * 2)
                        ctx.fillStyle = panel.accent
                        ctx.fill()
                        ctx.beginPath()
                        ctx.arc(px(last[0]), py(last[1]), 6, 0, Math.PI * 2)
                        ctx.lineWidth = 1
                        ctx.strokeStyle = Util.alpha(panel.accent, 0.45)
                        ctx.stroke()
                      }
                    }
                  }
                  Rectangle {  // hover crosshair
                    visible: paceMouse.containsMouse
                    x: Math.max(pace.padL, Math.min(parent.width - pace.padR, paceMouse.mouseX)); y: pace.padT
                    width: 1; height: parent.height - pace.padT - pace.padB
                    color: Util.alpha(panel.foreground, 0.4); border.width: 0
                  }
                  MouseArea { id: paceMouse; anchors.fill: parent; hoverEnabled: true
                              readonly property real hour: Math.max(0, Math.min(24, (mouseX - pace.padL) / Math.max(1, width - pace.padL - pace.padR) * 24)) }
                  PanelToolTip {
                    parent: paceMouse
                    visible: paceMouse.containsMouse
                    x: Math.min(paceMouse.width - width, paceMouse.mouseX + 12); y: Math.max(0, paceMouse.mouseY - height - 10)
                    text: {
                      var h = paceMouse.hour
                      var td = panel.valueAt(d.paceToday, h), ty = panel.valueAt(d.paceTypical, h)
                      var hh = Math.floor(h), mm = Math.floor((h - hh) * 60)
                      var s = String(hh).padStart(2, "0") + ":" + String(mm).padStart(2, "0")
                      s += "\ntoday    " + (td === null ? "--" : panel.fmt(td * 3600))
                      s += "\ntypical  " + (ty === null ? "--" : panel.fmt(ty * 3600))
                      if (td !== null && ty !== null) s += "\n" + panel.fmtD((td - ty) * 3600)
                      return s
                    }
                  }
                }
                Caption { text: "APPS PER HOUR  //  fewer is deeper" }
                Item {
                  id: dist
                  Layout.fillWidth: true
                  Layout.preferredHeight: Style.space(66)
                  readonly property int peakN: Math.max(4, Math.max.apply(null, d.dist || [4]))
                  readonly property real bw: (width - 23 * Style.space(2)) / 24
                  Repeater {
                    model: d.dist || []
                    delegate: Item {
                      required property int modelData
                      required property int index
                      x: index * (dist.bw + Style.space(2)); width: dist.bw; height: dist.height
                      Rectangle {
                        anchors.bottom: lb.top; anchors.bottomMargin: 2
                        width: parent.width; radius: 1; border.width: 0
                        height: modelData ? Math.max(3, (parent.height - lb.height - 2) * modelData / dist.peakN) : 0
                        color: modelData >= 5 ? panel.urgent : (modelData >= 3 ? Util.alpha(panel.foreground, 0.65) : panel.accent)
                      }
                      Text { id: lb; anchors.bottom: parent.bottom; anchors.horizontalCenter: parent.horizontalCenter
                             text: index % 3 === 0 ? String(index) : ""; color: panel.dim
                             font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall * 0.8 }
                      MouseArea { id: dm; anchors.fill: parent; hoverEnabled: true }
                      PanelToolTip { visible: dm.containsMouse
                                     text: String(index).padStart(2, "0") + ":00  " + modelData + (modelData === 1 ? " app" : " apps") }
                    }
                  }
                }
              }

              // ---- apps list, scrolls in place
              ColumnLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignTop
                spacing: Style.space(6)
                Caption { text: "APPS TODAY  //  daily trend, time, share" }
                Rectangle {
                  Layout.fillWidth: true
                  Layout.preferredHeight: Style.space(300)
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
                      height: Style.space(24)
                      RowLayout {
                        anchors.fill: parent
                        spacing: Style.space(8)
                        Rectangle { Layout.preferredWidth: Style.space(10); Layout.preferredHeight: Style.space(10)
                                    radius: 2; border.width: 0; color: panel.appColor(Math.min(8, modelData.rank)) }
                        Text { Layout.fillWidth: true; Layout.preferredWidth: Style.space(90)
                               text: modelData.name; elide: Text.ElideRight
                               color: panel.foreground; font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall }
                        Spark { values: modelData.series || []
                                stroke: panel.appColor(Math.min(8, modelData.rank)) }
                        Text { Layout.preferredWidth: Style.space(48); horizontalAlignment: Text.AlignRight
                               text: panel.fmt(modelData.sec); color: panel.foreground
                               font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall }
                        Text { Layout.preferredWidth: Style.space(32); horizontalAlignment: Text.AlignRight
                               text: Math.round(100 * modelData.sec / Math.max(1, d.total || 1)) + "%"
                               color: panel.dim; font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall * 0.9 }
                      }
                      MouseArea { id: am; anchors.fill: parent; hoverEnabled: true }
                      PanelToolTip { visible: am.containsMouse; text: modelData.cls || "no window focused" }
                    }
                  }
                }
              }
            }
          }

          // ============================================================ TRENDS
          ColumnLayout {
            spacing: Style.space(12)

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(8)
              Stat {
                label: "AVG / DAY"; value: panel.fmt(d.avg); valueColor: panel.accent
                sub: ((d.records && d.records.days) || 0) + " days tracked"
                tip: "Average active time per finished day (today is left out until it ends)."
              }
              Stat {
                label: "THIS WEEK"; value: panel.fmt(d.wow ? d.wow.cur : 0)
                sub: !d.wow || d.wow.pct === null || d.wow.pct === undefined ? "building history"
                     : (d.wow.pct >= 0 ? "+" : "") + d.wow.pct + "% vs prior 7d"
                tip: "The last 7 days against the 7 before them."
              }
              Stat {
                label: "BEST DAY"; value: panel.fmt(d.records && d.records.bestDay ? d.records.bestDay.sec : 0)
                sub: d.records && d.records.bestDay ? panel.dlabel(d.records.bestDay.date, "ddd MMM d") : ""
                tip: d.records && d.records.deepDay
                     ? "Most deep focus: " + panel.fmt(d.records.deepDay.sec) + " on " + panel.dlabel(d.records.deepDay.date, "ddd MMM d")
                       + (d.records.longest ? "\nLongest stretch: " + panel.fmt(d.records.longest.sec) + " in " + d.records.longest.name
                          + " on " + panel.dlabel(d.records.longest.date, "ddd MMM d") : "")
                     : ""
              }
              Stat {
                label: "GOAL STREAK"; value: ((d.records && d.records.streak) || 0) + "d"
                sub: "best " + ((d.records && d.records.bestStreak) || 0) + "d, goal " + panel.fmt(panel.goalSec)
                tip: "Days in a row at or above the daily goal."
              }
              Stat {
                label: "ACTIVE WINDOW"; value: (d.records && d.records.window) || "--"
                sub: "middle 80% of a day"
                tip: "The hours that hold the middle 80% of your active time, averaged over earlier days."
              }
              Stat {
                label: "LIFETIME"; value: ((d.records && d.records.hours) || 0) + "h"
                sub: ((d.records && d.records.days) || 0) + " days tracked"
                tip: "Everything Hourglass has counted on this machine."
              }
            }

            Caption { text: "LAST " + (d.span || 0) + " DAYS  //  active time by app, dashed line is your average" }
            Item {
              Layout.fillWidth: true
              Layout.preferredHeight: Style.space(196)
              Canvas {
                id: hist
                anchors.fill: parent
                property var days: d.hist || []
                property real goalH: panel.goalSec / 3600
                property real avgH: (d.avg || 0) / 3600
                readonly property int n: days.length
                readonly property real padL: Style.space(30)
                readonly property real padR: Style.space(6)
                readonly property real padT: Style.space(8)
                readonly property real padB: Style.space(18)
                readonly property real gap: n > 20 ? Style.space(3) : Style.space(6)
                readonly property real bw: n > 0 ? (width - padL - padR - gap * (n - 1)) / n : 0
                readonly property real ymax: {
                  var m = Math.max(goalH, avgH, 1)
                  for (var i = 0; i < days.length; i++) m = Math.max(m, days[i].total / 3600)
                  var step = panel.niceStep(m)
                  return Math.max(step, Math.ceil(m * 1.05 / step) * step)
                }
                onDaysChanged: requestPaint()
                onGoalHChanged: requestPaint()
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
                Connections { target: panel; function onRepaintAll() { hist.requestPaint() } }
                function py(v) { return padT + (height - padT - padB) * (1 - v / ymax) }
                // a label with a halo in the panel colour, so it reads over bars and lines
                function tag(ctx, txt, x, y, col) {
                  ctx.lineWidth = 3
                  ctx.lineJoin = "round"
                  ctx.strokeStyle = Color.popups.background
                  ctx.strokeText(txt, x, y)
                  ctx.fillStyle = col
                  ctx.fillText(txt, x, y)
                }
                onPaint: {
                  var ctx = getContext("2d")
                  ctx.reset()
                  if (n === 0) return
                  ctx.font = Math.round(Style.font.bodySmall * 0.8) + "px " + panel.fontFamily
                  var step = panel.niceStep(ymax)
                  ctx.lineWidth = 1
                  ctx.textBaseline = "middle"
                  for (var g = 0; g <= ymax + 0.001; g += step) {
                    ctx.strokeStyle = panel.faint
                    ctx.beginPath(); ctx.moveTo(padL, py(g)); ctx.lineTo(width - padR, py(g)); ctx.stroke()
                    ctx.fillStyle = panel.dim
                    ctx.textAlign = "right"
                    ctx.fillText(g + "h", padL - 4, py(g))
                  }
                  var base = height - padB
                  for (var i = 0; i < n; i++) {
                    var x = padL + i * (bw + gap), yb = base, day = days[i]
                    for (var r = 0; r <= 8; r++) {
                      var h = (day.seg[r] / 3600) / ymax * (height - padT - padB)
                      if (h <= 0) continue
                      ctx.fillStyle = panel.appColor(r)
                      ctx.fillRect(x, yb - h, bw, h)
                      yb -= h
                    }
                    if (i === n - 1 && day.total > 0) {
                      ctx.lineWidth = 1.5
                      ctx.strokeStyle = panel.foreground
                      ctx.strokeRect(x - 0.5, yb - 0.5, bw + 1, base - yb + 1)
                    }
                    var show = bw >= Style.space(30) || (bw >= Style.space(15) && i % 2 === (n - 1) % 2) || i === n - 1 || i % 4 === (n - 1) % 4
                    if (show) {
                      ctx.textAlign = "center"
                      ctx.textBaseline = "alphabetic"
                      ctx.fillStyle = i === n - 1 ? panel.accent : panel.dim
                      ctx.fillText(day.dow.charAt(0) + panel.dlabel(day.date, "d"), x + bw / 2, height - 4)
                    }
                  }
                  // average and goal
                  ctx.textBaseline = "middle"
                  ctx.setLineDash([5, 4])
                  ctx.lineWidth = 1.3
                  if (avgH > 0) {
                    ctx.strokeStyle = Util.alpha(panel.foreground, 0.8)
                    ctx.beginPath(); ctx.moveTo(padL, py(avgH)); ctx.lineTo(width - padR, py(avgH)); ctx.stroke()
                  }
                  ctx.strokeStyle = Util.alpha(panel.accent, 0.9)
                  ctx.beginPath(); ctx.moveTo(padL, py(goalH)); ctx.lineTo(width - padR, py(goalH)); ctx.stroke()
                  ctx.setLineDash([])
                  ctx.textAlign = "left"
                  tag(ctx, "goal " + panel.fmt(goalH * 3600), padL + 4, py(goalH) + (goalH >= avgH ? -7 : 9), panel.accent)
                  if (avgH > 0) {
                    ctx.textAlign = "right"
                    tag(ctx, "avg " + panel.fmt(avgH * 3600), width - padR - 4, py(avgH) + (avgH > goalH ? -7 : 9), panel.foreground)
                  }
                }
              }
              MouseArea {
                id: histMouse; anchors.fill: parent; hoverEnabled: true
                readonly property int idx: {
                  if (hist.n === 0) return -1
                  var i = Math.floor((mouseX - hist.padL) / (hist.bw + hist.gap))
                  return i >= 0 && i < hist.n ? i : -1
                }
              }
              PanelToolTip {
                parent: histMouse
                visible: histMouse.containsMouse && histMouse.idx >= 0
                x: Math.min(histMouse.width - width, histMouse.mouseX + 12); y: Math.max(0, histMouse.mouseY - height - 10)
                text: {
                  var h = (d.hist || [])[histMouse.idx]
                  if (!h) return ""
                  var s = panel.dlabel(h.date, "ddd MMM d") + "  " + panel.fmt(h.total) + (h.total >= panel.goalSec ? "  goal met" : "")
                  var segs = []
                  for (var r = 0; r <= 8; r++) if (h.seg[r] > 0) segs.push([r, h.seg[r]])
                  segs.sort(function(a, b) { return b[1] - a[1] })
                  for (var k = 0; k < Math.min(3, segs.length); k++) s += "\n" + panel.rankName(segs[k][0]) + "  " + panel.fmt(segs[k][1])
                  s += "\n" + h.sw + " switches" + (h.deep ? ", deep " + panel.fmt(h.deep) : "")
                  return s
                }
              }
            }
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

              // ---- weekday x hour heatmap
              ColumnLayout {
                Layout.preferredWidth: Style.space(500); Layout.maximumWidth: Style.space(500)
                Layout.alignment: Qt.AlignTop
                spacing: Style.space(6)
                Caption { text: "WHEN YOU WORK  //  average active minutes per hour" }
                Item {
                  id: heat
                  Layout.fillWidth: true
                  Layout.preferredHeight: Style.space(7 * 18 + 16)
                  readonly property real labelW: Style.space(30)
                  readonly property real cw: (width - labelW) / 24
                  readonly property real ch: Style.space(16)
                  readonly property real peak: {
                    var m = 1, hm = d.heat || []
                    for (var i = 0; i < hm.length; i++) for (var j = 0; j < hm[i].length; j++) m = Math.max(m, hm[i][j])
                    return m
                  }
                  readonly property var names: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
                  readonly property int nowDow: (new Date().getDay() + 6) % 7
                  Repeater {
                    model: 7
                    delegate: Text {
                      required property int index
                      x: 0; y: index * (heat.ch + Style.space(2)); height: heat.ch
                      verticalAlignment: Text.AlignVCenter
                      text: heat.names[index]
                      color: index === heat.nowDow ? panel.accent : panel.dim; font.bold: index === heat.nowDow
                      font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall * 0.85
                    }
                  }
                  Repeater {
                    model: 168
                    delegate: Rectangle {
                      required property int index
                      readonly property int row: Math.floor(index / 24)
                      readonly property int col: index % 24
                      readonly property real v: ((d.heat || [])[row] || [])[col] || 0
                      x: heat.labelW + col * heat.cw; y: row * (heat.ch + Style.space(2))
                      width: heat.cw - Style.space(2); height: heat.ch
                      radius: 2
                      color: v <= 0 ? Util.alpha(panel.foreground, 0.05)
                                    : Util.alpha(panel.accent, 0.14 + 0.86 * Math.pow(v / heat.peak, 0.7))
                      border.width: row === heat.nowDow && col === new Date().getHours() ? 1 : 0
                      border.color: panel.foreground
                      MouseArea { id: hcm; anchors.fill: parent; hoverEnabled: true }
                      PanelToolTip {
                        visible: hcm.containsMouse
                        text: heat.names[row] + " " + String(col).padStart(2, "0") + ":00  avg " + Math.round(v / 60) + "m active"
                      }
                    }
                  }
                  Repeater {
                    model: 8
                    delegate: Text {
                      required property int index
                      x: heat.labelW + index * 3 * heat.cw - implicitWidth / 2 + (index === 0 ? implicitWidth / 2 : 0)
                      anchors.bottom: parent.bottom
                      text: String(index * 3).padStart(2, "0")
                      color: panel.dim; font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall * 0.8
                    }
                  }
                }
              }

              // ---- weekday averages
              ColumnLayout {
                Layout.preferredWidth: Style.space(210); Layout.maximumWidth: Style.space(210)
                Layout.alignment: Qt.AlignTop
                spacing: Style.space(6)
                Caption { text: "BY WEEKDAY  //  avg" }
                Item {
                  id: dow
                  Layout.fillWidth: true
                  Layout.preferredHeight: Style.space(7 * 18)
                  readonly property real peak: Math.max(1, Math.max.apply(null, d.dowAvg || [1]))
                  Repeater {
                    model: 7
                    delegate: RowLayout {
                      required property int index
                      readonly property real v: (d.dowAvg || [])[index] || 0
                      y: index * Style.space(18); width: dow.width; height: Style.space(16)
                      spacing: Style.space(6)
                      Text { Layout.preferredWidth: Style.space(28); text: heat.names[index]
                             color: index === heat.nowDow ? panel.accent : panel.dim; font.bold: index === heat.nowDow
                             font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall * 0.85 }
                      Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: Style.space(8); radius: 2; color: panel.faint; border.width: 0
                        Rectangle { height: parent.height; radius: 2; border.width: 0
                                    color: v >= dow.peak ? panel.accent : Util.alpha(panel.accent, 0.5)
                                    width: parent.width * v / dow.peak }
                      }
                      Text { Layout.preferredWidth: Style.space(36); horizontalAlignment: Text.AlignRight
                             text: v > 0 ? panel.fmt(v) : "--"; color: panel.foreground
                             font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall * 0.9 }
                    }
                  }
                }
              }

              // ---- top apps over the window, scrolls in place
              ColumnLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignTop
                spacing: Style.space(6)
                Caption { text: "TOP APPS  //  trend vs prior week" }
                Rectangle {
                  Layout.fillWidth: true
                  Layout.preferredHeight: Style.space(7 * 18 + 8)
                  radius: Style.space(6); color: panel.faint; border.width: 0
                  clip: true
                  ListView {
                    id: rlist
                    anchors.fill: parent; anchors.margins: Style.space(6)
                    model: d.rapps || []
                    spacing: Style.space(3)
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar {}
                    delegate: Item {
                      required property var modelData
                      width: rlist.width - Style.space(10)
                      height: Style.space(22)
                      RowLayout {
                        anchors.fill: parent
                        spacing: Style.space(7)
                        Rectangle { Layout.preferredWidth: Style.space(10); Layout.preferredHeight: Style.space(10)
                                    radius: 2; border.width: 0; color: panel.appColor(Math.min(8, modelData.rank)) }
                        Text { Layout.fillWidth: true; Layout.preferredWidth: Style.space(70)
                               text: modelData.name; elide: Text.ElideRight
                               color: panel.foreground; font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall }
                        Spark { implicitWidth: Style.space(64); values: modelData.series
                                stroke: panel.appColor(Math.min(8, modelData.rank)) }
                        Text { Layout.preferredWidth: Style.space(46); horizontalAlignment: Text.AlignRight
                               text: panel.fmt(modelData.total); color: panel.foreground
                               font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall }
                        Text { Layout.preferredWidth: Style.space(42); horizontalAlignment: Text.AlignRight
                               text: modelData.trend === null || modelData.trend === undefined ? "new"
                                     : (modelData.trend >= 0 ? "▲" : "▼") + Math.abs(modelData.trend) + "%"
                               color: modelData.trend === null || modelData.trend === undefined || modelData.trend >= 0 ? panel.accent : panel.dim
                               font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall * 0.9 }
                      }
                      MouseArea { id: rm; anchors.fill: parent; hoverEnabled: true }
                      PanelToolTip {
                        visible: rm.containsMouse
                        text: modelData.cls + "\n" + modelData.share + "% of the window, today " + panel.fmt(modelData.today)
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
  }
}

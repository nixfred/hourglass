import QtQuick
import Quickshell
import Quickshell.Io

// Runs the tracker daemon for the life of the shell and polls its report.
// The daemon holds a flock, so a second copy (another shell, a restart that
// left an orphan) exits at once and the survivor keeps counting.
Item {
  id: root

  property var settings: ({})
  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\/(localhost)?/, ""))

  property bool ready: false
  property bool ok: true
  property string error: ""
  property var data: ({})
  readonly property int total: data.total || 0
  readonly property var live: data.live || ({})

  function num(key, def, lo, hi) {
    var n = parseInt(String(settings && settings[key] !== undefined ? settings[key] : def), 10)
    return isFinite(n) ? Math.max(lo, Math.min(hi, n)) : def
  }
  readonly property int refreshSec: num("refreshSec", 15, 5, 300)
  readonly property int breakMinutes: num("breakMinutes", 90, 0, 480)
  readonly property bool stretch: breakMinutes > 0 && !!live.active && (live.run || 0) >= breakMinutes * 60

  function fmt(sec) {
    sec = Math.round(sec || 0)
    var h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60)
    if (h > 0) return h + "h" + (m < 10 ? "0" : "") + m
    if (m > 0) return m + "m"
    return sec + "s"
  }

  function apply(text) {
    var d
    try { d = JSON.parse(text) } catch (e) { ok = false; error = "bad JSON from hourglass.py"; ready = true; return }
    ok = !!d.ok
    error = d.error || ""
    if (d.ok) data = d
    ready = true
  }

  Process {
    id: tracker
    command: ["python3", root.pluginDir + "hourglass.py", "daemon"]
    running: true
    onExited: revive.restart()
  }
  Timer { id: revive; interval: 30000; onTriggered: tracker.running = true }

  Process {
    id: poll
    command: ["python3", root.pluginDir + "hourglass.py", "report", "7"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.apply(text)
    }
  }

  function refresh() { if (!poll.running) poll.running = true }

  Timer {
    interval: root.refreshSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
}

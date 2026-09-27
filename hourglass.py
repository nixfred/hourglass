#!/usr/bin/env python3
"""Hourglass: per-app screen time for Hyprland.

  hourglass.py daemon          track focus, one sample every 2 s (single instance)
  hourglass.py report [days]   print JSON for the bar and panel

Only window *classes* are stored, never titles. Data lives in
~/.local/share/hourglass/YYYY-MM-DD.json, one small file per day.
Time counts as active while the screen is unlocked and something happened
(cursor moved, focus or title changed) within the idle window.
"""
import datetime as dt
import fcntl
import json
import os
import signal
import socket
import sys
import time

DATA = os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"), "hourglass")
TICK = 2
FLUSH = 10
IDLE_SEC = int(os.environ.get("HOURGLASS_IDLE_SEC", "300"))
FOCUS_SEC = 25 * 60  # a run this long counts as a focus session

PRETTY = {
    "brave-browser": "Brave", "firefox": "Firefox", "chromium": "Chromium", "google-chrome": "Chrome",
    "kitty": "Kitty", "foot": "Foot", "alacritty": "Alacritty", "ghostty": "Ghostty",
    "com.mitchellh.ghostty": "Ghostty", "code": "VS Code", "code-oss": "VS Code", "obsidian": "Obsidian",
    "org.gnome.nautilus": "Files", "spotify": "Spotify", "signal": "Signal", "discord": "Discord",
    "localsend": "LocalSend", "mpv": "mpv", "imv": "imv", "steam": "Steam", "zoom": "Zoom",
}


def pretty(cls):
    if not cls:
        return "Desktop"
    low = cls.lower()
    if low in PRETTY:
        return PRETTY[low]
    if low.startswith("brave-") and low.endswith("-default"):
        return "Web app"
    name = cls.split(".")[-1] if cls.count(".") >= 2 else cls
    return name[:1].upper() + name[1:]


def day_path(d):
    return os.path.join(DATA, d + ".json")


def load_day(d):
    try:
        with open(day_path(d)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"date": d, "apps": {}, "min": {}, "switches": 0, "sessions": 0,
                "best": {"cls": "", "sec": 0, "end": ""}, "first": "", "last": ""}


def save_day(day):
    os.makedirs(DATA, exist_ok=True)
    p = day_path(day["date"])
    tmp = p + ".tmp"
    with open(tmp, "w") as f:
        json.dump(day, f, separators=(",", ":"))
    os.replace(tmp, p)


# ---------------------------------------------------------------- Hyprland IPC
def hypr_sock():
    sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
    run = os.environ.get("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid())
    if not sig:  # launched without the env: take the newest instance
        base = os.path.join(run, "hypr")
        try:
            sig = max(os.listdir(base), key=lambda s: os.path.getmtime(os.path.join(base, s)))
        except (OSError, ValueError):
            return ""
    return os.path.join(run, "hypr", sig, ".socket.sock")


def hypr(cmd):
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(1.0)
        s.connect(hypr_sock())
        s.sendall(cmd.encode())
        out = b""
        while True:
            b = s.recv(65536)
            if not b:
                break
            out += b
        s.close()
        return out.decode("utf-8", "replace")
    except OSError:
        return ""


def locked():
    for pid in os.listdir("/proc"):
        if pid.isdigit():
            try:
                with open("/proc/%s/comm" % pid) as f:
                    if f.read().strip() == "hyprlock":
                        return True
            except OSError:
                pass
    return False


# ---------------------------------------------------------------- daemon
def daemon():
    os.makedirs(DATA, exist_ok=True)
    lock = open(os.path.join(DATA, ".daemon.lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print(json.dumps({"ok": True, "note": "already running"}))
        return 0

    today = dt.date.today().isoformat()
    day = load_day(today)
    state = {"cls": None, "sig": None, "cur": None, "act": time.time(), "run": 0, "flushed": time.time(), "lockchk": 0, "locked": False}

    def flush(*_):
        save_day(day)
        state["flushed"] = time.time()

    def stop(*_):
        flush()
        sys.exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    last = time.time()

    while True:
        time.sleep(TICK)
        now = time.time()
        dt_s = min(now - last, TICK * 3)  # a suspend gap is never counted
        last = now
        d = dt.date.today().isoformat()
        if d != day["date"]:
            flush()
            day = load_day(d)
            state["run"] = 0

        try:
            w = json.loads(hypr("j/activewindow") or "{}")
        except ValueError:
            w = {}
        cls = w.get("class") or ""
        sig = (w.get("address"), w.get("title"))
        cur = hypr("cursorpos").strip()
        if sig != state["sig"] or cur != state["cur"]:
            state["act"] = now
        state["sig"], state["cur"] = sig, cur

        if now - state["lockchk"] > 6:
            state["locked"], state["lockchk"] = locked(), now
        active = not state["locked"] and (now - state["act"]) < IDLE_SEC

        if not active:
            state["run"] = 0
            state["cls"] = None
        else:
            if cls != state["cls"]:
                if state["cls"] is not None:
                    day["switches"] += 1
                state["run"] = 0
                state["cls"] = cls
            day["apps"][cls] = day["apps"].get(cls, 0) + dt_s
            lt = time.localtime(now)
            k = str(lt.tm_hour * 60 + lt.tm_min)
            m = day["min"].setdefault(k, {})
            m[cls] = round(m.get(cls, 0) + dt_s, 1)
            prev = state["run"]
            state["run"] += dt_s
            if prev < FOCUS_SEC <= state["run"]:
                day["sessions"] += 1
            if state["run"] > day["best"]["sec"]:
                day["best"] = {"cls": cls, "sec": round(state["run"]), "end": time.strftime("%H:%M", lt)}
            hm = time.strftime("%H:%M", lt)
            day["first"] = day["first"] or hm
            day["last"] = hm
        # live state for the bar, cheap to read
        day["live"] = {"cls": state["cls"] or "", "run": round(state["run"]), "active": active, "t": round(now)}
        if now - state["flushed"] >= FLUSH:
            flush()


# ---------------------------------------------------------------- report
def report(ndays=7):
    today = dt.date.today()
    days = [load_day((today - dt.timedelta(days=i)).isoformat()) for i in range(ndays - 1, -1, -1)]
    t = days[-1]
    apps = sorted(t["apps"].items(), key=lambda kv: -kv[1])
    total = sum(v for _, v in apps)

    # rank: today's top apps first, then anything big from the week
    week_apps = {}
    for d in days:
        for c, v in d["apps"].items():
            week_apps[c] = week_apps.get(c, 0) + v
    order = [c for c, _ in apps]
    for c, _ in sorted(week_apps.items(), key=lambda kv: -kv[1]):
        if c not in order:
            order.append(c)
    TOP = 8
    rank = {c: i for i, c in enumerate(order[:TOP])}

    def r(c):
        return rank.get(c, TOP)  # TOP == "other"

    # ribbon: 288 five-minute cells, dominant app rank or -1 idle
    ribbon = []
    for b in range(288):
        acc = {}
        for mm in range(b * 5, b * 5 + 5):
            for c, v in t["min"].get(str(mm), {}).items():
                acc[c] = acc.get(c, 0) + v
        if sum(acc.values()) < 30:
            ribbon.append(-1)
        else:
            ribbon.append(r(max(acc, key=acc.get)))

    hours = [0] * 24
    for k, m in t["min"].items():
        hours[int(k) // 60] += sum(m.values())
    peak = max(range(24), key=lambda h: hours[h]) if total else -1

    week = []
    for d in days:
        seg = [0] * (TOP + 1)
        for c, v in d["apps"].items():
            seg[r(c)] += v
        week.append({"date": d["date"], "dow": dt.date.fromisoformat(d["date"]).strftime("%a"),
                     "total": round(sum(seg)), "seg": [round(x) for x in seg]})

    live = t.get("live") or {}
    fresh = live and time.time() - live.get("t", 0) < 90
    avg_days = [w["total"] for w in week[:-1] if w["total"] > 0]
    return {
        "ok": True,
        "tracking": bool(fresh),
        "date": t["date"],
        "total": round(total),
        "apps": [{"cls": c, "name": pretty(c), "sec": round(v), "rank": r(c)} for c, v in apps[:40]],
        "legend": [pretty(c) for c in order[:TOP]] + (["Other"] if len(order) > TOP else []),
        "ribbon": ribbon,
        "hours": [round(h) for h in hours],
        "peak": peak,
        "switches": t["switches"],
        "perHour": round(t["switches"] / max(total / 3600, 1), 1),
        "sessions": t["sessions"],
        "best": dict(t["best"], name=pretty(t["best"]["cls"])),
        "first": t["first"], "last": t["last"],
        "week": week,
        "avg": round(sum(avg_days) / len(avg_days)) if avg_days else 0,
        "live": {"name": pretty(live.get("cls", "")) if live.get("cls") else "", "run": live.get("run", 0) if fresh else 0,
                 "active": bool(fresh and live.get("active"))},
    }


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "report"
    if mode == "daemon":
        sys.exit(daemon() or 0)
    try:
        print(json.dumps(report(int(sys.argv[2]) if len(sys.argv) > 2 else 7)))
    except Exception as e:  # never hand the panel a traceback
        print(json.dumps({"ok": False, "error": "%s: %s" % (type(e).__name__, e)}))

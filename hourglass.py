#!/usr/bin/env python3
"""Hourglass: per-app screen time for Hyprland.

  hourglass.py daemon          track focus, one sample every 2 s (single instance)
  hourglass.py report [days] [goalSec]   print JSON for the bar and panel (default 30 days, 6 h goal)

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
    "com.microsoft.vscode": "VS Code", "com.obsproject.studio": "OBS", "chatgpt": "ChatGPT",
    "org.gnome.nautilus": "Files", "spotify": "Spotify", "signal": "Signal", "discord": "Discord",
    "localsend": "LocalSend", "mpv": "mpv", "imv": "imv", "steam": "Steam", "zoom": "Zoom",
    "orca": "Orca", "org.quickshell": "Quickshell", "org.omarchy.cliamp": "Cliamp",
    "org.omarchy.agent": "Agent", "org.omarchy.claude-pr": "Claude PR", "virt-viewer": "Virt Viewer",
    "dev.csfh.atmos": "Atmos", "io.github.lgse.strata": "Strata", "omarchy-quake-btop-full": "btop",
}

# First matching rule wins. Substring on the lowercased class; "code" is matched whole.
CATS = ["Terminal", "Browser", "Agents", "Dev", "Comms", "Media", "System", "Other"]
RULES = [
    (0, ("kitty", "foot", "alacritty", "ghostty", "wezterm", "konsole", "xterm", "btop")),
    (1, ("brave", "firefox", "chromium", "chrome", "zen-", "librewolf")),
    (2, ("orca", "chatgpt", "org.omarchy.agent", "claude", "codex", "herdr", "harness", "strata", "hermes")),
    (3, ("vscode", "cursor", "zed", "jetbrains", "idea", "sublime", "neovide")),
    (4, ("zoom", "signal", "discord", "slack", "telegram", "whatsapp", "thunderbird", "element", "teams", "omamail")),
    (5, ("spotify", "cliamp", "imv", "mpv", "vlc", "obs", "screensaver", "kodi", "youtube")),
    (6, ("quickshell", "portal", "nautilus", "thunar", "dolphin", "atmos", "flea", "virt-viewer", "pavucontrol", "blueberry", "polkit")),
]


def category(cls):
    low = (cls or "").lower()
    if not low:
        return 6  # no window focused: the desktop itself
    if low in ("code", "code-oss") or low.startswith("code-"):
        return 3
    for idx, keys in RULES:
        if any(k in low for k in keys):
            return idx
    return len(CATS) - 1


def pretty(cls):
    if not cls:
        return "Desktop"
    low = cls.lower()
    if low in PRETTY:
        return PRETTY[low]
    if low.startswith("brave-") and low.endswith("-default"):  # a Brave web app: brave-<host>__<path>-Default
        core = cls[6:-8]
        host, _, path = core.partition("__")
        bare = host == "localhost" or host.replace(".", "").isdigit()
        if bare and path:
            return "Web: " + path.split("_")[-1][:22]
        return "Web: " + host[:22]
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
TOP = 8          # named app colours; everything else folds into "Other"
DEEP_MIN = 20    # minutes of one app, back to back, that count as deep focus
BREAK_MIN = 5    # a gap this long between active minutes is a break
CACHE = os.path.join(DATA, ".summary.json")


def summarize(day):
    """Everything the panel needs from one day, small enough to cache."""
    apps = day.get("apps", {})
    per = [0.0] * 1440
    dom = []
    for k, v in day.get("min", {}).items():
        m = int(k)
        s = sum(v.values())
        if s > 0 and 0 <= m < 1440:
            per[m] = s
            dom.append((m, max(v, key=v.get), s))
    dom.sort()
    pre = [0.0] * 1441
    for i in range(1440):
        pre[i + 1] = pre[i] + per[i]
    runs, cur = [], None
    for m, c, s in dom:
        if cur and c == cur["c"] and m - cur["last"] <= 2:
            cur["n"] += 1
            cur["sec"] += s
            cur["last"] = m
        else:
            if cur:
                runs.append(cur)
            cur = {"c": c, "n": 1, "sec": s, "last": m}
    if cur:
        runs.append(cur)
    # work runs only: music players, video and the bare desktop are not focus
    work = [x for x in runs if category(x["c"]) not in (5, 6)]
    deep = [x for x in work if x["n"] >= DEEP_MIN]
    top = max(work, key=lambda x: x["sec"], default=None)
    gaps = [b[0] - a[0] - 1 for a, b in zip(dom, dom[1:]) if b[0] - a[0] - 1 >= BREAK_MIN]
    return {
        "date": day["date"],
        "total": round(sum(apps.values())),
        "apps": {c: round(v) for c, v in apps.items()},
        "hours": [round(sum(per[h * 60:(h + 1) * 60])) for h in range(24)],
        "cum": [round(pre[h * 60]) for h in range(25)],
        "first": day.get("first", ""), "last": day.get("last", ""),
        "sw": day.get("switches", 0), "sess": len(deep),
        "best": {"cls": top["c"], "sec": round(top["sec"]), "end": min_to_hm(top["last"])} if top else {"cls": "", "sec": 0, "end": ""},
        "deep": round(sum(x["sec"] for x in deep)),
        "breaks": len(gaps), "lbreak": max(gaps) if gaps else 0,
    }


def load_cache():
    try:
        with open(CACHE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def hm_to_min(s):
    try:
        h, m = s.split(":")
        return int(h) * 60 + int(m)
    except ValueError:
        return None


def median(xs):
    xs = sorted(xs)
    return xs[len(xs) // 2] if xs else None


def min_to_hm(m):
    return "%02d:%02d" % (m // 60, m % 60) if m is not None else ""


def report(ndays=30, goal=21600):
    now = dt.datetime.now()
    today = now.date()
    tstr = today.isoformat()
    now_min = now.hour * 60 + now.minute
    full = load_day(tstr)

    # one summary per day on disk; finished days come from the cache
    cache, dirty, sums = load_cache(), False, {}
    try:
        names = sorted(n[:-5] for n in os.listdir(DATA) if n.endswith(".json") and n[:4].isdigit())[-400:]
    except OSError:
        names = []
    for d in names:
        if d == tstr:
            continue
        try:
            mt = os.stat(day_path(d)).st_mtime_ns
        except OSError:
            continue
        c = cache.get(d)
        if c and c.get("mt") == mt:
            sums[d] = c["s"]
        else:
            sums[d] = summarize(load_day(d))
            cache[d] = {"mt": mt, "s": sums[d]}
            dirty = True
    if dirty:
        try:
            tmp = CACHE + ".tmp"
            with open(tmp, "w") as f:
                json.dump(cache, f, separators=(",", ":"))
            os.replace(tmp, CACHE)
        except OSError:
            pass
    t = summarize(full)
    sums[tstr] = t

    # the history window never reaches back before the first tracked day
    start = max(dt.date.fromisoformat(min(sums)), today - dt.timedelta(days=ndays - 1))
    dates = [(start + dt.timedelta(days=i)).isoformat() for i in range((today - start).days + 1)]
    empty = lambda d: {"date": d, "total": 0, "apps": {}, "hours": [0] * 24, "cum": [0] * 25, "first": "", "last": "",
                       "sw": 0, "sess": 0, "best": {"cls": "", "sec": 0, "end": ""}, "deep": 0, "breaks": 0, "lbreak": 0}
    H = [sums.get(d) or empty(d) for d in dates]
    past = [s for s in H if s["date"] != tstr and s["total"] > 0]

    # colours are stable: ranked by time over the whole window, not by today
    rng = {}
    for s in H:
        for c, v in s["apps"].items():
            rng[c] = rng.get(c, 0) + v
    order = sorted(rng, key=lambda c: -rng[c])
    rank = {c: i for i, c in enumerate(order[:TOP])}
    r = lambda c: rank.get(c, TOP)

    total = t["total"]
    apps = sorted(t["apps"].items(), key=lambda kv: -kv[1])

    # 24 h ribbon: 288 five-minute cells, dominant app rank or -1 idle
    mins = full.get("min", {})
    ribbon = []
    for b in range(288):
        acc = {}
        for mm in range(b * 5, b * 5 + 5):
            for c, v in mins.get(str(mm), {}).items():
                acc[c] = acc.get(c, 0) + v
        ribbon.append(r(max(acc, key=acc.get)) if sum(acc.values()) >= 30 else -1)
    hours = t["hours"]
    peak = max(range(24), key=lambda h: hours[h]) if total else -1

    # apps per hour today: how scattered the hour was
    dist = [0] * 24
    byh = {}
    for k, v in mins.items():
        h = int(k) // 60
        for c, sec in v.items():
            byh.setdefault(h, {})
            byh[h][c] = byh[h].get(c, 0) + sec
    for h, v in byh.items():
        dist[h] = sum(1 for sec in v.values() if sec >= 15)

    # pace: today's running total against the average of earlier days
    avg_cum = [sum(s["cum"][h] for s in past) / len(past) if past else 0 for h in range(25)]
    frac = now_min / 60.0
    lo = min(int(frac), 23)
    typ_now = avg_cum[lo] + (avg_cum[lo + 1] - avg_cum[lo]) * (frac - lo)
    pace_today = [[h, round(t["cum"][h] / 3600, 3)] for h in range(0, int(frac) + 1)] + [[round(frac, 3), round(total / 3600, 3)]]
    pace_typ = [[h, round(avg_cum[h] / 3600, 3)] for h in range(25)]

    # categories, today and across the window
    ct, cr = [0] * len(CATS), [0] * len(CATS)
    for c, v in t["apps"].items():
        ct[category(c)] += v
    for c, v in rng.items():
        cr[category(c)] += v
    cats = [{"name": CATS[i], "idx": i, "today": ct[i], "range": cr[i]} for i in range(len(CATS))]
    cats.sort(key=lambda x: -x["range"])

    # per-app table over the window, with a daily series for the sparkline
    rapps = []
    rt = sum(rng.values()) or 1
    for c in order[:15]:
        series = [s["apps"].get(c, 0) for s in H]
        last7, prev7 = sum(series[-7:]), sum(series[-14:-7])
        rapps.append({"cls": c, "name": pretty(c), "rank": r(c), "total": rng[c], "share": round(100 * rng[c] / rt, 1),
                      "today": t["apps"].get(c, 0), "series": series,
                      "trend": round(100 * (last7 - prev7) / prev7) if prev7 and len(series) >= 14 else None})

    # weekday x hour: average active seconds in each cell
    heat = []
    for dow in range(7):
        ds = [s for s in past if dt.date.fromisoformat(s["date"]).weekday() == dow]
        heat.append([round(sum(s["hours"][h] for s in ds) / len(ds)) if ds else 0 for h in range(24)])
    dow_avg = [round(sum(row)) for row in heat]

    # week over week
    tot = [s["total"] for s in H]
    cur7, prev7 = sum(tot[-7:]), sum(tot[-14:-7])
    wow = {"cur": cur7, "prev": prev7, "pct": round(100 * (cur7 - prev7) / prev7) if prev7 and len(tot) >= 14 else None}

    # records over every day on disk
    alls = list(sums.values())
    tracked = [s for s in alls if s["total"] > 0]
    best_day = max(tracked, key=lambda s: s["total"], default=None)
    deep_day = max(tracked, key=lambda s: s["deep"], default=None)
    long_day = max(tracked, key=lambda s: s["best"]["sec"], default=None)
    streak = best_streak = run = 0
    for d in sorted(sums):
        if sums[d]["total"] >= goal:
            run += 1
            best_streak = max(best_streak, run)
        else:
            run = 0
    # current streak: back from today if today made it, else from yesterday
    d = today if t["total"] >= goal else today - dt.timedelta(days=1)
    while sums.get(d.isoformat(), {"total": 0})["total"] >= goal:
        streak += 1
        d -= dt.timedelta(days=1)
    prof = [sum(x["hours"][h] for x in past) / len(past) if past else 0 for h in range(24)]
    ptot, acc, w0, w1 = sum(prof), 0.0, None, None
    for h in range(24):
        acc += prof[h]
        if w0 is None and acc >= 0.10 * ptot:
            w0 = h
        if w1 is None and acc >= 0.90 * ptot:
            w1 = h + 1
    window = "%02d:00-%02d:00" % (w0, w1) if ptot and w0 is not None else ""
    records = {
        "days": len(tracked), "hours": round(sum(s["total"] for s in tracked) / 3600),
        "bestDay": {"date": best_day["date"], "sec": best_day["total"]} if best_day else None,
        "deepDay": {"date": deep_day["date"], "sec": deep_day["deep"]} if deep_day else None,
        "longest": {"date": long_day["date"], "sec": long_day["best"]["sec"], "name": pretty(long_day["best"]["cls"])} if long_day else None,
        "streak": streak, "bestStreak": best_streak,
        "window": window,
    }

    live = full.get("live") or {}
    fresh = bool(live) and time.time() - live.get("t", 0) < 90
    avg = round(sum(s["total"] for s in past) / len(past)) if past else 0
    hist = []
    for s in H:
        seg = [0] * (TOP + 1)
        for c, v in s["apps"].items():
            seg[r(c)] += v
        hist.append({"date": s["date"], "dow": dt.date.fromisoformat(s["date"]).strftime("%a"), "total": s["total"],
                     "seg": seg, "sw": s["sw"], "sess": s["sess"], "deep": s["deep"], "first": s["first"], "last": s["last"]})
    return {
        "ok": True, "tracking": fresh, "date": tstr, "now": now_min, "goal": goal,
        "total": total, "avg": avg,
        "apps": [{"cls": c, "name": pretty(c), "sec": v, "rank": r(c), "series": [x["apps"].get(c, 0) for x in H]}
                 for c, v in apps[:40]],
        "legend": [pretty(c) for c in order[:TOP]] + (["Other"] if len(order) > TOP else []),
        "ribbon": ribbon, "hours": hours, "peak": peak, "dist": dist,
        "switches": t["sw"], "perHour": round(t["sw"] / max(total / 3600, 1), 1), "sessions": t["sess"],
        "best": dict(t["best"], name=pretty(t["best"]["cls"])),
        "first": t["first"], "last": t["last"],
        "deep": t["deep"], "deepPct": round(100 * t["deep"] / total) if total else 0,
        "breaks": t["breaks"], "lbreak": t["lbreak"],
        "vsTypical": round(total - typ_now) if past else None, "typicalNow": round(typ_now),
        "paceToday": pace_today, "paceTypical": pace_typ,
        "cats": cats, "hist": hist, "rapps": rapps, "heat": heat, "dowAvg": dow_avg,
        "wow": wow, "records": records, "span": len(H),
        "live": {"name": pretty(live.get("cls", "")) if live.get("cls") else "", "run": live.get("run", 0) if fresh else 0,
                 "active": bool(fresh and live.get("active"))},
    }


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "report"
    if mode == "daemon":
        sys.exit(daemon() or 0)
    try:
        nd = int(sys.argv[2]) if len(sys.argv) > 2 else 30
        gl = int(sys.argv[3]) if len(sys.argv) > 3 else 21600
        print(json.dumps(report(nd, gl), separators=(",", ":")))
    except Exception as e:  # never hand the panel a traceback
        print(json.dumps({"ok": False, "error": "%s: %s" % (type(e).__name__, e)}))

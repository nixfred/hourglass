# Surprise plugin #2: pick

Coordination: session 1 (~/Projects/surprise.plugin) took **Shipyard** (git
output counter) and rejected MSI fan cockpit + Session Radar. None of those here.

## PICK: Hourglass (`nixfred.hourglass`)
Screen-time for Omarchy. A local Python daemon listens to Hyprland's event
socket and logs which app class has focus, second by second, pausing when the
seat is idle (no cursor/window change for 3 min) or hyprlock is up.
Bar: a tiny hourglass + today's active time, coloured by the top app.
Panel (one screen, LAW 17): today's ring by app, 24-hour focus ribbon (every
minute coloured by the app that owned it), 7-day stacked bars, longest
unbroken focus streak, context switches/hour, and an in-place scrolling list
of apps with time + share.

Why: it is **OMW-021 on Fred's own wish list** ("Digital wellbeing dashboard:
opt-in per-app usage, daily/weekly charts, peak hours, focus sessions"),
status Planned, never built. Nothing on gus answers "where did today go?".
Shipyard shows output, Burn Bar shows AI spend; Hourglass shows attention.
Local only: data in ~/.local/share/hourglass, window classes only, never titles.

X check (2026-09-27): 65 recent omarchy posts, no concrete plugin requests;
the wish list is the stronger signal.

## Runner-ups
1. NPU Pulse: Intel NPU busy%/freq/mem from /sys/class/accel (gus embeds recall
   on the NPU). Rejected: tiny panel, Pulse family could absorb it as a lane.
2. Cinematic lock screen (OMW-018). Rejected: touches the secure auth path.

#!/usr/bin/env bash
# Usage: focus.sh PID
# Focuses the window of the process PID (find it with niri msg -j windows, swaymsg -t get_tree or
# hyprctl -j clients). Exits 1 when no window has that PID. niri is verified; Sway and Hyprland
# follow their IPC docs, untested.
set -euo pipefail
pid=${1:-}
[[ $pid =~ ^[0-9]+$ ]] || { echo "usage: focus.sh PID" >&2; exit 2; }
if [ -n "${NIRI_SOCKET:-}" ]; then
    id=$(niri msg -j windows | jq -r --argjson p "$pid" '[.[] | select(.pid == $p)][0].id // empty')
    [ -n "$id" ] || { echo "focus.sh: no window with pid $pid" >&2; exit 1; }
    niri msg action focus-window --id "$id"
elif [ -n "${SWAYSOCK:-}" ]; then
    swaymsg -t get_tree | jq -e --argjson p "$pid" '[.. | objects | select(.pid? == $p)] | length > 0' >/dev/null ||
        { echo "focus.sh: no window with pid $pid" >&2; exit 1; }
    swaymsg "[pid=$pid] focus" >/dev/null
elif [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    hyprctl -j clients | jq -e --argjson p "$pid" 'any(.[]; .pid == $p)' >/dev/null ||
        { echo "focus.sh: no window with pid $pid" >&2; exit 1; }
    hyprctl dispatch focuswindow "pid:$pid" >/dev/null
else
    echo "focus.sh: no niri, Sway or Hyprland session found" >&2
    exit 1
fi

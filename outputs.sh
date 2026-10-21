#!/usr/bin/env bash
# Usage: outputs.sh
# Prints the outputs of the running compositor in layout (logical) pixels, one per line, focused
# output first: NAME X Y W H. niri is verified; Sway and Hyprland follow their IPC docs, untested.
set -euo pipefail
list() {
if [ -n "${NIRI_SOCKET:-}" ]; then
    focused=$(niri msg -j focused-output | jq -r .name)
    niri msg -j outputs | jq -r --arg f "$focused" '[.[] | select(.logical != null)]
      | sort_by(.name != $f)[] | "\(.name) \(.logical.x) \(.logical.y) \(.logical.width) \(.logical.height)"'
elif [ -n "${SWAYSOCK:-}" ]; then
    swaymsg -t get_outputs -r | jq -r '[.[] | select(.active)] | sort_by(.focused | not)[]
      | "\(.name) \(.rect.x) \(.rect.y) \(.rect.width) \(.rect.height)"'
elif [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    hyprctl -j monitors | jq -r 'sort_by(.focused | not)[]
      | "\(.name) \(.x) \(.y) \(.width / .scale | floor) \(.height / .scale | floor)"'
else
    echo "outputs.sh: no niri, Sway or Hyprland session found" >&2
    exit 1
fi
}
out=$(list)
if [ -z "$out" ]; then
    echo "outputs.sh: no active output (display off or unplugged); screen tools cannot run" >&2
    exit 1
fi
printf '%s\n' "$out"

#!/usr/bin/env bash
# Usage: pointer.sh X Y [left|right|middle|double | drag X2 Y2 | scroll N]
# Puts the pointer on global pixel X,Y (the layout coordinates `shot.sh` reports) in one absolute
# jump through the wlr virtual-pointer protocol, then optionally clicks, drags the left button to
# X2,Y2, or scrolls N notches (positive is down). Exact on every output: two side-by-side
# 1920x1080 outputs, five targets on both, all landed on the pixel in 1-2 ms each (2026-10-21).
# The pointer is the owner's, so before it moves anything:
#   POINTER_WHY (required) says why keys and ax.py cannot reach the target; empty: exit 2.
#   It waits until the owner has had no input for POINTER_IDLE_MS (default 2000) and gives up
#   after POINTER_WAIT_S seconds (default 30): exit 4. Every call therefore takes at least
#   POINTER_IDLE_MS (ext-idle-notify starts its timer when asked, so past idleness does not count).
#   Unless a save from the last 30 minutes exists, it runs `cursor.sh ensure` first;
#   POINTER_AUTOSAVE=0 skips that (cursor.sh restore sets it).
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
if [ -z "${POINTER_WHY:-}" ]; then
    echo "pointer.sh: refused. Try keys (wtype, focus.sh) and ax.py first; if neither reaches the target, set POINTER_WHY to one line saying why." >&2
    exit 2
fi
[ -x "$here/vptr" ] && [ -x "$here/vidle" ] || { echo "vptr or vidle not built: run $here/setup.sh" >&2; exit 1; }
idle=0
"$here/vidle" "${POINTER_IDLE_MS:-2000}" "$(( ${POINTER_WAIT_S:-30} * 1000 ))" >/dev/null || idle=$?
case $idle in
0) ;;
4) echo "pointer.sh: owner is using the mouse or keyboard" >&2; exit 4 ;;
*) exit "$idle" ;;
esac
[ "${POINTER_AUTOSAVE:-1}" = 0 ] || "$here/cursor.sh" ensure >/dev/null || true
read -r minx miny w h < <("$here/outputs.sh" | awk '
  NR == 1 || $2 < x0 { x0 = $2 } NR == 1 || $3 < y0 { y0 = $3 }
  $2 + $4 > x1 { x1 = $2 + $4 } $3 + $5 > y1 { y1 = $3 + $5 }
  END { print x0, y0, x1 - x0, y1 - y0 }')
if [ "${3:-}" = drag ]; then
    exec "$here/vptr" $(( $1 - minx )) $(( $2 - miny )) "$w" "$h" drag $(( $4 - minx )) $(( $5 - miny ))
fi
exec "$here/vptr" $(( $1 - minx )) $(( $2 - miny )) "$w" "$h" "${@:3}"

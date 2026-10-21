#!/usr/bin/env bash
# Usage: pointer.sh X Y [left|right|middle|double | drag X2 Y2 | scroll N]
# Puts the pointer on global pixel X,Y (the layout coordinates `shot.sh` reports) in one absolute
# jump through the wlr virtual-pointer protocol, then optionally clicks, drags the left button to
# X2,Y2, or scrolls N notches (positive is down). Exact on every output: two side-by-side
# 1920x1080 outputs, five targets on both, all landed on the pixel in 1-2 ms each (2026-10-21).
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
[ -x "$here/vptr" ] || { echo "vptr not built: run $here/setup.sh" >&2; exit 1; }
read -r minx miny w h < <("$here/outputs.sh" | awk '
  NR == 1 || $2 < x0 { x0 = $2 } NR == 1 || $3 < y0 { y0 = $3 }
  $2 + $4 > x1 { x1 = $2 + $4 } $3 + $5 > y1 { y1 = $3 + $5 }
  END { print x0, y0, x1 - x0, y1 - y0 }')
if [ "${3:-}" = drag ]; then
    exec "$here/vptr" $(( $1 - minx )) $(( $2 - miny )) "$w" "$h" drag $(( $4 - minx )) $(( $5 - miny ))
fi
exec "$here/vptr" $(( $1 - minx )) $(( $2 - miny )) "$w" "$h" "${@:3}"

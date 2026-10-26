#!/usr/bin/env bash
# Usage: shot.sh [OUTPUT | "X,Y WxH"] [file]
# Captures one output (default: the focused one) or a region, as JPEG, and prints
#   <file> origin=X,Y size=WxH
# A pixel (px,py) in the image is the global point (X+px, Y+py): pass that to pointer.sh.
# One output at a time keeps the image under the model's size limit; a 3840-wide desktop is not.
# The cursor is left out; SHOT_CURSOR=1 draws it (grim -c).
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
target=${1:-}
file=${2:-${TMPDIR:-/tmp}/computer-use/shot.jpg}
mkdir -p "$(dirname "$file")"
if [[ $target == *,*\ *x* ]]; then
    geom=$target
else
    read -r _ x y w h < <("$here/outputs.sh" | awk -v n="$target" 'n == "" || $1 == n' | head -1) ||
        { echo "no output ${target:-focused}" >&2; exit 1; }
    geom="$x,$y ${w}x$h"
fi
cursor=()
[ "${SHOT_CURSOR:-}" = 1 ] && cursor=(-c)
grim "${cursor[@]}" -g "$geom" -t jpeg -q 80 "$file"
echo "$file origin=${geom% *} size=${geom#* }"

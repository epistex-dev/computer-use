#!/usr/bin/env bash
# Usage: cursor.sh save | restore
# The agent shares the owner's single pointer. `save` prints and stores the pointer's global
# position X Y in ${XDG_RUNTIME_DIR:-/tmp}/computer-use-cursor; `restore` moves the pointer back
# there (a move, no click), deletes the file and prints X Y. Exit 1: no position could be read
# (save) or none is saved (restore); exit 2: bad usage.
# niri has no IPC for the pointer (niri-wm/niri#4348), so save diffs `grim` against `grim -c`
# taken back to back on each output. The pointer is the only thing that differs on a still screen.
# It retries up to 3 times when the diff is empty (pointer hidden) or large (screen changing).
# Measured on niri with Bibata-Modern-Ice 24 (2026-10-26): the arrow's faint outer halo shows or
# not with the background, so its box varies by up to 4 px per side; the box centre does not move.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
state=${XDG_RUNTIME_DIR:-/tmp}/computer-use-cursor
usage() { echo "usage: cursor.sh save|restore" >&2; exit 2; }
[ $# -eq 1 ] || usage
case $1 in
save)
    pos=$(python3 -I - "$here" <<'PY'
import concurrent.futures as cf, io, subprocess, sys, time
from PIL import Image, ImageChops

here = sys.argv[1]
THRESH = 32       # max channel difference that counts as pointer; weaker pixels are the halo
MAX_BOX = 96      # a larger diff is the screen changing, not a pointer
ARROW_CENTRE = (7, 11)   # hotspot to the centre of the arrow's box: 18x22 on light, 14x18 on black

def fail(why):
    print(f'cursor.sh: cannot read the pointer position: {why}', file=sys.stderr)
    sys.exit(1)

def grab(geom, cursor):
    cmd = ['grim', *(['-c'] if cursor else []), '-g', geom, '-t', 'ppm', '-']
    return Image.open(io.BytesIO(subprocess.run(cmd, check=True, capture_output=True).stdout)).convert('RGB')

def diff(out):
    _, x, y, w, h = out
    geom = f'{x},{y} {w}x{h}'
    d = ImageChops.difference(grab(geom, False), grab(geom, True))
    r, g, b = d.split()
    box = ImageChops.lighter(ImageChops.lighter(r, g), b).point(lambda v: 255 if v > THRESH else 0).getbbox()
    return box and (x + box[0], y + box[1], x + box[2], y + box[3])

try:
    outs = [(n, *map(int, rest)) for n, *rest in (l.split() for l in subprocess.run(
        [f'{here}/outputs.sh'], check=True, capture_output=True, text=True).stdout.splitlines())]
    right = max(x + w for _, x, _, w, _ in outs)
    bottom = max(y + h for _, _, y, _, h in outs)
    why = ''
    for attempt in range(3):
        if attempt:
            time.sleep(0.2)
        # One pair per output in parallel; the cursor straddling two outputs shows on both.
        with cf.ThreadPoolExecutor(len(outs)) as ex:
            boxes = [b for b in ex.map(diff, outs) if b]
        if not boxes:
            why = 'no pointer in the screenshots (hidden?)'
            continue
        x0, y0 = min(b[0] for b in boxes), min(b[1] for b in boxes)
        x1, y1 = max(b[2] for b in boxes), max(b[3] for b in boxes)
        if x1 - x0 > MAX_BOX or y1 - y0 > MAX_BOX:
            why = f'the screen is changing (diff {x1 - x0}x{y1 - y0})'
            continue
        w, h = x1 - x0, y1 - y0
        if x1 >= right or y1 >= bottom:
            # The box is cut off at the screen edge, so only its top-left corner is true: assume the arrow.
            print(x0 + 1, y0 - 1)
        elif h - w <= 6:
            print((x0 + x1) // 2 - ARROW_CENTRE[0], (y0 + y1) // 2 - ARROW_CENTRE[1])
        else:
            # Narrow shapes such as the I-beam have the hotspot at the centre.
            print((x0 + x1) // 2, (y0 + y1) // 2)
        sys.exit(0)
    fail(why)
except subprocess.CalledProcessError as e:
    fail(f'{e.cmd[0]} failed: {(e.stderr or "").strip()}')
PY
    ) || exit 1
    echo "$pos" > "$state"
    echo "$pos"
    ;;
restore)
    [ -s "$state" ] || { echo "cursor.sh: no saved position (run save first)" >&2; exit 1; }
    read -r x y < "$state"
    [[ $x =~ ^-?[0-9]+$ && $y =~ ^-?[0-9]+$ ]] || { echo "cursor.sh: bad state in $state" >&2; exit 1; }
    "$here/pointer.sh" "$x" "$y"
    rm -f "$state"
    echo "$x $y"
    ;;
*) usage ;;
esac

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
# Shapes, as hotspot offsets from the centre of the diff box (Bibata-Modern-Ice 24, measured):
ARROW_CENTRE = (7, 11)   # box 18x22 on light, 14x18 on black; hotspot is the tip
HAND_CENTRE = (2, 11)    # link hand, box 22x22 on light, 18x19 on black; hotspot is the fingertip
IBEAM_HALF = 11          # I-beam, box 12x22 on light, 8x19 on black; hotspot is its centre
# Crosshairs and other symmetric shapes (box 20x20) have the hotspot at the centre.

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
    mask = ImageChops.lighter(ImageChops.lighter(r, g), b).point(lambda v: 255 if v > THRESH else 0)
    box = mask.getbbox()
    return box and ((x + box[0], y + box[1], x + box[2], y + box[3]), mask.crop(box))

def symmetric(shape):
    # Top-bottom mirror image: the hand is not (fingers above, wrist below), the others are.
    flipped = ImageChops.difference(shape, shape.transpose(Image.FLIP_TOP_BOTTOM)).point(lambda v: 255 if v else 0)
    return flipped.histogram()[255] <= shape.histogram()[255] // 10

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
            hits = [h for h in ex.map(diff, outs) if h]
        if not hits:
            why = 'no pointer in the screenshots (hidden?)'
            continue
        x0, y0 = min(b[0] for b, _ in hits), min(b[1] for b, _ in hits)
        x1, y1 = max(b[2] for b, _ in hits), max(b[3] for b, _ in hits)
        if x1 - x0 > MAX_BOX or y1 - y0 > MAX_BOX:
            why = f'the screen is changing (diff {x1 - x0}x{y1 - y0})'
            continue
        w, h = x1 - x0, y1 - y0
        cx, cy = (x0 + x1) // 2, (y0 + y1) // 2
        clip_x, clip_y = x1 >= right, y1 >= bottom
        arrow_w, arrow_h = 12 <= w <= 20, 16 <= h <= 24
        if clip_x or clip_y:
            # Cut off at the screen edge: only the sides still whole can be trusted.
            # At the bottom edge the I-beam keeps its width (8 or 12) and is 11 or more rows tall; the
            # arrow's visible part narrows as it is cut, and is 13 or wider once it is 11 rows tall.
            if clip_y and not clip_x and w <= 12 and h >= 11:
                print(cx, y0 + IBEAM_HALF)
            else:
                print(x0 + 1, y0 - 1)        # anything else is assumed to be the arrow, tip at the top-left
        elif arrow_w and arrow_h and 2 <= h - w <= 6:
            print(cx - ARROW_CENTRE[0], cy - ARROW_CENTRE[1])
        else:
            shape = Image.new('L', (w, h))
            for (bx0, by0, _, _), m in hits:
                shape.paste(m, (bx0 - x0, by0 - y0))
            if symmetric(shape):
                print(cx, cy)
            else:
                print(cx - HAND_CENTRE[0], cy - HAND_CENTRE[1])
        sys.exit(0)
    fail(why)
except subprocess.CalledProcessError as e:
    fail(f'{e.cmd[0]} failed: {(e.stderr or "").strip()}')
except OSError as e:
    fail(str(e))
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

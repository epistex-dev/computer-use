#!/usr/bin/env bash
# Usage: find.sh "label" [OUTPUT | "X,Y WxH"]
#   FIND_SCALE=3 for small text (default 2); FIND_LANG=eng+deu etc. (default eng, plus vie if installed)
# OCRs one output (default: the focused one) or a region and prints every line where the label
# appears, exact lines first, then by confidence, as global centre points ready for pointer.sh:
#   X Y conf "line text"
# Exits 1 when nothing matches. Matching ignores case, spaces and diacritics and
# treats l/I/1 and o/0 alike, because tesseract drops marks and glues words on UI text
# (2026-10-21: "Tìm kiếm" read as "Tim kiém", "Cú Đêm AI" as "CúĐêmAIv").
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
read -r _ origin _ < <("$here/shot.sh" "${2:-}" "$tmp/s.jpg")
origin=${origin#origin=}
lang=${FIND_LANG:-$(tesseract --list-langs 2>/dev/null | grep -qx vie && echo eng+vie || echo eng)}
python3 -I - "$tmp" "$1" "${origin%,*}" "${origin#*,}" "${FIND_SCALE:-2}" "$lang" <<'PY'
import csv, subprocess, sys, unicodedata
from PIL import Image, ImageOps, ImageStat
tmp, label, ox, oy, scale, lang = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]), sys.argv[6]

im = Image.open(f'{tmp}/s.jpg').convert('L')
if ImageStat.Stat(im).mean[0] < 128:  # tesseract reads dark text on light ground
    im = ImageOps.invert(im)
im = ImageOps.autocontrast(im.resize((im.width * scale, im.height * scale), Image.LANCZOS))
im.save(f'{tmp}/p.png')
SAME = str.maketrans({'l': 'i', '1': 'i', '|': 'i', '0': 'o', 'đ': 'd'})
def norm(s):
    s = ''.join(c for c in unicodedata.normalize('NFD', s.casefold()) if not unicodedata.combining(c))
    return ''.join(c for c in s.translate(SAME) if c.isalnum())

def ocr_lines(psm):
    subprocess.run(['tesseract', f'{tmp}/p.png', f'{tmp}/o', '-l', lang, '--psm', psm, 'tsv'],
                   check=True, capture_output=True)
    lines = {}
    for r in csv.DictReader(open(f'{tmp}/o.tsv', encoding='utf-8'), delimiter='\t', quoting=csv.QUOTE_NONE):
        if r['level'] == '5' and r['text'].strip():
            lines.setdefault((r['block_num'], r['par_num'], r['line_num']), []).append(r)
    return lines.values()

want = norm(label)
hits = []
# Sparse mode (11) suits a whole screen but can skip outlined buttons that block mode (6) reads,
# so block mode runs until a line equals the label (2026-10-21: the "Cho phép" button of a
# Brave dialog, missed whole-screen behind its title "Cho phép gỡ lỗi từ xa?", and in a 600x50 crop).
for psm in ('11', '6'):
    for words in ocr_lines(psm):
        words.sort(key=lambda r: int(r['word_num']))
        text, owner = '', []          # owner[i] = (word, index of char i inside that word's key)
        for w in words:
            k = norm(w['text'])
            owner += [(w, j, len(k)) for j in range(len(k))]
            text += k
        start = text.find(want) if want else -1
        while start >= 0:
            span = owner[start:start + len(want)]
            if span[0][1] != 0:  # starts mid-word: "Huỷ" inside "chuyển"
                start = text.find(want, start + 1)
                continue
            def x_at(entry, edge):  # interpolate inside a glued word
                w, j, n = entry
                return int(w['left']) + int(w['width']) * (j + edge) / n
            l, r_ = x_at(span[0], 0), x_at(span[-1], 1)
            used = {id(e[0]): e[0] for e in span}.values()
            t = min(int(w['top']) for w in used); b = max(int(w['top']) + int(w['height']) for w in used)
            conf = min(float(w['conf']) for w in used)
            hits.append((text == want, conf, ox + round((l + r_) / 2 / scale), oy + round((t + b) / 2 / scale),
                         ' '.join(w['text'] for w in words)))
            start = text.find(want, start + 1)
    if any(exact for exact, *_ in hits):
        break

# A line that is exactly the label (a button) beats a longer line that merely contains it
# (2026-10-21: "Deny" matched a chat message above the real Deny button).
for _, conf, x, y, line in sorted(hits, key=lambda h: (not h[0], -h[1])):
    print(f'{x} {y} {conf:.0f} "{line}"')
sys.exit(0 if hits else 1)
PY

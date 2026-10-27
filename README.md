# computer-use: Linux Wayland computer use for AI agents

An agent skill that lets Claude Code, Codex, or any agent that reads `SKILL.md` operate a Linux
Wayland desktop itself: screenshots, exact clicks, drags and scrolls on multi-monitor layouts,
keyboard input, OCR text search, and accessibility-tree actions. Built and measured on niri;
Sway and Hyprland are wired through their IPC but untested.

Anthropic's built-in computer use targets macOS and Windows, and most Linux tools either assume
X11 or move the pointer with `ydotool`, whose "absolute" move is a relative sweep that lands on
the wrong monitor. This skill takes the routes that measured exact:

| Need | Route | Why |
| --- | --- | --- |
| Point, click, drag, scroll | `vptr`, a 100-line C client of the wlr virtual-pointer protocol | One absolute jump over the whole layout: exact on every output, 1-2 ms, no root, no `/dev/uinput` |
| See | `grim` per output or region | No portal permission prompt; one output stays under the model's image size limit; the cursor is hidden unless `SHOT_CURSOR=1` (`grim -c`) |
| Find a label | `tesseract` with Vietnamese-aware fuzzy matching | Folds diacritics, glued words and l/I confusions that OCR produces on UI text |
| Press, check, fill without coordinates | `ax.py` over AT-SPI | Works on unfocused windows and through layout shifts, under 0.2 s; `set` reads the value back (exit 3 on mismatch) and leaves the clipboard alone except for emoji and values with a tab or newline; GTK4 check buttons expose no action, so use `find.sh` and `pointer.sh` there |
| Type | `wtype`, then check; the clipboard for emoji | `wtype` typed Vietnamese right 10/10 in Chromium on 2026-10-26 but dropped characters on 2026-10-21; it turns emoji into U+F600 |

## Install

```sh
npx skills add epistex-dev/computer-use        # any agent the skills CLI knows; or:
git clone https://github.com/epistex-dev/computer-use ~/.claude/skills/computer-use
```

Then run `./setup.sh` in the installed directory.

`setup.sh` is idempotent. It installs packages with pacman on Arch, builds `vptr`, turns on
AT-SPI, and proves a pointer drag with `slurp`; exit 0 means ready. On other distros, install
these first (names untested):

| Arch | Debian / Ubuntu | Fedora |
| --- | --- | --- |
| `grim slurp wtype wl-clipboard jq gcc wayland tesseract tesseract-data-eng python-pillow python-gobject at-spi2-core` | `grim slurp wtype wl-clipboard jq gcc libwayland-dev libwayland-bin tesseract-ocr python3-pil python3-gi gir1.2-atspi-2.0` | `grim slurp wtype wl-clipboard jq gcc wayland-devel tesseract python3-pillow python3-gobject at-spi2-core` |

Add an OCR language pack (`tesseract-data-vie`, `tesseract-ocr-vie`, ...) and set `FIND_LANG`
for languages other than English; Vietnamese is picked up automatically when installed.

## Use

The agent reads [SKILL.md](SKILL.md). By hand:

```sh
./shot.sh                       # /tmp/computer-use/shot.jpg origin=1920,0 size=1920x1080
./find.sh "Allow"               # 3046 363 92 "Allow"
./pointer.sh 3046 363 left
./pointer.sh 500 400 drag 700 600
./pointer.sh 1000 500 scroll 5
./cursor.sh save                # 300 200: the owner's pointer, read by diffing grim and grim -c
./cursor.sh restore             # moves it back (a move, no click) and forgets it
./ax.py 12345 do "Allow"        # PID from niri msg -j windows
./ax.py 12345 set "Search" "xin chào"   # exit 3 and mismatch: got "..." if the field differs
./focus.sh 12345                # focus that process's window
SHOT_CURSOR=1 ./shot.sh         # same output line, cursor drawn
```

## Credits

- [agent-sh/computer-use-linux](https://github.com/agent-sh/computer-use-linux) (MIT), whose
  accessibility-first design led to `ax.py`.
- `wlr-virtual-pointer-unstable-v1.xml` is © 2019 Josef Gajdusek under the MIT license in the file.

## License

MIT, see [LICENSE](LICENSE).

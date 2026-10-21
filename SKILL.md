---
name: computer-use
description: "Computer use on Linux Wayland (niri, Sway, Hyprland): see the screen, click, drag, scroll, type and press keys yourself, find on-screen text by OCR, and press buttons or fill fields through the accessibility tree. Use for anything no API reaches: native apps, system and permission dialogs, the browser's own UI (settings and internal pages, extension popups, consent prompts), and any step you would otherwise hand the user to click, toggle or type. Content inside a web page is better served by a browser-automation tool."
---

# Computer use on Linux Wayland

Run these from this skill's directory:

```
./shot.sh [OUTPUT | "X,Y WxH"]          # look: prints <file> origin=X,Y size=WxH; Read the file
./find.sh "label" [OUTPUT | "X,Y WxH"]   # OCR: X Y conf "line" per match, exact lines first
./ax.py PID list [text] | do "name" | set "name" "value"   # accessibility tree, no coordinates
./pointer.sh X Y [left|right|middle|double | drag X2 Y2 | scroll N]
wtype -M ctrl l -m ctrl                  # key combo; wtype -k Return, -k Escape, -k Tab
wtype 'ascii text'                       # type (non-ASCII: trap 4)
./outputs.sh                             # NAME X Y W H per output, focused first
```

## Check first

`test -x vptr && echo ok` must print `ok`; otherwise run `./setup.sh`. It installs the tools (on
Arch; elsewhere it names what is missing), builds `vptr`, turns on accessibility, and ends by
proving a pointer drag with slurp. Exit 0 means ready.

## Pick the route

1. **Keys** when a shortcut reaches it: no coordinates at all. A browser's internal page is
   Ctrl+L, its URL, Enter (`brave 'brave://...'` from a shell opens nothing).
2. **`ax.py`** when the app exposes an accessibility tree: GTK and Qt apps started after setup,
   Chromium and Electron started with `--force-renderer-accessibility`. It works on unfocused
   windows, ignores layout shifts and answers in under 0.2 s. `list` shows controls with their
   actions, `do` presses, checks or opens one, `set` fills a field. Chromium refuses direct text
   writes, so `set` focuses the field, selects all and pastes, which replaces the clipboard. Get
   the PID from the window list: `niri msg -j windows`, `swaymsg -t get_tree`, `hyprctl -j clients`.
3. **`find.sh`, then `pointer.sh`**, for everything else: about 2 s per output and no image tokens.
4. **A screenshot and coordinates** when there is no text to find.

## One step

1. **Look.** `./shot.sh`, Read the file, and say in one sentence what it shows. This screenshot
   decides the click, so read it in its own call before the call that clicks (2026-10-21: a
   before-shot taken in the same command as the click showed another app where the target page
   had been, and the click landed on that app's Home button).
2. **Act and capture the result** in one call: `./pointer.sh X Y left && sleep 0.7 && ./shot.sh`.
3. **Check.** That after-shot is the next step's look, unless something may have moved since.
   The same action twice with an unchanged screen means switch route.

`find.sh` cannot tell a dialog's title from its button when both hold the label, so with several
lines Read a shot to pick. A short word in an outlined button ("OK", "Huỷ") needs a tight crop:
`FIND_SCALE=3 ./find.sh "Huỷ" "X,Y 140x50"`.

Dialogs stack: each request opens its own, drawn identically on top of the last. A click that
seems to do nothing may have closed one and revealed the next (2026-10-21: three
remote-debugging prompts took three clicks).

## The traps, all measured

1. **The cursor is invisible in screenshots.** `pointer.sh` is exact, so the pointer is where
   your last `pointer.sh` put it unless the owner moved the mouse.
2. **Tiling layouts shift** whenever a window opens or closes (niri scrolls sideways).
   Coordinates from a screenshot taken before that shift point at a different window.
3. **Focus may follow the mouse**, so a pointer jump can move keyboard focus. Before typing,
   check the focused window (`niri msg focused-window`, `hyprctl activewindow`, or the
   `focused` node of `swaymsg -t get_tree`) and stop if it is not the one you meant.
4. **Typing is ASCII only.** `wtype` drops some characters in Chromium (2026-10-21: "đường đi"
   arrived as "ường i"). Vietnamese, emoji or long text go through the clipboard:
   `printf %s "xin chào" | wl-copy`, then `wtype -M ctrl v -m ctrl` (Ctrl+Shift+V in a terminal).
   This replaces the owner's clipboard; say so in your report.
5. **Other tools may ask for standing permissions.** A portal screenshot request shows "Allow
   apps to take screenshots at any time?". `grim` needs no permission, so deny prompts you did
   not expect.

## Coordinates and cost

`shot.sh` captures one output (default: the focused one), so the image stays inside the model's
size limit; a 3840-wide desktop gets downscaled and coordinates drift. A pixel `(px,py)` in the
image is the global point `(originX+px, originY+py)`, which is what `pointer.sh` takes. To zoom,
capture a region: `./shot.sh "X,Y WxH"` keeps native resolution and prints its origin. If you
scale an image down, scale its coordinates back up before clicking.

## Verifying a pointer position

slurp is the ruler, since the cursor never appears in a screenshot:
`slurp -f '%x,%y %wx%h' & sleep 1.2; ./pointer.sh X Y drag $((X+200)) $((Y+200))` prints
`X,Y 201x201`. Kill slurp if a step fails, or its overlay keeps grabbing the owner's mouse.

## Measured on

- **niri, two 1920x1080 outputs side by side** (2026-10-21). Pointer, drag and scroll exact on
  both outputs; a jump takes 1-2 ms; Chromium scrolls 120 px per notch. `ax.py list` 0.14 s.
  `find.sh` about 2 s per output.
- **Sway, Hyprland**: `outputs.sh` follows their IPC; untested.
- **GNOME** has no wlr virtual-pointer or screencopy, so `pointer.sh` and `shot.sh` do not run.
  KDE is untested.

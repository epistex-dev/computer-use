#!/usr/bin/env -S python3 -I
"""Drive an app through its accessibility tree (AT-SPI): no coordinates, no focus needed.

  ax.py PID list [TEXT]          controls whose name contains TEXT: path role "name" [actions]
  ax.py PID do "name" [ACTION]   invoke ACTION (default the first one) on the best match
  ax.py PID set "name" "value"   replace a field's text, then read it back; where the app refuses
                                 (Chromium), focus the field, select all and type the value
                                 (emoji go through the clipboard, which this replaces)

PID comes from `niri msg -j windows`. Names match like find.sh: case, spaces and diacritics
are folded, an exact name beats a substring. Exits 1 when nothing matches, 3 when `set` reads
back something other than the value (stderr: mismatch: got "...").
"""
import json, subprocess, sys, time, unicodedata, warnings
import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi, GLib

warnings.filterwarnings('ignore', category=DeprecationWarning)  # get_action_name has no replacement in python-gobject
GLib.log_set_handler('atspi', GLib.LogLevelFlags.LEVEL_WARNING, lambda *_: None)  # niri's own node has no cache

CONTROLS = {'push button', 'toggle button', 'check box', 'radio button', 'link', 'entry',
            'password text', 'combo box', 'menu item', 'check menu item', 'radio menu item',
            'page tab', 'list item', 'tree item', 'slider', 'spin button', 'text', 'button'}
MAX_NODES = 20000

def fold(s):
    s = ''.join(c for c in unicodedata.normalize('NFD', (s or '').casefold()) if not unicodedata.combining(c))
    return ''.join(c for c in s.replace('đ', 'd') if c.isalnum())

def app_for(pid):
    desktop = Atspi.get_desktop(0)
    for i in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(i)
        if app and app.get_process_id() == pid:
            return app
    sys.exit(f'pid {pid} exposes no accessibility tree. Enable it with setup.sh; Chromium and '
             f'Electron apps also need --force-renderer-accessibility at launch.')

def walk(root):
    stack: list = [((), root)]
    seen = 0
    while stack and seen < MAX_NODES:
        path, node = stack.pop()
        seen += 1
        try:
            n = node.get_child_count()
            yield path, node
        except Exception:  # a node can vanish mid-walk
            continue
        stack.extend((path + (i,), node.get_child_at_index(i)) for i in reversed(range(n)))

def actions(node):
    act = node.get_action_iface()
    return [Atspi.Action.get_action_name(act, i) or str(i) for i in range(act.get_n_actions())] if act else []

def matches(pid, text, usable=lambda node: True):
    want, hits = fold(text), []
    for path, node in walk(app_for(pid)):
        if node.get_role_name() not in CONTROLS or not usable(node):
            continue
        name = node.get_name() or ''
        if not want or want in fold(name):
            hits.append((fold(name) != want, len(name), path, node))
    hits.sort(key=lambda h: h[:2])
    return [(p, n) for *_, p, n in hits]

def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    pid, cmd, rest = int(sys.argv[1]), sys.argv[2], sys.argv[3:]
    usable = {'do': actions, 'set': lambda n: n.get_role_name() in ('entry', 'password text', 'text')
              or n.get_editable_text_iface()}.get(cmd, lambda n: True)
    found = matches(pid, rest[0] if rest else '', usable)
    if cmd == 'list':
        for path, node in found[:200]:
            print('.'.join(map(str, path)), node.get_role_name(), f'"{node.get_name()}"', actions(node))
        sys.exit(0 if found else 1)
    if not found:
        sys.exit(1)
    path, node = found[0]
    if cmd == 'do':
        names = actions(node)
        i = names.index(rest[1]) if len(rest) > 1 else 0
        node.get_action_iface().do_action(i)
        print(node.get_role_name(), f'"{node.get_name()}"', names[i])
    elif cmd == 'set':
        value = rest[1]
        editable = node.get_editable_text_iface()
        if not (editable and editable.set_text_contents(value)):
            window = subprocess.run(['niri', 'msg', '-j', 'windows'], capture_output=True, text=True)
            ids = [w['id'] for w in json.loads(window.stdout) if w['pid'] == pid]
            subprocess.run(['niri', 'msg', 'action', 'focus-window', '--id', str(ids[0])], check=True)
            node.get_component_iface().grab_focus()
            # wtype turns characters outside the BMP into U+F600 and control characters into
            # keypresses: Tab changes field, Return submits
            if any(ord(c) > 0xFFFF or ord(c) < 0x20 or ord(c) == 0x7F for c in value):
                print('ax.py: clipboard replaced to paste a control or non-BMP character', file=sys.stderr)
                subprocess.run(['wl-copy', '--', value], check=True, stdout=subprocess.DEVNULL)
                time.sleep(0.1)
                subprocess.run(['wtype', '-M', 'ctrl', 'a', '-m', 'ctrl', '-M', 'ctrl', 'v', '-m', 'ctrl'], check=True)
            else:
                subprocess.run(['wtype', '-M', 'ctrl', 'a', '-m', 'ctrl', '--', value], check=True)
        text = node.get_text_iface()
        for _ in range(10):  # Chromium updates its tree a moment after the keys land
            time.sleep(0.1)
            got = Atspi.Text.get_text(text, 0, -1) if text else ''
            if got == value:
                break
        if got != value:
            print(f'mismatch: got "{got}"', file=sys.stderr)
            sys.exit(3)
        print(node.get_role_name(), f'"{node.get_name()}"', '=', repr(got))
    else:
        sys.exit(__doc__)

main()

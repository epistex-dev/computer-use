"""Seam tests for pointer.sh's gate, yield and auto-save.

Run them only on a private Wayland seat, never on the owner's compositor, for example the one
agent-seat.sh starts:  eval "$(./agent-seat.sh env)"; python3 -m unittest tests/test_pointer_yield.py
They refuse to run when NIRI_SOCKET is set or SWAYSOCK is not.
"""
import os
import pathlib
import signal
import subprocess
import tempfile
import time
import unittest

SKILL = pathlib.Path(__file__).resolve().parent.parent
POINTER, CURSOR, VPTR, OUTPUTS = (str(SKILL / n) for n in ("pointer.sh", "cursor.sh", "vptr", "outputs.sh"))
SEAT_OK = not os.environ.get("NIRI_SOCKET") and os.environ.get("SWAYSOCK") and os.environ.get("WAYLAND_DISPLAY")


def layout():
    rows = [l.split() for l in subprocess.run([OUTPUTS], capture_output=True, text=True, check=True).stdout.splitlines()]
    x0, y0 = min(int(r[1]) for r in rows), min(int(r[2]) for r in rows)
    return x0, y0, max(int(r[1]) + int(r[3]) for r in rows) - x0, max(int(r[2]) + int(r[4]) for r in rows) - y0


@unittest.skipUnless(SEAT_OK, "needs a private sway seat (agent-seat.sh env); never the owner's niri")
class PointerYield(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.mkdtemp(prefix="cu-yield-build-")
        xml = str(SKILL / "wlr-virtual-pointer-unstable-v1.xml")
        for mode, out in (("client-header", "wlr-virtual-pointer-unstable-v1-client-protocol.h"), ("private-code", "protocol.c")):
            subprocess.run(["wayland-scanner", mode, xml, f"{cls.build}/{out}"], check=True)
        cls.hold_bin = f"{cls.build}/hold"
        subprocess.run(["gcc", "-I", cls.build, "-o", cls.hold_bin, str(SKILL / "tests" / "hold.c"), f"{cls.build}/protocol.c",
                        "-lwayland-client"], check=True)

    @classmethod
    def tearDownClass(cls):
        subprocess.run(["rm", "-rf", cls.build])

    def setUp(self):
        self.run_dir = tempfile.mkdtemp(prefix="cu-yield-test-")
        wd = os.environ["WAYLAND_DISPLAY"]
        real_run = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
        self.env = dict(os.environ, XDG_RUNTIME_DIR=self.run_dir,   # state files stay out of the owner's runtime dir
                        WAYLAND_DISPLAY=wd if os.path.isabs(wd) else os.path.join(real_run, wd),
                        POINTER_IDLE_MS="800", POINTER_WAIT_S="30")
        self.env.pop("POINTER_WHY", None)
        self.state = pathlib.Path(self.run_dir) / "computer-use" / "cursor"
        self.procs = []
        self.minx, self.miny, self.w, self.h = layout()
        self.holder = None
        # cursor.sh's hotspot offsets are Bibata's and sway draws another theme, so measure its offset once.
        self.place(100, 100)
        got = self.read_pointer()
        self.off = (got[0] - 100, got[1] - 100)

    def tearDown(self):
        for p in self.procs:
            if p.poll() is None:
                p.kill()
            p.wait()
        subprocess.run(["rm", "-rf", self.run_dir])

    def spawn(self, *cmd, **kw):
        p = subprocess.Popen(cmd, env=self.env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kw)
        self.procs.append(p)
        return p

    def new_holder(self):
        """Sway draws the cursor in only the first `grim -c` after a pointer device appears (measured), and
        a headless seat has no device of its own: a fresh holder gives the next read its one good capture."""
        if self.holder:
            self.holder.kill(); self.holder.wait()
        self.holder = self.spawn(self.hold_bin)
        self.assertEqual(self.holder.stdout.readline().strip(), "ready")

    def place(self, x, y):
        """Put the pointer on x,y directly through vptr: test setup, not the code under test."""
        self.new_holder()
        subprocess.run([VPTR, str(x - self.minx), str(y - self.miny), str(self.w), str(self.h)], env=self.env, check=True)

    def jiggle(self, seconds, around=(100, 100), end=None):
        """A second process standing in for the owner: a pointer move every 0.5 s, the last at seconds-0.5
        (`end`: the owner's pointer comes to rest there, as one more move at the very end)."""
        script = (f'for i in $(seq {int(seconds * 2)}); do "{VPTR}" $(({around[0]}+i%2*10-{self.minx})) '
                  f'{around[1] - self.miny} {self.w} {self.h}; sleep 0.5; done')
        if end:
            script += f'; "{VPTR}" {end[0] - self.minx} {end[1] - self.miny} {self.w} {self.h}'
        return self.spawn("bash", "-c", script)

    def read_pointer(self):
        """cursor.sh save in a scratch state dir; returns (x, y)."""
        self.new_holder()
        r = subprocess.run([CURSOR, "save"], env=dict(self.env, XDG_RUNTIME_DIR=tempfile.mkdtemp(dir=self.run_dir)),
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        return tuple(map(int, r.stdout.split()))

    def assertNear(self, got, want, tol, off=True):
        if off:
            want = (want[0] + self.off[0], want[1] + self.off[1])
        self.assertTrue(all(abs(g - w) <= tol for g, w in zip(got, want)), f"pointer at {got}, want {want} +-{tol}")

    def ruler(self):
        if not self.holder:
            self.new_holder()
        p = self.spawn("slurp", "-f", "%x,%y %wx%h")
        time.sleep(1.2)
        subprocess.run([VPTR, "150", "150", str(self.w), str(self.h)], env=self.env, check=True)   # slurp's pointer enter
        time.sleep(0.3)
        return p

    def seed_state(self):
        self.state.parent.mkdir(parents=True, exist_ok=True)
        self.state.write_text("50 50\n")

    def drag_and_measure(self, activity_s=0, with_ruler=True):
        env = dict(self.env, POINTER_WHY="test: no key or accessibility route")
        ruler = self.ruler() if with_ruler else None
        if not with_ruler:
            self.new_holder()
        if activity_s:
            self.jiggle(activity_s)
        t0 = time.monotonic()
        r = subprocess.run([POINTER, "400", "300", "drag", "600", "500"], env=env, capture_output=True, text=True)
        elapsed = time.monotonic() - t0
        out = ""
        if ruler:
            try:
                out, _ = ruler.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                pass
        return r, elapsed, out.strip()

    # (a) the gate fails closed
    def test_a_no_reason_no_move(self):
        self.place(300, 250)
        r = subprocess.run([POINTER, "700", "500", "left"], env=self.env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 2, r.stderr)
        for word in ("POINTER_WHY", "keys", "ax.py"):
            self.assertIn(word, r.stderr)
        self.assertNear(self.read_pointer(), (300, 250), 1)

    # (b) an idle owner: the drag lands as before
    def test_b_idle_owner_drag_lands(self):
        self.seed_state()
        for _ in range(2):   # slurp on a headless sway sometimes misses the drag (it never exits); one retry
            r, _, out = self.drag_and_measure()
            self.assertEqual(r.returncode, 0, r.stderr)
            if out:
                break
        self.assertRegex(out, r"^400,300 20[01]x20[01]$")

    # (c) owner activity for 5 s: wait, then act after the activity plus the idle window
    def test_c_waits_for_activity_to_stop(self):
        self.seed_state()
        r, elapsed, _ = self.drag_and_measure(activity_s=5, with_ruler=False)
        print(f"\n(c) elapsed {elapsed:.2f} s", flush=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNear(self.read_pointer(), (600, 500), 1)    # the drag ended where it was aimed
        self.assertGreaterEqual(elapsed, 5.0)    # last move at ~4.5 s + the 0.8 s idle window; no yield would take ~0.8 s
        self.assertLess(elapsed, 8.5)

    # (d) activity that outlasts POINTER_WAIT_S: exit 4, nothing happens
    def test_d_timeout_exit_4_no_action(self):
        self.seed_state()
        ruler = self.ruler()
        jig = self.jiggle(9, around=(100, 100))
        env = dict(self.env, POINTER_WHY="test: no key or accessibility route", POINTER_WAIT_S="3")
        t0 = time.monotonic()
        r = subprocess.run([POINTER, "400", "300", "drag", "600", "500"], env=env, capture_output=True, text=True)
        elapsed = time.monotonic() - t0
        self.assertEqual(r.returncode, 4, r.stderr)
        self.assertIn("owner is using the mouse or keyboard", r.stderr)
        self.assertTrue(2.8 <= elapsed < 5, f"gave up after {elapsed:.2f} s")
        jig.kill(); jig.wait()
        time.sleep(1)
        self.assertIsNone(ruler.poll(), "slurp finished: a drag happened")
        self.assertNear(self.read_pointer(), (105, 100), 12)    # still in the jiggler's spot, not at 400,300

    # (e) the first call saves the owner's position; restore puts it back
    def test_e_autosave_and_restore(self):
        self.place(250, 220)
        self.assertFalse(self.state.exists())
        env = dict(self.env, POINTER_WHY="test: no key or accessibility route")
        r = subprocess.run([POINTER, "700", "500", "left"], env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(self.state.exists(), f"no position was saved: {r.stderr}")
        saved = tuple(map(int, self.state.read_text().split()))
        self.assertNear(saved, (250, 220), 1)
        self.assertNear(self.read_pointer(), (700, 500), 1)
        r = subprocess.run([CURSOR, "restore"], env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(self.state.exists(), "restore left the state")
        # The saved coordinate already carries the hotspot offset, and read_pointer adds it again.
        self.assertNear(self.read_pointer(), (saved[0] + self.off[0], saved[1] + self.off[1]), 1, off=False)

    # (g) the save is taken before the wait: it holds where the owner's pointer was when the call began
    def test_g_saves_before_waiting(self):
        self.place(250, 220)
        self.assertFalse(self.state.exists())
        self.jiggle(4, around=(250, 220), end=(120, 90))   # active from the start, rests at 120,90 after ~4 s
        env = dict(self.env, POINTER_WHY="test: no key or accessibility route")
        t0 = time.monotonic()
        r = subprocess.run([POINTER, "400", "300", "drag", "600", "500"], env=env, capture_output=True, text=True)
        elapsed = time.monotonic() - t0
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertGreaterEqual(elapsed, 4.0)    # the action still waits for the activity to end
        self.assertTrue(self.state.exists(), f"no position was saved: {r.stderr}")
        self.assertNear(tuple(map(int, self.state.read_text().split())), (255, 220), 12)   # not 120,90
        self.assertNear(self.read_pointer(), (600, 500), 1)

    # a save from the last 30 minutes is kept; an older one is replaced
    def test_f_save_age(self):
        self.place(250, 220)
        env = dict(self.env, POINTER_WHY="test: no key or accessibility route")
        self.seed_state()
        subprocess.run([POINTER, "700", "500"], env=env, check=True)
        self.assertEqual(self.state.read_text().split(), ["50", "50"])
        old = time.time() - 31 * 60
        os.utime(self.state, (old, old))
        self.place(250, 220)
        subprocess.run([POINTER, "700", "500"], env=env, check=True)
        self.assertNear(tuple(map(int, self.state.read_text().split())), (250, 220), 1)


if __name__ == "__main__":
    unittest.main()

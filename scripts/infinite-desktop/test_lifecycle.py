"""Unit tests for session_lock.py — the per-Hyprland-session lifecycle.

Run:  python3 -m unittest test_lifecycle -v   (from scripts/infinite-desktop/)

No root, no real Hyprland: every test points XDG_RUNTIME_DIR at a tmp dir and
fakes the Hyprland instance directory / lock file by hand.
"""

import os
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import session_lock as sl

HERE = os.path.dirname(os.path.abspath(__file__))


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="idlifecycle-")
        self._old = os.environ.get("XDG_RUNTIME_DIR")
        self._old_sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
        os.environ["XDG_RUNTIME_DIR"] = self.tmp
        os.environ.pop("HYPRLAND_INSTANCE_SIGNATURE", None)
        self._fds = []

    def tearDown(self):
        for fd in self._fds:
            try:
                os.close(fd)
            except OSError:
                pass
        if self._old is None:
            os.environ.pop("XDG_RUNTIME_DIR", None)
        else:
            os.environ["XDG_RUNTIME_DIR"] = self._old
        if self._old_sig is not None:
            os.environ["HYPRLAND_INSTANCE_SIGNATURE"] = self._old_sig
        subprocess.run(["rm", "-rf", self.tmp])

    def acquire(self, sig):
        fd, holder = sl.acquire_session_lock(sig)
        if fd is not None:
            self._fds.append(fd)
        return fd, holder

    def write_hypr_lock(self, sig, pid, wl="wayland-1"):
        d = os.path.join(self.tmp, "hypr", sig)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "hyprland.lock"), "w") as f:
            f.write("%d\n%s\n" % (pid, wl))


class SameSessionLock(Base):
    def test_second_acquire_same_session_is_refused(self):
        fd, holder = self.acquire("SIG-A")
        self.assertIsNotNone(fd)
        self.assertIsNone(holder)

        fd2, holder2 = self.acquire("SIG-A")
        self.assertIsNone(fd2, "a 2nd instance for the same session must fail the lock")
        self.assertEqual(holder2, str(os.getpid()), "reports the current holder pid")

    def test_lock_file_records_holder_pid(self):
        self.acquire("SIG-A")
        with open(sl.lock_path("SIG-A")) as f:
            self.assertEqual(f.read().strip(), str(os.getpid()))


class NewSessionCanStart(Base):
    def test_different_signature_is_independent(self):
        fd_a, _ = self.acquire("SIG-A")
        fd_b, holder_b = self.acquire("SIG-B")
        self.assertIsNotNone(fd_a)
        self.assertIsNotNone(fd_b, "a different session's signature must get its own lock")
        self.assertIsNone(holder_b)
        self.assertNotEqual(sl.lock_path("SIG-A"), sl.lock_path("SIG-B"))

    def test_no_session_uses_nosession_key(self):
        fd, _ = self.acquire(None)
        self.assertIsNotNone(fd)
        self.assertIn("nosession-", sl.lock_path(None))


class StaleLock(Base):
    def _spawn_holder(self, sig):
        code = textwrap.dedent(
            """
            import os, sys, time
            sys.path.insert(0, %r)
            import session_lock as sl
            fd, holder = sl.acquire_session_lock(%r)
            print("LOCKED" if fd is not None else "FAIL:%%s" %% holder, flush=True)
            time.sleep(60)
            """
        ) % (HERE, sig)
        env = dict(os.environ, XDG_RUNTIME_DIR=self.tmp, PYTHONPATH=HERE)
        p = subprocess.Popen([sys.executable, "-c", code], stdout=subprocess.PIPE,
                             text=True, env=env)
        self.assertEqual(p.stdout.readline().strip(), "LOCKED")
        return p

    def test_dead_holder_does_not_block_new_instance(self):
        holder = self._spawn_holder("SIG-A")
        try:
            fd, who = self.acquire("SIG-A")
            self.assertIsNone(fd, "lock is held while the holder lives")
            self.assertEqual(who, str(holder.pid))
        finally:
            holder.kill()
            holder.wait()
            holder.stdout.close()
        # holder is gone -> the kernel released its flock -> we acquire cleanly
        fd, who = self.acquire("SIG-A")
        self.assertIsNotNone(fd, "a stale lock (dead holder) must not block a new instance")
        self.assertIsNone(who)

    def test_released_lock_is_reusable(self):
        fd, _ = sl.acquire_session_lock("SIG-A")
        os.close(fd)  # release
        fd2, who = self.acquire("SIG-A")
        self.assertIsNotNone(fd2)
        self.assertIsNone(who)


class SessionDeath(Base):
    def test_alive_true_only_for_a_live_hyprland_pid(self):
        # missing lock file
        self.assertFalse(sl.hyprland_alive("SIG-X"))
        # dead pid
        self.write_hypr_lock("SIG-X", 2 ** 31 - 1)
        self.assertFalse(sl.hyprland_alive("SIG-X"))
        # our own live pid, but comm is not Hyprland -> reject (pid reuse guard)
        self.write_hypr_lock("SIG-X", os.getpid())
        self.assertFalse(sl.hyprland_alive("SIG-X", _comm="python3"))
        # our own live pid, comm looks like Hyprland -> alive
        self.assertTrue(sl.hyprland_alive("SIG-X", _comm="Hyprland"))

    def test_no_signature_is_always_alive(self):
        self.assertTrue(sl.hyprland_alive(None))

    def test_watchdog_fires_on_dead_after_grace(self):
        state = {"alive": True}
        fired = threading.Event()
        seq = []

        def alive(_sig):
            seq.append(state["alive"])
            return state["alive"]

        t = threading.Thread(
            target=sl.watch_session,
            args=("SIG-X", fired.set),
            kwargs=dict(poll=0.01, strikes_needed=2, _alive=alive),
            daemon=True,
        )
        t.start()
        time.sleep(0.05)
        self.assertFalse(fired.is_set(), "must not fire while the session is alive")
        state["alive"] = False
        self.assertTrue(fired.wait(2.0), "watchdog must fire after the session dies")
        t.join(1.0)

    def test_watchdog_noop_without_signature(self):
        fired = threading.Event()
        sl.watch_session(None, fired.set, poll=0.01, _alive=lambda _s: False)
        self.assertFalse(fired.is_set())


class LogIsolation(Base):
    def test_per_session_log_paths_differ(self):
        self.assertNotEqual(sl.session_log_path("SIG-A"), sl.session_log_path("SIG-B"))
        self.assertTrue(sl.session_log_path("SIG-A").endswith("SIG-A.log"))

    def test_gc_removes_only_dead_sessions(self):
        sd = sl.state_dir()
        dead = "deadbeef_1000000000_1"
        live = "1ivebeef_2000000000_2"
        cur = "cccccccc_3000000000_3"
        # a dead session's leftovers
        open(os.path.join(sd, dead + ".lock"), "w").close()
        open(os.path.join(sd, dead + ".log"), "w").close()
        # a live session's leftovers
        self.write_hypr_lock(live, os.getpid())
        open(os.path.join(sd, live + ".lock"), "w").close()
        open(os.path.join(sd, live + ".log"), "w").close()
        # our own convenience pointer + the current session's files must survive
        open(os.path.join(sd, "current.log"), "w").close()
        open(os.path.join(sd, cur + ".log"), "w").close()

        orig = sl._proc_comm
        sl._proc_comm = lambda pid: "Hyprland"   # our pid counts as Hyprland for `live`
        try:
            sl.gc_dead_sessions(current_sig=cur)
        finally:
            sl._proc_comm = orig

        self.assertFalse(os.path.exists(os.path.join(sd, dead + ".lock")))
        self.assertFalse(os.path.exists(os.path.join(sd, dead + ".log")))
        self.assertTrue(os.path.exists(os.path.join(sd, live + ".lock")))
        self.assertTrue(os.path.exists(os.path.join(sd, "current.log")))
        self.assertTrue(os.path.exists(os.path.join(sd, cur + ".log")))

    def test_doctor_reads_only_the_current_session_log(self):
        """Mirror doctor's log-selection: it derives <key>.log from the CURRENT
        HYPRLAND_INSTANCE_SIGNATURE, so a warning in an OLD session's log is
        never read."""
        sd = sl.state_dir()
        warn = "Sin dispositivos de entrada accesibles: 3 nodo(s)"
        with open(os.path.join(sd, "OLD.log"), "w") as f:
            f.write(warn + "\n")
        with open(os.path.join(sd, "NEW.log"), "w") as f:
            f.write("[+] Teclado detectado: /dev/input/event3\n")

        script = (
            'sd="$1"; sig="$2"; key=$(printf "%s" "$sig" | tr / _); '
            'grep -q "Sin dispositivos de entrada accesibles" "$sd/$key.log"'
        )
        cur = subprocess.run(["bash", "-c", script, "_", sd, "NEW"])
        old = subprocess.run(["bash", "-c", script, "_", sd, "OLD"])
        self.assertNotEqual(cur.returncode, 0, "current session's clean log must not match")
        self.assertEqual(old.returncode, 0, "the phrase really is in the old log (sanity)")


if __name__ == "__main__":
    unittest.main(verbosity=2)

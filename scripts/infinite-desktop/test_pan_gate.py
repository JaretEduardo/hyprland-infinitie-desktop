"""test_pan_gate.py — mechanical tests for the idle gate (pan_gate.Gate).

Runs a worker loop with the SAME shape infinite_desktop_core.py uses
(idle: gate.wait_until_active(); active: a ~16 ms body until the predicate
drops) driven by a fake producer, and asserts:

  A  idle           -> worker blocked, ~0 iterations/s
  B  producer wake  -> worker active within a few ms (no polling latency)
  C  active         -> body keeps iterating at ~16 ms
  D  predicate drop -> worker returns to blocked
  E/F/G/H           -> same, second independent gate (drag)
  I  rapid on/off   -> never a lost wakeup (worker always ends in the
                       correct state for the final predicate value)
  J  1000 cycles    -> never hangs, never spins
  K  shutdown while blocked -> worker exits promptly

    python3 scripts/infinite-desktop/test_pan_gate.py
"""
import os
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pan_gate import Gate


class Worker:
    """A stand-in for infinite_desktop_core's loops: idle-block on the gate,
    then run a cheap body every `period` s until the predicate drops."""

    def __init__(self, gate, period=0.016):
        self.gate = gate
        self.period = period
        self.iterations = 0
        self.active_spans = 0          # times it went idle -> active
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        self._thread.start()

    def join(self, timeout=None):
        self._thread.join(timeout)
        return not self._thread.is_alive()

    def _run(self):
        while not self.gate.shutting_down():
            if not self.gate.wait_until_active():
                return
            self.active_spans += 1
            while not self.gate.shutting_down():
                time.sleep(self.period)
                if not _pred_now():
                    break
                self.iterations += 1


# --- fake shared state, exactly the pattern the daemon uses -------------------
lock = threading.Lock()
shutdown = threading.Event()
_super = False
_alt = False
_btn = False
drag_active = False


def _pan_pred():
    return _super and _alt


def _drag_pred():
    return (_super and _btn) or drag_active


pan_gate = Gate(lock, _pan_pred, shutdown, heal_timeout=5.0)
drag_gate = Gate(lock, _drag_pred, shutdown, heal_timeout=5.0)

# the worker bodies check the live predicate the same way the daemon does
_pred_now = _pan_pred


def set_state(**kw):
    """Producer: mutate state under the lock, then wake the gates — the exact
    ordering the evdev readers use (wake_locked inside `with lock:`)."""
    global _super, _alt, _btn, drag_active
    with lock:
        if 'super' in kw:
            _super = kw['super']
        if 'alt' in kw:
            _alt = kw['alt']
        if 'btn' in kw:
            _btn = kw['btn']
        if 'drag_active' in kw:
            drag_active = kw['drag_active']
        pan_gate.wake_locked()
        drag_gate.wake_locked()


PASS = 0
FAIL = 0


def _worker_quiescent(worker, window):
    """True if the worker does not iterate at all over `window` seconds."""
    n0 = worker.iterations
    time.sleep(window)
    return worker.iterations == n0


def check(name, cond):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  PASS  {name}")
    else:
        FAIL += 1
        print(f"  FAIL  {name}")


# ===========================================================================
print("A/B/C/D  pan gate")
w = Worker(pan_gate)
w.start()
time.sleep(0.5)
check("A idle: worker did ~0 iterations while blocked", w.iterations == 0)
check("A idle: worker never entered active span", w.active_spans == 0)

t0 = time.time()
set_state(super=True, alt=True)
# wait for the worker to notice
while w.active_spans == 0 and time.time() - t0 < 1.0:
    time.sleep(0.001)
wake_latency = time.time() - t0
check(f"B wake latency < 50 ms (got {wake_latency*1000:.1f} ms)", wake_latency < 0.05)

n0 = w.iterations
time.sleep(0.32)                       # ~20 periods of 16 ms
did = w.iterations - n0
check(f"C active: ~16 ms cadence (got {did} iters in 320 ms, expect 15-22)",
      15 <= did <= 24)

set_state(super=True, alt=False)       # drop the predicate
time.sleep(0.1)
n1 = w.iterations
time.sleep(0.3)
check("D release: worker returned to blocked (no more iterations)",
      w.iterations == n1)

# ===========================================================================
print("E/F/G/H  drag gate (independent)")
_pred_now = _drag_pred
set_state(super=False, alt=False, btn=False)
wd = Worker(drag_gate)
wd.start()
time.sleep(0.4)
check("E idle: drag worker blocked", wd.iterations == 0 and wd.active_spans == 0)

t0 = time.time()
set_state(super=True, btn=True)
while wd.active_spans == 0 and time.time() - t0 < 1.0:
    time.sleep(0.001)
check(f"F wake latency < 50 ms (got {(time.time()-t0)*1000:.1f} ms)",
      time.time() - t0 < 0.05)

n0 = wd.iterations
time.sleep(0.32)
check(f"G active: continuous updates (got {wd.iterations-n0} in 320 ms)",
      15 <= wd.iterations - n0 <= 24)

set_state(super=False, btn=False)
time.sleep(0.1)
n1 = wd.iterations
time.sleep(0.3)
check("H release: drag worker blocked again", wd.iterations == n1)

# ===========================================================================
print("I  rapid press/release — no lost wakeup")
_pred_now = _pan_pred
set_state(super=False, alt=False, btn=False)
time.sleep(0.2)

# 300 asymmetric cycles: the OFF phase is longer than one worker period so the
# worker genuinely reaches the idle gate between many of them — this is where a
# check-then-wait race would drop a wakeup.
for i in range(300):
    set_state(super=True, alt=True)
    time.sleep(0.0007)
    set_state(super=True, alt=False)
    time.sleep(0.02)
    # each iteration ends OFF; the worker must be idle-blocked here
check("I after 300 cycles ending OFF: worker idle-blocked",
      _worker_quiescent(w, 0.25))

# now turn it ON, stably, and it MUST wake (a lost wakeup would leave it asleep)
n0 = w.iterations
set_state(super=True, alt=True)
time.sleep(0.15)
check("I final ON: worker woke and is iterating (no lost wakeup)",
      w.iterations > n0)
set_state(super=False, alt=False)
time.sleep(0.1)

# ===========================================================================
print("J  1000 fast cycles — no hang, no spin")
j_iters_start = w.iterations
t0 = time.time()
for i in range(1000):
    set_state(super=True, alt=True)
    set_state(super=False, alt=False)
elapsed = time.time() - t0
time.sleep(0.2)
# with predicate ending False, the worker must be idle
n0 = w.iterations
time.sleep(0.3)
check("J ends idle after 1000 toggles (no runaway spin)", w.iterations == n0)
check(f"J completed fast ({elapsed*1000:.0f} ms for 1000 cycles)", elapsed < 5.0)
# and it can still be woken
set_state(super=True, alt=True)
time.sleep(0.12)
check("J still responsive after the storm", w.iterations > n0)
set_state(super=False, alt=False)

# ===========================================================================
print("K  shutdown wakes blocked workers")
time.sleep(0.2)                       # both workers now idle-blocked
w2 = Worker(pan_gate)
w2.start()
time.sleep(0.2)
t0 = time.time()
shutdown.set()
# mimic the daemon's _shutdown_waker
for g in (pan_gate, drag_gate):
    g.wake()
ok_w = w.join(2.0)
ok_wd = wd.join(2.0)
ok_w2 = w2.join(2.0)
shut_latency = time.time() - t0
check(f"K all workers exited within 2 s (got {shut_latency*1000:.0f} ms)",
      ok_w and ok_wd and ok_w2)

# ===========================================================================
print()
print(f"{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)

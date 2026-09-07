"""pan_gate.py — a lost-wakeup-safe idle gate for infinite_desktop_core.py.

infinite_desktop_core.py runs two worker loops that, historically, spun at
~62 Hz forever (``while True: time.sleep(0.016)``) even with zero input —
~145 wakeups/s permanently. This wraps the "should this loop be doing work
right now?" decision so the loop can BLOCK while the answer is no and wake the
instant a producer changes the relevant state.

Design (why a Condition, not an Event):

* One ``threading.Condition`` layered over the daemon's EXISTING ``lock``. The
  predicate reads the same shared state the producers mutate under that lock,
  so evaluating the predicate and starting to wait happen without ever
  releasing the lock — there is no check-then-wait gap, therefore no lost
  wakeup. This is the textbook-correct primitive for the job.
* Producers (the evdev readers) already hold ``lock`` when they change
  ``super_pressed`` / ``btn_left`` / etc. They call ``wake_locked()`` from
  inside that block — a bare ``notify_all()``.
* Shutdown: a ``threading.Event``. A tiny waker thread in the daemon blocks on
  it and, once set, notifies every gate so the loops fall out of ``wait()``
  and return. ``wait_until_active()`` then returns ``False`` and the loop
  breaks. A long ``heal_timeout`` on the wait is a pure self-heal safety net
  (a Condition cannot actually lose a wakeup) — it is NOT the normal path.

Nothing about pan/drag semantics, speed, smoothing or cadence lives here — the
active loop bodies in infinite_desktop_core.py are unchanged. This only decides
*when* those bodies run.
"""

import threading


class Gate:
    """One idle gate over a predicate on shared, lock-protected state.

    lock         the daemon's shared threading.Lock (NOT an RLock)
    predicate    zero-arg callable, evaluated WITH `lock` held, returns True
                 when the worker loop should be running its active body
    shutdown     threading.Event; when set, wait_until_active() returns False
    heal_timeout seconds; upper bound on how long a (theoretically impossible)
                 lost wakeup could stall the loop. Not a polling interval.
    """

    def __init__(self, lock, predicate, shutdown, heal_timeout=5.0):
        self._cv = threading.Condition(lock)
        self._predicate = predicate
        self._shutdown = shutdown
        self._heal_timeout = heal_timeout

    def wake_locked(self):
        """Notify waiters. The caller MUST already hold the shared lock
        (the evdev readers do, inside their existing ``with lock:`` block)."""
        self._cv.notify_all()

    def wake(self):
        """Notify waiters, acquiring the shared lock first. For callers that do
        not already hold it (the shutdown waker thread)."""
        with self._cv:
            self._cv.notify_all()

    def wait_until_active(self):
        """Block while the predicate is false. Returns:
            True  -> predicate is true, run the active loop body
            False -> shutting down, break out of the loop
        """
        with self._cv:
            while not self._shutdown.is_set() and not self._predicate():
                self._cv.wait(self._heal_timeout)
            return not self._shutdown.is_set()

    def shutting_down(self):
        return self._shutdown.is_set()

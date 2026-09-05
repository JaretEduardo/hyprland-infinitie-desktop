#!/usr/bin/env python3
"""Pure absolute-position -> relative-delta transform for a touchpad.

No I/O, no `evdev` import: it consumes plain ``(ev_type, code, value)`` integer
triples (as read from an evdev device, or synthesised in a test) and returns the
per-``SYN_REPORT`` change in finger position, **in device units**. Pixel scaling
(axis resolution, the daemon's speed multiplier, direction) is the caller's job
-- see ``units_to_pixels`` and ``infinite_desktop_core.touchpad_reader_device``.

Why a separate module: ``infinite_desktop_core.py`` runs the daemon at import
time (module-level ``while True`` loops), so its logic cannot be imported by a
unit test. This can -- ``test_abs_delta.py`` exercises it directly.

Design
------
* One finger drives panning. With protocol-B multitouch there is exactly one
  contact reporting position while a single finger is down, so we simply follow
  "the position the device is currently reporting" and gate on finger count.
* The FIRST positioned frame of a contact only stores the baseline and emits no
  delta -- this is what stops the window jumping when a finger lands.
* Every later frame emits ``(x - last_x, y - last_y)`` and advances the baseline.
* "A finger is down" is ``BTN_TOUCH`` **or** ``BTN_TOOL_FINGER`` (some pads only
  assert one of the two). A lift -- both clear -- drops the baseline, so the
  next contact starts fresh and never inherits the previous finger's position.
* Two or more fingers (``BTN_TOOL_DOUBLETAP`` / ``TRIPLETAP`` / ...) -> treated
  as scroll / gesture / palm: no delta, baseline dropped. Returning to a single
  finger (``BTN_TOOL_FINGER`` 1) re-primes cleanly (first frame is baseline
  again).
* A frame whose delta exceeds ``jump_reject_fraction`` of the axis range on
  either axis is dropped as a slot-switch / dropped-frame teleport. The range
  comes from the device's own ``AbsInfo`` at open time, not from a hardcoded
  number.
* X and Y updates within one ``SYN_REPORT`` frame are combined; an axis not
  updated in a frame contributes 0 for that frame.
"""

# Linux input-event-codes -- ABI-stable, duplicated here as plain ints so this
# module needs no dependency.
EV_SYN = 0
EV_KEY = 1
EV_ABS = 3

SYN_REPORT = 0

ABS_X = 0
ABS_Y = 1
ABS_MT_POSITION_X = 53
ABS_MT_POSITION_Y = 54

BTN_TOUCH = 330
BTN_TOOL_FINGER = 325
BTN_TOOL_DOUBLETAP = 333
BTN_TOOL_TRIPLETAP = 334
BTN_TOOL_QUADTAP = 335
BTN_TOOL_QUINTTAP = 328

_MULTI_FINGER_BTNS = frozenset((
    BTN_TOOL_DOUBLETAP, BTN_TOOL_TRIPLETAP, BTN_TOOL_QUADTAP, BTN_TOOL_QUINTTAP,
))


class AbsDeltaTracker:
    """Feed it evdev events with :meth:`feed`; it returns a ``(dx, dy)`` unit
    delta on frames that produced single-finger motion, else ``None``."""

    def __init__(self, code_x, code_y, range_x=0, range_y=0,
                 jump_reject_fraction=0.5):
        self.code_x = code_x
        self.code_y = code_y
        self.jump_x = int(range_x * jump_reject_fraction) if range_x else 0
        self.jump_y = int(range_y * jump_reject_fraction) if range_y else 0

        self._touch = False       # BTN_TOUCH
        self._finger = False      # BTN_TOOL_FINGER (single-finger tool)
        self._multi = False       # 2+ fingers -> do not pan
        self._have_base = False
        self._last_x = None
        self._last_y = None
        self._pend_x = None       # position updates seen in the current frame
        self._pend_y = None

    @property
    def _down(self):
        return self._touch or self._finger

    def _reset_contact(self):
        self._have_base = False
        self._last_x = self._last_y = None
        self._pend_x = self._pend_y = None

    def feed(self, ev_type, code, value):
        if ev_type == EV_KEY:
            if code == BTN_TOUCH:
                self._touch = bool(value)
                if not self._down:
                    self._multi = False
                    self._reset_contact()
            elif code == BTN_TOOL_FINGER:
                was_down = self._down
                self._finger = bool(value)
                if not self._down:
                    self._multi = False
                    self._reset_contact()
                elif value and self._multi:
                    # 2+ fingers -> 1: re-prime, so no jump from the lifted one.
                    self._multi = False
                    self._reset_contact()
                elif value and not was_down:
                    # finger arrived via BTN_TOOL_FINGER alone
                    self._reset_contact()
            elif code in _MULTI_FINGER_BTNS and value:
                self._multi = True
                self._reset_contact()
            return None

        if ev_type == EV_ABS:
            if code == self.code_x:
                self._pend_x = value
            elif code == self.code_y:
                self._pend_y = value
            return None

        if ev_type == EV_SYN and code == SYN_REPORT:
            return self._end_frame()

        return None

    def _end_frame(self):
        px, py = self._pend_x, self._pend_y
        self._pend_x = self._pend_y = None

        if not self._down or self._multi:
            return None

        x = px if px is not None else self._last_x
        y = py if py is not None else self._last_y
        if x is None or y is None:
            # Only part of the position known so far -- keep it, still no delta.
            if x is not None:
                self._last_x = x
            if y is not None:
                self._last_y = y
            return None

        if not self._have_base:
            self._last_x, self._last_y = x, y
            self._have_base = True
            return None

        dx = x - self._last_x
        dy = y - self._last_y
        self._last_x, self._last_y = x, y

        if (self.jump_x and abs(dx) > self.jump_x) or \
           (self.jump_y and abs(dy) > self.jump_y):
            return None
        if dx == 0 and dy == 0:
            return None
        return (dx, dy)


def units_to_pixels(d_units, units_per_mm, pixels_per_mm):
    """Convert a device-unit delta to a screen-pixel delta.

    ``units_per_mm``  -- the axis' ``AbsInfo.resolution`` (units per mm), or a
                         sane model-independent fallback when the kernel reports
                         0 for it.
    ``pixels_per_mm``  -- model-independent tuning constant: how many screen
                         pixels one millimetre of finger travel maps to (before
                         the daemon's ``speed`` multiplier).
    """
    if units_per_mm <= 0:
        return 0.0
    return (d_units / units_per_mm) * pixels_per_mm

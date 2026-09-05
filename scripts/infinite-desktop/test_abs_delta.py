#!/usr/bin/env python3
"""Synthetic-sequence tests for abs_delta.AbsDeltaTracker / units_to_pixels.

Run:  python3 -m unittest scripts.infinite-desktop.test_abs_delta
  or:  python3 scripts/infinite-desktop/test_abs_delta.py

No device access, no evdev import -- pure event sequences in, deltas out.
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from abs_delta import (  # noqa: E402
    AbsDeltaTracker, units_to_pixels,
    EV_ABS, EV_KEY, EV_SYN, SYN_REPORT,
    ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_X, ABS_Y,
    BTN_TOUCH, BTN_TOOL_FINGER, BTN_TOOL_DOUBLETAP,
)


def mt_tracker(range_x=1400, range_y=860):
    return AbsDeltaTracker(ABS_MT_POSITION_X, ABS_MT_POSITION_Y, range_x, range_y)


def st_tracker(range_x=1400, range_y=860):
    return AbsDeltaTracker(ABS_X, ABS_Y, range_x, range_y)


def frame(tr, x=None, y=None, touch=None, extra=()):
    """Push one SYN-terminated frame, return the tracker's frame result."""
    if touch is not None:
        tr.feed(EV_KEY, BTN_TOUCH, 1 if touch else 0)
    for code, val in extra:
        tr.feed(EV_KEY, code, val)
    if x is not None:
        tr.feed(EV_ABS, tr.code_x, x)
    if y is not None:
        tr.feed(EV_ABS, tr.code_y, y)
    return tr.feed(EV_SYN, SYN_REPORT, 0)


class FirstContactNoJump(unittest.TestCase):
    def test_first_positioned_frame_emits_nothing(self):
        tr = mt_tracker()
        self.assertIsNone(frame(tr, x=500, y=500, touch=True))

    def test_touch_then_move_emits_delta_from_baseline_not_absolute(self):
        tr = mt_tracker()
        frame(tr, x=500, y=500, touch=True)          # baseline
        self.assertEqual(frame(tr, x=512, y=506), (12, 6))   # not (512, 506)

    def test_landing_far_from_origin_still_no_jump(self):
        tr = mt_tracker()
        self.assertIsNone(frame(tr, x=1350, y=800, touch=True))
        self.assertEqual(frame(tr, x=1340, y=790), (-10, -10))


class LaterMovement(unittest.TestCase):
    def test_successive_frames_accumulate_independently(self):
        tr = mt_tracker()
        frame(tr, x=100, y=100, touch=True)
        self.assertEqual(frame(tr, x=110, y=100), (10, 0))
        self.assertEqual(frame(tr, x=110, y=115), (0, 15))
        self.assertEqual(frame(tr, x=90, y=105), (-20, -10))

    def test_axis_not_updated_in_frame_contributes_zero(self):
        tr = mt_tracker()
        frame(tr, x=200, y=200, touch=True)
        self.assertEqual(frame(tr, x=210), (10, 0))   # only X in this frame
        self.assertEqual(frame(tr, y=190), (0, -10))  # only Y in this frame

    def test_x_and_y_in_same_frame_combined(self):
        tr = mt_tracker()
        frame(tr, x=0, y=0, touch=True)
        self.assertEqual(frame(tr, x=7, y=-3), (7, -3))

    def test_no_motion_frame_returns_none(self):
        tr = mt_tracker()
        frame(tr, x=300, y=300, touch=True)
        self.assertIsNone(frame(tr, x=300, y=300))


class FingerUpResetsBaseline(unittest.TestCase):
    def test_lift_then_new_contact_does_not_inherit_position(self):
        tr = mt_tracker()
        frame(tr, x=500, y=500, touch=True)
        self.assertEqual(frame(tr, x=520, y=500), (20, 0))
        frame(tr, touch=False)                       # finger up
        # New contact lands at the opposite corner: must NOT emit ~ (480, 300).
        self.assertIsNone(frame(tr, x=1000, y=800, touch=True))
        self.assertEqual(frame(tr, x=1005, y=805), (5, 5))

    def test_delta_after_lift_without_new_touch_is_ignored(self):
        tr = mt_tracker()
        frame(tr, x=100, y=100, touch=True)
        frame(tr, touch=False)
        self.assertIsNone(frame(tr, x=900, y=900))   # no finger down

    def test_btn_tool_finger_alone_counts_as_down(self):
        # A pad that asserts BTN_TOOL_FINGER but not BTN_TOUCH.
        tr = mt_tracker()
        tr.feed(EV_KEY, BTN_TOOL_FINGER, 1)
        self.assertIsNone(frame(tr, x=400, y=400))   # baseline
        self.assertEqual(frame(tr, x=410, y=395), (10, -5))
        tr.feed(EV_KEY, BTN_TOOL_FINGER, 0)
        self.assertIsNone(frame(tr, x=900, y=900))   # lifted


class MultiFinger(unittest.TestCase):
    def test_two_fingers_suppress_delta(self):
        tr = mt_tracker()
        frame(tr, x=400, y=400, touch=True)
        frame(tr, x=410, y=400)                      # (10, 0) - single finger
        tr.feed(EV_KEY, BTN_TOOL_DOUBLETAP, 1)
        self.assertIsNone(frame(tr, x=460, y=440))   # scroll - suppressed
        self.assertIsNone(frame(tr, x=500, y=480))

    def test_back_to_one_finger_reprimes_without_jump(self):
        tr = mt_tracker()
        frame(tr, x=400, y=400, touch=True)
        tr.feed(EV_KEY, BTN_TOOL_DOUBLETAP, 1)
        frame(tr, x=600, y=600)
        tr.feed(EV_KEY, BTN_TOOL_DOUBLETAP, 0)
        tr.feed(EV_KEY, BTN_TOOL_FINGER, 1)
        self.assertIsNone(frame(tr, x=610, y=610))   # baseline re-primes here
        self.assertEqual(frame(tr, x=615, y=612), (5, 2))


class JumpReject(unittest.TestCase):
    def test_teleport_larger_than_half_range_is_dropped(self):
        tr = mt_tracker(range_x=1000, range_y=1000)  # jump limit = 500
        frame(tr, x=100, y=100, touch=True)
        self.assertIsNone(frame(tr, x=900, y=100))   # dx = 800 > 500 -> drop
        # baseline advanced to the new spot, so normal motion resumes
        self.assertEqual(frame(tr, x=910, y=100), (10, 0))

    def test_small_moves_within_limit_pass(self):
        tr = mt_tracker(range_x=1000, range_y=1000)
        frame(tr, x=100, y=100, touch=True)
        self.assertEqual(frame(tr, x=400, y=100), (300, 0))


class SingleTouchFallback(unittest.TestCase):
    def test_abs_x_y_path_behaves_like_mt(self):
        tr = st_tracker()
        self.assertIsNone(frame(tr, x=500, y=500, touch=True))
        self.assertEqual(frame(tr, x=510, y=490), (10, -10))
        frame(tr, touch=False)
        self.assertIsNone(frame(tr, x=50, y=50, touch=True))
        self.assertEqual(frame(tr, x=55, y=52), (5, 2))


class ReaderIntegration(unittest.TestCase):
    """Mirror exactly what touchpad_reader_device() does with a realistic
    hid-multitouch Precision-Touchpad frame stream: pick the MT axes, ignore the
    mirrored ABS_X/ABS_Y, run the tracker, scale units->px with the axis
    resolution, sum. Proves the whole ABS -> pixel-delta chain end to end."""

    # As decoded from this laptop's touchpad HID report descriptor:
    #   ABS_MT_POSITION_X: 0..1404, ~12 units/mm  ;  Y: 0..864, ~12 units/mm
    RES = 12.0
    PX_PER_MM = 8.0          # == TOUCHPAD_PIXELS_PER_MM default

    def _run(self, frames):
        tr = AbsDeltaTracker(ABS_MT_POSITION_X, ABS_MT_POSITION_Y, 1404, 864)
        ax = ay = 0.0
        for evs in frames:
            out = None
            for (t, c, v) in evs:
                out = tr.feed(t, c, v)
            if out is not None:
                ax += units_to_pixels(out[0], self.RES, self.PX_PER_MM)
                ay += units_to_pixels(out[1], self.RES, self.PX_PER_MM)
        return ax, ay

    def test_finger_down_then_12mm_right_6mm_down(self):
        # frame 1: finger lands at (700, 400)  -> baseline, no motion
        # frame 2: moves to (700+144, 400+72)  == +12 mm X, +6 mm Y in units
        f1 = [(EV_KEY, BTN_TOUCH, 1), (EV_KEY, BTN_TOOL_FINGER, 1),
              (EV_ABS, 47, 0), (EV_ABS, 57, 100),          # SLOT 0, TRACKING_ID
              (EV_ABS, ABS_MT_POSITION_X, 700), (EV_ABS, ABS_MT_POSITION_Y, 400),
              (EV_ABS, ABS_X, 700), (EV_ABS, ABS_Y, 400),  # mirror - must be ignored
              (EV_SYN, SYN_REPORT, 0)]
        f2 = [(EV_ABS, ABS_MT_POSITION_X, 844), (EV_ABS, ABS_MT_POSITION_Y, 472),
              (EV_ABS, ABS_X, 844), (EV_ABS, ABS_Y, 472),
              (EV_SYN, SYN_REPORT, 0)]
        ax, ay = self._run([f1, f2])
        self.assertAlmostEqual(ax, 12.0 / self.RES * self.PX_PER_MM * 144 / 12, places=6)
        # simpler: 144 units / 12 u/mm * 8 px/mm == 96 px ; 72 units -> 48 px
        self.assertAlmostEqual(ax, 96.0)
        self.assertAlmostEqual(ay, 48.0)

    def test_lift_and_reland_does_not_add_the_gap(self):
        f_down = [(EV_KEY, BTN_TOUCH, 1), (EV_ABS, 57, 1),
                  (EV_ABS, ABS_MT_POSITION_X, 100), (EV_ABS, ABS_MT_POSITION_Y, 100),
                  (EV_SYN, SYN_REPORT, 0)]
        f_move = [(EV_ABS, ABS_MT_POSITION_X, 130), (EV_SYN, SYN_REPORT, 0)]
        f_up = [(EV_KEY, BTN_TOUCH, 0), (EV_ABS, 57, -1), (EV_SYN, SYN_REPORT, 0)]
        f_reland = [(EV_KEY, BTN_TOUCH, 1), (EV_ABS, 57, 2),
                    (EV_ABS, ABS_MT_POSITION_X, 1300), (EV_ABS, ABS_MT_POSITION_Y, 800),
                    (EV_SYN, SYN_REPORT, 0)]
        f_move2 = [(EV_ABS, ABS_MT_POSITION_X, 1312), (EV_SYN, SYN_REPORT, 0)]
        ax, ay = self._run([f_down, f_move, f_up, f_reland, f_move2])
        # 30 units then 12 units, both /12*8 ; the 1170-unit jump is NOT counted
        self.assertAlmostEqual(ax, (30 + 12) / 12.0 * 8.0)
        self.assertAlmostEqual(ay, 0.0)


class UnitsToPixels(unittest.TestCase):
    def test_resolution_maps_mm_to_pixels(self):
        # 12 units/mm, 8 px/mm  ->  12 units == 1 mm == 8 px
        self.assertAlmostEqual(units_to_pixels(12, 12.0, 8.0), 8.0)
        self.assertAlmostEqual(units_to_pixels(24, 12.0, 8.0), 16.0)
        self.assertAlmostEqual(units_to_pixels(-6, 12.0, 8.0), -4.0)

    def test_zero_or_missing_resolution_yields_zero(self):
        self.assertEqual(units_to_pixels(100, 0, 8.0), 0.0)
        self.assertEqual(units_to_pixels(100, -1, 8.0), 0.0)


if __name__ == "__main__":
    unittest.main()

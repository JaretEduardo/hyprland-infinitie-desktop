# hand-control — webcam gesture control for the Infinite Desktop (experiment)

Optional. Off by default. The webcam is opened **only** while `hand_control.py`
runs; `hand-control stop` (or Super+H, or the navbar HandButton) kills it and
releases the device. All processing is local — nothing is sent anywhere.

This is a deliberately small **first pass**: three gestures, reusing the
existing Infinite Desktop scripts/mechanism. No computer vision goes near the
`infinite_desktop_core.py` evdev daemon — this is a separate process.

## Gestures

| gesture | action | reuses |
| --- | --- | --- |
| **open palm + translate X/Y** | pan the Infinite Desktop | `world.py` camera + `hypr_ipc` batch move — the same as touchpad/keyboard |
| **fist** | **CLUTCH** — stop everything; recolocate the hand freely | `Panner.end()` |
| **fist → thumbs-up** | toggle Viewport Mosaic | `viewport_mosaic.py toggle` |
| **palm tilt left / right** | previous / next window | `world_navigate.py prev-window` / `next-window` (focus-only during a Viewport Mosaic) |

**No gesture uses finger count.** A finger leaving the frame at a screen edge
would make a false trigger, so tilt comes from stable wrist/MCP landmarks only,
and the mosaic needs the deliberate fist→thumbs-up *sequence*. Fist = "the four
main fingers are curled" (a real fist or fingers folded near an edge — either
way the safe response is to stop).

Priority (highest first): shutter-closed → **fist/clutch** → partial hand (no
discrete actions) → **pan** → **tilt**. The mosaic state machine runs alongside,
only ever advancing from a stable fist.

- **CLUTCH** has absolute priority: fist ends the pan immediately, cancels any
  tilt candidate, and on release the *current* hand position becomes the new pan
  baseline — pull your hand back to the middle without the desktop moving (the
  physical "clutch" you already do). A thumbs-up is still a curled fist, so it
  also clutches.
- **Mosaic gesture** is `idle → fist_armed → thumbs_pending → fired →
  wait_reset`: a stable fist (`fist_arm_seconds`) that *then* becomes a
  clear thumbs-up (four fingers curled, thumb extended and pointing up) held
  `thumb_hold_seconds` fires once. Holding the thumbs-up never re-toggles; you
  must return to a fist or an open palm for `reset_seconds` to re-arm. A bare
  thumbs-up with no fist first does nothing.
- **Pan** is smooth and immediate — it tracks the palm *base* (wrist + two
  MCPs) with an adaptive EMA (more smoothing when slow, more response when
  fast), and an **outlier reject** drops isolated landmark spikes
  (`pan.max_tracking_speed`). Fist is the only intentional way to release it. A
  1–2 frame `None`/`other` dropout is ridden out (`pan.grace_seconds`); a real
  loss stops the pan and re-baselines on return.
- **Tilt has lower priority than pan.** It is evaluated **only while the palm is
  stationary** — `tilt.max_translation_speed` for `tilt.stationary_seconds`. A
  natural wrist tilt during a pan never navigates; you must stop the hand, then
  tilt deliberately. On fire: `Panner.end()`, then pan is suppressed for
  `tilt.nav_block_seconds` while `world_navigate.py` moves the camera, then the
  pan re-baselines to the current hand position — the two never move the camera
  at once. The angle is auto-zeroed to a *near-upright* rest pose; it never
  repeats while held; return near upright + cooldown to re-arm.
- **Mirror** is applied exactly once (`camera.mirror`): hand visually
  right/tilt-right → `next-window` and pan right.

## Privacy shutter

This Lenovo's privacy shutter has **no signal on Linux** (no `camera_power`
sysfs, no V4L2 privacy control, no `ideapad_laptop` change, no key/ACPI event).
So `hand_control.py` detects it from the video stream: a covered lens gives very
low variance **and** very low texture **and** is temporally stable, judged over
several frames with hysteresis (`close_delay` / `open_delay` in the config) so a
dark room does not flip the state.

While the shutter reads **CLOSED**: MediaPipe does not run, no pan/swipe/mosaic
is sent, any active gesture is cleared, and the loop drops to `closed_fps`
(~4 FPS) doing only the cheap check. On **CLOSED → OPEN** the smoothing/history
is reset so there is no camera jump and nothing accumulated fires.

The navbar HandButton shows three states — OFF / shutter-CLOSED / ACTIVE — and
`$XDG_RUNTIME_DIR/hand-control/state` carries `running=` / `shutter=` /
`tracking=`.

## Install

```sh
scripts/hand-control/setup-venv.sh      # once, by hand
```

Creates `$XDG_DATA_HOME/hand-control/venv` (~500 MB, never system site-packages:
`mediapipe` + `opencv-contrib-python` + `numpy` + `matplotlib`), downloads
`hand_landmarker.task` (~7 MB), and copies `config.toml.example` to
`~/.config/hand-control/config.toml` (`hand_control.py` also creates it on first
run — it never silently uses defaults without a file, and it always prints which
file it loaded). No emerge, no root. To undo: `rm -rf ~/.local/share/hand-control`.

Needs a working webcam (`/dev/video*`, `uvcvideo`) that the session user can
open — no root. Runs the TFLite XNNPACK **CPU** model; it does not wake the RTX.

## Use

```sh
hand-control start | stop | toggle | status | debug
```

`Super+H` toggles it; the navbar's HandButton lights up while it runs.
`hand-control status` prints `shutter=` / `tracking=`.

### `hand-control debug`

Prints the loaded config path + active thresholds, then one line per frame:

```
dbg shutter=open lofi=62 | gesture=open_palm pan=1 clutch=0 partial=0 speed=0.35 \
    stat=0 tilt=+0.02 tilt_state=neutral mosaic=idle thumb=0 th=0.00 | \
    raw=0.512,0.480 filt=0.514,0.478 dxy=+4,-1 outl=0
```

- `shutter` / `lofi` — shutter detector (open/close the lens to calibrate)
- `gesture` — `open_palm` / `fist` / `thumbs_up` / `other`
- `pan` — 1 while panning; `clutch` — 1 while a fist/thumbs-up is held;
  `partial` — 1 when a palm landmark left the frame (discrete actions blocked)
- `speed` — real translational palm speed (norm/s); `stat` — 1 when it has been
  below `tilt.max_translation_speed` long enough for tilt to be allowed
- `tilt` — palm angle from upright, radians, auto-zeroed;
  `tilt_state` — `neutral` / `pending` / `fired-left|right` (`action=prev|next`)
- `mosaic` — `idle` / `fist_armed` / `thumbs_pending` / `fired` / `wait_reset`;
  `thumb` — 1 on a thumbs-up pose; `th` — seconds held in `thumbs_pending`
- `raw` / `filt` — palm-base position before / after the EMA;
  `dxy` — the pan delta sent this frame (logical px); `outl` — 1 on a rejected spike

It also tries a preview window (needs XWayland; metrics print regardless).

**Calibrate** `~/.config/hand-control/config.toml`:
- shutter: open/close the lens, read `lofi`, put a threshold in the gap
- pan jitter: pan slowly and watch `raw` vs `filt` and `dxy` — a stable `raw`
  with a wobbly `filt`/`dxy` means the filter is too weak (raise `pan.smoothing`
  = lower value); big `dxy` spikes with `outl=0` → lower `pan.max_tracking_speed`
- tilt: while panning, `tilt_state` must stay `neutral` (if it goes `pending`,
  lower `tilt.max_translation_speed`); stop the hand (`stat=1`), then tip it —
  it should reach past `tilt.angle_threshold` and fire
- mosaic: fist (`mosaic=fist_armed`), thumb up (`thumb=1`,
  `mosaic=thumbs_pending`); if `thumb` stays 0, lower
  `mosaic_gesture.thumb_direction_threshold`

## Config

`~/.config/hand-control/config.toml` — see `config.toml.example`. Camera index,
mirror, pan sensitivity / smoothing / deadzone, confidence, gesture cooldowns.
Nothing is tuned to a specific screen; deltas are relative and normalised.

## Not yet (later passes, if the basic tracking is reliable)

pinch-grab a window · two-hand resize · pointing at windows · multi-monitor
hand targeting · complex gestures.

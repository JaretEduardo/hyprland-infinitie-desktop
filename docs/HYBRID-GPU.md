# Hybrid GPU — AMD primary, NVIDIA on demand

This laptop has two GPUs:

| Role | GPU | Driver | PCI (this machine) |
| --- | --- | --- | --- |
| **Primary / compositor** | AMD Radeon 680M (Rembrandt iGPU) | `amdgpu` | `0000:06:00.0` (`boot_vga`) |
| **On-demand / offload / compute** | NVIDIA RTX 3050 Ti Mobile (GA107M) | `nvidia` (proprietary) | `0000:01:00.0` |

The AMD iGPU runs Hyprland and everything on screen. The NVIDIA dGPU is off
(RTD3) most of the time and is used only when something explicitly asks for it:
a GL/Vulkan app through `nvidia-offload`, or a CUDA/compute workload.

Nothing here is hardcoded to a bus address or a `cardN` number — the installer
reads the topology from `lib/hardware.sh` / `lib/nvidia.sh`.

---

## Three separate concerns

1. **Which GPU composits** — `AQ_DRM_DEVICES` (Hyprland/Aquamarine). Must be the
   AMD iGPU. The NVIDIA card must not become primary by accident.
2. **Render offload** — running one graphics app *on* the NVIDIA GPU while the
   desktop stays on AMD. `bin/nvidia-offload`.
3. **Power / RTD3** — the NVIDIA GPU powering down when idle, and coming back for
   CUDA. Mostly handled by the modern driver; `install.sh gpu` fills the gaps.

CUDA is **not** in this list — see [CUDA vs render offload](#cuda-vs-render-offload).

---

## `install.sh gpu`

```
install.sh gpu            # detect + explain + show the proposed changes (read-only)
install.sh gpu --apply    # apply, one change at a time, after confirmation
install.sh gpu --dry-run  # same as the default; never writes
```

It configures **only what the driver package does not already provide**, and
only after showing you the exact file and asking:

| Change | When | Why |
| --- | --- | --- |
| `/etc/udev/rules.d/70-hypr-gpu-paths.rules` | always | stable `/dev/dri/hypr-primary` (AMD) + `/dev/dri/hypr-secondary` (NVIDIA) symlinks for `AQ_DRM_DEVICES` |
| `/etc/modprobe.d/hypr-nvidia.conf` (`options nvidia_drm modeset=1`) | only if `/sys/module/nvidia_drm/parameters/modeset` is not `Y` | NVIDIA needs DRM KMS for Wayland |
| `/etc/udev/rules.d/80-nvidia-rtd3.rules` | only if the driver ships no equivalent | put the NVIDIA GPU into runtime PM on driver bind |

It never rebuilds the initramfs, never edits the bootloader, never enables
`nvidia-persistenced`, and backs up (`.bak.<timestamp>`) any pre-existing file
it did not create before replacing it — and only with your confirmation.
Re-running it is a no-op once applied.

Privileges: `install.sh gpu` (plan) needs none. `--apply` writes to `/etc`, so
run it with `sudo` **or** let it print the exact `sudo install ...` command for
each file. It never calls `sudo` itself.

---

## Compositor GPU: `AQ_DRM_DEVICES`

Hyprland picks its render GPU from `AQ_DRM_DEVICES` — a `:`-separated list of
`/dev/dri/card*` paths, first = primary renderer. Problems:

- raw `cardN` numbers are reassigned across boots;
- `/dev/dri/by-path/pci-<addr>-card` is stable but its `:` collide with the
  `AQ_DRM_DEVICES` list separator.

So `70-hypr-gpu-paths.rules` creates colon-free stable symlinks by PCI address
(`KERNELS=="0000:06:00.0"` etc., filled in by the installer), and the Hyprland
config uses:

```
env = AQ_DRM_DEVICES,/dev/dri/hypr-primary:/dev/dri/hypr-secondary
```
```lua
hl.env("AQ_DRM_DEVICES", "/dev/dri/hypr-primary:/dev/dri/hypr-secondary")
```

AMD (`hypr-primary`) is the compositor. The NVIDIA card (`hypr-secondary`) is
listed too because an external monitor wired to it (the HDMI port on this
laptop is on the NVIDIA GPU) only works if its card is in the list — and
community reports show listing *only* the iGPU can hang session startup.

The `desktop` stage wires this line into the Hyprland config; `install.sh gpu`
only prints it and installs the udev rule it depends on.

---

## `nvidia-offload`

```
nvidia-offload blender
nvidia-offload vkcube
nvidia-offload glxinfo | grep "OpenGL renderer"
```

It exports the PRIME render-offload variables and `exec`s the command:

| Variable | Purpose |
| --- | --- |
| `__NV_PRIME_RENDER_OFFLOAD=1` | enable GLX/EGL offload |
| `__NV_PRIME_RENDER_OFFLOAD_PROVIDER=NVIDIA-G0` | the NVIDIA provider name |
| `__GLX_VENDOR_LIBRARY_NAME=nvidia` | use the NVIDIA GLX vendor library |
| `__VK_LAYER_NV_optimus=NVIDIA_only` | Vulkan: prefer the NVIDIA ICD via the optimus layer |
| `__EGL_VENDOR_LIBRARY_FILENAMES=<nvidia json>` | EGL: prefer the NVIDIA vendor library (only if that file exists) |

These are **not** set globally in the session — the desktop is AMD, and forcing
`__GLX_VENDOR_LIBRARY_NAME=nvidia` session-wide would be wrong. They live only
inside this wrapper, per invocation.

### CUDA vs render offload

`nvidia-offload` is **only** for making a graphics app *render* on the NVIDIA
GPU. It does nothing for compute:

- A CUDA app (PyTorch, TensorFlow, `nvcc`-built code, a **CUDA** Blender render,
  OptiX, `nvidia-smi`) selects the NVIDIA device through the CUDA driver /
  `CUDA_VISIBLE_DEVICES` directly. None of the offload variables affect it.
- Run compute workloads **normally**, not through `nvidia-offload`.
- Render offload and compute are independent code paths in the driver.

---

## Power / RTD3

The goal in ECO (the default, see `nvidia-compute-mode`):

```
power/control = auto  →  the NVIDIA GPU enters runtime suspend (D3hot / D3cold,
                         hardware permitting) when it has no clients, and CUDA
                         can still wake it automatically.
```

### What the modern driver does by itself

Observed on driver **610.57.04** with **no** module options set:

- `grep DynamicPowerManagement /proc/driver/nvidia/params` → `3` — the driver
  auto-selected fine-grained RTD3 on this supported laptop.
- `PreserveVideoMemoryAllocations: 2` — default; the suspend/resume services
  rely on it.
- The driver package ships `80-nvidia-pm.rules` setting `power/control=auto` on
  bind.
- `nvidia-suspend.service` / `nvidia-resume.service` / `nvidia-hibernate.service`
  are installed and preset-enabled.

### Old configs this repo deliberately does NOT apply

| Old advice | Why not |
| --- | --- |
| `options nvidia NVreg_DynamicPowerManagement=0x02` | The driver auto-selects the best level (observed `3`). Forcing `0x02` can *downgrade* it. Only add it if `/proc/driver/nvidia/params` shows `DynamicPowerManagement: 0` after boot. |
| `options nvidia NVreg_PreserveVideoMemoryAllocations=1` | Default on recent drivers. |
| hand-written `80-nvidia-pm.rules` | Shipped by the driver package now. `install.sh gpu` only adds one if it is genuinely missing. |
| manually `systemctl enable nvidia-suspend/resume/hibernate` | Preset-enabled by the driver package. `install.sh gpu` reports their state and prints the `enable` command only if one is disabled. |
| Early KMS (nvidia modules in the initramfs `MODULES`) | Can break resume-from-hibernate, and needs a manual initramfs rebuild. Not worth it here. |
| `nvidia-drm.modeset=1` on the kernel command line | Uses `/etc/modprobe.d` instead — no bootloader edit. |
| `nvidia-persistenced` enabled permanently | Holds the GPU at D0, defeating ECO/RTD3. Kept disabled; `nvidia-compute-mode compute` may start it on demand later (backend TBD). |
| X11 `xrandr --setprovideroutputsource` / PRIME sync | X11-only, irrelevant on Wayland. |

### D3hot vs D3cold

`runtime_status=suspended` does **not** imply D3cold. `nvidia-compute-mode
status` reports the runtime PM state and the PCI power state (`power_state`)
separately, and only claims **D3cold** when `power_state` literally reads
`D3cold`. Some Lenovo ACPI tables only reach D3hot — that is still a large power
saving, just not the maximum. This is a per-laptop fact to confirm on Gentoo.

---

## `nvidia-compute-mode`

`bin/nvidia-compute-mode` (previous stage) is the runtime policy layer on top of
this configuration:

- **ECO** (default) — ensure `power/control=auto`; let RTD3 work; CUDA still wakes.
- **COMPUTE** — keep the GPU prepared during a work session, via an abstract
  `compute_backend` (`auto` | `power-control` | `persistenced` | `none`) that is
  **not yet resolved** — first-run on Gentoo picks the right one.

`install.sh gpu` only lays the permanent groundwork; it does not change the
policy or the backend.

---

## Quickshell widget (`modules/NvidiaGpu.qml`)

A frontend for `bin/nvidia-compute-mode` — **no NVIDIA logic is duplicated in
QML**. It only shells out to the backend, parses `--json`, and renders. The
backend is looked up by name (`command -v nvidia-compute-mode`), so
`install/dotfiles.manifest` symlinks `bin/nvidia-compute-mode` and
`bin/nvidia-offload` into `~/.local/bin/` — without that, the widget could
never find the backend to be a frontend of.

Compact bar pill, one of three strings, derived entirely from backend fields
(never computed independently):

```
NVIDIA · ECO        policy=eco,     runtime != active
NVIDIA · ACTIVE      policy=eco,     runtime == active   (flags "something is keeping it awake")
NVIDIA · COMPUTE       policy=compute                    (active is expected here, not called out)
```

Clicking it opens a detail panel (a `PopupWindow` anchored under the bar) that
always shows **Policy** and **Runtime** as separate lines — `ACTIVE` is never
written back as if it were a policy, only ever read from `runtime_pm_state`.
It also separates **Runtime PM** from **PCI power state**, and only appends
"(confirmed)" to the PCI state when the backend's own `d3cold_confirmed` field
says so — the widget does not decide D3cold on its own.

### The no-wake rule, enforced in one place

While `Policy=ECO`, the automatic refresh timer calls **only**
`nvidia-compute-mode status --json` — never `--deep` — regardless of whether
`Runtime` is `active` or `suspended`. The only two code paths that can ever add
`--deep` are:

1. the refresh timer while `Policy=COMPUTE` (keeping the GPU awake is
   intentional there), or
2. `Show detailed metrics` in ECO, which takes **two explicit clicks**: the
   first only arms a warning — *"This check may wake or keep the NVIDIA GPU
   active."* — the second, separate click actually runs the one-off
   `--deep` query. It is never turned into polling.

Cadence: ECO polls `status --json` every 4.5 s; COMPUTE polls
`status --json --deep` every 3 s (both moderate, no sub-second timers). After
`Start Compute Session` / `Return to Eco`, the widget re-queries `status --json`
immediately instead of waiting for the next tick.

### Privilege boundary (unchanged from `bin/nvidia-compute-mode`)

The widget never writes `power/control`, never calls `sudo`, and holds no
privilege logic itself — that boundary lives entirely in the backend (see
above). `Start Compute Session` / `Return to Eco` call `nvidia-compute-mode
eco|compute` and then **always re-run `status --json`** to show the real
resulting state; a failed transition (missing privilege, an error from the
backend) is surfaced as an error banner, never presented as if it had
succeeded.

### `backend=auto` / unresolved

The panel distinguishes `Policy: COMPUTE` from whether a keep-awake mechanism
is actually in effect: when `backend` is `auto` or `none` (or `backend_active`
is false), it shows `Backend: auto (unresolved)` plus a warning that COMPUTE is
recorded but not yet guaranteeing keep-awake — it is never presented as a fully
active COMPUTE session.

### Clients

Labelled `Detected NVIDIA clients (best-effort)`, straight from the backend's
`clients` array — the wording never claims the list is complete or that those
are necessarily all the processes responsible. Nothing is ever killed.

---

## Requires Gentoo first-run validation

- [ ] `cat /sys/module/nvidia_drm/parameters/modeset` returns `Y` after reboot
      (add `/etc/modprobe.d/hypr-nvidia.conf` if not)
- [ ] `grep DynamicPowerManagement /proc/driver/nvidia/params` — if `0`, add
      `options nvidia NVreg_DynamicPowerManagement=0x02`
- [ ] whether `x11-drivers/nvidia-drivers` ships the RTD3 `power/control` udev
      rule (if yes, skip `80-nvidia-rtd3.rules`)
- [ ] `nvidia-suspend.service` / `nvidia-resume.service` / `nvidia-hibernate.service`
      installed and enabled (USE flags / `systemctl enable` if not)
- [ ] whether the GPU reaches **D3cold** or only **D3hot** on this laptop's ACPI
- [ ] `AQ_DRM_DEVICES` with `/dev/dri/hypr-primary` first actually starts the
      Hyprland session (add `hypr-secondary` if it hangs)
- [ ] a real `compute_backend` for `nvidia-compute-mode compute`
- [ ] suspend/resume across a few real cycles with the NVIDIA GPU both asleep
      and awake
- [ ] `modules/NvidiaGpu.qml` against real `nvidia-compute-mode` output — no
      `qs`, `qmllint`, or Quickshell runtime is available on Fedora, so the
      QML has only been verified statically and by extracting and exercising
      its real JS logic outside a QML engine (see the stage's commit)

---

## References

- Hyprland wiki — Multi-GPU: `wiki.hypr.land/Configuring/Multi-GPU/`
- Hyprland wiki — NVIDIA: `wiki.hypr.land/Nvidia/`
- Gentoo wiki — `NVIDIA/nvidia-drivers`, `Hybrid graphics`
- NVIDIA driver README — "PRIME Render Offload", "Dynamic Power Management"

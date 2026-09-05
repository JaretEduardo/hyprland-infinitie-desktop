# Machine profiles

`profiles/` separates two kinds of decision that this repo otherwise mixes
together implicitly:

- **common** — defaults that apply to any machine this repo targets (Gentoo +
  systemd, Hyprland, Quickshell, NetworkManager, PipeWire/WirePlumber, AMD
  primary / NVIDIA on-demand, ...). Already true today, just not written down
  anywhere as data until this stage.
- **a specific machine** — hardware that is only true of *this* Lenovo, kept
  separate so it's obvious what would need to change (or simply wouldn't
  apply) on different hardware.

This is deliberately small: a profile is one flat `key=value` data file and a
handful of functions in `lib/profile.sh` that read it and cross-check it
against `lib/hardware.sh`. It is not a generic templating or override system,
and it never writes anything — see "What a profile is not", below.

## Layout

```
profiles/
  common/
    profile.conf          no match.* fields -> the fallback profile
  lenovo-82sc/
    profile.conf           matched by real DMI data (LENOVO / 82SC)
```

Adding a new machine means adding one new `profiles/<id>/profile.conf` — the
loader (`lib/profile.sh`) already enumerates whatever directories exist
under `profiles/`, nothing else needs to change.

## Profile file format

Plain `key=value` lines, one per line, `#` comments and blank lines ignored.
**`profile.conf` is never sourced or executed as shell** — it is parsed with
`grep`/`awk` only, so it cannot contain arbitrary logic, command
substitution, or side effects by construction.

| Field | Meaning |
| --- | --- |
| `id` | the profile's own id (should match its directory name) |
| `name` | human-readable label |
| `match.sys_vendor`, `match.product_name`, `match.product_version`, `match.product_family`, `match.board_name` | real DMI fields (`/sys/class/dmi/id/*`) this profile requires to match. **All** present `match.*` fields must agree (AND). A profile with **zero** `match.*` fields can never be matched this way — that's what makes `common` the fallback rather than a DMI match. |
| `laptop`, `hybrid_gpu` | `1`/unset feature flags, informational |
| `primary_gpu`, `secondary_gpu`, `nvidia_role` | which GPU is which, and how NVIDIA is expected to be used (`on-demand`, ...) |
| `internal_panel_role` | e.g. `edp` — a hint, never a hardcoded connector name |
| `init`, `network_backend`, `audio_stack`, `compositor`, `shell`, `primary_gpu_preference` | `common`'s own defaults; not duplicated from `install/packages.gentoo`, just named here |
| `expect.cpu_vendor` | e.g. `AuthenticAMD` |
| `expect.igpu_pci`, `expect.dgpu_pci`, `expect.wifi_pci`, `expect.eth_pci` | `VVVV:DDDD` PCI vendor:device ids, checked against **any** matching device regardless of bus address or PCI enumeration order |
| `expect.igpu_desc`, `expect.dgpu_desc`, `expect.wifi_desc`, `expect.eth_desc` | human labels shown next to the corresponding `expect.*_pci` check |
| `expect.battery`, `expect.backlight` | `1` to expect a battery / backlight device to be present |
| `note.*` | free-text, informational only, shown verbatim by `install.sh profile` — **never** applied automatically |

`profiles/lenovo-82sc/profile.conf` deliberately does **not** contain a
monitor connector name or resolution as an effective setting — only a
`note.internal_resolution` / `note.internal_reset` pair labeled as
informational. The real monitor configuration is always resolved for real,
live, by `install.sh monitor` / `first-run` (see
[FIRST-RUN.md](FIRST-RUN.md#monitor-configuration-installsh-monitor)) — a
profile note can go stale or be wrong for a given unit and must never
override that detection.

## How `lenovo-82sc` is matched

```
match.sys_vendor=LENOVO
match.product_name=82SC
```

Both come straight from `/sys/class/dmi/id/sys_vendor` and
`/sys/class/dmi/id/product_name` — real firmware data, read the same way
`lib/hardware.sh` already reads it for `install.sh check`. **The hostname is
never used.** If both DMI fields agree, `lib/profile.sh`'s
`profile::detect` returns `lenovo-82sc`; if either differs (different
machine, or a BIOS that reports these fields differently), it falls back to
`common` and `install.sh profile` prints a warning, never an error — an
unrecognised machine is expected to happen and must not block anything.

## Hardware expectations for `lenovo-82sc`

Checked read-only, by PCI vendor:device id (or presence, for
battery/backlight), never by a fixed PCI bus address:

| Expectation | PCI id |
| --- | --- |
| AMD Radeon 680M (iGPU) | `1002:1681` |
| NVIDIA RTX 3050 Ti Mobile (dGPU) | `10de:25a0` |
| MediaTek MT7921 Wi-Fi | `14c3:7961` |
| Realtek RTL8111/8168 Ethernet | `10ec:8168` |
| CPU vendor | `AuthenticAMD` |
| Battery | present (`BAT1` on this unit) |
| Backlight | present (`amdgpu_bl1` on this unit) |

A missing expectation is a **warning**, never fatal — PCI ids and driver
binding are real facts that can legitimately be absent (docked, a driver not
loaded yet, a BIOS toggle) without anything being wrong.

## Integration with `check` / `doctor` / `first-run`

No detection logic is duplicated anywhere; each command only *consumes*
`lib/profile.sh`:

- **`check`** — one line in the "Machine" section: the detected profile id
  and name.
- **`doctor`** — its own "Machine profile" section: the match result plus
  every `expect.*` check, each folded into doctor's existing `[OK]`/`[WARN]`
  tally the same way every other doctor check already is.
- **`first-run`** — calls `install.sh profile` itself (not a re-detection) as
  the first thing in its "Baseline" section, purely as context for the
  sections that follow.

`install.sh profile` also exists standalone (`./install.sh profile` /
`--json`) for anything that wants just the profile, without the rest of
`check`/`doctor`.

## What a profile is not

- **Not an installer.** Detecting `lenovo-82sc` never writes a file, sets a
  config value, or runs a command by itself. Every command that actually
  changes something (`gpu`, `power`, `dotfiles`, `monitor`, ...) still goes
  through its own detect → explain → show → confirm → apply — a profile only
  informs what gets shown, exactly like any other piece of detected context.
- **Not a general templating system.** There is no inheritance, no
  overriding one profile's fields from another, no conditionals inside
  `profile.conf`. If that's ever needed for real, it should grow deliberately
  then — not be speculatively built in now.
- **Not a source of effective monitor/GPU config.** `expected_internal_resolution`-style
  `note.*` fields are read-only hints for a human, never consumed as
  overrides by `install.sh monitor`, `gpu`, or anything else.

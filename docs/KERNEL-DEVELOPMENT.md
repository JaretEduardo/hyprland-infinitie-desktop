# Kernel development

`install.sh kernel-dev` is a readiness checker, a detector, and a
reproducible-command generator for Linux kernel development on this
workstation — never a kernel builder. It does not run `make`, does not clone
or modify any kernel source tree, does not write to `/boot`, does not run
`make install` / `make modules_install`, does not touch the bootloader/EFI,
does not run `dracut`/`genkernel`, does not change the `/usr/src/linux`
symlink, and does not reboot. Every command it prints is meant to be copied
and run by you, exactly as printed.

```
install.sh kernel-dev             everything below
install.sh kernel-dev --check     just the toolchain/tool readiness list
install.sh kernel-dev --env       just source tree / output dir / jobs
install.sh kernel-dev --commands  just the reproducible command list
```

There is no `--apply` and there will not be one — see "Safety", below.

## Dependencies

Reuses `install/packages.gentoo`'s `kernel-dev` group (see
[INSTALL.md](INSTALL.md#deps--gentoo-package-plan) for `install.sh deps`,
which prints the actual `emerge`/overlay commands). `kernel-dev --check`
additionally checks whether each tool is actually on `PATH` right now, the
same way `install.sh check`/`doctor` already do for their own tools — that
is a genuinely different question from "is the atom merged" and is not a
duplicate of what `deps` reports.

Atoms verified against the official Gentoo tree (2026-09) for this stage:
`sys-devel/sparse`, `dev-libs/elfutils`, `dev-libs/openssl`, `llvm-core/lld`
were added to the catalogue's `kernel-dev` group; everything else needed
(`dev-vcs/git`, `dev-build/make`, `llvm-core/clang`, `sys-devel/gcc`,
`sys-devel/binutils`, `sys-devel/bc`, `sys-devel/flex`, `sys-devel/bison`,
`sys-libs/ncurses`, `dev-util/pahole`, `dev-util/ccache`) was already there.
`perl` and `python` are part of Gentoo's `@system` set already — not listed
as atoms, but still checked for on `PATH` since Kconfig and several kernel
scripts need them at runtime.

## Current system vs. this command

This machine (Fedora, Ryzen 7 6800H, 16 GB RAM — the same hardware
[`profiles/lenovo-82sc`](PROFILES.md) describes) is not hardcoded anywhere in
`kernel-dev.sh`. Parallelism, CPU core count and RAM come from
`lib/hardware.sh` (`hw::cpu`, the new `hw::mem_total_gb`), read fresh every
run — on Gentoo, on different hardware, or on this same Fedora host, the
command reports whatever is real at the time.

## Source tree detection

Checked in this order, first valid one wins — **never guessed further, never
written to, never deleted**:

1. `$KERNEL_SRC` — explicit override, if set
2. `~/src/linux` — the preferred layout for actual kernel *development*
   (your own clone, easy to add worktrees off)
3. `/usr/src/linux` — the Gentoo `eselect-kernel` symlink (points at
   whichever `sys-kernel/gentoo-sources` version `eselect kernel set`
   picked)

A path only counts as a real kernel source tree if it has its own `Makefile`
(with a `VERSION = ` line) and `Kconfig` at the top — a stray empty directory
or a broken symlink at one of these paths is reported honestly (`exists, not
a kernel tree` / `broken symlink`), never silently treated as a hit. If more
than one candidate is valid, all of them are listed, the chosen one is
marked, and nothing is touched either way.

If none are found, `kernel-dev --check` explains three ways to get one
(Gentoo sources + `eselect kernel`, your own `git clone`, a `git worktree`
off an existing clone) — as text only, nothing is run.

## Output directory (out-of-tree build)

Suggested as `~/build/linux` by default (override with `$KERNEL_BUILD_DIR`),
passed to every build/config command as `O=<dir>`. This keeps the source
tree clean — no `.o`/`.config`/generated files mixed into `git status` on
whatever you cloned into `~/src/linux`. `O=<dir>` and its own `.config`
travel together: config commands below always target
`O=<dir>/.config`, never the source tree's.

## Config

`kernel-dev --commands` picks the first config source that actually exists,
in order:

1. an existing `.config` already in the output dir or the source tree →
   just `make O=<dir> olddefconfig` to refresh it
2. `/proc/config.gz`, if the **running** kernel exposes
   `CONFIG_IKCONFIG_PROC` → `zcat /proc/config.gz > <dir>/.config`
3. `/boot/config-$(uname -r)`, if present → copied in as a starting point
4. otherwise, `make O=<dir> defconfig` — the tree's own defaults

`make O=<dir> menuconfig` is always shown too (needs `sys-libs/ncurses`).

**`make localmodconfig` is documented, never run.** It trims the config down
to only the modules `lsmod` shows loaded on THIS boot — anything not
currently loaded (a USB device unplugged, a filesystem not mounted, a
network driver for hardware that's asleep) gets dropped from the resulting
config. Useful for a fast personal-build config, risky as-is for anything
you'll boot generally without reviewing the diff first.

## Build

```
make O=<dir> -j<N>                # GCC
make O=<dir> LLVM=1 -j<N>         # Clang/LLVM
```

Per the kernel's own `Documentation/kbuild/llvm.rst` (checked for this
stage): the integrated assembler is **already the default** once you pass
`LLVM=1` — `LLVM_IAS=0` is only needed if you specifically want Clang to
invoke the non-integrated (GNU) assembler instead (e.g. targets without full
LLVM assembler support). Older guidance that always pairs `LLVM=1` with
`LLVM_IAS=1` is redundant on current kernels, not wrong, just unnecessary.

`make O=<dir> modules -j<N>` builds modules only;
`make O=<dir> M=<subdir> -j<N>` builds one module subdirectory (e.g.
`M=drivers/net/wireless`).

### Parallelism (`-j<N>`)

Never just `nproc`. The recommendation is
`min(physical cores, RAM_GB / 2)`, explained inline every time it's shown —
for example, on 8 physical cores / 16 threads and ~15 GB RAM detected:
`min(8, 15/2) = 7`. The reasoning: a single GCC/Clang compile unit can peak
past 1 GB RSS with debug info (`CONFIG_DEBUG_INFO_BTF`/DWARF) enabled: 16
parallel jobs on 15 GB can mean real swap thrashing the moment anything else
(a browser, an IDE) is also running. The suggestion is a safe starting
point, not a hard ceiling — watch `free -h` during your first build on a
given tree and raise `-j` if memory stays idle.

## `compile_commands.json`

```
make O=<dir> compile_commands.json
```

Verified for this stage against the current kernel Makefile: this target
already exists upstream and wraps
`scripts/clang-tools/gen_compile_commands.py` (the current, correct path —
some older guidance online still references `scripts/gen_compile_commands.py`
at the top level, which has moved). It needs object files or `.cmd` files to
already exist, so build first (even a partial build is enough — it only
reads what's already been compiled). Call the script directly only if you
need flags the Makefile target doesn't expose (`--directory`, `--output`
for unusual layouts).

## Static analysis

```
make O=<dir> C=1 CHECK=sparse   # sparse only on files the build actually recompiles
make O=<dir> C=2 CHECK=sparse   # sparse on ALL files, whether recompiled or not
```

`clang-format -i <file>.c` is suggested only when the detected source tree
ships its own `.clang-format` (mainline `torvalds/linux` does).

## Patch workflow

Real, unautomated `git` — `kernel-dev` prints this as reference text, it
never runs any of it:

```
git status
git diff
git add -p
git commit -s                              # -s: sign-off, required upstream
<tree>/scripts/checkpatch.pl <patch>
<tree>/scripts/get_maintainer.pl <patch>
```

Sending patches (`git send-email`, `--to`/`--cc` sourced from
`get_maintainer.pl`'s own output) is deliberately **not** built here — that
is a real, externally-visible action (mailing a maintainer/list) and stays
entirely manual. No commit is ever made for you, and no attribution/tooling
metadata is added to a commit message on your behalf — a kernel patch's
authorship is yours alone.

## Module development

Two genuinely different things:

- **Out-of-tree module** — your own `.c`/`Makefile` outside the kernel
  source tree entirely, built against the *running* kernel's build symlink:

  ```
  make -C /lib/modules/$(uname -r)/build M=$PWD modules
  ```

  A minimal out-of-tree `Makefile`:

  ```make
  obj-m += mymodule.o

  all:
  	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) modules
  clean:
  	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) clean
  ```

  No example module is added to this repo — it would just be dead weight
  sitting in a config repo that isn't about kernel module code itself.

- **In-tree module** — a driver added under `drivers/` (or similar) inside
  a real kernel source tree (`~/src/linux`, from the detection above), built
  as part of that tree's own `make`/`make modules` (or singled out with
  `M=drivers/your/subdir`), and subject to the tree's own `Kconfig`/Kbuild
  wiring (`obj-$(CONFIG_YOUR_OPTION) += yourdriver.o` in that directory's
  `Makefile`). This is the path for anything you intend to eventually send
  upstream, since it lives, builds and is reviewed the same way the rest of
  the kernel is.

## Safety

`kernel-dev` never does any of the following — if a step below is shown at
all, it is explicitly marked as a manual, deliberate, out-of-scope action:

- `make install` / `make modules_install`
- `grub-mkconfig` / `grub2-mkconfig`
- `efibootmgr`
- `dracut` / `genkernel` (initramfs generation)
- `eselect kernel set <N>` (changes the `/usr/src/linux` symlink)
- replacing the kernel currently booted
- a reboot
- cloning or installing a kernel source tree automatically
- running `emerge`, `sudo`, or any privileged command

## What this needs a real Gentoo target to confirm

Toolchain versions, whether `sys-kernel/gentoo-sources` + `eselect-kernel`
behave as described, and whether the parallelism recommendation holds up
under a real allmodconfig-scale build can only be confirmed on the real
Gentoo target — this was developed and tested on Fedora, where `kernel-dev`
correctly reports real tool presence and a real (if empty) source-tree
picture without pretending to be Gentoo.

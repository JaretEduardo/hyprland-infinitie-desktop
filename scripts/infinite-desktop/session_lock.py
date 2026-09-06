"""session_lock.py — per-Hyprland-session lifecycle for the Infinite Desktop daemon.

Goal: every Hyprland session has AT MOST ONE infinite_desktop_core.py, and that
instance dies when the session that launched it ends. Three mechanisms, none of
which hardcode a PID or /run/user/<uid>:

  * a per-session advisory lock  ($XDG_RUNTIME_DIR/infinite-desktop/<sig>.lock)
    - the kernel releases an flock automatically when the holder dies, so a
      stale lock never blocks a new instance — no PID bookkeeping, no pkill.
    - a *different* session = a different <sig> = a different lock file, so a
      new session always gets to start its own instance, and an instance from
      an older session never blocks it.
  * a watchdog thread that polls the launching Hyprland instance
    (its pid from $XDG_RUNTIME_DIR/hypr/<sig>/hyprland.lock) and exits the
    daemon once that process is gone.
  * per-session logging to $XDG_RUNTIME_DIR/infinite-desktop/<sig>.log — never
    one shared /tmp file that daemons from other sessions also append to
    (that was the actual bug: contradictory interleaved logs).

`$XDG_RUNTIME_DIR` is itself per-user and tmpfs (wiped on final logout), so the
lock/log files do not accumulate across reboots.
"""

import errno
import fcntl
import os
import re
import stat as _stat
import time

_TMP_COMPAT_LOG = "/tmp/infinite-desktop.log"   # kept as a courtesy symlink only

# The "current.log" convenience pointer and per-user manual-run files are ours,
# not per-session state to garbage-collect.
_RESERVED_KEYS = {"current"}
# A real Hyprland instance signature: <hex>_<unix-seconds>_<pid-ish>.
_SIG_RE = re.compile(r"^[0-9a-f]+_[0-9]+_[0-9]+$")


def runtime_dir():
    d = os.environ.get("XDG_RUNTIME_DIR")
    if d and os.path.isdir(d):
        return d
    return "/run/user/%d" % os.getuid()


def session_signature():
    """The Hyprland instance signature that launched us, or None when we were
    not started from inside a Hyprland session (a manual dev run)."""
    return os.environ.get("HYPRLAND_INSTANCE_SIGNATURE") or None


def state_dir(create=True):
    d = os.path.join(runtime_dir(), "infinite-desktop")
    if create:
        try:
            os.makedirs(d, mode=0o700, exist_ok=True)
        except OSError:
            pass
    return d


def _key(sig):
    return (sig or ("nosession-%d" % os.getuid())).replace("/", "_")


def lock_path(sig):
    return os.path.join(state_dir(), _key(sig) + ".lock")


def session_log_path(sig):
    return os.path.join(state_dir(), _key(sig) + ".log")


# ---------------------------------------------------------------------------
# single instance, per session
# ---------------------------------------------------------------------------

def acquire_session_lock(sig):
    """Try to become THE Infinite Desktop instance for this session.

    Returns (fd, None) on success — keep `fd` open for the whole process
    lifetime; closing it (or exiting) releases the lock.
    Returns (None, holder) when another live instance for this same session
    already holds it (`holder` is its pid as a string, or "?").
    """
    path = lock_path(sig)
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as e:
        os.close(fd)
        if e.errno in (errno.EWOULDBLOCK, errno.EAGAIN, errno.EACCES):
            try:
                with open(path) as f:
                    holder = f.read().strip().splitlines()[0]
            except (OSError, IndexError):
                holder = "?"
            return None, (holder or "?")
        raise
    # we own it — record our pid so `doctor` can show it (the flock, not this
    # number, is the source of truth for "is it running").
    try:
        os.ftruncate(fd, 0)
        os.write(fd, ("%d\n" % os.getpid()).encode())
        os.fsync(fd)
    except OSError:
        pass
    return fd, None


# ---------------------------------------------------------------------------
# session-death detection
# ---------------------------------------------------------------------------

def _hyprland_pid(sig):
    p = os.path.join(runtime_dir(), "hypr", sig, "hyprland.lock")
    try:
        with open(p) as f:
            return int(f.readline().strip())
    except (OSError, ValueError):
        return None


def _proc_comm(pid):
    try:
        with open("/proc/%d/comm" % pid) as f:
            return f.read().strip()
    except OSError:
        return ""


def hyprland_alive(sig, _comm=None):
    """True if the Hyprland instance <sig> that launched us is still running.
    With no session binding (`sig` falsy) this returns True — a manual run
    must never self-exit. `_comm` is a test seam for the /proc/<pid>/comm read.
    """
    if not sig:
        return True
    pid = _hyprland_pid(sig)
    if not pid or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True   # exists, just not ours to signal
    comm = _proc_comm(pid) if _comm is None else _comm
    return comm.startswith("Hypr")


def watch_session(sig, on_dead, poll=5.0, strikes_needed=2, _alive=None):
    """Block, polling the launching Hyprland session; call `on_dead()` once it
    has been gone for `strikes_needed` consecutive polls (a small grace window
    for transient fs hiccups). No-op without a session binding. `_alive` is a
    test seam for the liveness check."""
    if not sig:
        return
    alive = _alive or hyprland_alive
    strikes = 0
    while True:
        time.sleep(poll)
        if alive(sig):
            strikes = 0
            continue
        strikes += 1
        if strikes >= strikes_needed:
            on_dead()
            return


# ---------------------------------------------------------------------------
# per-session logging
# ---------------------------------------------------------------------------

def redirect_output_to_session_log(sig):
    """Point fd 1 and 2 at this session's own log file, so daemons from two
    sessions never interleave into one file. Returns the log path, or None if
    it could not be set up (output then stays wherever it was)."""
    path = session_log_path(sig)
    try:
        logfd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    except OSError:
        return None
    try:
        os.dup2(logfd, 1)
        os.dup2(logfd, 2)
    except OSError:
        pass
    finally:
        if logfd > 2:
            os.close(logfd)
    _point(os.path.join(state_dir(), "current.log"), path)
    _point(_TMP_COMPAT_LOG, path, tmp_safe=True)
    return path


def _point(link, target, tmp_safe=False):
    """Best-effort: make `link` a symlink to `target`. In a world-writable
    directory (/tmp) only touch `link` if it is absent, already a symlink, or
    a plain file this user owns — never clobber someone else's file."""
    try:
        if os.path.lexists(link):
            if tmp_safe:
                st = os.lstat(link)
                if not _stat.S_ISLNK(st.st_mode) and not (
                    _stat.S_ISREG(st.st_mode) and st.st_uid == os.getuid()
                ):
                    return
            os.unlink(link)
        os.symlink(target, link)
    except OSError:
        pass


# ---------------------------------------------------------------------------
# housekeeping
# ---------------------------------------------------------------------------

def gc_dead_sessions(current_sig):
    """Remove <sig>.lock / <sig>.log left behind by Hyprland sessions that are
    no longer running. Best-effort; never touches the current session's files
    or a session that is still alive."""
    d = state_dir(create=False)
    try:
        entries = os.listdir(d)
    except OSError:
        return
    seen = set()
    cur = _key(current_sig)
    for name in entries:
        if not (name.endswith(".lock") or name.endswith(".log")):
            continue
        sig = name.rsplit(".", 1)[0]
        if sig in seen or sig == cur or sig in _RESERVED_KEYS:
            continue
        seen.add(sig)
        # only collect things that are actually a past Hyprland session
        if not _SIG_RE.match(sig):
            continue
        if hyprland_alive(sig):
            continue
        for ext in (".lock", ".log"):
            try:
                os.unlink(os.path.join(d, sig + ext))
            except OSError:
                pass

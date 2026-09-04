// services/Frame.qml — the IPC contract Infinite Desktop's evdev daemon talks
// to, plus the "held hidden" state Bar.qml observes.
//
// scripts/infinite-desktop/infinite_desktop_core.py calls, around a
// SUPER + ALT pan gesture (notify_quickshell_hold(), unchanged by this stage):
//
//     qs ipc call frame setHeldHidden true    (on press)
//     qs ipc call frame setHeldHidden false   (on release)
//
// IpcHandler routes "qs ipc call <target> <function> <args...>" to a function
// of the same name on the handler with target == <target>. A `bool` argument
// accepts "true"/"false" (or 0/other-than-0) exactly as the Python side sends
// it — see https://quickshell.org/docs/v0.3.0/types/Quickshell.Io/IpcHandler/.
// The Python code is not touched; this file only has to satisfy the contract
// it already calls.
//
// "The frame" here is the shell's own visual chrome (Bar.qml) — the thing that
// stays fixed on screen while Infinite Desktop pans every floating window
// underneath it. Bar.qml binds its visibility to !heldHidden, so it disappears
// for the duration of the pan and reappears the instant the daemon releases it.

import Quickshell.Io

IpcHandler {
    id: root
    target: "frame"

    // true while Infinite Desktop is actively panning the canvas.
    property bool heldHidden: false

    function setHeldHidden(hidden: bool): void {
        root.heldHidden = hidden;
    }
}

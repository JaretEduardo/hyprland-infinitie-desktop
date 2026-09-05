// shell.qml — entrypoint. Keep this file tiny: it wires the Frame IPC service
// to the Bar and nothing else. NVIDIA compute-mode UI, hypridle/hyprlock,
// power/lid handling, and a first-run/monitor step are deliberately not here
// yet (later stages).
//
// import "./..." pulls in sibling QML files by filename as types — no module
// manifest needed for a shell this small.
// https://quickshell.org/docs/v0.3.0/guide/qml-language

import Quickshell
import "./services"

ShellRoot {
    Frame {
        id: frame
    }

    Bar {
        frame: frame
    }
}

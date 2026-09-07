pragma Singleton
// OpenAppsModel.qml — the ONE list of open-application groups.
//
// modules/OpenApps.qml renders it as the navbar's open-app row; shell.qml's
// `openapps` IpcHandler drives keyboard navigation from the SAME list
// (Super+Alt+Tab / Super+Alt+Shift+Tab / Super+Alt+1..9 — see
// lua/window-edit.lua). Identical order and filters, so the number a key uses
// is always the icon the user sees.
//
// Navigation reuses scripts/infinite-desktop/world_navigate.py in `class` mode:
// it flies the Infinite Desktop camera to the app (relative layout preserved)
// and cycles that app's windows when the same shortcut repeats. No workspace
// switching, no single-window yank — same mechanism the mouse click already
// uses.
import QtQuick
import Quickshell
import Quickshell.Hyprland

Singleton {
    id: root

    readonly property string navScript:
        Quickshell.env("HOME") + "/scripts/world_navigate.py"

    // Layer surfaces (Quickshell, fuzzel, hyprlock) are not toplevels and never
    // reach here; this covers the rest.
    readonly property var denyClasses: [
        "quickshell", "fuzzel", "hyprlock", ""
    ]

    // [{ key: classLower, cls: classRaw, count }] — left-to-right, one per app
    property var groups: []

    function rebuild() {
        const by = {};
        const list = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        for (const t of list) {
            const o = t.lastIpcObject || {};
            const raw = (o["initialClass"] || o["class"] || "").trim();
            const key = raw.toLowerCase();
            if (key === "" || root.denyClasses.indexOf(key) !== -1) continue;
            if ((o.workspace || {}).id <= 0) continue;   // special workspace
            if (!by[key]) by[key] = { key: key, cls: raw, count: 0 };
            by[key].count++;
        }
        const out = [];
        for (const k in by) out.push(by[k]);
        out.sort((a, b) => a.cls.localeCompare(b.cls));
        root.groups = out;
    }

    function _activeClass() {
        const a = Hyprland.activeToplevel;
        const o = a ? a.lastIpcObject : null;
        return o ? (o["initialClass"] || o["class"] || "").trim().toLowerCase() : "";
    }

    function _nav(cls) {
        Quickshell.execDetached(["python3", root.navScript, "class", cls]);
    }

    // qs ipc call openapps activate <1..N> — the Nth icon, left to right.
    function activate(index) {
        rebuild();
        if (index >= 1 && index <= root.groups.length)
            root._nav(root.groups[index - 1].cls);
    }

    // qs ipc call openapps next | prev — relative to the focused app; wraps.
    function step(dir) {
        rebuild();
        const n = root.groups.length;
        if (n === 0) return;
        const cur = root._activeClass();
        let i = -1;
        for (let k = 0; k < n; k++)
            if (root.groups[k].key === cur) { i = k; break; }
        const target = (i === -1)
            ? (dir > 0 ? 0 : n - 1)
            : (((i + dir) % n) + n) % n;
        root._nav(root.groups[target].cls);
    }

    // keep `groups` current (same triggers the navbar row used before)
    Component.onCompleted: { Hyprland.refreshToplevels(); rebuild(); }
    Connections {
        target: Hyprland
        function onRawEvent(e) {
            const n = e.name;
            if (n === "openwindow" || n === "closewindow"
                || n === "movewindowv2" || n === "windowtitlev2"
                || n === "changefloatingmode")
                deb.restart();
        }
    }
    Connections {
        target: Hyprland.toplevels
        function onValuesChanged() { root.rebuild(); }
    }
    Timer { id: deb; interval: 60; onTriggered: { Hyprland.refreshToplevels(); root.rebuild(); } }
}

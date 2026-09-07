// modules/OpenApps.qml — a compact row of open-application icons in the navbar.
//
// Grouped by window class. A small badge shows the window count when an app has
// more than one. Click → scripts/infinite-desktop/world_navigate.py flies the
// Infinite Desktop camera to that app (cycling its windows on repeated clicks) —
// it does NOT yank a single window to the viewport.
//
// Layer surfaces (Quickshell, fuzzel, hyprlock) are not toplevels, so they
// never appear here. A small deny-list covers the rest.
import QtQuick
import Quickshell
import Quickshell.Hyprland
import "root:/"

Row {
    id: root
    spacing: 4

    readonly property string navScript:
        Quickshell.env("HOME") + "/scripts/world_navigate.py"

    readonly property var denyClasses: [
        "quickshell", "fuzzel", "hyprlock", ""
    ]

    // { key: classLower, cls, count, icon }  — rebuilt on window events
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

    Repeater {
        model: root.groups
        delegate: Item {
            required property var modelData
            width: 20; height: Theme.navHeight - 8

            Rectangle {
                anchors.fill: parent
                radius: Theme.radiusSmall
                color: appMouse.containsMouse ? Theme.surfaceHover : "transparent"
            }
            Image {
                id: ico
                anchors.centerIn: parent
                width: 15; height: 15
                asynchronous: true
                fillMode: Image.PreserveAspectFit
                source: {
                    const e = DesktopEntries.heuristicLookup(modelData.cls);
                    const p = e ? Quickshell.iconPath(e.icon, true) : "";
                    return p && p.length ? p : "";
                }
                visible: status === Image.Ready
            }
            Text {
                anchors.centerIn: parent
                visible: ico.status !== Image.Ready
                text: (modelData.cls[0] || "?").toUpperCase()
                font.family: Theme.fontFamily; font.pixelSize: 11; font.bold: true
                color: Theme.foregroundMuted
            }
            Rectangle {   // count badge
                visible: modelData.count > 1
                anchors { right: parent.right; top: parent.top; rightMargin: -2; topMargin: -1 }
                width: 11; height: 11; radius: 5.5
                color: Theme.accent
                Text {
                    anchors.centerIn: parent
                    text: modelData.count
                    font.family: Theme.fontFamily; font.pixelSize: 8; font.bold: true
                    color: Theme.scrim
                }
            }
            MouseArea {
                id: appMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: Quickshell.execDetached(["python3", root.navScript,
                                                    "class", modelData.cls])
            }
        }
    }
}

// modules/OpenApps.qml — a compact row of open-application icons in the navbar.
//
// Grouped by window class, a badge shows the window count when an app has more
// than one. Click → the Infinite Desktop camera flies to that app (cycling its
// windows on repeated clicks) — it does NOT yank a single window to the
// viewport.
//
// The list itself lives in OpenAppsModel.qml (a singleton) so the keyboard
// shortcuts (Super+Alt+Tab / Super+Alt+1..9, via shell.qml's `openapps`
// IpcHandler and lua/window-edit.lua) navigate the exact same groups, in the
// exact same order, that are drawn here.
import QtQuick
import Quickshell
import "root:/"

Row {
    id: root
    spacing: 4

    Repeater {
        model: OpenAppsModel.groups
        delegate: Item {
            id: entry
            required property var modelData
            required property int index
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
                    const e = DesktopEntries.heuristicLookup(entry.modelData.cls);
                    const p = e ? Quickshell.iconPath(e.icon, true) : "";
                    return p && p.length ? p : "";
                }
                visible: status === Image.Ready
            }
            Text {
                anchors.centerIn: parent
                visible: ico.status !== Image.Ready
                text: (entry.modelData.cls[0] || "?").toUpperCase()
                font.family: Theme.fontFamily; font.pixelSize: 11; font.bold: true
                color: Theme.foregroundMuted
            }
            Rectangle {   // count badge
                visible: entry.modelData.count > 1
                anchors { right: parent.right; top: parent.top; rightMargin: -2; topMargin: -1 }
                width: 11; height: 11; radius: 5.5
                color: Theme.accent
                Text {
                    anchors.centerIn: parent
                    text: entry.modelData.count
                    font.family: Theme.fontFamily; font.pixelSize: 8; font.bold: true
                    color: Theme.scrim
                }
            }
            MouseArea {
                id: appMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                // same call the keyboard uses (1-based, left to right)
                onClicked: OpenAppsModel.activate(entry.index + 1)
            }
        }
    }
}

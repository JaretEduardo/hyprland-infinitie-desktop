// modules/Workspaces.qml — a long row of tiny marks, the visual centrepiece of
// the navbar. Focused = a clear mint/green ring with a hollow centre; occupied
// = a small soft dot; inactive = a dim muted dot; urgent = an urgent dot.
// Compact spacing, event-driven (no polling). Click to switch workspace.
import QtQuick
import Quickshell.Hyprland
import "root:/"

Row {
    id: root
    spacing: 9

    Repeater {
        model: Hyprland.workspaces

        Item {
            id: ws
            required property var modelData
            readonly property bool focused: modelData.focused
            readonly property bool occupied: modelData.windows > 0
            width: 12
            height: 12

            // focused: hollow mint ring — the strong point of the navbar
            Rectangle {
                anchors.centerIn: parent
                width: 12; height: 12; radius: 6
                color: "transparent"
                border.width: 2
                border.color: Theme.positive
                visible: ws.focused
            }
            // everyone else: a small dot
            Rectangle {
                anchors.centerIn: parent
                width: ws.occupied ? 6 : 4
                height: width
                radius: width / 2
                color: ws.modelData.urgent ? Theme.urgent
                     : ws.occupied         ? Theme.withAlpha(Theme.foreground, 0.55)
                     : Theme.withAlpha(Theme.foregroundMuted, 0.30)
                visible: !ws.focused
            }

            MouseArea {
                anchors.fill: parent
                anchors.margins: -5
                cursorShape: Qt.PointingHandCursor
                onClicked: ws.modelData.activate()
            }
        }
    }
}

// modules/Workspaces.qml — Hyprland workspace indicators.
// Event-driven: Quickshell.Hyprland keeps `workspaces` in sync over Hyprland's
// event socket, no polling. https://quickshell.org/docs/v0.3.0/types/Quickshell.Hyprland/Hyprland/

import QtQuick
import Quickshell.Hyprland

Row {
    id: root
    spacing: 6

    Repeater {
        model: Hyprland.workspaces

        Rectangle {
            id: dot
            required property var modelData

            width: 20
            height: 20
            radius: 5
            color: modelData.focused ? "#7aa2f7"
                 : modelData.urgent  ? "#f7768e"
                 : "#2a2e3f"

            Text {
                anchors.centerIn: parent
                text: dot.modelData.name
                font.pixelSize: 11
                color: dot.modelData.focused ? "#1a1b26" : "#c0caf5"
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: dot.modelData.activate()
            }
        }
    }
}

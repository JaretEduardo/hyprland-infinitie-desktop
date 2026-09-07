// modules/WorldButton.qml — the navbar centrepiece: a ring that opens the
// World Map (WorldMap.qml). Click toggles; Super+Tab does the same.
import QtQuick
import "root:/"

Item {
    id: root
    property bool active: false        // World Map currently open
    signal toggled()

    implicitWidth: 18
    implicitHeight: 18

    Rectangle {
        id: ring
        anchors.centerIn: parent
        width: 14; height: 14; radius: 7
        color: "transparent"
        border.width: 2
        border.color: root.active ? Theme.accent
                    : m.containsMouse ? Theme.foreground
                    : Theme.foregroundMuted
        Behavior on border.color { ColorAnimation { duration: 120 } }
    }
    Rectangle {   // "you are here" dot
        anchors.centerIn: parent
        width: root.active ? 6 : 4
        height: width; radius: width / 2
        color: root.active ? Theme.accent : Theme.withAlpha(Theme.foreground, 0.5)
        Behavior on width { NumberAnimation { duration: 120 } }
    }

    MouseArea {
        id: m
        anchors.fill: parent
        anchors.margins: -5
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggled()
    }

    // tooltip
    Rectangle {
        anchors { bottom: parent.top; bottomMargin: 8; horizontalCenter: parent.horizontalCenter }
        visible: m.containsMouse && !root.active
        width: tip.width + 14; height: 20
        radius: Theme.radiusSmall
        color: Theme.withAlpha(Theme.scrim, 0.85)
        Text {
            id: tip
            anchors.centerIn: parent
            text: "World Map"
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeSmall
            color: Theme.foreground
        }
    }
}

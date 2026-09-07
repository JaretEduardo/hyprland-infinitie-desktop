// modules/Clock.qml — compact time + weekday. SystemClock, no Timer.
import QtQuick
import Quickshell
import "root:/"

Row {
    id: root
    spacing: 5

    SystemClock { id: clock; precision: SystemClock.Minutes }

    Text {
        anchors.verticalCenter: parent.verticalCenter
        font.family: Theme.iconFamily
        font.pixelSize: Theme.iconSize
        color: Theme.foregroundMuted
        text: Theme.icon.clock
    }
    Text {
        anchors.verticalCenter: parent.verticalCenter
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.foreground
        text: Qt.formatDateTime(clock.date, "ddd d  ") + Qt.formatDateTime(clock.date, "HH:mm")
    }
}

// panels/NotificationsPanel.qml — placeholder. We do NOT own
// org.freedesktop.Notifications yet (mako still does, untouched). This panel
// only reserves the slot in PanelHost so the navbar's notifications button has
// somewhere to go; a real notification list lands here if/when we migrate the
// daemon.
import QtQuick
import "root:/"

Rectangle {
    id: panel

    implicitWidth: 380
    implicitHeight: 146
    radius: Theme.radiusLarge
    color: Theme.panelBg
    border.width: 1
    border.color: Theme.withAlpha(Theme.border, 0.6)

    Column {
        anchors.centerIn: parent
        spacing: 8

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            font.family: Theme.iconFamily; font.pixelSize: 24
            color: Theme.withAlpha(Theme.foregroundMuted, 0.7)
            text: Theme.icon.dnd
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize; font.bold: true
            color: Theme.foreground
            text: "Notifications"
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeSmall
            color: Theme.foregroundMuted
            text: "Delivered by mako for now"
        }
    }
}

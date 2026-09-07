// modules/ActiveWindow.qml — a faint, secondary hint of the focused window.
import QtQuick
import Quickshell.Hyprland
import "root:/"

Text {
    id: root
    font.family: Theme.fontFamily
    font.pixelSize: Theme.fontSizeSmall
    color: Theme.foregroundMuted
    opacity: 0.55
    elide: Text.ElideRight
    width: Math.min(implicitWidth, 170)
    visible: text.length > 0
    text: Hyprland.activeToplevel ? Hyprland.activeToplevel.title : ""
}

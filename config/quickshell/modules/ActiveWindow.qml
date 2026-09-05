// modules/ActiveWindow.qml — title of the focused window.
// Event-driven via Hyprland.activeToplevel, no polling.
// https://quickshell.org/docs/v0.3.0/types/Quickshell.Hyprland/HyprlandToplevel/

import QtQuick
import Quickshell.Hyprland

Text {
    id: root
    font.pixelSize: 12
    color: "#8a92b2"
    elide: Text.ElideRight
    width: Math.min(implicitWidth, 320)
    text: Hyprland.activeToplevel ? Hyprland.activeToplevel.title : ""
}

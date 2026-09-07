// Bar.qml — the navbar as a FLOATING ISLAND, not an edge-to-edge bar.
// One PanelWindow per monitor, centred on the top edge (anchor top only ->
// wlr-layer-shell centres it horizontally), small and rounded, translucent +
// blurred, reserving NO exclusive zone (it floats over content like the
// reference rice). Hides during an Infinite Desktop pan (frame.heldHidden).
//
// Content is deliberately minimal — a "dynamic island", not a status
// dashboard:
//   LEFT   panel buttons (controls / stats / wallpapers / notifications) +
//          a tiny workspace indicator
//   CENTRE the World Map ring — the entry to the Infinite Desktop minimap
//          (WorldMap.qml; also Super+Tab)
//   RIGHT  open-app icons · network · audio · battery · clock
// CPU / MEM / NVIDIA / brightness live in the panels now, not here.
import QtQuick
import Quickshell
import Quickshell.Wayland
import "root:/"
import "./modules"

Scope {
    id: scope

    property var frame: null
    // which contextual panel is open ("", "controls", "stats", "notifications")
    property string panel: ""
    property bool worldMapOpen: false
    // click on a navbar button -> shell.qml toggles the panel
    signal requestPanel(string name)
    signal requestWorldMap()

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: bar
            required property var modelData
            screen: modelData

            WlrLayershell.namespace: "quickshell:bar"
            WlrLayershell.layer: WlrLayer.Top
            anchors { top: true }
            margins.top: Theme.navTopMargin
            implicitWidth: Math.min(Theme.navMaxWidth,
                                    Math.round(modelData.width * Theme.navWidthRatio))
            implicitHeight: Theme.navHeight
            exclusiveZone: 0
            color: "transparent"
            visible: scope.frame === null || !scope.frame.heldHidden

            Rectangle {
                id: island
                anchors.fill: parent
                radius: Theme.radiusLarge
                color: Theme.barBg
                border.width: 1
                border.color: Theme.withAlpha(Theme.border, 0.5)

                // ---- left: panel buttons + workspace indicator ----------
                Row {
                    anchors { left: parent.left; leftMargin: 8; verticalCenter: parent.verticalCenter }
                    spacing: 3
                    NavButton { glyph: Theme.icon.dashboard; name: "controls" }
                    NavButton { glyph: Theme.icon.cpu;       name: "stats" }
                    NavButton { glyph: Theme.icon.wallpaper; name: "wallpapers" }
                    NavButton { glyph: Theme.icon.dnd;       name: "notifications" }
                    Item { width: 4; height: 1 }
                    Workspaces { anchors.verticalCenter: parent.verticalCenter }
                    Item { width: 4; height: 1 }
                    MosaicButton { anchors.verticalCenter: parent.verticalCenter }
                }

                // ---- centre: the World Map ring -----------------------
                WorldButton {
                    anchors.centerIn: parent
                    active: scope.worldMapOpen
                    onToggled: scope.requestWorldMap()
                }

                // ---- right: open apps + essential status --------------
                Row {
                    anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                    spacing: Theme.spacingSmall
                    OpenApps { anchors.verticalCenter: parent.verticalCenter }
                    Item { width: 2; height: 1 }
                    Network {}
                    Audio { compact: true }
                    Battery {}
                    Clock {}
                }
            }

            // a tiny square icon button; highlighted while its panel is open
            component NavButton: Rectangle {
                id: nb
                property string glyph
                property string name
                readonly property bool on: scope.panel === nb.name
                width: Theme.navHeight - 8
                height: Theme.navHeight - 8
                radius: Theme.radiusSmall
                color: nb.on            ? Theme.accent
                     : nbMouse.containsMouse ? Theme.surfaceHover
                     : "transparent"
                Text {
                    anchors.centerIn: parent
                    text: nb.glyph
                    font.family: Theme.iconFamily
                    font.pixelSize: Theme.iconSize
                    color: nb.on ? Theme.scrim : Theme.foregroundMuted
                }
                MouseArea {
                    id: nbMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: scope.requestPanel(nb.name)
                }
            }
        }
    }
}

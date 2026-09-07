// PanelHost.qml — the ONE contextual-panel zone. The navbar (Bar.qml) is the
// anchor; whatever panel is open renders here, docked just below the island.
//
//   scope.panel == ""              -> nothing shown
//   scope.panel == "controls"      -> panels/ControlsPanel.qml
//   scope.panel == "stats"         -> panels/StatsPanel.qml
//   scope.panel == "notifications" -> panels/NotificationsPanel.qml
//   scope.panel == "wallpapers"    -> panels/WallpaperPicker.qml
//
// Only one panel is ever mounted. Clicking a navbar button toggles / switches
// it (logic in shell.qml). Clicking outside or pressing Escape closes it, via
// HyprlandFocusGrab. A short opacity+slide transition (~160 ms) makes the panel
// feel like an extension of the island rather than a separate window.
//
// A host exists per monitor (Variants) but only the FOCUSED monitor's host goes
// `live`: it renders the card, holds the one HyprlandFocusGrab, and claims
// Exclusive keyboard focus. With every host live (the old behaviour) two focus
// grabs raced on a dual-monitor setup and, because OnDemand windows never hold
// keyboard focus, the grab fired onCleared the instant the panel opened — it
// flashed open and shut ("click, nothing happens"). One live host fixes that
// and also means one panel instance = no doubled /proc or nvidia polling.
//
// Overlay semantics: full-screen transparent window, ExclusionMode.Ignore, so
// it never reserves space or pushes tiled windows — it floats over them.
import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import "root:/"
import "./panels"

Scope {
    id: scope

    property string panel: ""
    signal requestClose()

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: host
            required property var modelData
            screen: modelData
            readonly property bool primary:
                Hyprland.focusedMonitor && Hyprland.focusedMonitor.name === modelData.name
            readonly property bool live: host.wantOpen && host.primary

            // what is actually mounted — lags `scope.panel` so the close
            // transition can play out before the panel is torn down.
            property string mounted: ""
            readonly property bool wantOpen: scope.panel !== ""

            WlrLayershell.namespace: "quickshell:dashboard"
            WlrLayershell.layer: WlrLayer.Top
            // OnDemand: no keyboard grab until something inside is clicked, so
            // the mouse-only panels are unaffected and WallpaperPicker can take
            // arrow keys / type-to-filter once focused.
            WlrLayershell.keyboardFocus: host.live ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
            anchors { top: true; left: true; right: true; bottom: true }
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            visible: wantOpen || mounted !== ""

            onWantOpenChanged: if (wantOpen) mounted = scope.panel
            Connections {
                target: scope
                function onPanelChanged() { if (scope.panel !== "") host.mounted = scope.panel; }
            }

            HyprlandFocusGrab {
                active: host.live
                windows: [host]
                onCleared: scope.requestClose()
            }

            // click anywhere outside the card closes
            MouseArea {
                anchors.fill: parent
                onClicked: scope.requestClose()
            }

            Item {
                id: card
                visible: host.primary
                anchors.horizontalCenter: parent.horizontalCenter
                y: Theme.panelTopY + (host.wantOpen ? 0 : -8)
                width: slot.implicitWidth
                height: slot.implicitHeight
                opacity: host.wantOpen ? 1 : 0

                Behavior on opacity {
                    SequentialAnimation {
                        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
                        ScriptAction { script: if (!host.wantOpen) host.mounted = ""; }
                    }
                }
                Behavior on y { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

                // swallow clicks that land on the panel itself
                MouseArea { anchors.fill: parent }

                Loader {
                    id: slot
                    active: host.mounted !== "" && host.primary
                    focus: true
                    sourceComponent: host.mounted === "controls"      ? controlsC
                                   : host.mounted === "stats"         ? statsC
                                   : host.mounted === "notifications" ? notifC
                                   : host.mounted === "wallpapers"    ? wallC
                                   : null
                    onLoaded: if (host.mounted === "wallpapers") item.forceActiveFocus()
                }
            }

            Component { id: controlsC; ControlsPanel {} }
            Component { id: statsC;    StatsPanel {} }
            Component { id: notifC;    NotificationsPanel {} }
            Component { id: wallC;     WallpaperPicker {} }
        }
    }
}

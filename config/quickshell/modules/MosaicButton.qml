// modules/MosaicButton.qml — a discreet navbar indicator for the Viewport
// Mosaic (scripts/infinite-desktop/viewport_mosaic.py, also Super+M).
//
// Active state = a per-workspace snapshot file exists
// ($XDG_RUNTIME_DIR/infinite-desktop/viewport-mosaic-<ws>.json). Click toggles
// the mosaic (optimistic flip for feel; the FileView reconciles).
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "root:/"

Item {
    id: root
    implicitWidth: 18
    implicitHeight: 18

    readonly property int ws: Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 1
    property bool active: false

    FileView {
        id: snap
        path: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp")
              + "/infinite-desktop/viewport-mosaic-" + root.ws + ".json"
        watchChanges: true
        printErrors: false
        onLoaded:      root.active = true
        onLoadFailed:  root.active = false
        onFileChanged: reload()
    }
    onWsChanged: snap.reload()
    Component.onCompleted: snap.reload()

    // a mosaic toggle emits a burst of movewindow events — use them to
    // reconcile the indicator (event-driven, no polling)
    Connections {
        target: Hyprland
        function onRawEvent(e) {
            if (e.name === "movewindowv2" || e.name === "openwindow"
                || e.name === "closewindow")
                reconcile.restart();
        }
    }
    Timer { id: reconcile; interval: 250; onTriggered: snap.reload() }

    Rectangle {
        anchors.fill: parent
        radius: Theme.radiusSmall
        color: root.active        ? Theme.withAlpha(Theme.accent, 0.22)
             : m.containsMouse    ? Theme.surfaceHover
                                  : "transparent"
        border.width: root.active ? 1 : 0
        border.color: Theme.withAlpha(Theme.accent, 0.6)
        Behavior on color { ColorAnimation { duration: 120 } }
    }

    // 2×2 grid glyph, drawn (no font dependency)
    Grid {
        anchors.centerIn: parent
        columns: 2
        rowSpacing: 2
        columnSpacing: 2
        Repeater {
            model: 4
            Rectangle {
                width: 4; height: 4; radius: 1
                color: root.active     ? Theme.accent
                     : m.containsMouse ? Theme.foreground
                                       : Theme.foregroundMuted
            }
        }
    }

    MouseArea {
        id: m
        anchors.fill: parent
        anchors.margins: -4
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            root.active = !root.active;   // optimistic
            Quickshell.execDetached(["python3",
                Quickshell.env("HOME") + "/scripts/viewport_mosaic.py", "toggle"]);
        }
    }

    Rectangle {   // tooltip
        visible: m.containsMouse
        anchors { bottom: parent.top; bottomMargin: 7; horizontalCenter: parent.horizontalCenter }
        width: tip.implicitWidth + 14
        height: 18
        radius: 4
        color: Theme.withAlpha(Theme.scrim, 0.92)
        Text {
            id: tip
            anchors.centerIn: parent
            text: "Viewport Mosaic"
            font.family: Theme.fontFamily
            font.pixelSize: 10
            color: Theme.foreground
        }
    }
}

// Bar.qml — the top panel. Compact, dark, three groups: workspaces/window on
// the left, clock centered, status modules on the right.
//
// This IS "the frame" Frame.qml's IPC contract controls: it hides for the
// duration of an Infinite Desktop pan (frame.heldHidden) and reappears the
// instant the daemon releases it, instead of staying static above windows
// that are all moving together underneath it.
// https://quickshell.org/docs/v0.3.0/types/Quickshell/PanelWindow/

import QtQuick
import Quickshell
import "./modules"

PanelWindow {
    id: bar

    // Passed in from shell.qml — the single Frame IPC service instance.
    property var frame: null

    anchors {
        top: true
        left: true
        right: true
    }
    implicitHeight: 32
    color: "transparent"

    visible: frame === null || !frame.heldHidden

    exclusiveZone: implicitHeight

    Rectangle {
        anchors.fill: parent
        color: "#1a1b26"
    }

    Row {
        anchors.left: parent.left
        anchors.leftMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        spacing: 12

        Workspaces {}
        ActiveWindow {}
    }

    Row {
        anchors.centerIn: parent
        Clock {}
    }

    Row {
        anchors.right: parent.right
        anchors.rightMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        spacing: 14

        SystemStats {}
        Network {}
        Audio {}
        Brightness {}
        NvidiaGpu { panelWindow: bar }
        Battery {}
    }
}

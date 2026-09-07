// modules/HandButton.qml — discreet navbar indicator for Hand Control
// (scripts/hand-control/, also Super+H). Three states:
//
//   OFF      process stopped, camera off        -> muted glyph
//   CLOSED   camera on, gestures suspended by    -> glyph + slash, urgent-tinted
//            the privacy shutter (detected from     border
//            the stream, no HW signal on Linux)
//   ACTIVE   hand tracking running               -> accent glyph + tint
//
// State comes from $XDG_RUNTIME_DIR/hand-control/state
//   running=1
//   shutter=open|closed
//   tracking=1|0
// (written by hand_control.py; absent = OFF). Click = master toggle (Super+H).
import QtQuick
import Quickshell
import Quickshell.Io
import "root:/"

Item {
    id: root
    implicitWidth: 18
    implicitHeight: 18

    property bool running: false
    property bool shutterClosed: false
    property bool tracking: false
    // 0 OFF · 1 CLOSED · 2 ACTIVE
    readonly property int mode: !running ? 0 : (shutterClosed ? 1 : 2)

    FileView {
        id: st
        path: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/hand-control/state"
        watchChanges: true
        printErrors: false
        function parse() {
            const t = text() || "";
            root.running = /(^|\n)running=1/.test(t);
            root.shutterClosed = /(^|\n)shutter=closed/.test(t);
            root.tracking = /(^|\n)tracking=1/.test(t);
        }
        onLoaded: parse()
        onLoadFailed: { root.running = false; root.shutterClosed = false; root.tracking = false; }
        onFileChanged: reload()
    }
    Component.onCompleted: st.reload()
    // watchChanges catches Super+H; a slow re-stat (one syscall / 2 s) covers a
    // missed create/delete — not a busy poll
    Timer { interval: 2000; running: true; repeat: true; onTriggered: st.reload() }

    readonly property color _fg: root.mode === 2 ? Theme.accent
                               : root.mode === 1 ? Theme.urgent
                               : m.containsMouse  ? Theme.foreground
                                                  : Theme.foregroundMuted

    Rectangle {
        anchors.fill: parent
        radius: Theme.radiusSmall
        color: root.mode === 2 ? Theme.withAlpha(Theme.accent, 0.22)
             : root.mode === 1 ? Theme.withAlpha(Theme.urgent, 0.16)
             : m.containsMouse  ? Theme.surfaceHover
                                : "transparent"
        border.width: root.mode === 0 ? 0 : 1
        border.color: root.mode === 1 ? Theme.withAlpha(Theme.urgent, 0.6)
                                      : Theme.withAlpha(Theme.accent, 0.6)
        Behavior on color { ColorAnimation { duration: 120 } }
    }

    // hand glyph — palm + three finger bars (drawn, no font dependency)
    Item {
        id: glyph
        anchors.centerIn: parent
        width: 12; height: 12
        Row {
            anchors { top: parent.top; horizontalCenter: parent.horizontalCenter }
            spacing: 1.5
            Repeater {
                model: 3
                Rectangle { width: 2; height: 5; radius: 1; color: root._fg }
            }
        }
        Rectangle {
            anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter }
            width: 10; height: 6; radius: 2; color: root._fg
        }
        // "shutter closed" = a slash across the glyph
        Rectangle {
            visible: root.mode === 1
            anchors.centerIn: parent
            width: 17; height: 2; radius: 1
            rotation: -45
            color: Theme.urgent
        }
    }

    MouseArea {
        id: m
        anchors.fill: parent
        anchors.margins: -4
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: Quickshell.execDetached([Quickshell.env("HOME")
            + "/.local/bin/hand-control", "toggle"])
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
            text: root.mode === 2 ? "Hand Control — active"
                : root.mode === 1 ? "Hand Control — shutter closed"
                                  : "Hand Control"
            font.family: Theme.fontFamily
            font.pixelSize: 10
            color: Theme.foreground
        }
    }
}

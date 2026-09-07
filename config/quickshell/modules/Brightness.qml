// modules/Brightness.qml — backlight as icon + %, scroll to adjust.
// Quickshell has no brightness type; shells out to `brightnessctl`. No polling:
// queried once and again after any change (this widget's scroll, the dashboard
// slider, or the XF86 keybinds via the "brightness" IPC target).
import QtQuick
import Quickshell.Io
import "root:/"

MouseArea {
    id: root
    property int percent: -1
    readonly property bool available: percent >= 0
    visible: available
    implicitWidth: row.implicitWidth
    implicitHeight: row.implicitHeight
    cursorShape: Qt.PointingHandCursor
    onWheel: (w) => bump(w.angleDelta.y > 0 ? 1 : -1)

    IpcHandler {
        target: "brightness"
        function refresh(): void { query.running = true; }
        function setPercent(p: int): void { root.setPercent(p); }
    }

    Process {
        id: query
        command: ["brightnessctl", "-m"]
        stdout: StdioCollector {
            onStreamFinished: {
                const f = this.text.trim().split(",");   // device,class,current,percent%,max
                if (f.length >= 4) root.percent = parseInt(f[3], 10);
            }
        }
    }
    Process { id: setter; onRunningChanged: if (!running) query.running = true }

    function bump(sign) { setter.exec(["brightnessctl", "-n2", "set", sign > 0 ? "5%+" : "5%-"]); }
    function setPercent(p) { setter.exec(["brightnessctl", "-n2", "set", Math.max(1, Math.min(100, p)) + "%"]); }

    Component.onCompleted: query.running = true

    Row {
        id: row
        spacing: Theme.gap
        Text {
            font.family: Theme.iconFamily
            font.pixelSize: Theme.iconSize
            color: Theme.foreground
            text: Theme.icon.brightness
        }
        Text {
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.foregroundMuted
            text: root.available ? root.percent + "%" : ""
        }
    }
}

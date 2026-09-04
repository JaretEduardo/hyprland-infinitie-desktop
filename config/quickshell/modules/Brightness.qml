// modules/Brightness.qml — screen backlight, click/scroll to adjust.
//
// Quickshell has no native brightness type, so this shells out to
// `brightnessctl` (already in install/packages.gentoo, power group). No
// backlight device name is hardcoded: `brightnessctl -m` auto-detects the
// right backlight class device, same principle as lib/hardware.sh.
//
// No polling: the initial value is queried once, and again only after this
// widget itself changes it. https://quickshell.org/docs/v0.3.0/types/Quickshell.Io/Process/

import QtQuick
import Quickshell.Io

Row {
    id: root
    spacing: 4

    property int percent: -1
    readonly property bool available: percent >= 0
    visible: available

    Process {
        id: query
        command: ["brightnessctl", "-m"]
        stdout: StdioCollector {
            onStreamFinished: {
                // format: device,class,current,percent%,max
                const fields = this.text.trim().split(",");
                if (fields.length >= 4) {
                    root.percent = parseInt(fields[3], 10);
                }
            }
        }
    }

    Process {
        id: setter
        onRunningChanged: {
            if (!running) query.running = true;
        }
    }

    function bump(sign) {
        setter.exec(["brightnessctl", "set", sign > 0 ? "5%+" : "5%-"]);
    }

    Component.onCompleted: query.running = true

    Text {
        font.pixelSize: 12
        color: "#c0caf5"
        text: root.available ? ("BRI " + root.percent + "%") : ""

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onWheel: (wheel) => root.bump(wheel.angleDelta.y > 0 ? 1 : -1)
        }
    }
}

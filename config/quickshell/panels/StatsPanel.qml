// panels/StatsPanel.qml — CPU / memory / NVIDIA, moved out of the navbar into
// a contextual panel. The backends are UNCHANGED: modules/SystemStats.qml
// (reads /proc) and modules/NvidiaGpu.qml (shells out to nvidia-compute-mode)
// are instantiated headless and only their values are read here.
import QtQuick
import "root:/"
import "../modules"

Rectangle {
    id: panel

    implicitWidth: 460
    implicitHeight: col.implicitHeight + 32
    radius: Theme.radiusLarge
    color: Theme.panelBg
    border.width: 1
    border.color: Theme.withAlpha(Theme.border, 0.6)

    // ---- headless backends ------------------------------------
    SystemStats { id: sys; visible: false }
    NvidiaGpu   { id: gpu; visible: false }

    Column {
        id: col
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 16 }
        spacing: 12

        Text {
            text: "System"
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeLarge; font.bold: true
            color: Theme.foreground
        }

        StatBar { label: "CPU";    glyph: Theme.icon.cpu; value: sys.cpuPercent }
        StatBar { label: "Memory"; glyph: Theme.icon.mem; value: sys.memPercent }

        Rectangle { width: parent.width; height: 1; color: Theme.withAlpha(Theme.border, 0.4); visible: gpu.present }

        // ---- NVIDIA (only when a discrete GPU is present) -----
        Column {
            width: parent.width
            spacing: 6
            visible: gpu.present

            Row {
                spacing: Theme.spacingSmall
                Text {
                    font.family: Theme.iconFamily; font.pixelSize: Theme.iconSize
                    color: gpu.activeUnderEco ? Theme.accent : Theme.foregroundMuted
                    text: Theme.icon.gpu
                }
                Text {
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize
                    color: Theme.foreground
                    text: "NVIDIA · " + gpu.policy.toUpperCase()
                }
                Rectangle {
                    width: 7; height: 7; radius: 3.5; y: 4
                    color: gpu.dotColor
                }
            }
            Text {
                visible: gpu.deep !== null
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeSmall
                color: Theme.foregroundMuted
                text: gpu.deep ? ("Temp " + gpu.deep.temp_c + "°C   ·   VRAM " + gpu.deep.mem_used_mib
                                  + "/" + gpu.deep.mem_total_mib + " MiB   ·   " + gpu.deep.util_pct + "%") : ""
            }
            Text {
                visible: gpu.confirmingDeep
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeSmall
                color: Theme.accent; wrapMode: Text.WordWrap; width: parent.width
                text: "This check may wake or keep the NVIDIA GPU active."
            }
            Text {
                visible: gpu.lastError.length > 0
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeSmall
                color: Theme.accent; wrapMode: Text.WordWrap; width: parent.width
                text: gpu.lastError
            }

            Row {
                spacing: Theme.spacing
                topPadding: 2
                ActBtn {
                    visible: gpu.policy === "eco"
                    label: gpu.confirmingDeep ? "Confirm" : "Details"
                    onClicked: gpu.requestDeepMetrics()
                }
                ActBtn {
                    enabled: !gpu.busy
                    label: gpu.policy === "eco" ? "Start Compute" : "Return to Eco"
                    onClicked: gpu.policy === "eco" ? gpu.setCompute() : gpu.setEco()
                }
            }
        }
    }

    // a labelled horizontal meter
    component StatBar: Item {
        id: sb
        property string label
        property string glyph
        property int value: 0
        width: parent ? parent.width : 0
        height: 26

        Text {
            id: g
            anchors { left: parent.left; verticalCenter: parent.verticalCenter }
            width: 18
            font.family: Theme.iconFamily; font.pixelSize: Theme.iconSize
            color: Theme.foregroundMuted
            text: sb.glyph
        }
        Text {
            id: l
            anchors { left: g.right; verticalCenter: parent.verticalCenter }
            width: 62
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeSmall
            color: Theme.foreground
            text: sb.label
        }
        Rectangle {
            id: track
            anchors { left: l.right; right: v.left; rightMargin: 10; verticalCenter: parent.verticalCenter }
            height: 6
            radius: 3
            color: Theme.surface
            Rectangle {
                width: Math.round(parent.width * Math.max(0, Math.min(1, sb.value / 100)))
                height: parent.height
                radius: parent.radius
                color: sb.value >= 85 ? Theme.urgent : Theme.accent
            }
        }
        Text {
            id: v
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            width: 38
            horizontalAlignment: Text.AlignRight
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeSmall
            color: Theme.foregroundMuted
            text: sb.value + "%"
        }
    }

    component ActBtn: Rectangle {
        id: btn
        property string label
        property bool enabled: true
        signal clicked()
        implicitWidth: bt.implicitWidth + 20
        implicitHeight: 24
        radius: Theme.radiusSmall
        color: ma.containsMouse ? Theme.surfaceHover : Theme.surface
        opacity: enabled ? 1 : 0.45
        Text {
            id: bt; anchors.centerIn: parent
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeSmall
            color: Theme.foreground; text: btn.label
        }
        MouseArea {
            id: ma; anchors.fill: parent; hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            enabled: btn.enabled
            onClicked: btn.clicked()
        }
    }
}

// panels/ControlsPanel.qml — the control centre, rendered inside PanelHost.qml
// docked under the navbar (was the standalone Dashboard.qml). Three zones:
// sliders + toggles / media card / Lavat card. Self-sizes via implicitWidth /
// implicitHeight so PanelHost can position it.
import QtQuick
import Quickshell.Io
import Quickshell.Services.Pipewire
import Quickshell.Networking
import "root:/"
import "../modules"

Rectangle {
    id: panel

    implicitWidth: 640
    implicitHeight: 196
    radius: Theme.radiusLarge
    color: Theme.panelBg
    border.width: 1
    border.color: Theme.withAlpha(Theme.border, 0.6)

    // ---- backends ----------------------------------------------
    PwObjectTracker { objects: [Pipewire.defaultAudioSink, Pipewire.defaultAudioSource] }
    readonly property var sink: Pipewire.defaultAudioSink
    readonly property var source: Pipewire.defaultAudioSource
    readonly property bool haveSink: sink !== null && sink.audio !== null

    property int briPercent: 50
    Process {
        id: briQuery
        command: ["brightnessctl", "-m"]
        stdout: StdioCollector {
            onStreamFinished: {
                const f = this.text.trim().split(",");
                if (f.length >= 4) panel.briPercent = parseInt(f[3], 10);
            }
        }
    }
    Process { id: briSet; onRunningChanged: if (!running) briQuery.running = true }
    Component.onCompleted: briQuery.running = true

    Process { id: shellProc }
    property bool dnd: false

    // ---- layout ---------------------------------------------------
    Row {
        anchors.fill: parent
        anchors.margins: 14
        spacing: 12

        // ===== LEFT: sliders + toggles =====
        Column {
            width: (parent.width - 24) * 0.36
            height: parent.height
            spacing: 9

            Slider {
                width: parent.width; glyph: Theme.icon.volHigh
                value: panel.haveSink ? panel.sink.audio.volume : 0
                onMoved: (v) => { if (panel.haveSink) panel.sink.audio.volume = v; }
            }
            Slider {
                width: parent.width; glyph: Theme.icon.brightness
                value: panel.briPercent / 100
                onMoved: (v) => briSet.exec(["brightnessctl", "-n2", "set", Math.max(1, Math.round(v * 100)) + "%"])
            }

            WideToggle {
                width: parent.width
                glyph: (panel.haveSink && panel.sink.audio.muted) ? Theme.icon.volMute : Theme.icon.volHigh
                label: (panel.haveSink && panel.sink.audio.muted) ? "Muted" : "Sound"
                active: !(panel.haveSink && panel.sink.audio.muted)
                onToggled: if (panel.haveSink) panel.sink.audio.muted = !panel.sink.audio.muted
            }
            WideToggle {
                width: parent.width
                glyph: Networking.wifiEnabled ? Theme.icon.wifi : Theme.icon.wifiOff
                label: Networking.wifiEnabled ? "Wi-Fi" : "Wi-Fi off"
                active: Networking.wifiEnabled
                onToggled: Networking.wifiEnabled = !Networking.wifiEnabled
            }

            Row {
                width: parent.width
                spacing: 7
                Pill {
                    glyph: Theme.icon.micOff
                    active: !(panel.source && panel.source.audio && panel.source.audio.muted)
                    onToggled: if (panel.source && panel.source.audio) panel.source.audio.muted = !panel.source.audio.muted
                }
                Pill {
                    glyph: Theme.icon.dnd
                    active: !panel.dnd
                    onToggled: {
                        panel.dnd = !panel.dnd;
                        shellProc.exec(["sh", "-c", panel.dnd
                            ? "makoctl mode -a do-not-disturb"
                            : "makoctl mode -r do-not-disturb"]);
                    }
                }
                Pill {
                    glyph: Theme.icon.dashboard
                    active: false
                    // close the panel first so it isn't in the shot
                    onToggled: shellProc.exec(["sh", "-c",
                        "qs ipc call panel close; sleep 0.2; hypr-screenshot full"])
                }
            }
        }

        // ===== CENTRE: media card =====
        Rectangle {
            width: (parent.width - 24) * 0.36
            height: parent.height
            radius: Theme.radiusMedium
            color: Theme.cardBg
            MediaPlayer { anchors.fill: parent; anchors.margins: 12 }
        }

        // ===== RIGHT: Lavat card =====
        Rectangle {
            width: parent.width - x
            height: parent.height
            radius: Theme.radiusMedium
            color: Theme.cardBg
            LavatBlob { anchors.fill: parent }
        }
    }

    // ---- components ----------------------------------------
    component WideToggle: Rectangle {
        id: wt
        property string glyph
        property string label
        property bool active: false
        signal toggled()
        height: 30
        radius: Theme.radiusSmall
        color: active ? Theme.accent : Theme.surface
        Row {
            anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
            spacing: 8
            Text {
                font.family: Theme.iconFamily; font.pixelSize: Theme.iconSize
                color: wt.active ? Theme.scrim : Theme.foregroundMuted
                text: wt.glyph
            }
            Text {
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeSmall
                color: wt.active ? Theme.scrim : Theme.foreground
                text: wt.label
            }
        }
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: wt.toggled() }
    }

    component Pill: Rectangle {
        id: pl
        property string glyph
        property bool active: false
        signal toggled()
        width: 34; height: 30
        radius: Theme.radiusSmall
        color: active ? Theme.accent : Theme.withAlpha(Theme.scrim, 0.5)
        Text {
            anchors.centerIn: parent
            font.family: Theme.iconFamily; font.pixelSize: Theme.iconSize
            color: pl.active ? Theme.scrim : Theme.foregroundMuted
            text: pl.glyph
        }
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: pl.toggled() }
    }
}

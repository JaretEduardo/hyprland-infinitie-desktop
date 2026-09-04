// modules/Audio.qml — output volume (click to mute) + a mic-muted indicator.
// Reactive over PipeWire via Quickshell.Services.Pipewire, no polling.
// PwObjectTracker binds the default sink/source so .audio.volume/.muted become
// valid and settable — https://quickshell.org/docs/v0.3.0/types/Quickshell.Services.Pipewire/PwObjectTracker/

import QtQuick
import Quickshell.Services.Pipewire

Row {
    id: root
    spacing: 10

    PwObjectTracker {
        objects: [Pipewire.defaultAudioSink, Pipewire.defaultAudioSource]
    }

    readonly property var sink: Pipewire.defaultAudioSink
    readonly property var source: Pipewire.defaultAudioSource

    Text {
        font.pixelSize: 12
        color: "#c0caf5"
        visible: root.sink !== null && root.sink.audio !== null
        text: {
            if (root.sink === null || root.sink.audio === null) return "";
            if (root.sink.audio.muted) return "mute";
            return "VOL " + Math.round(root.sink.audio.volume * 100) + "%";
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                if (root.sink !== null && root.sink.audio !== null) {
                    root.sink.audio.muted = !root.sink.audio.muted;
                }
            }
        }
    }

    // Only shown while the mic is actually muted, so it stays quiet otherwise.
    Text {
        font.pixelSize: 12
        color: "#f7768e"
        visible: root.source !== null && root.source.audio !== null && root.source.audio.muted
        text: "mic muted"

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                if (root.source !== null && root.source.audio !== null) {
                    root.source.audio.muted = !root.source.audio.muted;
                }
            }
        }
    }
}

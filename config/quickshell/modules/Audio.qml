// modules/Audio.qml — output volume as icon (+ % unless compact), click to
// mute, scroll to adjust. Reactive over Quickshell.Services.Pipewire, no
// polling. `compact: true` (navbar) drops the percentage, keeping just the icon.
import QtQuick
import Quickshell.Services.Pipewire
import "root:/"

MouseArea {
    id: root
    implicitWidth: row.implicitWidth
    implicitHeight: row.implicitHeight
    cursorShape: Qt.PointingHandCursor
    property bool compact: false
    onClicked: if (haveSink) sink.audio.muted = !sink.audio.muted
    onWheel: (w) => setPct(pct + (w.angleDelta.y > 0 ? 5 : -5))

    PwObjectTracker { objects: [Pipewire.defaultAudioSink, Pipewire.defaultAudioSource] }
    readonly property var sink: Pipewire.defaultAudioSink
    readonly property var source: Pipewire.defaultAudioSource
    readonly property bool haveSink: sink !== null && sink.audio !== null
    readonly property int pct: haveSink ? Math.round(sink.audio.volume * 100) : 0
    readonly property bool muted: haveSink && sink.audio.muted
    readonly property bool micMuted: source !== null && source.audio !== null && source.audio.muted

    function setPct(p) { if (haveSink) sink.audio.volume = Math.max(0, Math.min(1, p / 100)); }

    Row {
        id: row
        spacing: Theme.gap
        Text {
            anchors.verticalCenter: parent.verticalCenter
            font.family: Theme.iconFamily
            font.pixelSize: Theme.iconSize
            color: root.micMuted ? Theme.accent : (root.muted ? Theme.foregroundMuted : Theme.foreground)
            text: root.micMuted ? Theme.icon.micOff
                : root.muted    ? Theme.icon.volMute
                : root.pct >= 55 ? Theme.icon.volHigh
                : root.pct >= 15 ? Theme.icon.volMed
                : Theme.icon.volLow
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.haveSink && !root.muted && !root.compact
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.foregroundMuted
            text: root.pct + "%"
        }
    }
}

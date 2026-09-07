// modules/MediaPlayer.qml — compact MPRIS "now playing" card body for the
// dashboard. Uses Quickshell.Services.Mpris. Calm empty state, never breaks.
import QtQuick
import Quickshell.Services.Mpris
import "root:/"

Item {
    id: root

    readonly property var player: {
        const ps = Mpris.players.values;
        for (let i = 0; i < ps.length; i++)
            if (ps[i].trackTitle && ps[i].trackTitle.length > 0) return ps[i];
        return ps.length > 0 ? ps[0] : null;
    }
    readonly property bool has: player !== null

    function act(a) {
        if (!has) return;
        if (a === "next") player.next();
        else if (a === "prev") player.previous();
        else player.togglePlaying();
    }

    // ---- empty ----------------------------------------------------
    Column {
        anchors.centerIn: parent
        spacing: 6
        visible: !root.has
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            font.family: Theme.iconFamily; font.pixelSize: 22
            color: Theme.withAlpha(Theme.foregroundMuted, 0.6); text: Theme.icon.music
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeSmall
            color: Theme.withAlpha(Theme.foregroundMuted, 0.7); text: "Nothing playing"
        }
    }

    // ---- playing ------------------------------------------------
    Column {
        anchors.fill: parent
        spacing: 7
        visible: root.has

        Text {
            width: parent.width
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeSmall; font.bold: true
            color: Theme.foreground; elide: Text.ElideRight
            text: root.has ? root.player.trackTitle : ""
        }
        Text {
            width: parent.width
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeSmall
            color: Theme.foregroundMuted; elide: Text.ElideRight
            text: root.has ? (root.player.trackArtist || "") : ""
        }

        Rectangle {
            width: parent.width; height: 3; radius: 2
            color: Theme.surface
            visible: root.has && root.player.lengthSupported && root.player.length > 0
            Rectangle {
                height: parent.height; radius: parent.radius; color: Theme.accent
                width: (root.has && root.player.length > 0)
                       ? parent.width * Math.max(0, Math.min(1, root.player.position / root.player.length))
                       : 0
            }
        }

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 8
            Ctl { action: "prev"; glyph: Theme.icon.prev; on: root.has && root.player.canGoPrevious }
            Ctl { action: "toggle"; big: true; on: root.has && root.player.canTogglePlaying
                  glyph: (root.has && root.player.isPlaying) ? Theme.icon.pause : Theme.icon.play }
            Ctl { action: "next"; glyph: Theme.icon.next; on: root.has && root.player.canGoNext }
        }
    }

    component Ctl: Rectangle {
        property string glyph
        property string action
        property bool on: true
        property bool big: false
        width: big ? 30 : 24
        height: width
        radius: width / 2
        color: ma.containsMouse && on ? Theme.surfaceHover : Theme.surface
        opacity: on ? 1 : 0.4
        Text {
            anchors.centerIn: parent
            font.family: Theme.iconFamily
            font.pixelSize: parent.big ? Theme.iconSize + 2 : Theme.iconSize
            color: Theme.foreground
            text: parent.glyph
        }
        MouseArea {
            id: ma; anchors.fill: parent; hoverEnabled: true
            enabled: parent.on
            cursorShape: Qt.PointingHandCursor
            onClicked: root.act(parent.action)
        }
    }
}

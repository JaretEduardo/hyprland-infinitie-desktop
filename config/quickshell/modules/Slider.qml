// modules/Slider.qml — a thin flat pink slider. value 0..1; emits moved(v).
import QtQuick
import "root:/"

Item {
    id: root
    property real value: 0
    property string glyph: ""
    signal moved(real v)

    implicitHeight: 22
    implicitWidth: 200

    function _set(mx) {
        root.moved(Math.max(0, Math.min(1, (mx - track.x) / track.width)));
    }

    Text {
        id: gl
        anchors { left: parent.left; verticalCenter: parent.verticalCenter }
        width: root.glyph ? 16 : 0
        visible: root.glyph !== ""
        font.family: Theme.iconFamily
        font.pixelSize: Theme.iconSize
        color: Theme.foregroundMuted
        text: root.glyph
    }

    Rectangle {
        id: track
        anchors { left: gl.right; leftMargin: root.glyph ? 8 : 0; right: parent.right; verticalCenter: parent.verticalCenter }
        height: 6
        radius: 3
        color: Theme.surface

        Rectangle {
            width: Math.round(parent.width * Math.max(0, Math.min(1, root.value)))
            height: parent.height
            radius: parent.radius
            color: Theme.accent
        }
        Rectangle {
            width: 12; height: 12; radius: 6
            color: Theme.accentSoft
            border.width: 2
            border.color: Theme.surfaceElevated
            anchors.verticalCenter: parent.verticalCenter
            x: Math.round(parent.width * Math.max(0, Math.min(1, root.value))) - width / 2
        }
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onPressed: (m) => root._set(m.x)
        onPositionChanged: (m) => { if (pressed) root._set(m.x); }
        onWheel: (w) => root.moved(Math.max(0, Math.min(1, root.value + (w.angleDelta.y > 0 ? 0.05 : -0.05))))
    }
}

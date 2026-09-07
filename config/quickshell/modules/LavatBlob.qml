// modules/LavatBlob.qml — PLACEHOLDER for the "Lavat" animated blob from the
// reference video (Lavat proper is a separate project). A soft, irregular,
// organic pale-pink mass: 7 overlapping lobes that each drift + breathe on
// their own timing, so the silhouette keeps deforming. Not concentric rings.
import QtQuick
import QtQuick.Effects
import "root:/"

Item {
    id: root

    Item {
        id: mass
        anchors.centerIn: parent
        width: Math.min(parent.width, parent.height) * 0.66
        height: width
        visible: false   // rendered through the blur effect below

        RotationAnimation on rotation {
            from: 0; to: 360; duration: 46000
            loops: Animation.Infinite; running: true
        }

        Repeater {
            model: [
                { d: 0.00, ang:   0, s: 0.62, dur: 4200 },
                { d: 0.28, ang:  25, s: 0.42, dur: 3600 },
                { d: 0.30, ang: 110, s: 0.46, dur: 5200 },
                { d: 0.26, ang: 175, s: 0.40, dur: 4800 },
                { d: 0.32, ang: 235, s: 0.44, dur: 3900 },
                { d: 0.24, ang: 300, s: 0.38, dur: 5600 },
                { d: 0.18, ang: 340, s: 0.34, dur: 4400 }
            ]
            Rectangle {
                required property var modelData
                readonly property real base: mass.width
                width: base * modelData.s
                height: width
                radius: width / 2
                color: modelData.d === 0 ? Theme.accentSoft : Theme.accent
                opacity: modelData.d === 0 ? 0.95 : 0.7
                x: mass.width / 2 - width / 2
                   + Math.cos(modelData.ang * Math.PI / 180) * base * modelData.d
                y: mass.height / 2 - height / 2
                   + Math.sin(modelData.ang * Math.PI / 180) * base * modelData.d
                transformOrigin: Item.Center

                SequentialAnimation on scale {
                    loops: Animation.Infinite; running: true
                    NumberAnimation { from: 0.86; to: 1.14; duration: modelData.dur; easing.type: Easing.InOutSine }
                    NumberAnimation { from: 1.14; to: 0.86; duration: modelData.dur; easing.type: Easing.InOutSine }
                }
            }
        }
    }

    MultiEffect {
        anchors.fill: parent
        source: mass
        blurEnabled: true
        blur: 0.65
        blurMax: 24
        autoPaddingEnabled: true
    }
}

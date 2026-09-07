// DiagonalWallpaperTransition.qml — the ONE diagonal-wipe implementation.
//
// Renders `source` (an incoming still: a wallpaper image, or a video's cached
// representative frame) revealed over whatever is drawn BEHIND this item,
// through an animated ~45° mask that sweeps from the TOP-RIGHT corner to the
// BOTTOM-LEFT as `progress` goes 0 -> 1. Wallpaper.qml uses it for every
// transition (static/animated, any combination) so there is never a second
// copy of the wipe that could drift out of sync.
//
//   source   — file:// URL of the incoming still
//   progress — 0 (nothing revealed) .. 1 (fully revealed); animate with
//              InOutCubic over Theme.wallpaperTransitionDuration. At 0 the
//              effect renders fully transparent, so this item can stay mapped.
//   ready()  — emitted once `source` has decoded (start the wipe then)
//
// Never toggles its own `visible` (that left the mask texture uninitialised and
// the wipe snapped) — the parent gates it, and progress 0 makes it invisible
// anyway. Captures no input.
import QtQuick
import QtQuick.Effects

Item {
    id: root

    property url  source: ""
    property real progress: 0

    readonly property bool imageReady: img.status === Image.Ready
    signal ready()

    Image {
        id: img
        anchors.fill: parent
        visible: false                       // sampled by the MultiEffect, not drawn directly
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        source: root.source
        onStatusChanged: if (status === Image.Ready) root.ready()
    }

    // Corner-to-corner alpha gradient: opaque (alpha 1) at the TOP-RIGHT,
    // transparent (alpha 0) at the BOTTOM-LEFT. A horizontal gradient on a
    // square rect rotated -45° gives the 45° boundary; the rect is (W+H) so the
    // gradient spans the whole screen diagonal with overscan.
    // NOTE: the rect MUST read the mask item's own size — a 0-size rect makes
    // the mask degenerate and the effect passes the source through unmasked.
    Item {
        id: mask
        anchors.fill: parent
        visible: false
        layer.enabled: true                  // make it a real texture provider
        Rectangle {
            anchors.centerIn: parent
            width:  mask.width + mask.height
            height: mask.width + mask.height
            rotation: -45
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "#00000000" }
                GradientStop { position: 1.0; color: "#ff000000" }
            }
        }
    }

    MultiEffect {
        anchors.fill: parent
        source: img
        maskEnabled: true
        maskSource: mask
        // top-right corner sits at mask alpha ~0.854, bottom-left at ~0.146;
        // sweeping 0.90 -> 0.10 reveals between them with a little overscan.
        // At progress 0 the threshold (0.90) is above every screen pixel's mask
        // alpha, so nothing is revealed -> the effect is fully transparent.
        maskThresholdMin: 0.90 - 0.80 * root.progress
        maskSpreadAtMin: 0.03                 // crisp edge, hair of feather
    }
}

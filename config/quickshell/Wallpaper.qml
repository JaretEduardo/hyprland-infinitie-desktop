// Wallpaper.qml — the desktop background, drawn by Quickshell.
//
// LAYER: one PanelWindow per monitor on WlrLayer.Bottom — ALWAYS above
// mpvpaper (which sits on WlrLayer.Background), so the transition overlay can
// wipe over a live video. When the settled wallpaper is animated the base
// Image layers go transparent and mpvpaper shows through from behind.
//
// STATIC BUFFERS + EXPLICIT PATH TRACKING (fixes "won't switch back to a
// previously loaded wallpaper"): two Image buffers, and `layer0Path` /
// `layer1Path` say exactly what each one holds. The state machine never uses
// Image.source equality to decide whether a load is needed — assigning the
// same source does not re-emit Image.Ready.
//   activeLayer / activePath / activeKind — what the desktop shows now
//   pending* + transitioning              — an in-flight diagonal wipe
//
// DIAGONAL WIPE: DiagonalWallpaperTransition.qml (the one implementation) is
// used for EVERY transition — static->static, static->animated,
// animated->static, animated->animated. The incoming still is a wallpaper
// image, or a video's cached representative frame (wallpaper.path holds it in
// both cases).
//
// mpvpaper LIFECYCLE: mpvpaper is a separate layer-shell surface, so the wipe
// is never applied to it directly. While Quickshell is running, hypr-wallpaper
// records the animated target in wallpaper.state but does NOT start the new
// mpvpaper or kill the old one — Wallpaper.qml starts the new one
// (`hypr-wallpaper --spawn-mpvpaper <video>`) as the wipe completes and retires
// the old one by pid a beat later, so there is a clean frame->video handoff and
// exactly one mpvpaper. hypr-wallpaper keeps a long safety-net kill of the
// previous pid for the Quickshell-not-running case.
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import "root:/"

Scope {
    id: scope

    // ---- wallpaper.state is the ONE trigger ------------------------
    // Everything comes from this single file, parsed atomically in one pass, so
    // `wpStill` / `wpKind` / `wpVideo` are always mutually consistent (reading
    // wallpaper.path separately raced the state and passed a stale video path
    // to --spawn-mpvpaper). The still to show IS `palette_source` (the image
    // for static, the cached frame for animated). wallpaper.path is still
    // written by hypr-wallpaper for other readers (hyprlock, scripts).
    FileView {
        id: wpStateFile
        path: Theme._cacheHome + "/hyprland-infinitie-desktop/wallpaper.state"
        watchChanges: true
        printErrors: false
        function parse() {
            const t = text() || "";
            const g = (re, d) => { const m = re.exec(t); return m ? (m[1] || "").trim() : d; };
            scope.wpKind  = g(/(?:^|\n)type=([a-z]+)/, "static");
            scope.wpStill = g(/(?:^|\n)palette_source=(.*)/, "");
            scope.wpVideo = g(/(?:^|\n)path=(.*)/, "");
            scope.wpPid   = g(/(?:^|\n)pid=(.*)/, "");
            scope.wpTick++;
        }
        onLoaded:      parse()
        onLoadFailed:  { scope.wpKind = "static"; scope.wpStill = ""; scope.wpTick++; }
        onFileChanged: reload()
    }

    property string wpStill: ""          // the still/frame to show (state palette_source)
    property string wpKind:  "static"    // "static" | "animated"
    property string wpVideo: ""          // state `path=` (the real video when animated)
    property string wpPid:   ""          // state `pid=` (mpvpaper; "" -> Quickshell spawns)
    property int    wpTick:  0           // bumps on every state write -> retrigger

    // mirror of the (single-monitor) machine, for `qs ipc call wallpaper status`
    property string statusPath: ""
    property string statusKind: "static"
    property bool   statusBusy: false

    IpcHandler {
        target: "wallpaper"
        function reload(): void { wpStateFile.reload(); }
        function status(): string {
            return scope.statusPath + "|" + scope.statusKind + "|" + (scope.statusBusy ? "T" : "-");
        }
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: win
            required property var modelData
            screen: modelData
            WlrLayershell.namespace: "quickshell:wallpaper"
            WlrLayershell.layer: WlrLayer.Bottom
            exclusionMode: ExclusionMode.Ignore
            anchors { top: true; bottom: true; left: true; right: true }
            color: "transparent"

            // ---- state machine -------------------------------------
            property int    activeLayer: 0
            property string activePath:  ""
            property string activeKind:  "static"
            property string layer0Path:  ""
            property string layer1Path:  ""

            property bool   transitioning: false
            property bool   handoffPending: false      // ->animated: frame -> live video
            property real   wipeProgress: 0
            property real   xferOpacity: 1             // overlay opacity (only the handoff fade drops it)
            property int    pendingLayer: 0
            property string pendingPath:  ""
            property string pendingKind:  "static"
            property string pendingVideo: ""
            property bool   spawnedEarly: false        // new mpvpaper started during the wipe
            property string retirePid:    ""           // old mpvpaper to kill at handoff
            property string knownPid:     ""           // mpvpaper pid we believe is live

            readonly property bool baseAnimated: activeKind === "animated"

            function uri(p)      { return (p && p.length) ? ("file://" + p) : ""; }
            function pathOf(i)   { return i === 0 ? layer0Path : layer1Path; }
            function imgOf(i)    { return i === 0 ? layer0 : layer1; }
            function bufReady(i) { return imgOf(i).status === Image.Ready && pathOf(i).length > 0; }
            function setBuf(i, p) {
                if (i === 0) { layer0Path = p; layer0.source = uri(p); }
                else         { layer1Path = p; layer1.source = uri(p); }
            }

            // ---- react to a new wallpaper.state (the single trigger) -
            property bool adopted: false
            Connections {
                target: scope
                function onWpTickChanged() { win.evaluate(); }
            }
            Component.onCompleted: evaluate()

            function publishStatus() {
                scope.statusPath = activePath;
                scope.statusKind = activeKind;
                scope.statusBusy = transitioning || handoffPending;
            }

            // adopt whatever is already on disk, WITHOUT a wipe (session/qs start)
            function adopt(still, kind) {
                adopted = true;
                activeLayer = 0;
                activePath  = still;
                activeKind  = kind;
                setBuf(0, still);
                knownPid = scope.wpPid;
                if (kind === "animated") {
                    // make sure the video is actually playing (idempotent: a
                    // no-op if a live mpvpaper for it already exists — e.g. a qs
                    // restart; it (re)starts it on a fresh session).
                    Quickshell.execDetached(["hypr-wallpaper", "--spawn-mpvpaper", scope.wpVideo]);
                    if (scope.wpPid === "") {
                        // no known pid -> assume it needs to warm up: hold the
                        // frame, then hand off to the video.
                        pendingPath  = still;
                        pendingKind  = "animated";
                        pendingVideo = scope.wpVideo;
                        handoffPending = true;
                        wipeProgress = 1;
                        xferOpacity = 1;
                        handoffDelay.restart();
                    }
                }
                publishStatus();
            }

            function evaluate() {
                const still = scope.wpStill;
                const kind  = scope.wpKind;
                if (still === "") return;

                if (!adopted) { adopt(still, kind); return; }
                if (transitioning || handoffPending) return;   // busy — re-checked at finish

                if (still === activePath && kind === activeKind) {
                    if (kind === "animated" && scope.wpPid !== "") knownPid = scope.wpPid;
                    return;
                }
                startTransition(still, kind);
            }

            function startTransition(still, kind) {
                pendingPath  = still;
                pendingKind  = kind;
                pendingVideo = (kind === "animated") ? scope.wpVideo : "";
                retirePid    = (activeKind === "animated") ? knownPid : "";
                spawnedEarly = false;

                // pick the incoming buffer: reuse whichever already holds `still`,
                // else load into the non-active one.
                let target = (pathOf(0) === still) ? 0
                           : (pathOf(1) === still) ? 1
                           : (1 - activeLayer);
                pendingLayer = target;
                if (pathOf(target) !== still) setBuf(target, still);

                // static -> animated: the opaque old static base will hide the
                // new mpvpaper for the whole wipe, so start it now and let it
                // warm up (no black at the frame->video handoff).
                if (kind === "animated" && activeKind !== "animated") {
                    Quickshell.execDetached(["hypr-wallpaper", "--spawn-mpvpaper", pendingVideo]);
                    spawnedEarly = true;
                }

                transitioning = true;
                wipeProgress = 0;
                xferOpacity = 1;
                publishStatus();
                tryBeginWipe();
            }

            function tryBeginWipe() {
                if (!transitioning || wipeAnim.running) return;
                if (!xfer.imageReady || xfer.source != uri(pendingPath)) return;
                if (!bufReady(pendingLayer)) return;
                wipeProgress = 0;
                wipeAnim.restart();
            }

            function onBufStatus(i) {
                if (transitioning && i === pendingLayer) tryBeginWipe();
            }

            NumberAnimation {
                id: wipeAnim
                target: win
                property: "wipeProgress"
                from: 0
                to: 1
                duration: Theme.wallpaperTransitionDuration
                easing.type: Easing.InOutCubic
                onFinished: win.finishTransition()
            }

            function finishTransition() {
                // the overlay now covers the screen with `pendingPath`
                activeLayer = pendingLayer;
                activePath  = pendingPath;
                activeKind  = pendingKind;

                if (pendingKind === "animated") {
                    // the overlay (full frame) covers everything now. If we did
                    // not already, start the new mpvpaper; keep the old one
                    // alive (hidden behind the overlay) until the handoff.
                    // Read the video path fresh from state — it is settled now.
                    if (!spawnedEarly)
                        Quickshell.execDetached(["hypr-wallpaper", "--spawn-mpvpaper",
                                                 scope.wpVideo.length ? scope.wpVideo : pendingVideo]);
                    knownPid = "";                 // re-learned from wallpaper.state
                    transitioning = false;
                    handoffPending = true;
                    wipeProgress = 1;              // overlay shows the full frame
                    handoffDelay.restart();
                } else {
                    // static: the base buffer already holds the new image
                    // (opaque, covered by the overlay showing the same image).
                    retireOld();
                    Quickshell.execDetached(["hypr-wallpaper", "--reap"]);
                    transitioning = false;
                    wipeProgress = 0;             // overlay -> transparent (base shows the same image)
                    Qt.callLater(evaluate);
                }
                publishStatus();
            }

            function retireOld() {
                if (retirePid && retirePid.length > 0)
                    Quickshell.execDetached(["kill", retirePid]);
                retirePid = "";
            }

            // ->animated: give the new mpvpaper time to present, THEN retire the
            // old one and dissolve the frame overlay into the live video (one
            // short handoff, no black).
            Timer {
                id: handoffDelay
                interval: Theme.wallpaperAnimatedGrace
                onTriggered: { win.retireOld(); handoffFade.start(); }
            }
            NumberAnimation {
                id: handoffFade
                target: win
                property: "xferOpacity"
                from: 1
                to: 0
                duration: 260
                easing.type: Easing.InOutCubic
                onFinished: {
                    win.handoffPending = false;
                    win.wipeProgress = 0;
                    win.xferOpacity = 1;         // reset for the next transition
                    // new video is live and its pid is in wallpaper.state now —
                    // kill any mpvpaper we started that is not that one.
                    Quickshell.execDetached(["hypr-wallpaper", "--reap"]);
                    win.publishStatus();
                    Qt.callLater(win.evaluate);
                }
            }
            // keep mpvpaper alive once we are settled on animated (fresh session
            // with a stale state, or a spawn that lost the race)
            Connections {
                target: scope
                function onWpPidChanged() {
                    if (win.activeKind === "animated" && scope.wpKind === "animated"
                        && !win.transitioning && !win.handoffPending) {
                        if (scope.wpPid !== "") win.knownPid = scope.wpPid;
                    }
                }
            }

            // ---- fallback wash (only while nothing is set) ---------
            Item {
                anchors.fill: parent
                z: -1
                visible: win.activePath === "" && !win.baseAnimated && !win.transitioning

                Rectangle {
                    anchors.fill: parent
                    gradient: Gradient {
                        orientation: Gradient.Vertical
                        GradientStop { position: 0.00; color: Theme.accentSoft }
                        GradientStop { position: 0.45; color: Theme.accent }
                        GradientStop { position: 0.78; color: Qt.darker(Theme.accent, 1.6) }
                        GradientStop { position: 1.00; color: Theme.surfaceElevated }
                    }
                }
                Item {
                    id: zones
                    anchors.fill: parent
                    visible: false
                    Rectangle {
                        x: parent.width * 0.52 - width / 2
                        y: parent.height * 0.30 - height / 2
                        width: parent.height * 0.9; height: width; radius: width / 2
                        color: Theme.accentSoft; opacity: 0.9
                    }
                    Rectangle {
                        x: parent.width * 0.16; y: parent.height * 0.10
                        width: parent.width * 0.40; height: width; radius: width / 2
                        color: Theme.withAlpha(Theme.accent, 0.7)
                    }
                    Rectangle {
                        x: parent.width * 0.62; y: parent.height * 0.55
                        width: parent.width * 0.50; height: width; radius: width / 2
                        color: Theme.withAlpha(Theme.accentSecondary, 0.5)
                    }
                    Rectangle {
                        x: parent.width * 0.04; y: parent.height * 0.58
                        width: parent.width * 0.44; height: width; radius: width / 2
                        color: Theme.withAlpha(Theme.accentSoft, 0.5)
                    }
                }
                MultiEffect {
                    anchors.fill: parent
                    source: zones
                    blurEnabled: true
                    blur: 1.0
                    blurMax: 64
                    autoPaddingEnabled: true
                    opacity: 0.85
                }
            }

            // ---- static base buffers ------------------------------
            // opaque for a static wallpaper; transparent when animated so
            // mpvpaper (behind, on Background) shows through.
            Image {
                id: layer0
                anchors.fill: parent
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: true
                z: win.activeLayer === 0 ? 1 : 0
                opacity: win.baseAnimated ? 0 : 1
                onStatusChanged: win.onBufStatus(0)
            }
            Image {
                id: layer1
                anchors.fill: parent
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: true
                z: win.activeLayer === 1 ? 1 : 0
                opacity: win.baseAnimated ? 0 : 1
                onStatusChanged: win.onBufStatus(1)
            }

            // ---- the diagonal-wipe overlay -----------------------
            // Always mapped; `xferOpacity` 0 culls it (no GPU) between
            // transitions without ever toggling `visible` (which left the mask
            // texture uninitialised and made the wipe snap).
            DiagonalWallpaperTransition {
                id: xfer
                anchors.fill: parent
                z: 5
                opacity: win.xferOpacity
                source: win.uri(win.pendingPath)
                progress: win.wipeProgress
                onReady: win.tryBeginWipe()
            }
        }
    }
}

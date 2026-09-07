// WorldMap.qml — a minimap of the Infinite Desktop canvas.
//
// STAGE WM-1 — WORKSPACE ISLANDS. Each WORKSPACE is drawn as its own world (an
// "island"), not each monitor. A workspace is a persistent world; a monitor is
// just a viewport that currently observes one. This matches camera.json already
// being per-workspace.
//
//   workspace-local screen  = window.at - monitor.origin   (strip the physical
//                             monitor offset so moving/re-assigning the monitor
//                             does not move the world)
//   workspace-world         = workspace-local screen + camera[ws]
//   the workspace's viewport = camera[ws] .. camera[ws] + monitor.logicalSize
//
// Islands are packed left-to-right by workspace id with a MAP-ONLY gap
// (`workspaceGap`) — nothing is written to camera.json, no real window moves.
// A window only ever appears inside its own workspace's island. If a workspace
// is not on any monitor it is still a valid world (labelled "Not visible") with
// no viewport rect.
//
// Click a window → world_navigate.py flies its workspace's camera to it, then
// focuses, then the map closes. Wheel = zoom (0.15×–4× of auto-fit). Drag empty
// space = pan the map view. Fit = frame every island.
//
// DRAG / RESIZE a window's body applies once on release via world_edit.py — the
// island-world geometry is converted back to a Hyprland screen coord
// (screen = islandWorld - camera[ws] + monitor.origin), so it is only allowed
// while the workspace has a visible monitor. Backends (world_edit.py /
// world_navigate.py) are UNCHANGED.
//
// Opened from the navbar's centre indicator or Super+Tab (see shell.qml).
import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Io
import "root:/"

Scope {
    id: scope

    property bool open: false
    function toggle() { scope.open = !scope.open; }
    function close()  { scope.open = false; }

    // ---- camera.json (written by world.py / world_navigate.py) -------
    FileView {
        id: camFile
        path: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/infinite-desktop/camera.json"
        watchChanges: true
        printErrors: false
        property var cams: ({})
        property int rev: 0
        property string _last: ""
        function parse() {
            let obj = {};
            try { obj = JSON.parse(text() || "{}"); } catch (e) { obj = {}; }
            const s = JSON.stringify(obj);
            if (s === _last) return;
            _last = s; cams = obj; rev++;
        }
        onLoaded: parse()
        onLoadFailed: { if (_last !== "") { _last = ""; cams = ({}); rev++; } }
        onFileChanged: reload()
    }

    readonly property string navScript:
        Quickshell.env("HOME") + "/scripts/world_navigate.py"
    readonly property string editScript:
        Quickshell.env("HOME") + "/scripts/world_edit.py"

    // map-only spacing between workspace islands, in workspace-world units
    // (islands are ~one monitor-width wide). Never written anywhere.
    readonly property real workspaceGap: 260

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: win
            required property var modelData
            screen: modelData

            WlrLayershell.namespace: "quickshell:worldmap"
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.keyboardFocus: scope.open ? WlrKeyboardFocus.Exclusive
                                                    : WlrKeyboardFocus.None
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            exclusiveZone: 0
            color: "transparent"
            visible: scope.open

            // only the screen with the focused workspace draws the map
            readonly property bool primary:
                Hyprland.focusedMonitor && Hyprland.focusedMonitor.name === modelData.name

            // ---- data ------------------------------------------------
            property int    monRev: 0
            function bumpMon() { monRev += 1; }

            // one entry per enabled monitor — GLOBAL origin + LOGICAL size + the
            // workspace it currently shows. Re-evaluates on add/remove, ws
            // switch and camFile changes.
            readonly property var monitors: {
                monRev;
                const list = Hyprland.monitors ? Hyprland.monitors.values : [];
                const out = [];
                for (const m of list) {
                    const io = m.lastIpcObject || {};
                    const aw = m.activeWorkspace;
                    const wsId = aw ? aw.id
                               : (io.activeWorkspace ? io.activeWorkspace.id : -1);
                    const sc = (m.scale && m.scale > 0) ? m.scale
                             : (io.scale && io.scale > 0) ? io.scale : 1;
                    const pw = m.width  || io.width  || 0;
                    const ph = m.height || io.height || 0;
                    if (wsId <= 0 || pw <= 0 || ph <= 0) continue;
                    out.push({
                        name: m.name || io.name || "?",
                        wsId: wsId,
                        focused: !!m.focused,
                        gx: (io.x || 0), gy: (io.y || 0),      // global origin
                        lw: Math.max(1, pw / sc), lh: Math.max(1, ph / sc)
                    });
                }
                return out;
            }
            readonly property var monByWs: {
                const o = {};
                for (const m of win.monitors) o[m.wsId] = m;
                return o;
            }

            // computed by rebuild():
            property var    islands: []       // {wsId,monName,visible,focused,ox,oy,bx,by,bw,bh,vp}
            property var    wins: []          // FLAT: {addr,ws,cls,title,wx,wy,w,h,monX,monY,canEdit,focused}
            property var    viewports: []     // {wsId,name,focused,mx,my,w,h}  (map-world)
            property var    islOff: ({})      // wsId -> {mox,moy}  map-world offset for that island
            property var    packed: ({ x: 0, y: 0, w: 1, h: 1 })
            property string _sig: ""

            property string focusedAddr: Hyprland.activeToplevel ? Hyprland.activeToplevel.address : ""
            property string selectedAddr: ""
            property bool   editing: false
            function _norm(a) { return String(a || "").replace(/^0x/, "").toLowerCase(); }

            function rebuild() {
                if (win.editing) return;
                const cams = (camFile.rev, camFile.cams);
                const fa = _norm(win.focusedAddr);
                const monByWs = win.monByWs;
                const tl = Hyprland.toplevels ? Hyprland.toplevels.values : [];

                // 1. which workspaces to draw: on a monitor, OR has a floating window
                const wsset = {};
                for (const m of win.monitors) wsset[m.wsId] = true;
                for (const t of tl) {
                    const o = t.lastIpcObject;
                    if (!o || !o.floating || !o.at || !o.size) continue;
                    const id = (o.workspace || {}).id;
                    if (id > 0) wsset[id] = true;
                }
                const ids = Object.keys(wsset).map(Number)
                    .filter(n => n > 0).sort((a, b) => a - b);

                // 2. one island per workspace, in workspace-world coords
                const isl = [];
                for (const id of ids) {
                    const mon = monByWs[id] || null;
                    const c = cams[String(id)] || { x: 0, y: 0 };
                    const monX = mon ? mon.gx : 0;
                    const monY = mon ? mon.gy : 0;
                    const iw = [];
                    for (const t of tl) {
                        const o = t.lastIpcObject;
                        if (!o || !o.floating || !o.at || !o.size) continue;
                        if ((o.workspace || {}).id !== id) continue;
                        iw.push({
                            addr: (o.address || t.address || ""),
                            cls:  (o["initialClass"] || o["class"] || "?"),
                            title: o.title || "",
                            wx: Math.round(o.at[0] - monX + c.x),   // ws-local + camera
                            wy: Math.round(o.at[1] - monY + c.y),
                            w:  Math.max(60, Math.round(o.size[0])),
                            h:  Math.max(40, Math.round(o.size[1])),
                            focused: (win._norm(o.address || t.address) === fa && fa.length > 0)
                        });
                    }
                    const vp = mon ? { wx: c.x, wy: c.y, w: mon.lw, h: mon.lh } : null;
                    let minx = 1e9, miny = 1e9, maxx = -1e9, maxy = -1e9;
                    if (vp) { minx = vp.wx; miny = vp.wy; maxx = vp.wx + vp.w; maxy = vp.wy + vp.h; }
                    for (const w of iw) {
                        minx = Math.min(minx, w.wx);        miny = Math.min(miny, w.wy);
                        maxx = Math.max(maxx, w.wx + w.w);  maxy = Math.max(maxy, w.wy + w.h);
                    }
                    if (minx > maxx) { minx = 0; miny = 0; maxx = 900; maxy = 560; }
                    const pad = 70;
                    isl.push({
                        wsId: id,
                        monName: mon ? mon.name : "",
                        visible: !!mon, focused: mon ? !!mon.focused : false,
                        monX: monX, monY: monY, vp: vp, wins: iw,
                        bx: minx - pad, by: miny - pad,
                        bw: (maxx - minx) + 2 * pad, bh: (maxy - miny) + 2 * pad
                    });
                }

                // 3. pack the islands left-to-right, centred vertically
                const maxBh = isl.reduce((a, s) => Math.max(a, s.bh), 1);
                let ox = 0;
                for (const s of isl) {
                    s.ox = ox;
                    s.oy = (maxBh - s.bh) / 2;
                    ox += s.bw + scope.workspaceGap;
                }
                const packedW = Math.max(1, ox - scope.workspaceGap);
                const mx = Math.max(30, packedW * 0.04);
                const my = Math.max(30, maxBh  * 0.06);
                const newPacked = { x: -mx, y: -my,
                                    w: packedW + 2 * mx, h: maxBh + 2 * my };

                // 4. flatten for the Repeaters
                const flatW = [], vps = [], off = {};
                for (const s of isl) {
                    const mox = s.ox - s.bx, moy = s.oy - s.by;
                    off[s.wsId] = { mox: mox, moy: moy };
                    for (const w of s.wins)
                        flatW.push({
                            addr: w.addr, ws: s.wsId, cls: w.cls, title: w.title,
                            wx: w.wx, wy: w.wy, w: w.w, h: w.h,
                            monX: s.monX, monY: s.monY, canEdit: s.visible,
                            focused: w.focused
                        });
                    if (s.vp)
                        vps.push({ wsId: s.wsId, name: s.monName, focused: s.focused,
                                   mx: s.vp.wx + mox, my: s.vp.wy + moy,
                                   w: s.vp.w, h: s.vp.h });
                }

                const sig = JSON.stringify([isl, flatW, vps, newPacked]);
                if (sig === win._sig) return;
                win._sig = sig;
                win.islands = isl;
                win.wins = flatW;
                win.viewports = vps;
                win.islOff = off;
                win.packed = newPacked;
            }

            function refresh() { Hyprland.refreshToplevels(); }

            onVisibleChanged: {
                if (visible) {
                    Hyprland.refreshMonitors(); refresh(); bumpMon();
                    userZoom = 1; panX = 0; panY = 0;
                    selectedAddr = ""; editing = false; _sig = "";
                    rebuild();
                }
            }
            onMonitorsChanged: if (visible) rebuild()
            onFocusedAddrChanged: if (visible) rebuild()
            Connections {
                target: camFile
                function onRevChanged() { if (win.visible && !win.editing) win.rebuild(); }
            }
            Connections {
                target: Hyprland
                function onRawEvent(e) {
                    if (!win.visible || win.editing) return;
                    const n = e.name;
                    if (n === "openwindow" || n === "closewindow"
                        || n === "movewindowv2" || n === "windowtitlev2"
                        || n === "activewindowv2" || n === "changefloatingmode"
                        || n === "fullscreen")
                        refreshDebounce.restart();
                    else if (n === "monitoradded" || n === "monitoraddedv2"
                        || n === "monitorremoved" || n === "workspacev2"
                        || n === "focusedmonv2" || n === "moveworkspacev2"
                        || n === "activespecialv2")
                        monDebounce.restart();
                }
            }
            Connections {
                target: Hyprland.toplevels
                function onValuesChanged() { if (win.visible && !win.editing) win.rebuild(); }
            }
            // refreshToplevels() only re-fetches geometry; it does not by itself
            // emit toplevels.onValuesChanged (that is for add/remove). So each
            // tick we refresh AND rebuild from whatever the previous refresh
            // landed — the map trails real geometry by ~one tick, which is fine.
            Timer { id: refreshDebounce; interval: 40; onTriggered: { win.refresh(); win.rebuild(); } }
            // monitor add/remove/ws-switch: re-fetch the monitor list and rebuild
            Timer {
                id: monDebounce; interval: 50
                onTriggered: {
                    Hyprland.refreshMonitors(); win.bumpMon();
                    win.refresh(); win.rebuild();
                }
            }
            // while open (and not mid-edit), catch geometry changes that emit no
            // Hyprland event (panning, pseudo-maximize, Floating-World resize,
            // World Map / SUPER+mouse edits)
            Timer {
                running: win.visible && !win.editing
                interval: 130; repeat: true
                onTriggered: { win.refresh(); camFile.reload(); win.rebuild(); }
            }
            // slower beat: output layout / scale changes emit no reliable event
            Timer {
                running: win.visible
                interval: 1000; repeat: true
                onTriggered: { Hyprland.refreshMonitors(); win.bumpMon(); }
            }
            // resume the refresh loop a beat after an edit is applied
            Timer {
                id: editSettle
                interval: 260
                onTriggered: { win.editing = false; win.refresh(); win.rebuild(); }
            }

            // ---- map transform -------------------------------------
            property real userZoom: 1      // 0.15 .. 4  (of the auto-fit scale)
            property real panX: 0
            property real panY: 0

            // `packed` (the total extent of every workspace island, map-world
            // units) is computed in rebuild(). The transform below fits it into
            // mapArea and applies the wheel-zoom + drag-pan.
            readonly property real fitScale:
                Math.min(mapArea.width  / Math.max(1, win.packed.w),
                         mapArea.height / Math.max(1, win.packed.h))
            readonly property real scale: fitScale * userZoom
            readonly property real offX:
                panX + (mapArea.width  - win.packed.w * scale) / 2
            readonly property real offY:
                panY + (mapArea.height - win.packed.h * scale) / 2

            function mapX(wx) { return (wx - win.packed.x) * scale + offX; }
            function mapY(wy) { return (wy - win.packed.y) * scale + offY; }
            // smoothness lives on the delegates (Behavior on x/y/width/height)

            // ---- close on Esc / outside --------------------------
            Item {
                anchors.fill: parent
                focus: win.visible
                Keys.onEscapePressed: scope.close()

                Rectangle {
                    anchors.fill: parent
                    color: Theme.withAlpha(Theme.scrim, 0.4)
                    opacity: win.visible ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 150 } }
                    MouseArea { anchors.fill: parent; onClicked: scope.close() }
                }
            }

            // ---- the card --------------------------------------
            Rectangle {
                id: card
                visible: win.primary
                anchors.centerIn: parent
                width:  parent.width  * 0.78
                height: parent.height * 0.72
                radius: Theme.radiusLarge
                color: Theme.panelBg
                border.width: 1
                border.color: Theme.withAlpha(Theme.border, 0.6)
                opacity: win.visible ? 1 : 0
                scale: win.visible ? 1 : 0.97
                Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                Behavior on scale   { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

                MouseArea { anchors.fill: parent }   // swallow clicks on the card

                // header
                Item {
                    id: header
                    anchors { left: parent.left; right: parent.right; top: parent.top }
                    height: 40
                    Text {
                        anchors { left: parent.left; leftMargin: 16; verticalCenter: parent.verticalCenter }
                        text: "World Map"
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeLarge; font.bold: true
                        color: Theme.foreground
                    }
                    Text {
                        anchors { left: parent.left; leftMargin: 108; verticalCenter: parent.verticalCenter }
                        text: win.wins.length + (win.wins.length === 1 ? " window" : " windows")
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeSmall
                        color: Theme.foregroundMuted
                    }
                    Row {
                        anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                        spacing: 6
                        ZoomBtn { label: "−"; onTapped: win.userZoom = Math.max(0.15, win.userZoom / 1.25) }
                        ZoomBtn { label: "+"; onTapped: win.userZoom = Math.min(4,   win.userZoom * 1.25) }
                        ZoomBtn {
                            label: "fit"; wide: true
                            onTapped: { win.userZoom = 1; win.panX = 0; win.panY = 0; }
                        }
                    }
                    Rectangle {
                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                        height: 1; color: Theme.withAlpha(Theme.border, 0.4)
                    }
                }

                // the map
                Item {
                    id: mapArea
                    anchors {
                        left: parent.left; right: parent.right
                        top: header.bottom; bottom: parent.bottom
                        margins: 10
                    }
                    clip: true

                    Rectangle {              // canvas ground
                        anchors.fill: parent
                        radius: Theme.radiusMedium
                        color: Theme.withAlpha(Theme.background, 0.55)
                        border.width: 1
                        border.color: Theme.withAlpha(Theme.border, 0.35)
                    }

                    // wheel zoom + drag-to-pan on empty space
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton
                        property real _px: 0
                        property real _py: 0
                        onWheel: (w) => {
                            const f = w.angleDelta.y > 0 ? 1.12 : 1 / 1.12;
                            win.userZoom = Math.max(0.15, Math.min(4, win.userZoom * f));
                        }
                        onPressed: (m) => { _px = m.x; _py = m.y; win.selectedAddr = ""; }
                        onPositionChanged: (m) => {
                            win.panX += m.x - _px;
                            win.panY += m.y - _py;
                            _px = m.x; _py = m.y;
                        }
                    }

                    // empty state
                    Text {
                        anchors.centerIn: parent
                        visible: win.islands.length === 0
                        text: "No workspaces"
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeSmall
                        color: Theme.foregroundMuted
                    }

                    // ---- workspace islands (one framed area per workspace) ----
                    Repeater {
                        model: win.islands
                        delegate: Item {
                            required property var modelData
                            x: win.mapX(modelData.ox)
                            y: win.mapY(modelData.oy)
                            width:  Math.max(4, modelData.bw * win.scale)
                            height: Math.max(4, modelData.bh * win.scale)
                            z: -2
                            Behavior on x      { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                            Behavior on y      { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                            Behavior on width  { NumberAnimation { duration: 140 } }
                            Behavior on height { NumberAnimation { duration: 140 } }

                            Rectangle {                 // island frame
                                anchors.fill: parent
                                radius: 8
                                color: modelData.focused ? Theme.withAlpha(Theme.accent, 0.05)
                                                         : Theme.withAlpha(Theme.foreground, 0.02)
                                border.width: 1
                                border.color: modelData.focused
                                    ? Theme.withAlpha(Theme.accent, 0.55)
                                    : Theme.withAlpha(Theme.border, 0.5)
                            }
                            Rectangle {                 // header chip
                                anchors { left: parent.left; top: parent.top; margins: 4 }
                                width: hdr.implicitWidth + 12
                                height: hdr.implicitHeight + 6
                                radius: 4
                                color: Theme.withAlpha(Theme.scrim, 0.78)
                                visible: parent.width > 84
                                Column {
                                    id: hdr
                                    anchors.centerIn: parent
                                    spacing: 0
                                    Text {
                                        text: "Workspace " + modelData.wsId
                                        font.family: Theme.fontFamily; font.pixelSize: 10; font.bold: true
                                        color: modelData.focused ? Theme.accent : Theme.foreground
                                    }
                                    Text {
                                        text: modelData.visible ? modelData.monName : "Not visible"
                                        font.family: Theme.fontFamily; font.pixelSize: 8
                                        color: Theme.foregroundMuted
                                    }
                                }
                            }
                        }
                    }

                    // ---- workspace viewports (only where a monitor shows one) ----
                    Repeater {
                        model: win.viewports
                        delegate: Rectangle {
                            required property var modelData
                            x: win.mapX(modelData.mx)
                            y: win.mapY(modelData.my)
                            width:  Math.max(2, modelData.w * win.scale)
                            height: Math.max(2, modelData.h * win.scale)
                            z: -1
                            color: modelData.focused ? Theme.withAlpha(Theme.accentSoft, 0.10)
                                                     : Theme.withAlpha(Theme.accentSoft, 0.045)
                            border.width: modelData.focused ? 2 : 1
                            border.color: modelData.focused
                                ? Theme.withAlpha(Theme.accentSoft, 0.9)
                                : Theme.withAlpha(Theme.accentSoft, 0.4)
                            radius: 3
                            Behavior on x      { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                            Behavior on y      { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                            Behavior on width  { NumberAnimation { duration: 120 } }
                            Behavior on height { NumberAnimation { duration: 120 } }

                            Rectangle {   // corner label — the monitor showing this workspace
                                anchors { right: parent.right; top: parent.top; margins: 3 }
                                width: vpl.width + 8; height: 13; radius: 3
                                color: Theme.withAlpha(Theme.scrim, 0.7)
                                visible: parent.width > 70
                                Text {
                                    id: vpl
                                    anchors.centerIn: parent
                                    text: modelData.name
                                    font.family: Theme.fontFamily; font.pixelSize: 9
                                    color: Theme.accentSoft
                                }
                            }
                        }
                    }

                    // ---- windows ----
                    Repeater {
                        model: win.wins
                        delegate: Item {
                            id: dg
                            required property var modelData
                            readonly property string addr: modelData.addr

                            // preview geometry in WORKSPACE-WORLD coords — the
                            // live model values until a drag breaks the binding;
                            // commit() pins the dropped value, editSettle re-syncs.
                            property real ewx: modelData.wx
                            property real ewy: modelData.wy
                            property real ew:  modelData.w
                            property real eh:  modelData.h
                            property bool moving:   false
                            property bool resizing: false
                            readonly property bool active:   moving || resizing
                            readonly property bool selected: win.selectedAddr === dg.addr
                            readonly property bool canEdit:  !!dg.modelData.canEdit
                            // map-world offset of this window's island
                            readonly property var _off: win.islOff[dg.modelData.ws] || { mox: 0, moy: 0 }

                            x: win.mapX(ewx + _off.mox)
                            y: win.mapY(ewy + _off.moy)
                            width:  Math.max(6, ew * win.scale)
                            height: Math.max(6, eh * win.scale)
                            z: (active || selected) ? 5 : 0

                            Behavior on x      { enabled: !dg.active; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                            Behavior on y      { enabled: !dg.active; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                            Behavior on width  { enabled: !dg.active; NumberAnimation { duration: 120 } }
                            Behavior on height { enabled: !dg.active; NumberAnimation { duration: 120 } }

                            function commit() {
                                var gx = Math.round(dg.ewx), gy = Math.round(dg.ewy);
                                var gw = Math.round(dg.ew),  gh = Math.round(dg.eh);
                                dg.ewx = gx; dg.ewy = gy; dg.ew = gw; dg.eh = gh;
                                // no real movement, or no monitor to map back to -> no-op
                                if (!dg.canEdit ||
                                    (gx === dg.modelData.wx && gy === dg.modelData.wy
                                     && gw === dg.modelData.w && gh === dg.modelData.h)) {
                                    editSettle.restart();
                                    return;
                                }
                                // world_edit.py does screen = arg - camera[ws]; we want
                                // screen at.x = islandWorld - camera[ws] + monitor.origin
                                // -> arg = islandWorld + monitor.origin.
                                Quickshell.execDetached(["python3", scope.editScript,
                                    "geometry", dg.addr,
                                    String(gx + dg.modelData.monX),
                                    String(gy + dg.modelData.monY),
                                    String(gw), String(gh)]);
                                editSettle.restart();
                            }

                            // ---- body ----
                            Rectangle {
                                id: body
                                anchors.fill: parent
                                radius: Math.min(6, width * 0.12)
                                color: dg.modelData.focused ? Theme.withAlpha(Theme.accent, 0.28)
                                     : dg.selected           ? Theme.withAlpha(Theme.accent, 0.15)
                                                             : Theme.withAlpha(Theme.surface, 0.75)
                                border.width: (dg.selected || dg.active || dg.modelData.focused) ? 2 : 1
                                border.color: (dg.selected || dg.active) ? Theme.accent
                                            : dg.modelData.focused        ? Theme.accent
                                            : bodyMA.containsMouse         ? Theme.accentSoft
                                                                          : Theme.withAlpha(Theme.border, 0.7)

                                Column {
                                    anchors.centerIn: parent
                                    spacing: 2
                                    visible: dg.width > 46 && dg.height > 34
                                    Image {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        width: Math.min(26, dg.height * 0.4)
                                        height: width
                                        asynchronous: true
                                        fillMode: Image.PreserveAspectFit
                                        source: {
                                            const e = DesktopEntries.heuristicLookup(dg.modelData.cls);
                                            const p = e ? Quickshell.iconPath(e.icon, true) : "";
                                            return p && p.length ? p : "";
                                        }
                                        visible: status === Image.Ready && dg.width > 64
                                    }
                                    Text {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        width: dg.width - 8
                                        horizontalAlignment: Text.AlignHCenter
                                        elide: Text.ElideRight
                                        text: dg.modelData.cls
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Math.max(8, Math.min(12, dg.height * 0.16))
                                        color: (dg.modelData.focused || dg.selected) ? Theme.foreground
                                                                                     : Theme.foregroundMuted
                                    }
                                }

                                MouseArea {
                                    id: bodyMA
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    acceptedButtons: Qt.LeftButton
                                    cursorShape: dg.moving ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                                    property real _gx: 0   // mapArea coords at press
                                    property real _gy: 0
                                    property real _bx: 0   // world coords at press
                                    property real _by: 0
                                    property bool _drag: false

                                    onPressed: (m) => {
                                        const p = mapArea.mapFromItem(bodyMA, m.x, m.y);
                                        _gx = p.x; _gy = p.y; _bx = dg.ewx; _by = dg.ewy;
                                        _drag = false;
                                        win.selectedAddr = dg.addr;
                                        // hold the refresh loop from the first press so a
                                        // 130 ms tick can't tear this delegate down mid-gesture
                                        win.editing = true;
                                    }
                                    onPositionChanged: (m) => {
                                        if (!pressed) return;
                                        const p = mapArea.mapFromItem(bodyMA, m.x, m.y);
                                        if (!_drag) {
                                            if (Math.hypot(p.x - _gx, p.y - _gy) < 6) return;
                                            if (!dg.canEdit) return;   // not-visible ws: click only
                                            _drag = true; dg.moving = true;
                                        }
                                        dg.ewx = _bx + (p.x - _gx) / win.scale;
                                        dg.ewy = _by + (p.y - _gy) / win.scale;
                                    }
                                    onReleased: (m) => {
                                        if (_drag) { dg.moving = false; dg.commit(); }
                                        else {
                                            win.editing = false;
                                            Quickshell.execDetached(["python3", scope.navScript,
                                                                     "address", dg.addr]);
                                            closeSoon.restart();
                                        }
                                        _drag = false;
                                    }
                                    onCanceled: {
                                        if (_drag) { dg.moving = false; dg.commit(); }
                                        else win.editing = false;
                                        _drag = false;
                                    }
                                }
                            }

                            // ---- resize handles (corners + edge midpoints) ----
                            Repeater {
                                model: [[-1,-1],[1,-1],[-1,1],[1,1],[0,-1],[0,1],[-1,0],[1,0]]
                                delegate: Rectangle {
                                    id: hnd
                                    required property var modelData
                                    readonly property int hx: modelData[0]
                                    readonly property int hy: modelData[1]
                                    readonly property bool corner: hx !== 0 && hy !== 0
                                    visible: dg.canEdit
                                             && (dg.selected || bodyMA.containsMouse || hMA.containsMouse || dg.active)
                                             && dg.width > 40 && dg.height > 30
                                    width:  corner ? 9 : (hx === 0 ? 18 : 6)
                                    height: corner ? 9 : (hy === 0 ? 18 : 6)
                                    radius: 2
                                    color: (hMA.containsMouse || dg.resizing) ? Theme.accent
                                                                              : Theme.withAlpha(Theme.accent, 0.8)
                                    border.width: 1
                                    border.color: Theme.withAlpha(Theme.scrim, 0.5)
                                    x: hx < 0 ? -width / 2  : hx > 0 ? dg.width  - width / 2  : (dg.width  - width)  / 2
                                    y: hy < 0 ? -height / 2 : hy > 0 ? dg.height - height / 2 : (dg.height - height) / 2
                                    z: 6

                                    MouseArea {
                                        id: hMA
                                        anchors.fill: parent
                                        anchors.margins: -4
                                        hoverEnabled: true
                                        acceptedButtons: Qt.LeftButton
                                        cursorShape: hnd.corner
                                            ? (hnd.hx === hnd.hy ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor)
                                            : (hnd.hx === 0 ? Qt.SizeVerCursor : Qt.SizeHorCursor)
                                        property real _gx: 0
                                        property real _gy: 0
                                        property real _bx: 0
                                        property real _by: 0
                                        property real _bw: 0
                                        property real _bh: 0

                                        onPressed: (m) => {
                                            const p = mapArea.mapFromItem(hMA, m.x, m.y);
                                            _gx = p.x; _gy = p.y;
                                            _bx = dg.ewx; _by = dg.ewy; _bw = dg.ew; _bh = dg.eh;
                                            win.selectedAddr = dg.addr;
                                            dg.resizing = true; win.editing = true;
                                        }
                                        onPositionChanged: (m) => {
                                            if (!pressed) return;
                                            const p = mapArea.mapFromItem(hMA, m.x, m.y);
                                            const dwx = (p.x - _gx) / win.scale;
                                            const dwy = (p.y - _gy) / win.scale;
                                            let nx = _bx, ny = _by, nw = _bw, nh = _bh;
                                            if (hnd.hx === 1)  nw = _bw + dwx;
                                            if (hnd.hx === -1) { nx = _bx + dwx; nw = _bw - dwx; }
                                            if (hnd.hy === 1)  nh = _bh + dwy;
                                            if (hnd.hy === -1) { ny = _by + dwy; nh = _bh - dwy; }
                                            const MINW = 220, MINH = 140;
                                            if (nw < MINW) { if (hnd.hx === -1) nx -= (MINW - nw); nw = MINW; }
                                            if (nh < MINH) { if (hnd.hy === -1) ny -= (MINH - nh); nh = MINH; }
                                            dg.ewx = nx; dg.ewy = ny; dg.ew = nw; dg.eh = nh;
                                        }
                                        onReleased: { dg.resizing = false; dg.commit(); }
                                        onCanceled:  { dg.resizing = false; dg.commit(); }
                                    }
                                }
                            }

                            // ---- move / resize readout ----
                            Rectangle {
                                visible: dg.active
                                anchors.horizontalCenter: parent.horizontalCenter
                                y: -17
                                width: elbl.implicitWidth + 12
                                height: 15
                                radius: 3
                                color: Theme.withAlpha(Theme.scrim, 0.85)
                                Text {
                                    id: elbl
                                    anchors.centerIn: parent
                                    text: dg.resizing
                                        ? (Math.round(dg.ew) + " × " + Math.round(dg.eh))
                                        : ("x " + Math.round(dg.ewx) + "   y " + Math.round(dg.ewy))
                                    color: Theme.accent
                                    font.family: Theme.fontFamily
                                    font.pixelSize: 9
                                }
                            }
                        }
                    }

                    // (monitor viewports are drawn above, behind the windows)
                }
            }

            Timer { id: closeSoon; interval: 170; onTriggered: scope.close() }

            component ZoomBtn: Rectangle {
                property string label
                property bool wide: false
                signal tapped()
                width: wide ? 34 : 24; height: 22
                radius: Theme.radiusSmall
                color: zbm.containsMouse ? Theme.surfaceHover : Theme.withAlpha(Theme.surface, 0.6)
                Text {
                    anchors.centerIn: parent
                    text: parent.label
                    font.family: Theme.fontFamily; font.pixelSize: parent.wide ? 10 : 14
                    color: Theme.foreground
                }
                MouseArea {
                    id: zbm
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: parent.tapped()
                }
            }
        }
    }
}

// WorldMap.qml — a minimap of the Infinite Desktop canvas.
//
// Infinite Desktop pans by physically moving every window, so this map works in
// WORLD coordinates: worldX = client.at.x + camera.x, where camera.x comes from
// scripts/infinite-desktop/world.py (camera.json, per workspace). Panning the
// desktop moves the camera, not the windows' world positions — so on the map
// the windows stay put and the viewport rectangle slides.
//
// Click a window → scripts/infinite-desktop/world_navigate.py flies the whole
// camera to it (same pan mechanism, relative layout preserved), then focuses
// it, then the map closes. Wheel = zoom the map (0.15×–4× of the auto-fit,
// never touches the real desktop). Drag empty space = pan the map view.
//
// DRAG a window's body → move it inside the canvas (world coordinates; the
// camera does NOT move). Select a window → resize handles on its corners/edges.
// Both preview live in QML and apply once, on release, via
// scripts/infinite-desktop/world_edit.py (world→screen conversion, one hyprctl
// batch, camera untouched). A short click still navigates.
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
    function cameraFor(wsId) {
        const c = camFile.cams[String(wsId)];
        return c ? { x: c.x, y: c.y } : { x: 0, y: 0 };
    }

    readonly property string navScript:
        Quickshell.env("HOME") + "/scripts/world_navigate.py"
    readonly property string editScript:
        Quickshell.env("HOME") + "/scripts/world_edit.py"

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
            property int    wsId: Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 1
            // camFile.rev in the expression forces re-eval when camera.json reloads
            property var    cam: (camFile.rev, scope.cameraFor(wsId))
            property var    wins: []          // {addr, cls, title, wx, wy, w, h, focused}
            property string _winsJson: ""     // dedupe: skip reassign when unchanged
            property string focusedAddr: Hyprland.activeToplevel ? Hyprland.activeToplevel.address : ""
            // which window shows resize handles; "" = none
            property string selectedAddr: ""
            // true while a move/resize drag is in flight — pauses the refresh
            // loop so the dragged delegate is not torn down under the cursor
            property bool   editing: false
            // Quickshell toplevel addresses have no "0x"; hyprctl's do.
            function _norm(a) { return String(a || "").replace(/^0x/, "").toLowerCase(); }

            function rebuild() {
                if (win.editing) return;
                const out = [];
                const fa = _norm(win.focusedAddr);
                const list = Hyprland.toplevels ? Hyprland.toplevels.values : [];
                for (const t of list) {
                    const o = t.lastIpcObject;
                    if (!o || !o.at || !o.size) continue;
                    const ows = (o.workspace || {}).id;
                    if (ows !== win.wsId || ows <= 0) continue;
                    if (!o.floating) continue;
                    out.push({
                        addr: (o.address || t.address || ""),
                        cls:  (o["initialClass"] || o["class"] || "?"),
                        title: o.title || "",
                        wx: Math.round(o.at[0] + win.cam.x),
                        wy: Math.round(o.at[1] + win.cam.y),
                        w:  Math.max(60, Math.round(o.size[0])),
                        h:  Math.max(40, Math.round(o.size[1])),
                        focused: (win._norm(o.address || t.address) === fa && fa.length > 0)
                    });
                }
                const s = JSON.stringify(out);
                if (s === win._winsJson) return;   // nothing moved → keep delegates
                win._winsJson = s;
                win.wins = out;
            }

            function refresh() { Hyprland.refreshToplevels(); }

            onVisibleChanged: {
                if (visible) {
                    refresh(); userZoom = 1; panX = 0; panY = 0;
                    selectedAddr = ""; editing = false; _winsJson = "";
                    rebuild();
                }
            }
            onCamChanged: rebuild()
            onFocusedAddrChanged: if (visible) rebuild()
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
            // while open (and not mid-edit), catch geometry changes that emit no
            // Hyprland event (panning, pseudo-maximize, Floating-World resize,
            // World Map / SUPER+mouse edits)
            Timer {
                running: win.visible && !win.editing
                interval: 130; repeat: true
                onTriggered: { win.refresh(); camFile.reload(); win.rebuild(); }
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

            // usable area of THIS monitor, in logical px = the viewport size
            readonly property var usable: {
                const m = modelData;
                const s = m.scale || 1;
                return { w: m.width / s, h: m.height / s };
            }

            // world bounds of everything to show (windows + the viewport)
            readonly property var bounds: {
                let minx = win.cam.x, miny = win.cam.y;
                let maxx = win.cam.x + usable.w, maxy = win.cam.y + usable.h;
                for (const w of win.wins) {
                    minx = Math.min(minx, w.wx);  miny = Math.min(miny, w.wy);
                    maxx = Math.max(maxx, w.wx + w.w);  maxy = Math.max(maxy, w.wy + w.h);
                }
                const mx = (maxx - minx) * 0.10 + 40;
                const my = (maxy - miny) * 0.10 + 40;
                return { x: minx - mx, y: miny - my,
                         w: (maxx - minx) + 2 * mx, h: (maxy - miny) + 2 * my };
            }

            readonly property real fitScale:
                Math.min(mapArea.width / Math.max(1, bounds.w),
                         mapArea.height / Math.max(1, bounds.h))
            readonly property real scale: fitScale * userZoom
            readonly property real offX:
                panX + (mapArea.width  - bounds.w * scale) / 2
            readonly property real offY:
                panY + (mapArea.height - bounds.h * scale) / 2

            function mapX(wx) { return (wx - bounds.x) * scale + offX; }
            function mapY(wy) { return (wy - bounds.y) * scale + offY; }
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
                        visible: win.wins.length === 0
                        text: "No windows on this workspace"
                        font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeSmall
                        color: Theme.foregroundMuted
                    }

                    // ---- windows ----
                    Repeater {
                        model: win.wins
                        delegate: Item {
                            id: dg
                            required property var modelData
                            readonly property string addr: modelData.addr

                            // preview geometry, WORLD coords — the live model
                            // values until a drag breaks the binding; commit()
                            // pins the dropped value, editSettle re-syncs.
                            property real ewx: modelData.wx
                            property real ewy: modelData.wy
                            property real ew:  modelData.w
                            property real eh:  modelData.h
                            property bool moving:   false
                            property bool resizing: false
                            readonly property bool active:   moving || resizing
                            readonly property bool selected: win.selectedAddr === dg.addr

                            x: win.mapX(ewx)
                            y: win.mapY(ewy)
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
                                // a press with no real movement is a no-op: don't
                                // spawn world_edit.py, don't drop pseudo-max state
                                if (gx === dg.modelData.wx && gy === dg.modelData.wy
                                    && gw === dg.modelData.w && gh === dg.modelData.h) {
                                    editSettle.restart();
                                    return;
                                }
                                Quickshell.execDetached(["python3", scope.editScript,
                                    "geometry", dg.addr, String(gx), String(gy),
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
                                    visible: (dg.selected || bodyMA.containsMouse || hMA.containsMouse || dg.active)
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

                    // ---- current viewport ----
                    Rectangle {
                        x: win.mapX(win.cam.x)
                        y: win.mapY(win.cam.y)
                        width:  win.usable.w * win.scale
                        height: win.usable.h * win.scale
                        color: Theme.withAlpha(Theme.accentSoft, 0.10)
                        border.width: 2
                        border.color: Theme.withAlpha(Theme.accentSoft, 0.9)
                        radius: 3
                        Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                        Behavior on y { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                        Rectangle {   // corner label
                            anchors { left: parent.left; top: parent.top; margins: 3 }
                            width: vpl.width + 8; height: 14; radius: 3
                            color: Theme.withAlpha(Theme.scrim, 0.7)
                            visible: parent.width > 60
                            Text {
                                id: vpl
                                anchors.centerIn: parent
                                text: "viewport"
                                font.family: Theme.fontFamily; font.pixelSize: 9
                                color: Theme.accentSoft
                            }
                        }
                    }
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

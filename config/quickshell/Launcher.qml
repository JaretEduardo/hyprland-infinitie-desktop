// Launcher.qml — a Caelestia-style application launcher, native to Quickshell
// (no fuzzel). A centred floating overlay with exclusive keyboard focus.
//
//   Super (tap and release)   -> toggle      (config/hypr/lua/bindings.lua)
//   Super + Space             -> toggle
//   type to fuzzy-search · ↑/↓ move · Enter launch · Esc close
//
// Apps come from Quickshell's DesktopEntries (parsed .desktop files): real
// icon, name, and the already-field-code-stripped argv. fuzzel stays installed
// as a fallback but is no longer bound.
import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import "root:/"

Scope {
    id: scope

    property bool open: false
    function toggle() { scope.open = !scope.open; }
    function close()  { scope.open = false; }

    PanelWindow {
        id: win
        visible: scope.open

        WlrLayershell.namespace: "quickshell:launcher"
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        anchors { top: true; bottom: true; left: true; right: true }
        exclusiveZone: 0
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"

        // ---- search / filter state --------------------------------
        property string query: ""
        property int index: 0
        property var results: []

        function score(entry, q) {
            if (q.length === 0) return 1;
            const name = (entry.name || "").toLowerCase();
            const gen  = (entry.genericName || "").toLowerCase();
            const hay = name + " " + gen;
            const needle = q.toLowerCase();
            let i = 0, s = 0, streak = 0;
            if (name.startsWith(needle)) s += 40;
            else if (name.indexOf(needle) !== -1) s += 20;
            for (let c = 0; c < hay.length && i < needle.length; c++) {
                if (hay[c] === needle[i]) { i++; streak++; s += 1 + streak; }
                else streak = 0;
            }
            return i === needle.length ? s : 0;
        }

        function rebuild() {
            const all = DesktopEntries.applications.values;
            const q = query.trim();
            let scored = [];
            for (const e of all) {
                if (e.noDisplay) continue;
                const sc = score(e, q);
                if (sc > 0) scored.push({ e: e, s: sc });
            }
            scored.sort((a, b) => b.s - a.s || (a.e.name || "").localeCompare(b.e.name || ""));
            results = scored.slice(0, 40).map(x => x.e);
            if (index >= results.length) index = Math.max(0, results.length - 1);
        }

        function launch(entry) {
            if (!entry) return;
            let argv = entry.command;
            if (entry.runInTerminal) argv = ["foot", "-e"].concat(argv);
            Quickshell.execDetached(argv);
            scope.close();
        }

        onVisibleChanged: {
            if (visible) { query = ""; index = 0; rebuild(); input.forceActiveFocus(); }
        }
        Connections {
            target: DesktopEntries.applications
            function onValuesChanged() { if (win.visible) win.rebuild(); }
        }

        HyprlandFocusGrab {
            active: win.visible
            windows: [win]
            onCleared: scope.close()
        }

        // dim + click-away
        Rectangle {
            anchors.fill: parent
            color: Theme.withAlpha(Theme.scrim, 0.38)
            MouseArea { anchors.fill: parent; onClicked: scope.close() }
        }

        // ---- the card --------------------------------------------
        Rectangle {
            id: card
            anchors.horizontalCenter: parent.horizontalCenter
            y: parent.height * 0.16
            width: Theme.launcherWidth
            height: header.height + list.height + 2 * pad
            readonly property int pad: 14
            radius: Theme.radiusLarge
            color: Theme.panelBg
            border.width: 1
            border.color: Theme.withAlpha(Theme.border, 0.6)

            opacity: win.visible ? 1 : 0
            scale: win.visible ? 1 : 0.97
            Behavior on opacity { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }
            Behavior on scale   { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }

            MouseArea { anchors.fill: parent }   // swallow clicks on the card

            // search field
            Row {
                id: header
                x: card.pad; y: card.pad
                width: parent.width - 2 * card.pad
                height: 40
                spacing: 10

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    font.family: Theme.iconFamily; font.pixelSize: Theme.iconSizeLarge
                    color: Theme.foregroundMuted
                    text: Theme.icon.search
                }
                TextInput {
                    id: input
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 34
                    font.family: Theme.fontFamily; font.pixelSize: 16
                    color: Theme.foreground
                    clip: true
                    focus: true
                    activeFocusOnTab: true
                    onTextChanged: { win.query = text; win.index = 0; win.rebuild(); }
                    Keys.onPressed: (e) => {
                        if (e.key === Qt.Key_Escape) { scope.close(); e.accepted = true; }
                        else if (e.key === Qt.Key_Down) { win.index = Math.min(win.results.length - 1, win.index + 1); e.accepted = true; }
                        else if (e.key === Qt.Key_Up)   { win.index = Math.max(0, win.index - 1); e.accepted = true; }
                        else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { win.launch(win.results[win.index]); e.accepted = true; }
                        else if (e.key === Qt.Key_Tab)  { win.index = Math.min(win.results.length - 1, win.index + 1); e.accepted = true; }
                    }
                    Text {
                        anchors.fill: parent
                        verticalAlignment: Text.AlignVCenter
                        visible: input.text.length === 0
                        font: input.font
                        color: Theme.foregroundMuted
                        text: "Search applications…"
                    }
                }
            }

            Rectangle {
                anchors { left: parent.left; right: parent.right; top: header.bottom; topMargin: 6 }
                height: 1
                color: Theme.withAlpha(Theme.border, 0.4)
            }

            // results
            ListView {
                id: list
                x: card.pad
                y: header.y + header.height + 10
                width: parent.width - 2 * card.pad
                height: Math.min(Theme.launcherMaxHeight,
                                 Math.max(Theme.launcherRowHeight, count * Theme.launcherRowHeight))
                clip: true
                model: win.results
                currentIndex: win.index
                interactive: true
                boundsBehavior: Flickable.StopAtBounds
                highlightMoveDuration: 90

                delegate: Rectangle {
                    required property var modelData
                    required property int index
                    width: list.width
                    height: Theme.launcherRowHeight
                    radius: Theme.radiusSmall
                    color: index === win.index ? Theme.withAlpha(Theme.accent, 0.22) : "transparent"

                    Row {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 12

                        Item {
                            width: 28; height: 28
                            anchors.verticalCenter: parent.verticalCenter
                            Image {
                                id: ico
                                anchors.fill: parent
                                asynchronous: true
                                source: {
                                    const p = Quickshell.iconPath(modelData.icon, true);
                                    return p && p.length ? p : "";
                                }
                                fillMode: Image.PreserveAspectFit
                                visible: status === Image.Ready
                            }
                            Text {
                                anchors.centerIn: parent
                                visible: ico.status !== Image.Ready
                                font.family: Theme.iconFamily; font.pixelSize: Theme.iconSizeLarge
                                color: Theme.foregroundMuted
                                text: Theme.icon.apps
                            }
                        }
                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - 52
                            spacing: 1
                            Text {
                                width: parent.width; elide: Text.ElideRight
                                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize
                                color: Theme.foreground
                                text: modelData.name || modelData.id
                            }
                            Text {
                                width: parent.width; elide: Text.ElideRight
                                visible: !!modelData.genericName || !!modelData.comment
                                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeSmall
                                color: Theme.foregroundMuted
                                text: modelData.genericName || modelData.comment || ""
                            }
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: win.index = index
                        onClicked: win.launch(modelData)
                    }
                }

                // empty state
                Text {
                    anchors.centerIn: parent
                    visible: list.count === 0
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeSmall
                    color: Theme.foregroundMuted
                    text: win.query.length ? "No matches" : "No applications found"
                }
            }
        }
    }
}

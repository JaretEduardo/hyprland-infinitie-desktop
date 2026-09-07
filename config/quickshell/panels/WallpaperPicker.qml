// panels/WallpaperPicker.qml — the visual wallpaper selector, rendered inside
// PanelHost.qml (docked under the navbar). Opens on Super+W or the navbar's
// wallpaper button.
//
// The list and every thumbnail come from `hypr-wallpaper --list-json` (which
// walks <Pictures>/Wallpapers recursively and extracts video frames via
// wallpaper-thumb). Applying a wallpaper ALWAYS shells out to
//   hypr-wallpaper <path>
// so there is zero wallpaper logic duplicated in QML.
import QtQuick
import Quickshell
import Quickshell.Io
import "root:/"

Rectangle {
    id: panel

    implicitWidth: 720
    implicitHeight: body.implicitHeight + 32
    radius: Theme.radiusLarge
    color: Theme.panelBg
    border.width: 1
    border.color: Theme.withAlpha(Theme.border, 0.6)
    focus: true

    // ---- data ------------------------------------------------------
    ListModel { id: allModel }
    property string currentPath: ""
    property string applyingPath: ""     // clicked but not yet the active wallpaper
    property string query: ""
    property int selected: 0

    function reload() { lister.running = true; stateFile.reload(); }

    // fire-and-forget — the picker never waits on hypr-wallpaper / wallust
    function apply(path) {
        applyingPath = path;
        applyClear.restart();
        Quickshell.execDetached(["hypr-wallpaper", path]);
    }
    Timer { id: applyClear; interval: 4000; onTriggered: panel.applyingPath = "" }
    onCurrentPathChanged: if (currentPath === applyingPath) applyingPath = "";

    Process {
        id: lister
        command: ["hypr-wallpaper", "--list-json"]
        stdout: StdioCollector {
            onStreamFinished: {
                allModel.clear();
                let arr = [];
                try { arr = JSON.parse(this.text || "[]"); } catch (e) { arr = []; }
                for (const w of arr) allModel.append(w);
                panel.clampSelection();
            }
        }
    }

    FileView {
        id: stateFile
        path: Theme._cacheHome + "/hyprland-infinitie-desktop/wallpaper.state"
        watchChanges: true
        printErrors: false
        function parse() {
            const m = /(^|\n)path=(.*)/.exec(text() || "");
            panel.currentPath = m ? m[2].trim() : "";
        }
        onLoaded: parse()
        onLoadFailed: panel.currentPath = ""
        onFileChanged: reload()
    }

    Component.onCompleted: reload()

    // filtered view -------------------------------------------------
    function matches(name) {
        if (query.length === 0) return true;
        return name.toLowerCase().indexOf(query.toLowerCase()) !== -1;
    }
    function visibleCount() {
        let n = 0;
        for (let i = 0; i < allModel.count; i++)
            if (matches(allModel.get(i).name)) n++;
        return n;
    }
    function clampSelection() {
        const n = visibleCount();
        if (selected >= n) selected = Math.max(0, n - 1);
        if (selected < 0) selected = 0;
    }
    function applyAt(idx) {
        let seen = -1;
        for (let i = 0; i < allModel.count; i++) {
            if (!matches(allModel.get(i).name)) continue;
            seen++;
            if (seen === idx) {
                panel.apply(allModel.get(i).path);
                return;
            }
        }
    }

    // ---- keyboard ------------------------------------------------
    Keys.onEscapePressed: (e) => { e.accepted = false; }   // let PanelHost close it
    Keys.onPressed: (e) => {
        const cols = grid.columns;
        if (e.key === Qt.Key_Right)      { selected = Math.min(visibleCount() - 1, selected + 1); e.accepted = true; }
        else if (e.key === Qt.Key_Left)  { selected = Math.max(0, selected - 1); e.accepted = true; }
        else if (e.key === Qt.Key_Down)  { selected = Math.min(visibleCount() - 1, selected + cols); e.accepted = true; }
        else if (e.key === Qt.Key_Up)    { selected = Math.max(0, selected - cols); e.accepted = true; }
        else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { applyAt(selected); e.accepted = true; }
        else if (e.key === Qt.Key_Backspace) { query = query.slice(0, -1); clampSelection(); e.accepted = true; }
        else if (e.text.length === 1 && e.text >= " ") { query += e.text; selected = 0; e.accepted = true; }
    }

    Column {
        id: body
        x: 16; y: 16
        width: parent.width - 32
        spacing: 12

        // header: title + live search string
        Item {
            width: parent.width
            height: 22
            Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "Wallpapers"
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeLarge; font.bold: true
                color: Theme.foreground
            }
            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6
                visible: panel.query.length > 0
                Text {
                    font.family: Theme.iconFamily; font.pixelSize: Theme.iconSize
                    color: Theme.foregroundMuted; text: Theme.icon.search
                }
                Text {
                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeSmall
                    color: Theme.foreground; text: panel.query
                }
            }
            Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: panel.query.length === 0
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeSmall
                color: Theme.foregroundMuted
                text: allModel.count + " · type to filter"
            }
        }

        // empty state
        Text {
            width: parent.width
            visible: allModel.count === 0
            wrapMode: Text.WordWrap
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeSmall
            color: Theme.foregroundMuted
            text: "No wallpapers found in " +
                  "~/Pictures/Wallpapers. Drop images (jpg/png/webp) or clips " +
                  "(gif/mp4/webm/mkv) there, or set $HYPR_WALLPAPER_DIR."
        }

        // the grid — panel height follows content up to a cap, then scrolls
        Flickable {
            id: flick
            width: parent.width
            height: Math.min(430, Math.max(grid.cellH, grid.height))
            visible: allModel.count > 0
            clip: true
            contentWidth: width
            contentHeight: grid.height
            boundsBehavior: Flickable.StopAtBounds

            Grid {
                id: grid
                width: parent.width
                columns: Math.max(3, Math.floor(width / 168))
                readonly property real cellW: (width - (columns - 1) * spacing) / columns
                readonly property real cellH: cellW * 0.62 + 22
                spacing: 12

                Repeater {
                    model: allModel
                    delegate: Item {
                        id: cell
                        required property var model
                        required property int index
                        visible: panel.matches(model.name)
                        width: visible ? grid.cellW : 0
                        height: visible ? grid.cellW * 0.62 + 22 : 0

                        // ordinal within the *filtered* set (for keyboard selection)
                        readonly property int filteredIndex: {
                            let seen = -1;
                            for (let i = 0; i <= index; i++)
                                if (panel.matches(allModel.get(i).name)) seen++;
                            return seen;
                        }
                        readonly property bool isCurrent: model.path === panel.currentPath
                        readonly property bool isSelected: filteredIndex === panel.selected
                        readonly property bool isApplying: model.path === panel.applyingPath && !isCurrent

                        Rectangle {
                            anchors.fill: parent
                            radius: Theme.radiusMedium
                            color: Theme.cardBg
                            border.width: (cell.isCurrent || cell.isSelected || cell.isApplying) ? 2 : 1
                            border.color: cell.isCurrent ? Theme.positive
                                        : cell.isApplying ? Theme.accentSoft
                                        : cell.isSelected ? Theme.accent
                                        : Theme.withAlpha(Theme.border, 0.5)
                            clip: true

                            // brief press feedback so the click feels instant
                            Rectangle {
                                anchors.fill: parent
                                radius: parent.radius
                                z: 5
                                visible: cell.isApplying
                                color: Theme.withAlpha(Theme.accent, 0.14)
                                Text {
                                    anchors.centerIn: parent
                                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.foreground
                                    text: "applying…"
                                }
                                SequentialAnimation on opacity {
                                    running: cell.isApplying; loops: Animation.Infinite
                                    NumberAnimation { from: 0.55; to: 1; duration: 500; easing.type: Easing.InOutSine }
                                    NumberAnimation { from: 1; to: 0.55; duration: 500; easing.type: Easing.InOutSine }
                                }
                            }

                            Column {
                                anchors.fill: parent
                                anchors.margins: 4
                                spacing: 3

                                Rectangle {
                                    width: parent.width
                                    height: parent.height - 18
                                    radius: Theme.radiusSmall
                                    clip: true
                                    color: Theme.surfaceElevated
                                    Image {
                                        anchors.fill: parent
                                        source: model.thumb.length ? "file://" + model.thumb : ""
                                        fillMode: Image.PreserveAspectCrop
                                        asynchronous: true
                                        cache: true
                                        sourceSize.width: 360
                                    }
                                    // type badge
                                    Rectangle {
                                        anchors { top: parent.top; right: parent.right; margins: 4 }
                                        width: badge.width + 10; height: 16
                                        radius: 8
                                        color: Theme.withAlpha(Theme.scrim, 0.72)
                                        Row {
                                            id: badge
                                            anchors.centerIn: parent
                                            spacing: 3
                                            Text {
                                                font.family: Theme.iconFamily; font.pixelSize: 9
                                                color: model.type === "animated" ? Theme.accent : Theme.foregroundMuted
                                                text: model.type === "animated" ? Theme.icon.video : Theme.icon.image
                                            }
                                            Text {
                                                font.family: Theme.fontFamily; font.pixelSize: 9
                                                color: Theme.foreground
                                                text: model.type === "animated" ? "GIF/Video" : "Image"
                                            }
                                        }
                                    }
                                    // active check
                                    Rectangle {
                                        anchors { top: parent.top; left: parent.left; margins: 4 }
                                        width: 16; height: 16; radius: 8
                                        visible: cell.isCurrent
                                        color: Theme.positive
                                        Text {
                                            anchors.centerIn: parent
                                            font.family: Theme.iconFamily; font.pixelSize: 10
                                            color: Theme.scrim; text: Theme.icon.check
                                        }
                                    }
                                }
                                Text {
                                    width: parent.width
                                    elide: Text.ElideMiddle
                                    horizontalAlignment: Text.AlignHCenter
                                    font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeSmall
                                    color: cell.isSelected ? Theme.foreground : Theme.foregroundMuted
                                    text: model.name
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onEntered: panel.selected = cell.filteredIndex
                                onClicked: panel.apply(model.path)
                            }
                        }
                    }
                }
            }
        }
    }
}

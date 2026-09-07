// modules/SystemStats.qml — CPU / RAM sampler. Reads /proc via FileView; there
// is no /proc type in Quickshell so this is the one genuinely-polling module
// (3 s while mounted — and it is only mounted inside StatsPanel, on the focused
// monitor, so exactly one instance ever runs).
//
// CPU% is a delta of two /proc/stat reads, so the FIRST read has no valid
// delta — `cpuReady` stays false and the UI shows "—" until a second read
// (~0.35 s later) lands. RAM needs no delta: used = MemTotal - MemAvailable,
// valid from the first read.
import QtQuick
import Quickshell.Io
import "root:/"

Row {
    id: root
    spacing: Theme.spacing

    // -1 / not-ready sentinels so the UI never shows a fake "0%"
    property int  cpuPercent: 0
    property bool cpuReady: false
    property real memUsedKib: 0
    property real memTotalKib: 0
    readonly property int memPercent:
        memTotalKib > 0 ? Math.round(memUsedKib / memTotalKib * 100) : 0
    readonly property bool memReady: memTotalKib > 0

    property real _prevIdle: -1
    property real _prevTotal: -1

    function sampleCpu() {
        const line = (statFile.text() || "").split("\n")[0];
        const f = line.trim().split(/\s+/).slice(1).map(Number);
        if (f.length < 4) return;
        const idle = f[3] + (f[4] || 0);
        const total = f.reduce((a, b) => a + b, 0);
        if (root._prevTotal >= 0) {
            const dI = idle - root._prevIdle, dT = total - root._prevTotal;
            if (dT > 0) {
                root.cpuPercent = Math.max(0, Math.min(100,
                    Math.round((1 - dI / dT) * 100)));
                root.cpuReady = true;
            }
        }
        root._prevIdle = idle; root._prevTotal = total;
    }
    function sampleMem() {
        const lines = (memFile.text() || "").split("\n");
        let total = 0, avail = 0;
        for (const l of lines) {
            if (l.startsWith("MemTotal:")) total = parseInt(l.split(/\s+/)[1], 10);
            else if (l.startsWith("MemAvailable:")) avail = parseInt(l.split(/\s+/)[1], 10);
        }
        if (total > 0) {
            root.memTotalKib = total;
            root.memUsedKib = Math.max(0, total - avail);
        }
    }

    FileView { id: statFile; path: "/proc/stat";    onLoaded: root.sampleCpu() }
    FileView { id: memFile;  path: "/proc/meminfo"; onLoaded: root.sampleMem() }

    // read once right now (RAM is instantly valid); a quick second /proc/stat
    // read makes CPU% real within ~0.35 s instead of waiting a full 3 s tick.
    Component.onCompleted: { statFile.reload(); memFile.reload(); }
    Timer { interval: 350;  running: true; repeat: false; onTriggered: statFile.reload() }
    Timer { interval: 3000; running: true; repeat: true
            onTriggered: { statFile.reload(); memFile.reload(); } }

    // compact bar rendering (unused now — CPU/MEM live in StatsPanel — kept so
    // the module still stands alone if ever placed back in the navbar)
    component Stat: Row {
        spacing: Theme.gap
        property string glyph
        property string value
        Text {
            font.family: Theme.iconFamily; font.pixelSize: Theme.iconSize
            color: Theme.foregroundMuted; text: glyph
        }
        Text {
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeSmall
            color: Theme.foreground
            text: parent.value
        }
    }

    Stat { glyph: Theme.icon.cpu; value: root.cpuReady ? root.cpuPercent + "%" : "—" }
    Stat { glyph: Theme.icon.mem; value: root.memReady ? root.memPercent + "%" : "—" }
}

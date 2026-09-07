// modules/SystemStats.qml — compact CPU / RAM. Reads /proc via FileView on a
// 3 s Timer (the one genuinely-polling module — Quickshell has no /proc type).
import QtQuick
import Quickshell.Io
import "root:/"

Row {
    id: root
    spacing: Theme.spacing

    property int cpuPercent: 0
    property int memPercent: 0
    property real _prevIdle: -1
    property real _prevTotal: -1

    function sampleCpu() {
        const line = statFile.text().split("\n")[0];
        const f = line.trim().split(/\s+/).slice(1).map(Number);
        if (f.length < 4) return;
        const idle = f[3] + (f[4] || 0);
        const total = f.reduce((a, b) => a + b, 0);
        if (root._prevTotal >= 0) {
            const dI = idle - root._prevIdle, dT = total - root._prevTotal;
            if (dT > 0) root.cpuPercent = Math.round((1 - dI / dT) * 100);
        }
        root._prevIdle = idle; root._prevTotal = total;
    }
    function sampleMem() {
        const lines = memFile.text().split("\n");
        let total = 0, avail = 0;
        for (const l of lines) {
            if (l.startsWith("MemTotal:")) total = parseInt(l.split(/\s+/)[1], 10);
            else if (l.startsWith("MemAvailable:")) avail = parseInt(l.split(/\s+/)[1], 10);
        }
        if (total > 0) root.memPercent = Math.round((1 - avail / total) * 100);
    }

    FileView { id: statFile; path: "/proc/stat"; onLoaded: root.sampleCpu() }
    FileView { id: memFile;  path: "/proc/meminfo"; onLoaded: root.sampleMem() }
    Timer { interval: 3000; running: true; repeat: true; onTriggered: { statFile.reload(); memFile.reload(); } }

    component Stat: Row {
        spacing: Theme.gap
        property string glyph
        property int value
        Text {
            font.family: Theme.iconFamily; font.pixelSize: Theme.iconSize
            color: Theme.foregroundMuted; text: glyph
        }
        Text {
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeSmall
            color: value >= 85 ? Theme.accent : Theme.foreground
            text: value + "%"
        }
    }

    Stat { glyph: Theme.icon.cpu; value: root.cpuPercent }
    Stat { glyph: Theme.icon.mem; value: root.memPercent }
}

// modules/SystemStats.qml — CPU and RAM usage.
//
// No /proc polling API exists in Quickshell, so this reads /proc/stat and
// /proc/meminfo via FileView and re-reads them on a moderate Timer (3s) — the
// one module in this bar that genuinely polls, as instructed. CPU% comes from
// the delta between two samples of the aggregate "cpu" line; RAM% is
// MemTotal/MemAvailable, which needs no delta.
// https://quickshell.org/docs/v0.3.0/types/Quickshell.Io/FileView/

import QtQuick
import Quickshell.Io

Row {
    id: root
    spacing: 10

    property int cpuPercent: 0
    property int memPercent: 0
    property real _prevIdle: -1
    property real _prevTotal: -1

    function sampleCpu() {
        const line = statFile.text().split("\n")[0]; // "cpu  user nice system idle iowait irq softirq ..."
        const fields = line.trim().split(/\s+/).slice(1).map(Number);
        if (fields.length < 4) return;
        const idle = fields[3] + (fields[4] || 0);
        const total = fields.reduce((a, b) => a + b, 0);
        if (root._prevTotal >= 0) {
            const dIdle = idle - root._prevIdle;
            const dTotal = total - root._prevTotal;
            if (dTotal > 0) root.cpuPercent = Math.round((1 - dIdle / dTotal) * 100);
        }
        root._prevIdle = idle;
        root._prevTotal = total;
    }

    function sampleMem() {
        const lines = memFile.text().split("\n");
        let total = 0, avail = 0;
        for (let i = 0; i < lines.length; i++) {
            if (lines[i].startsWith("MemTotal:")) total = parseInt(lines[i].split(/\s+/)[1], 10);
            else if (lines[i].startsWith("MemAvailable:")) avail = parseInt(lines[i].split(/\s+/)[1], 10);
        }
        if (total > 0) root.memPercent = Math.round((1 - avail / total) * 100);
    }

    FileView {
        id: statFile
        path: "/proc/stat"
        onLoaded: root.sampleCpu()
    }

    FileView {
        id: memFile
        path: "/proc/meminfo"
        onLoaded: root.sampleMem()
    }

    Timer {
        interval: 3000
        running: true
        repeat: true
        onTriggered: {
            statFile.reload();
            memFile.reload();
        }
    }

    Text {
        font.pixelSize: 12
        color: "#c0caf5"
        text: "CPU " + root.cpuPercent + "%"
    }
    Text {
        font.pixelSize: 12
        color: "#c0caf5"
        text: "MEM " + root.memPercent + "%"
    }
}

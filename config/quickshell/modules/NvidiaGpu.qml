// modules/NvidiaGpu.qml — frontend for bin/nvidia-compute-mode. UNCHANGED
// backend: every fact and every state change still goes through that CLI's
// `status --json` / `eco` / `compute` (and, only on explicit user confirm,
// `status --json --deep`). This file only shells out, parses JSON, and renders
// — now in the Theme palette, as a compact bar pill + a popup.
//
// Energy rule (docs/HYBRID-GPU.md): while Policy=ECO the auto-refresh timer
// NEVER passes --deep, even when Runtime is "active".
import QtQuick
import Quickshell
import Quickshell.Io
import "root:/"

Item {
    id: root

    property var bar: null

    implicitWidth: pill.implicitWidth
    implicitHeight: pill.implicitHeight
    visible: present

    // ---- backend-reported state (nothing computed independently) --------
    property bool present: false
    property string policy: "eco"
    property string backend: "auto"
    property bool backendActive: false
    property string runtimePm: "unknown"
    property string pciPower: "unknown"
    property bool d3coldConfirmed: false
    property string driver: ""
    property string moduleVersion: ""
    property int clientsDetected: 0
    property var clients: []
    property var deep: null

    property bool busy: false
    property string lastError: ""
    property bool confirmingDeep: false
    property string _lastActionOutput: ""

    readonly property bool backendUnresolved: backend === "auto" || backend === "none"
    readonly property bool activeUnderEco: policy === "eco" && runtimePm === "active"

    readonly property color dotColor:
          !present                       ? Theme.foregroundMuted
        : policy === "compute"           ? Theme.accent
        : runtimePm === "suspended"      ? Theme.positive
        : activeUnderEco                 ? Theme.accent
        : Theme.foregroundMuted

    function refresh(deep) {
        if (statusProc.running) return;
        const extra = deep ? " --deep" : "";
        statusProc.exec(["sh", "-c",
            "command -v nvidia-compute-mode >/dev/null 2>&1 && " +
            "nvidia-compute-mode status --json" + extra +
            " || echo '{\"present\":false}'"]);
    }
    function _applyStatus(text) {
        let j;
        try { j = JSON.parse(text); } catch (e) { root.present = false; return; }
        root.policy = j.policy || "eco";
        root.backend = j.backend || "auto";
        root.backendActive = !!j.backend_active;
        root.present = !!j.present;
        if (!root.present) { root.deep = null; return; }
        root.runtimePm = j.runtime_pm_state || "unknown";
        root.pciPower = j.pci_power_state || "unknown";
        root.d3coldConfirmed = !!j.d3cold_confirmed;
        root.driver = j.driver || "";
        root.moduleVersion = j.module_version || "";
        root.clientsDetected = j.clients_detected || 0;
        root.clients = j.clients || [];
        root.deep = (j.deep && typeof j.deep === "object" && !j.deep.error) ? j.deep : null;
    }

    Process {
        id: statusProc
        stdout: StdioCollector { onStreamFinished: root._applyStatus(this.text) }
    }
    Process {
        id: actionProc
        stdout: StdioCollector { onStreamFinished: root._lastActionOutput = this.text }
        onRunningChanged: {
            if (running) return;
            root.busy = false;
            const m = root._lastActionOutput.match(/QS_EXIT:(-?\d+)\s*$/);
            const code = m ? parseInt(m[1], 10) : -1;
            root.lastError = (code === 0) ? ""
                : (root._lastActionOutput.replace(/QS_EXIT:-?\d+\s*$/, "").trim() || ("exit " + code));
            root.refresh(root.policy === "compute");
        }
    }
    function _runAction(action) {
        if (root.busy) return;
        root.busy = true; root.confirmingDeep = false; root._lastActionOutput = "";
        actionProc.exec(["sh", "-c",
            "command -v nvidia-compute-mode >/dev/null 2>&1 && nvidia-compute-mode " +
            action + " 2>&1; echo QS_EXIT:$?"]);
    }
    function setEco() { _runAction("eco"); }
    function setCompute() { _runAction("compute"); }
    function requestDeepMetrics() {
        if (root.policy === "compute") { root.refresh(true); return; }
        if (!root.confirmingDeep) { root.confirmingDeep = true; return; }
        root.confirmingDeep = false;
        root.refresh(true);
    }

    Component.onCompleted: root.refresh(false)
    Timer {
        interval: root.policy === "compute" ? 3000 : 4500
        running: root.present; repeat: true
        onTriggered: root.refresh(root.policy === "compute")
    }

    // ---- compact pill ------------------------------------------------
    MouseArea {
        id: pill
        implicitWidth: pillRow.implicitWidth
        implicitHeight: pillRow.implicitHeight
        cursorShape: Qt.PointingHandCursor
        onClicked: popup.visible = !popup.visible

        Row {
            id: pillRow
            spacing: Theme.gap
            Text {
                font.family: Theme.iconFamily; font.pixelSize: Theme.iconSize
                color: root.activeUnderEco ? Theme.accent : Theme.foregroundMuted
                text: Theme.icon.gpu
            }
            Rectangle {
                width: 6; height: 6; radius: 3
                y: 4
                color: root.dotColor
            }
        }
    }

    // ---- detail popup ----------------------------------------------
    PopupWindow {
        id: popup
        anchor.window: root.bar
        anchor.rect.x: root.bar ? root.bar.width - width - Theme.spacing : 0
        anchor.rect.y: root.bar ? root.bar.height + 6 : 0
        implicitWidth: 300
        implicitHeight: content.implicitHeight + 24
        visible: false
        color: "transparent"

        Rectangle {
            anchors.fill: parent
            color: Theme.panelBg
            radius: Theme.radiusMedium
            border.width: 1
            border.color: Theme.withAlpha(Theme.border, 0.7)

            Column {
                id: content
                x: 14; y: 12
                width: parent.width - 28
                spacing: Theme.spacingSmall

                Row {
                    spacing: Theme.spacingSmall
                    Text { font.family: Theme.iconFamily; font.pixelSize: Theme.iconSizeLarge
                           color: Theme.accent; text: Theme.icon.gpu }
                    Text { font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeLarge; font.bold: true
                           color: Theme.foreground; text: "NVIDIA" }
                }

                Text { color: Theme.foreground; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize
                       text: "Policy: " + root.policy.toUpperCase()
                             + (root.backendUnresolved ? "  (backend unresolved)" : "") }
                Text { color: Theme.foregroundMuted; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeSmall
                       text: "Runtime: " + root.runtimePm + "   ·   PCI: " + root.pciPower
                             + (root.d3coldConfirmed ? " (confirmed)" : "") }
                Text { visible: root.driver.length > 0
                       color: Theme.foregroundMuted; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeSmall
                       text: "driver " + root.driver + (root.moduleVersion ? ("  ·  " + root.moduleVersion) : "") }

                Rectangle { width: parent.width; height: 1; color: Theme.withAlpha(Theme.border, 0.5)
                            visible: root.clientsDetected > 0 }
                Text { visible: root.clientsDetected > 0
                       color: Theme.foreground; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeSmall
                       text: "Detected NVIDIA clients (best-effort):" }
                Repeater {
                    model: root.clients
                    Text {
                        required property var modelData
                        color: Theme.foregroundMuted; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeSmall
                        text: "  - " + modelData.comm + " (pid " + modelData.pid + ")"
                    }
                }

                Rectangle { width: parent.width; height: 1; color: Theme.withAlpha(Theme.border, 0.5)
                            visible: root.deep !== null }
                Text { visible: root.deep !== null; color: Theme.foreground
                       font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeSmall
                       text: root.deep ? ("Temp " + root.deep.temp_c + "°C   ·   VRAM " + root.deep.mem_used_mib
                                          + "/" + root.deep.mem_total_mib + " MiB   ·   " + root.deep.util_pct + "%") : "" }

                Text { visible: root.lastError.length > 0
                       color: Theme.accent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeSmall
                       wrapMode: Text.WordWrap; width: parent.width; text: root.lastError }
                Text { visible: root.confirmingDeep
                       color: Theme.accent; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeSmall
                       wrapMode: Text.WordWrap; width: parent.width
                       text: "This check may wake or keep the NVIDIA GPU active." }

                Row {
                    spacing: Theme.spacing
                    topPadding: 4
                    PillButton {
                        visible: root.policy === "eco"
                        label: root.confirmingDeep ? "Confirm" : "Details"
                        onClicked: root.requestDeepMetrics()
                    }
                    PillButton {
                        enabled: !root.busy
                        label: root.policy === "eco" ? "Start Compute" : "Return to Eco"
                        onClicked: root.policy === "eco" ? root.setCompute() : root.setEco()
                    }
                }
            }
        }
    }

    component PillButton: Rectangle {
        id: btn
        property string label
        signal clicked()
        implicitWidth: t.implicitWidth + 20
        implicitHeight: 24
        radius: Theme.radiusSmall
        color: ma.containsMouse ? Theme.surfaceHover : Theme.surface
        opacity: enabled ? 1 : 0.45
        Text {
            id: t; anchors.centerIn: parent
            font.family: Theme.fontFamily; font.pixelSize: Theme.fontSizeSmall
            color: Theme.foreground; text: btn.label
        }
        MouseArea {
            id: ma; anchors.fill: parent; hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            enabled: btn.enabled
            onClicked: btn.clicked()
        }
    }
}

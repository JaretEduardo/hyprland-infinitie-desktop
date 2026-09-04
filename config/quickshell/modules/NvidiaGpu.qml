// modules/NvidiaGpu.qml — frontend for bin/nvidia-compute-mode. No NVIDIA logic
// lives here: every fact and every state change goes through that backend's
// `status --json` / `eco` / `compute` (and, only on explicit user confirmation,
// `status --json --deep`). This file only shells out, parses JSON, and renders.
//
// Energy rule (see docs/HYBRID-GPU.md): while Policy=ECO, the automatic refresh
// timer NEVER passes --deep, even when Runtime is "active". --deep only runs
// (a) automatically while Policy=COMPUTE, where keeping the GPU awake is
// intentional, or (b) once, after the user explicitly confirms the
// "may wake the GPU" warning via "Show detailed metrics".
//
// Two separate concepts are kept visually separate, per the backend's own
// design: Policy (eco|compute, requested) vs. observed Runtime PM state
// (active|suspended|...) vs. PCI power state (D0|D3hot|D3cold|unknown).
// "ACTIVE" is never treated as a policy — it only ever comes from runtimePm.

import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: root

    // The Bar's PanelWindow, so the popup can anchor under it.
    property var panelWindow: null

    implicitWidth: pill.implicitWidth
    implicitHeight: pill.implicitHeight
    visible: present

    // ---- backend-reported state (nothing here is computed independently) ----
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
    property var clients: []            // [{pid, comm}, ...]
    property var deep: null             // {name, temp_c, util_pct, ...} or null

    property bool busy: false
    property string lastError: ""
    property bool confirmingDeep: false
    property string _lastActionOutput: ""

    readonly property bool backendUnresolved: backend === "auto" || backend === "none"

    readonly property string compactLabel: {
        if (!present) return "";
        // ECO + already active is the one case worth flagging in the compact
        // pill (something is keeping the GPU awake right now); COMPUTE+active
        // is simply COMPUTE working as intended, so it stays labelled COMPUTE.
        if (policy === "eco" && runtimePm === "active") return "NVIDIA · ACTIVE";
        return "NVIDIA · " + policy.toUpperCase();
    }

    // ------------------------------------------------------------------
    // status query. Always goes through the backend; never reads sysfs or
    // runs nvidia-smi directly. `deep` must only be true from the COMPUTE
    // timer or an explicit confirmed user action — see call sites below.
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
        try {
            j = JSON.parse(text);
        } catch (e) {
            // backend missing / produced garbage — degrade cleanly, no crash.
            root.present = false;
            return;
        }
        root.policy = j.policy || "eco";
        root.backend = j.backend || "auto";
        root.backendActive = !!j.backend_active;
        root.present = !!j.present;
        if (!root.present) {
            root.deep = null;
            return;
        }
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
        stdout: StdioCollector {
            onStreamFinished: root._applyStatus(this.text)
        }
    }

    // ---- policy actions -------------------------------------------------
    // Never writes power/control or calls sudo itself — that boundary lives
    // entirely in bin/nvidia-compute-mode. A failed transition (e.g. missing
    // privilege, unresolved backend) is surfaced, never hidden as success.
    Process {
        id: actionProc
        stdout: StdioCollector {
            onStreamFinished: root._lastActionOutput = this.text
        }
        onRunningChanged: {
            if (running) return;
            root.busy = false;
            const m = root._lastActionOutput.match(/QS_EXIT:(-?\d+)\s*$/);
            const code = m ? parseInt(m[1], 10) : -1;
            root.lastError = (code === 0) ? ""
                : (root._lastActionOutput.replace(/QS_EXIT:-?\d+\s*$/, "").trim() || ("exit " + code));
            // Always re-query the real state afterward instead of assuming success.
            root.refresh(root.policy === "compute");
        }
    }

    function _runAction(action) {
        if (root.busy) return;
        root.busy = true;
        root.confirmingDeep = false;
        root._lastActionOutput = "";
        actionProc.exec(["sh", "-c",
            "command -v nvidia-compute-mode >/dev/null 2>&1 && nvidia-compute-mode " +
            action + " 2>&1; echo QS_EXIT:$?"]);
    }
    function setEco() { _runAction("eco"); }
    function setCompute() { _runAction("compute"); }

    // ---- explicit, confirmed deep metrics (ECO only; COMPUTE polls automatically) ----
    function requestDeepMetrics() {
        if (root.policy === "compute") { root.refresh(true); return; }
        if (!root.confirmingDeep) { root.confirmingDeep = true; return; }
        root.confirmingDeep = false;
        root.refresh(true); // the one explicit, user-confirmed deep probe
    }

    Component.onCompleted: root.refresh(false) // first call is always non-deep

    // ECO: 4.5s, status only. COMPUTE: 3s, deep allowed (GPU meant to stay awake).
    Timer {
        interval: root.policy === "compute" ? 3000 : 4500
        running: root.present
        repeat: true
        onTriggered: root.refresh(root.policy === "compute")
    }

    // ---- compact bar pill -------------------------------------------------
    Rectangle {
        id: pill
        implicitWidth: label.implicitWidth + 16
        implicitHeight: 20
        radius: 5
        color: popup.visible ? "#2a2e3f" : "transparent"
        anchors.verticalCenter: parent.verticalCenter

        Text {
            id: label
            anchors.centerIn: parent
            font.pixelSize: 12
            color: root.policy === "eco" && root.runtimePm === "active" ? "#e0af68" : "#c0caf5"
            text: root.compactLabel
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: popup.visible = !popup.visible
        }
    }

    // ---- detail popup -------------------------------------------------
    PopupWindow {
        id: popup
        anchor.window: root.panelWindow
        anchor.rect.x: root.panelWindow ? root.panelWindow.width - width - 10 : 0
        anchor.rect.y: root.panelWindow ? root.panelWindow.height : 0
        implicitWidth: 300
        implicitHeight: content.implicitHeight + 20
        visible: false
        color: "#1a1b26"

        Column {
            id: content
            x: 10
            y: 10
            width: parent.width - 20
            spacing: 6

            Text { font.pixelSize: 13; font.bold: true; color: "#c0caf5"; text: "NVIDIA" }

            Text { color: "#c0caf5"; font.pixelSize: 12; text: "Policy: " + root.policy.toUpperCase() }
            Text {
                color: "#c0caf5"; font.pixelSize: 12
                text: "Backend: " + root.backend + (root.backendUnresolved ? "  (unresolved)" : "")
            }
            Text {
                visible: root.backendUnresolved
                color: "#e0af68"; font.pixelSize: 11; wrapMode: Text.WordWrap; width: parent.width
                text: root.policy === "compute"
                    ? "COMPUTE is recorded, but no keep-awake mechanism is active yet — the GPU will still follow RTD3."
                    : "No keep-awake mechanism is configured. Resolve a real backend on Gentoo first-run before relying on COMPUTE."
            }

            Rectangle { width: parent.width; height: 1; color: "#2a2e3f" }

            Text { color: "#c0caf5"; font.pixelSize: 12; text: "Runtime: " + root.runtimePm }
            Text {
                color: "#c0caf5"; font.pixelSize: 12
                text: "PCI power: " + root.pciPower + (root.d3coldConfirmed ? "  (confirmed)" : "")
            }
            Text {
                visible: root.driver.length > 0
                color: "#8a92b2"; font.pixelSize: 11
                text: "driver " + root.driver + (root.moduleVersion ? ("  ·  " + root.moduleVersion) : "")
            }

            Rectangle { width: parent.width; height: 1; color: "#2a2e3f"; visible: root.clientsDetected > 0 }

            Text {
                visible: root.clientsDetected > 0
                color: "#c0caf5"; font.pixelSize: 12
                text: "Detected NVIDIA clients (best-effort):"
            }
            Repeater {
                model: root.clients
                Text {
                    required property var modelData
                    color: "#8a92b2"; font.pixelSize: 11
                    text: "  - " + modelData.comm + " (pid " + modelData.pid + ")"
                }
            }

            Rectangle { width: parent.width; height: 1; color: "#2a2e3f"; visible: root.deep !== null }

            Text { visible: root.deep !== null; color: "#c0caf5"; font.pixelSize: 12
                   text: root.deep ? ("Temperature: " + root.deep.temp_c + " C") : "" }
            Text { visible: root.deep !== null; color: "#c0caf5"; font.pixelSize: 12
                   text: root.deep ? ("VRAM: " + root.deep.mem_used_mib + " / " + root.deep.mem_total_mib + " MiB") : "" }
            Text { visible: root.deep !== null; color: "#c0caf5"; font.pixelSize: 12
                   text: root.deep ? ("Utilization: " + root.deep.util_pct + "%") : "" }
            Text { visible: root.deep !== null; color: "#c0caf5"; font.pixelSize: 12
                   text: root.deep ? ("Clocks: " + root.deep.clock_sm_mhz + " MHz") : "" }

            Text {
                visible: root.lastError.length > 0
                color: "#f7768e"; font.pixelSize: 11; wrapMode: Text.WordWrap; width: parent.width
                text: root.lastError
            }

            Text {
                visible: root.confirmingDeep
                color: "#e0af68"; font.pixelSize: 11; wrapMode: Text.WordWrap; width: parent.width
                text: "This check may wake or keep the NVIDIA GPU active."
            }

            Row {
                spacing: 8
                Text {
                    visible: root.policy === "eco" && !root.busy
                    color: "#7aa2f7"; font.pixelSize: 12
                    text: root.confirmingDeep ? "Confirm" : "Show detailed metrics"
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.requestDeepMetrics() }
                }
            }

            Row {
                spacing: 10
                Text {
                    visible: root.policy === "eco"
                    color: root.busy ? "#565f89" : "#7aa2f7"; font.pixelSize: 12
                    text: "Start Compute Session"
                    MouseArea { anchors.fill: parent; enabled: !root.busy; cursorShape: Qt.PointingHandCursor; onClicked: root.setCompute() }
                }
                Text {
                    visible: root.policy === "compute"
                    color: root.busy ? "#565f89" : "#7aa2f7"; font.pixelSize: 12
                    text: "Return to Eco"
                    MouseArea { anchors.fill: parent; enabled: !root.busy; cursorShape: Qt.PointingHandCursor; onClicked: root.setEco() }
                }
            }
        }
    }
}

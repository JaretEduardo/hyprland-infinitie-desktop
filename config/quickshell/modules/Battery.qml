// modules/Battery.qml — battery percentage + charge state.
// Reactive over UPower's D-Bus signals (property bindings), no polling.
// Cleanly hides on a desktop with no battery (isLaptopBattery false).
// https://quickshell.org/docs/v0.3.0/types/Quickshell.Services.UPower/UPower/

import QtQuick
import Quickshell.Services.UPower

Text {
    id: root
    readonly property var device: UPower.displayDevice

    visible: device.ready && device.isLaptopBattery
    font.pixelSize: 12
    color: {
        const low = device.percentage <= 0.15 && device.state !== UPowerDeviceState.Charging;
        return low ? "#f7768e" : "#c0caf5";
    }

    text: {
        const pct = Math.round(device.percentage * 100);
        const charging = device.state === UPowerDeviceState.Charging
                       || device.state === UPowerDeviceState.PendingCharge;
        return (charging ? "CHG " : "BAT ") + pct + "%";
    }
}

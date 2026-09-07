// modules/Battery.qml — icon + %, reactive over UPower. Hides on a desktop.
import QtQuick
import Quickshell.Services.UPower
import "root:/"

Row {
    id: root
    spacing: Theme.gap

    readonly property var device: UPower.displayDevice
    readonly property int pct: device.ready ? Math.round(device.percentage * 100) : 0
    readonly property bool charging: device.state === UPowerDeviceState.Charging
                                  || device.state === UPowerDeviceState.PendingCharge
    readonly property bool low: pct <= 15 && !charging
    visible: device.ready && device.isLaptopBattery

    Text {
        font.family: Theme.iconFamily
        font.pixelSize: Theme.iconSize
        color: root.low ? Theme.accent : (root.charging ? Theme.positive : Theme.foreground)
        text: root.charging ? Theme.icon.batteryChg : (root.low ? Theme.icon.batteryLow : Theme.icon.battery)
    }
    Text {
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSizeSmall
        color: root.low ? Theme.accent : Theme.foregroundMuted
        text: root.pct + "%"
    }
}

// modules/Network.qml — Wi-Fi state as a single icon (SSID lives in the
// dashboard, not the bar). Reactive over Quickshell.Networking, no polling.
import QtQuick
import Quickshell.Networking
import "root:/"

Text {
    id: root

    readonly property var wifiDevice: {
        const devs = Networking.devices.values;
        for (let i = 0; i < devs.length; i++)
            if (devs[i].type === DeviceType.Wifi) return devs[i];
        return null;
    }
    readonly property var activeNetwork: {
        if (wifiDevice === null) return null;
        const nets = wifiDevice.networks.values;
        for (let i = 0; i < nets.length; i++)
            if (nets[i].connected) return nets[i];
        return null;
    }

    visible: wifiDevice !== null
    font.family: Theme.iconFamily
    font.pixelSize: Theme.iconSize
    color: activeNetwork !== null ? Theme.foreground : Theme.foregroundMuted
    text: !Networking.wifiEnabled ? Theme.icon.wifiOff
        : activeNetwork !== null  ? Theme.icon.wifi
        : Theme.icon.wifiAlert
}

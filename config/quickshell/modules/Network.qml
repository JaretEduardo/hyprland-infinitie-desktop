// modules/Network.qml — WiFi state + connected SSID.
// Reactive over NetworkManager via Quickshell.Networking, no polling.
// Requires net-misc/networkmanager (already in install/packages.gentoo).
// https://quickshell.org/docs/v0.3.0/types/Quickshell.Networking/Networking/

import QtQuick
import Quickshell.Networking

Text {
    id: root
    font.pixelSize: 12
    color: "#c0caf5"

    readonly property var wifiDevice: {
        const devices = Networking.devices.values;
        for (let i = 0; i < devices.length; i++) {
            if (devices[i].type === DeviceType.Wifi) return devices[i];
        }
        return null;
    }

    readonly property var activeNetwork: {
        if (wifiDevice === null) return null;
        const nets = wifiDevice.networks.values;
        for (let i = 0; i < nets.length; i++) {
            if (nets[i].connected) return nets[i];
        }
        return null;
    }

    // No WiFi device on this system (or Networking backend unavailable) ->
    // hide the module instead of showing a permanently broken indicator.
    visible: wifiDevice !== null

    text: {
        if (!Networking.wifiEnabled) return "WiFi off";
        if (activeNetwork !== null) return activeNetwork.name;
        return "WiFi --";
    }
}

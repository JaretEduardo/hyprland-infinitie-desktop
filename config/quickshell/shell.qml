// shell.qml — entrypoint. Wires the pieces together and owns the one piece of
// cross-component state: which contextual panel is open.
//
// Visual layer (reconstructed from the @gentoolarp rice video):
//   Wallpaper  — Quickshell-drawn background (no hyprpaper daemon); steps aside
//                for mpvpaper when the wallpaper is a video (see hypr-wallpaper)
//   Bar        — floating navbar island, centred on the top edge
//   PanelHost  — the ONE contextual-panel zone, docked under the navbar
//                (controls / stats / notifications / wallpapers)
//   Launcher   — Caelestia-style app launcher (Super tap / Super+Space)
//   WorldMap   — the Infinite Desktop minimap (navbar ring / Super+Tab)
//   Frame      — the Infinite Desktop IPC contract (unchanged)
import QtQuick
import Quickshell
import Quickshell.Io
import "root:/"
import "./services"

ShellRoot {
    id: root

    // "" | "controls" | "stats" | "notifications" | "wallpapers"
    property string panel: ""
    function setPanel(name) {
        root.panel = (root.panel === name ? "" : name);
        if (root.panel !== "") launcher.close();
    }

    // qs ipc call panel toggle controls   / open stats / close
    IpcHandler {
        target: "panel"
        function toggle(name: string): void { root.setPanel(name); }
        function open(name: string): void   { root.panel = name; }
        function close(): void              { root.panel = ""; }
    }

    // qs ipc call launcher toggle | open | close  (Super tap / Super+Space)
    IpcHandler {
        target: "launcher"
        function toggle(): void { if (!launcher.open) root.panel = ""; launcher.toggle(); }
        function open(): void   { root.panel = ""; launcher.open = true; }
        function close(): void  { launcher.close(); }
    }

    // qs ipc call worldmap toggle | open | close   (navbar ring / Super+Tab)
    IpcHandler {
        target: "worldmap"
        function toggle(): void {
            if (!worldMap.open) { root.panel = ""; launcher.close(); }
            worldMap.toggle();
        }
        function open(): void  { root.panel = ""; launcher.close(); worldMap.open = true; }
        function close(): void { worldMap.close(); }
    }

    // backward-compatible alias: the old "dashboard" target -> controls panel
    IpcHandler {
        target: "dashboard"
        function toggle(): void { root.setPanel("controls"); }
        function open(): void   { root.panel = "controls"; }
        function close(): void  { root.panel = ""; }
    }

    // Re-read the wallpaper-driven palette (config/quickshell/Theme.qml).
    // hypr-wallpaper calls this after wallust regenerates colors.json.
    IpcHandler {
        target: "theme"
        function reload(): void { Theme.reloadPalette(); }
    }

    Wallpaper {}

    Frame { id: frame }

    Bar {
        frame: frame
        panel: root.panel
        worldMapOpen: worldMap.open
        onRequestPanel: (name) => root.setPanel(name)
        onRequestWorldMap: {
            if (!worldMap.open) { root.panel = ""; launcher.close(); }
            worldMap.toggle();
        }
    }

    PanelHost {
        panel: root.panel
        onRequestClose: root.panel = ""
    }

    Launcher { id: launcher }

    WorldMap { id: worldMap }
}

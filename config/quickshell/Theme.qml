pragma Singleton
// Theme.qml — the ONE place geometry / type / glyphs live, and the ONE place
// colours are resolved.
//
// Colours are WALLPAPER-DRIVEN. `hypr-wallpaper <image>` runs wallust, which
// renders config/wallust/templates/quickshell-colors.json into
//   $XDG_CACHE_HOME/hyprland-infinitie-desktop/colors.json
// This singleton watches that file (live reload, no restart) and maps the raw
// palette onto SEMANTIC tokens. Components use the semantic tokens only —
// never a raw colour. Every token has a safe fallback baked in here, so
// Quickshell starts and looks reasonable with no generated palette at all
// (fresh install, or `hypr-wallpaper --reset`).
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: t

    // ---- generated palette (wallpaper-driven, hot-reloaded) ------------
    readonly property string _cacheHome: {
        const x = Quickshell.env("XDG_CACHE_HOME");
        return (x && x.length > 0) ? x : Quickshell.env("HOME") + "/.cache";
    }

    function reloadPalette() { paletteFile.reload(); }

    FileView {
        id: paletteFile
        path: t._cacheHome + "/hyprland-infinitie-desktop/colors.json"
        watchChanges: true
        printErrors: false           // a missing palette is normal on a fresh session
        onFileChanged: reload()

        JsonAdapter {
            id: pal
            // Raw wallust-derived slots this project consumes. The defaults are
            // the "dusty sakura" look shipped before theming — identical to
            // config/wallust/fallback/colors.json.
            property string background: "#332632"
            property string foreground: "#f1e2ec"
            property string dark:       "#241a20"
            property string surface:    "#4a3745"
            property string muted:      "#c2aab8"
            property string accent:     "#e6c4d8"
            property string accent2:    "#c9b7d6"
            property string good:       "#c3e0cc"
            property string bad:        "#e6a6b0"
            property string line:       "#5a4657"
        }
    }

    // ---- semantic colour tokens --------------------------------------
    // Panels stay dark + translucent whatever the wallpaper: background /
    // surface come from the wallust dark tones, foreground from its light
    // tone, accent from a dominant vibrant colour.
    readonly property color background:      pal.background
    readonly property color surface:         pal.surface
    readonly property color surfaceElevated: pal.dark
    readonly property color surfaceHover:    Qt.lighter(pal.surface, 1.22)
    readonly property color foreground:      pal.foreground
    readonly property color foregroundMuted: pal.muted
    readonly property color accent:          pal.accent
    readonly property color accentSoft:      Qt.lighter(pal.accent, 1.18)
    readonly property color accentDim:       Qt.darker(pal.accent, 1.35)
    readonly property color accentSecondary: pal.accent2
    readonly property color positive:        pal.good
    readonly property color urgent:          pal.bad
    readonly property color border:          pal.line
    readonly property color scrim:           Qt.darker(pal.dark, 1.35)

    readonly property real  barOpacity:    0.72
    readonly property real  panelOpacity:  0.86
    readonly property real  cardOpacity:   0.92

    function withAlpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a); }
    readonly property color barBg:   withAlpha(background, barOpacity)
    readonly property color panelBg: withAlpha(background, panelOpacity)
    readonly property color cardBg:  withAlpha(surfaceElevated, cardOpacity)

    // ---- geometry ---------------------------------------------------
    readonly property int barHeight:    30
    readonly property int radiusSmall:  6
    readonly property int radiusMedium: 9
    readonly property int radiusLarge:  13
    readonly property int spacing:      10
    readonly property int spacingSmall: 6
    readonly property int gap:          4

    // navbar = a floating island, NOT an edge-to-edge bar (see Bar.qml).
    // Centred on the monitor, small, rounded. Contextual panels (PanelHost.qml)
    // dock just below it — panelTopY is measured from the screen's top edge.
    readonly property int  navHeight:     28
    readonly property int  navMaxWidth:   920
    readonly property real navWidthRatio: 0.48
    readonly property int  navTopMargin:  6
    readonly property int  panelGap:      8
    readonly property int  panelTopY:     navTopMargin + navHeight + panelGap

    // Launcher (Launcher.qml) — a centred floating overlay, NOT docked to the
    // navbar. Super (tap) or Super+Space opens it.
    readonly property int  launcherWidth:      560
    readonly property int  launcherMaxHeight:  520
    readonly property int  launcherRowHeight:  46

    // Wallpaper transitions (Wallpaper.qml). One place to tune the feel.
    //   wallpaperTransitionDuration — static->static DIAGONAL WIPE (ms): a 45°
    //                                 boundary sweeping top-right -> bottom-left
    //   wallpaperAnimatedGrace      — how long the last still is held while
    //                                 mpvpaper spins up on static->animated
    // (Theme *colours* update instantly when wallust rewrites colors.json —
    // there is no palette tween; the wallpaper wipe is what smooths the change.)
    readonly property int  wallpaperTransitionDuration: 800
    readonly property int  wallpaperAnimatedGrace:      1100

    // ---- type -----------------------------------------------------
    readonly property string fontFamily: "Fira Sans, sans-serif"
    readonly property string iconFamily: "Symbols Nerd Font, sans-serif"
    readonly property int    fontSize:      12
    readonly property int    fontSizeSmall: 11
    readonly property int    fontSizeLarge: 14
    readonly property int    iconSize:      12
    readonly property int    iconSizeLarge: 16

    // ---- glyphs (Nerd Font codepoints; wrong one? fix it HERE only) ----
    readonly property QtObject icon: QtObject {
        readonly property string dashboard:  "\u{f0765}"
        readonly property string close:      "\u{f0156}"
        readonly property string wifi:       "\u{f05a9}"
        readonly property string wifiOff:    "\u{f05aa}"
        readonly property string wifiAlert:  "\u{f092b}"
        readonly property string volHigh:    "\u{f057e}"
        readonly property string volMed:     "\u{f0580}"
        readonly property string volLow:     "\u{f057f}"
        readonly property string volMute:    "\u{f0581}"
        readonly property string micOff:     "\u{f036d}"
        readonly property string battery:    "\u{f0079}"
        readonly property string batteryChg: "\u{f0084}"
        readonly property string batteryLow: "\u{f0083}"
        readonly property string brightness: "\u{f00e0}"
        readonly property string clock:      "\u{f0954}"
        readonly property string cpu:        "\u{f0ee0}"
        readonly property string mem:        "\u{f035b}"
        readonly property string gpu:        "\u{f08ae}"
        readonly property string music:      "\u{f0387}"
        readonly property string prev:       "\u{f04ae}"
        readonly property string play:       "\u{f040a}"
        readonly property string pause:      "\u{f03e4}"
        readonly property string next:       "\u{f04ad}"
        readonly property string dnd:        "\u{f009b}"   // bell-off
        readonly property string wallpaper:  "\u{f021f}"   // image-multiple
        readonly property string image:      "\u{f02e9}"
        readonly property string video:      "\u{f0567}"
        readonly property string search:     "\u{f0349}"   // magnify
        readonly property string apps:       "\u{f003b}"
        readonly property string check:      "\u{f012c}"
    }
}

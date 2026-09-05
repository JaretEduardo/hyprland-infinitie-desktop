// modules/Clock.qml — date/time.
// SystemClock updates itself at the given precision; no manual Timer needed.
// Minute precision is enough for a bar clock and keeps this idle between ticks.
// https://quickshell.org/docs/v0.3.0/types/Quickshell/SystemClock/

import QtQuick
import Quickshell

Text {
    id: root
    font.pixelSize: 12
    color: "#c0caf5"

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    text: Qt.formatDateTime(clock.date, "ddd d MMM  hh:mm")
}

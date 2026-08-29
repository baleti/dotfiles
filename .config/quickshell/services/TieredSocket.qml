import QtQuick
import Quickshell
import Quickshell.Io

// Reconnects with a new "<metric>:<tier>\n" request whenever `tier`
// changes -- sysmond's protocol is request-once-then-stream (see
// sysmon/src/lib.rs's Request), so switching which of the 6 fixed
// granularities (10m/30m/6h/7d/7w/7mo) a panel is viewing means closing
// this connection and opening a fresh one, not sending a second request
// on the same stream.
Item {
    id: root

    required property string metricName
    property string tier: "10m"
    property var data: ({})

    function socketPath(): string {
        return `${Quickshell.env("XDG_RUNTIME_DIR")}/sysmond.sock`;
    }

    onTierChanged: {
        sock.connected = false;
        sock.connected = true;
    }

    Socket {
        id: sock
        path: root.socketPath()
        connected: true
        onConnectedChanged: if (connected) write(root.metricName + ":" + root.tier + "\n")
        parser: SplitParser {
            splitMarker: "\n"
            onRead: data => { root.data = JSON.parse(data); }
        }
    }

    // sysmond isn't meant to restart under a running session, but it does
    // during development and on package upgrades -- without this the bar's
    // graphs just silently freeze on the last frame until qs is reloaded,
    // because `connected: true` is a constant binding that never re-fires.
    Timer {
        interval: 2000
        repeat: true
        running: !sock.connected
        onTriggered: sock.connected = true
    }
}

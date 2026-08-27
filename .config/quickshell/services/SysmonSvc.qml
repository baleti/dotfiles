pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Client for ~/.config/hypr/sysmon's sysmond daemon (Unix socket at
// $XDG_RUNTIME_DIR/sysmond.sock) -- reuses its existing continuous
// background sampler/ring-buffer instead of re-implementing one here.
// Protocol: write "<metric>\n" once, then read one JSON snapshot line per
// second for as long as the socket stays open (see sysmon/src/lib.rs).
QtObject {
    id: root

    // Every non-loopback interface sysmond has seen, each with its own
    // rx_bps/tx_bps history -- e.g. [{name: "wlan0", rx_bps: [...], tx_bps:
    // [...]}, {name: "wg-wsl", ...}]. Bar.qml/GraphPill assign each a color.
    property var netInterfaces: []

    property list<real> cpuTotal: []
    // One history array per logical CPU, index = core number.
    property var cpuCores: []

    property list<real> tempC: []

    property list<real> memUsedPct: []
    property list<real> memCachedPct: []

    // [{pid, name, value}], value = %CPU of one core, or MB resident.
    property var topCpu: []
    property var topMem: []
    // value = combined sent+received KB over the last ~1s (nethogs trace
    // mode, sysmond's own subprocess -- see sysmond.rs's nethogs_loop).
    property var topNet: []

    // Whole-disk block devices, same shape as netInterfaces.
    property var diskDevices: []

    function socketPath(): string {
        return `${Quickshell.env("XDG_RUNTIME_DIR")}/sysmond.sock`;
    }

    readonly property Socket netSocket: Socket {
        path: root.socketPath()
        connected: true
        onConnectedChanged: if (connected) write("net\n")
        parser: SplitParser {
            splitMarker: "\n"
            onRead: data => { root.netInterfaces = JSON.parse(data).interfaces; }
        }
    }

    readonly property Socket cpuSocket: Socket {
        path: root.socketPath()
        connected: true
        onConnectedChanged: if (connected) write("cpu\n")
        parser: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                const snap = JSON.parse(data);
                root.cpuTotal = snap.total;
                root.cpuCores = snap.cores;
            }
        }
    }

    readonly property Socket tempSocket: Socket {
        path: root.socketPath()
        connected: true
        onConnectedChanged: if (connected) write("temp\n")
        parser: SplitParser {
            splitMarker: "\n"
            onRead: data => { root.tempC = JSON.parse(data).celsius; }
        }
    }

    readonly property Socket memSocket: Socket {
        path: root.socketPath()
        connected: true
        onConnectedChanged: if (connected) write("mem\n")
        parser: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                const snap = JSON.parse(data);
                root.memUsedPct = snap.used_pct;
                root.memCachedPct = snap.cached_pct;
            }
        }
    }

    readonly property Socket topCpuSocket: Socket {
        path: root.socketPath()
        connected: true
        onConnectedChanged: if (connected) write("topcpu\n")
        parser: SplitParser {
            splitMarker: "\n"
            onRead: data => { root.topCpu = JSON.parse(data).procs; }
        }
    }

    readonly property Socket diskSocket: Socket {
        path: root.socketPath()
        connected: true
        onConnectedChanged: if (connected) write("disk\n")
        parser: SplitParser {
            splitMarker: "\n"
            onRead: data => { root.diskDevices = JSON.parse(data).devices; }
        }
    }

    readonly property Socket topMemSocket: Socket {
        path: root.socketPath()
        connected: true
        onConnectedChanged: if (connected) write("topmem\n")
        parser: SplitParser {
            splitMarker: "\n"
            onRead: data => { root.topMem = JSON.parse(data).procs; }
        }
    }

    readonly property Socket topNetSocket: Socket {
        path: root.socketPath()
        connected: true
        onConnectedChanged: if (connected) write("topnet\n")
        parser: SplitParser {
            splitMarker: "\n"
            onRead: data => { root.topNet = JSON.parse(data).procs; }
        }
    }
}

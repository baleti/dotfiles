pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Client for ~/.config/hypr/sysmon's sysmond daemon (Unix socket at
// $XDG_RUNTIME_DIR/sysmond.sock) -- reuses its existing continuous
// background sampler/tiered-history buffer instead of re-implementing one
// here. Protocol: write "<metric>" or "<metric>:<tier>" once, then read one
// JSON snapshot line per second for as long as the socket stays open (see
// sysmon/src/lib.rs's Request/Tier). The five history metrics (net/cpu/
// mem/disk/temp) go through TieredSocket so callers can switch which of the
// 5 fixed granularities (30m/6h/7d/7w/7mo) they're viewing; this is process-
// wide (one singleton, shared by every monitor's Bar.qml instance), so
// switching tier on one monitor's panel switches it everywhere -- a
// deliberate simplification rather than 5x-ing the live socket count.
QtObject {
    id: root

    readonly property var tierCodes: ["30m", "6h", "7d", "7w", "7mo"]
    readonly property var tierLabels: ({
        "30m": qsTr("last 30 minutes"),
        "6h": qsTr("last 6 hours"),
        "7d": qsTr("last 7 days"),
        "7w": qsTr("last 7 weeks"),
        "7mo": qsTr("last 7 months"),
    })

    readonly property TieredSocket netSock: TieredSocket { metricName: "net" }
    readonly property TieredSocket cpuSock: TieredSocket { metricName: "cpu" }
    readonly property TieredSocket memSock: TieredSocket { metricName: "mem" }
    readonly property TieredSocket diskSock: TieredSocket { metricName: "disk" }
    readonly property TieredSocket tempSock: TieredSocket { metricName: "temp" }

    function setNetTier(t: string): void { netSock.tier = t; }
    function setCpuTier(t: string): void { cpuSock.tier = t; }
    function setMemTier(t: string): void { memSock.tier = t; }
    function setDiskTier(t: string): void { diskSock.tier = t; }
    function setTempTier(t: string): void { tempSock.tier = t; }

    // Every non-loopback interface sysmond has seen, each with its own
    // rx_bps/tx_bps history -- e.g. [{name: "wlan0", rx_bps: [...], tx_bps:
    // [...]}, {name: "wg-wsl", ...}]. Bar.qml/GraphPill assign each a color.
    readonly property var netInterfaces: netSock.data.interfaces ?? []

    readonly property list<real> cpuTotal: cpuSock.data.total ?? []
    // One history array per logical CPU, index = core number.
    readonly property var cpuCores: cpuSock.data.cores ?? []

    readonly property list<real> tempC: tempSock.data.celsius ?? []

    readonly property list<real> memUsedPct: memSock.data.used_pct ?? []
    readonly property list<real> memCachedPct: memSock.data.cached_pct ?? []

    // [{pid, name, value}], value = %CPU of one core, or MB resident.
    property var topCpu: []
    property var topMem: []
    // value = combined sent+received KB over the last ~1s (nethogs trace
    // mode, sysmond's own subprocess -- see sysmond.rs's nethogs_loop).
    property var topNet: []

    // Whole-disk block devices, same shape as netInterfaces.
    readonly property var diskDevices: diskSock.data.devices ?? []

    function socketPath(): string {
        return `${Quickshell.env("XDG_RUNTIME_DIR")}/sysmond.sock`;
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

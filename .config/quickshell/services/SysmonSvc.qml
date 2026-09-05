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
// 6 fixed granularities (10m/30m/6h/7d/7w/7mo) they're viewing; this is process-
// wide (one singleton, shared by every monitor's Bar.qml instance), so
// switching tier on one monitor's panel switches it everywhere -- a
// deliberate simplification rather than 5x-ing the live socket count.
QtObject {
    id: root

    readonly property var tierCodes: ["10m", "30m", "6h", "7d", "7w", "7mo"]
    readonly property var tierLabels: ({
        "10m": qsTr("last 10 minutes"),
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
    readonly property TieredSocket gpuSock: TieredSocket { metricName: "gpu"; includeProcs: root.gpuProcsRefs > 0 }

    function setNetTier(t: string): void { netSock.tier = t; }
    function setCpuTier(t: string): void { cpuSock.tier = t; }
    function setMemTier(t: string): void { memSock.tier = t; }
    function setDiskTier(t: string): void { diskSock.tier = t; }
    function setTempTier(t: string): void { tempSock.tier = t; }
    function setGpuTier(t: string): void { gpuSock.tier = t; }

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
    readonly property list<real> swapUsedPct: memSock.data.swap_used_pct ?? []

    // Every GPU on the machine, one object each (iGPU + dGPU on a hybrid
    // laptop). Per entry: name, vendor ("intel"|"nvidia"), the history
    // series util_pct / vram_pct / power_pct (vram & power are empty for the
    // iGPU -- no dedicated VRAM total, no board-power telemetry), the
    // point-in-time detail scalars (temp_c/power_w/power_limit_w/
    // vram_used_mb/vram_total_mb/sm_clock_mhz/mem_clock_mhz/enc_pct/dec_pct/
    // fan_pct), and `procs` (this GPU's top-10, value = memory MiB, util% in
    // `detail`). Fed by sysmond's `gpu_loop` (nvidia-smi) + `intel_gpu_loop`
    // (i915 fdinfo). `gpuPresent` gates the bar pill -- false on a machine
    // with no supported GPU, so the pill never appears.
    readonly property var gpuList: gpuSock.data.gpus ?? []
    readonly property bool gpuPresent: (gpuSock.data.gpus?.length ?? 0) > 0

    // [{pid, name, value}], value = %CPU of one core, or MB resident.
    property var topCpu: []
    property var topMem: []
    // value = combined sent+received KB over the last ~1s (nethogs trace
    // mode, sysmond's own subprocess -- see sysmond.rs's nethogs_loop).
    property var topNet: []
    // value = combined read+write KB/s over the last sample tick, from
    // /proc/[pid]/io -- excludes any process sysmond can't read (someone
    // else's, or one marked non-dumpable), see sysmond.rs's proc_io_bytes.
    property var topDisk: []

    // Whole-disk block devices, same shape as netInterfaces.
    readonly property var diskDevices: diskSock.data.devices ?? []

    // Filesystem *space* usage (percent full), separate from diskDevices'
    // I/O-rate history above -- that's per whole-disk block device, this is
    // per mounted filesystem, and changes slowly enough that polling `df`
    // every 60s (instead of sysmond's per-second sampler) is plenty.
    // [{name: "/", pcent: 46}, ...], restricted to the mounts listed in
    // ~/.config/quickshell/disk-usage-mounts.conf (user-editable, plain
    // text -- see that file's header) and ordered the same way, since a
    // btrfs root has one usage% per subvolume mount (/, /home, /var, ...
    // all read the same, would just be noise) and the FUSE remotes
    // (gdrive: etc.) are otherwise out of scope for local disk usage (see
    // memory) but the user does want specific ones surfaced here.
    property var diskUsage: []
    readonly property real rootUsagePct: {
        for (const d of root.diskUsage)
            if (d.name === "/")
                return d.pcent;
        return NaN;
    }

    property var _wantedMounts: []
    property string _lastDfText: ""

    // Re-applies the wanted-mounts filter to the last `df` run, without
    // waiting up to 60s for diskUsageTimer's next tick -- so editing the
    // config file takes effect close to immediately.
    readonly property FileView diskMountsConfig: FileView {
        path: `${Quickshell.env("HOME")}/.config/quickshell/disk-usage-mounts.conf`
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            root._wantedMounts = text().split("\n")
                .map(l => l.trim())
                .filter(l => l.length > 0 && !l.startsWith("#"));
            if (root._lastDfText)
                root._parseDfOutput(root._lastDfText);
        }
        onLoadFailed: root._wantedMounts = ["/"];
    }

    function _parseDfOutput(text) {
        root._lastDfText = text;
        const lines = text.trim().split("\n");
        lines.shift(); // header: "Filesystem Type Use% Mounted on"
        const bySource = {};
        for (const line of lines) {
            const parts = line.trim().split(/\s+/);
            if (parts.length < 4)
                continue;
            const source = parts[0];
            const pcent = parseInt(parts[2]);
            const target = parts.slice(3).join(" ");
            if (isNaN(pcent))
                continue;
            // Dedupes multiple mounts of the same source (btrfs subvolumes
            // under one device) down to its shortest/topmost mount path,
            // before the wanted-list filter matches against it.
            const existing = bySource[source];
            if (!existing || target.length < existing.target.length)
                bySource[source] = { source, target, pcent };
        }
        const bySourceOrTarget = {};
        for (const d of Object.values(bySource)) {
            bySourceOrTarget[d.source] = d;
            bySourceOrTarget[d.target] = d;
        }
        const out = [];
        for (const wanted of root._wantedMounts) {
            const d = bySourceOrTarget[wanted];
            if (d)
                out.push({ name: d.target, pcent: d.pcent });
        }
        root.diskUsage = out;
    }

    readonly property Process dfProc: Process {
        command: ["df", "--output=source,fstype,pcent,target", "-x", "tmpfs", "-x", "devtmpfs", "-x", "overlay", "-x", "squashfs", "-x", "efivarfs"]
        stdout: StdioCollector {
            onStreamFinished: root._parseDfOutput(text)
        }
    }

    readonly property Timer diskUsageTimer: Timer {
        interval: 60000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.dfProc.running = true
    }

    function socketPath(): string {
        return `${Quickshell.env("XDG_RUNTIME_DIR")}/sysmond.sock`;
    }

    // On-demand panel data (2026-09-05: "data that shows up in panels ...
    // isn't needed until that panel gets opened"). Each of these counts how
    // many currently-expanded panels want that metric's per-process data --
    // could be more than one pill across monitors (cpu's list is also
    // shown by the temp panel as a heat proxy, and either panel on either
    // monitor's Bar.qml instance can be open at once), so it's a refcount,
    // not a bool, incremented/decremented by GraphPill's onExpandedChanged
    // via ref*()/unref*() below. The matching sockets only connect (and
    // sysmond only does the expensive work behind them -- a full-process
    // scan for cpu/mem/disk, the nethogs subprocess for net, nvidia-smi
    // pmon + the intel per-process ranking for gpu) while their count is
    // above zero; see sysmond.rs's Demand.
    property int topCpuRefs: 0
    property int topMemRefs: 0
    property int topNetRefs: 0
    property int topDiskRefs: 0
    property int gpuProcsRefs: 0

    // unref*() clears the corresponding array back to [] once its refcount
    // hits zero -- topCpu/topMem/topNet/topDisk only ever get *reassigned*
    // on an incoming socket message (see each socket's onRead below), never
    // on disconnect, so without this a reopened panel would briefly flash
    // whatever was last shown before this session's real (or the
    // placeholder-then-real) data arrives -- reported 2026-09-06: "flash
    // for a split second, then disappear, then reappear 1-2s later".
    function refTopCpu(): void { root.topCpuRefs++; }
    function unrefTopCpu(): void {
        root.topCpuRefs = Math.max(0, root.topCpuRefs - 1);
        if (root.topCpuRefs === 0)
            root.topCpu = [];
    }
    function refTopMem(): void { root.topMemRefs++; }
    function unrefTopMem(): void {
        root.topMemRefs = Math.max(0, root.topMemRefs - 1);
        if (root.topMemRefs === 0)
            root.topMem = [];
    }
    function refTopNet(): void { root.topNetRefs++; }
    function unrefTopNet(): void {
        root.topNetRefs = Math.max(0, root.topNetRefs - 1);
        if (root.topNetRefs === 0)
            root.topNet = [];
    }
    function refTopDisk(): void { root.topDiskRefs++; }
    function unrefTopDisk(): void {
        root.topDiskRefs = Math.max(0, root.topDiskRefs - 1);
        if (root.topDiskRefs === 0)
            root.topDisk = [];
    }
    function refGpuProcs(): void { root.gpuProcsRefs++; }
    function unrefGpuProcs(): void { root.gpuProcsRefs = Math.max(0, root.gpuProcsRefs - 1); }

    readonly property Socket topCpuSocket: Socket {
        path: root.socketPath()
        connected: root.topCpuRefs > 0
        onConnectedChanged: if (connected) write("topcpu\n")
        parser: SplitParser {
            splitMarker: "\n"
            onRead: data => { root.topCpu = JSON.parse(data).procs; }
        }
    }

    readonly property Socket topMemSocket: Socket {
        path: root.socketPath()
        connected: root.topMemRefs > 0
        onConnectedChanged: if (connected) write("topmem\n")
        parser: SplitParser {
            splitMarker: "\n"
            onRead: data => { root.topMem = JSON.parse(data).procs; }
        }
    }

    readonly property Socket topNetSocket: Socket {
        path: root.socketPath()
        connected: root.topNetRefs > 0
        onConnectedChanged: if (connected) write("topnet\n")
        parser: SplitParser {
            splitMarker: "\n"
            onRead: data => { root.topNet = JSON.parse(data).procs; }
        }
    }

    readonly property Socket topDiskSocket: Socket {
        path: root.socketPath()
        connected: root.topDiskRefs > 0
        onConnectedChanged: if (connected) write("topdisk\n")
        parser: SplitParser {
            splitMarker: "\n"
            onRead: data => { root.topDisk = JSON.parse(data).procs; }
        }
    }

    // Re-assert a socket if sysmond drops it while still wanted (dev
    // restarts, package upgrades) -- `connected: root.topXxxRefs > 0` only
    // re-fires when the ref *count* changes, not when the daemon-side
    // connection silently dies out from under an unchanged true value, so
    // this timer is still needed as the same fix TieredSocket.qml's own
    // timer applies. Only touches sockets that are actually wanted right
    // now -- never force-reconnects one nobody's asked for.
    readonly property Timer reconnectTimer: Timer {
        interval: 2000
        repeat: true
        running: (root.topCpuRefs > 0 && !root.topCpuSocket.connected)
            || (root.topMemRefs > 0 && !root.topMemSocket.connected)
            || (root.topNetRefs > 0 && !root.topNetSocket.connected)
            || (root.topDiskRefs > 0 && !root.topDiskSocket.connected)
        onTriggered: {
            if (root.topCpuRefs > 0)
                root.topCpuSocket.connected = true;
            if (root.topMemRefs > 0)
                root.topMemSocket.connected = true;
            if (root.topNetRefs > 0)
                root.topNetSocket.connected = true;
            if (root.topDiskRefs > 0)
                root.topDiskSocket.connected = true;
        }
    }
}

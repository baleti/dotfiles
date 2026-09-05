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
    // GPU only: whether this connection should also carry per-process data
    // (see sysmond's Request::include_procs) -- the compact pill's own
    // util/vram/power numbers never need it, only the expanded panel's
    // "Top processes" list does. Meaningless for every other metricName.
    property bool includeProcs: false

    function socketPath(): string {
        return `${Quickshell.env("XDG_RUNTIME_DIR")}/sysmond.sock`;
    }

    onTierChanged: {
        sock.connected = false;
        sock.connected = true;
    }
    // Toggling includeProcs, like changing tier, means a new request line
    // -- reconnect rather than trying to change it on a live stream.
    onIncludeProcsChanged: {
        sock.connected = false;
        sock.connected = true;
    }

    // Mirrors sysmond.rs's TIER_CAPACITY -- can't import the Rust constant
    // directly, so this just has to be kept in sync (rarely changes).
    readonly property int _tierCapacity: 600

    function _appendTrim(arr, extra) {
        if (!extra || extra.length === 0)
            return arr;
        const out = arr.concat(extra);
        if (out.length > root._tierCapacity)
            out.splice(0, out.length - root._tierCapacity);
        return out;
    }

    // Merges a delta-streamed message into `root.data`, mirroring the same
    // append-and-trim contract sysmond's other client (sysmon-graph.rs's
    // own merge_snapshot) uses. `msg.full` (2026-09-05 protocol rework --
    // see sysmon/src/lib.rs's `Snapshot` doc comment) decides whether to
    // replace wholesale (a fresh connection, or one of sysmond's periodic
    // resyncs) or append. GPU's point-in-time fields (detail scalars,
    // procs) always just take the incoming value since they're never
    // deltas -- object-spreading `d` first and only overriding the three
    // history arrays gets that for free.
    function _merge(existing, msg) {
        if (msg.full || !existing || Object.keys(existing).length === 0)
            return msg;
        switch (root.metricName) {
        case "net":
        case "disk": {
            const listKey = root.metricName === "net" ? "interfaces" : "devices";
            const aKey = root.metricName === "net" ? "rx_bps" : "read_bps";
            const bKey = root.metricName === "net" ? "tx_bps" : "write_bps";
            const byName = {};
            for (const item of existing[listKey] ?? [])
                byName[item.name] = { name: item.name, [aKey]: item[aKey], [bKey]: item[bKey] };
            for (const d of msg[listKey] ?? []) {
                const cur = byName[d.name];
                if (!cur) {
                    // Shouldn't happen -- a new interface/device forces sysmond
                    // to send this whole message full instead.
                    byName[d.name] = d;
                    continue;
                }
                cur[aKey] = root._appendTrim(cur[aKey], d[aKey]);
                cur[bKey] = root._appendTrim(cur[bKey], d[bKey]);
            }
            const out = { metric: root.metricName };
            out[listKey] = Object.values(byName);
            return out;
        }
        case "cpu": {
            const total = root._appendTrim(existing.total ?? [], msg.total);
            const cores = (existing.cores ?? []).map((c, i) => root._appendTrim(c, (msg.cores ?? [])[i] ?? []));
            return { metric: "cpu", total, cores };
        }
        case "temp":
            return { metric: "temp", celsius: root._appendTrim(existing.celsius ?? [], msg.celsius) };
        case "mem":
            return {
                metric: "mem",
                used_pct: root._appendTrim(existing.used_pct ?? [], msg.used_pct),
                cached_pct: root._appendTrim(existing.cached_pct ?? [], msg.cached_pct),
                swap_used_pct: root._appendTrim(existing.swap_used_pct ?? [], msg.swap_used_pct),
            };
        case "gpu": {
            const byName = {};
            for (const g of existing.gpus ?? [])
                byName[g.name] = g;
            const gpus = (msg.gpus ?? []).map(d => {
                const cur = byName[d.name];
                if (!cur)
                    return d; // shouldn't happen -- the GPU list never changes post-startup
                // No object-spread here -- this engine's JS dialect doesn't
                // support it (confirmed live: it crashed the whole shell,
                // "Unexpected token '...'"). Copy every point-in-time field
                // from `d` explicitly instead of trying to shortcut it.
                return {
                    name: d.name,
                    vendor: d.vendor,
                    util_pct: root._appendTrim(cur.util_pct, d.util_pct),
                    vram_pct: root._appendTrim(cur.vram_pct, d.vram_pct),
                    power_pct: root._appendTrim(cur.power_pct, d.power_pct),
                    temp_c: d.temp_c,
                    power_w: d.power_w,
                    power_limit_w: d.power_limit_w,
                    vram_used_mb: d.vram_used_mb,
                    vram_total_mb: d.vram_total_mb,
                    sm_clock_mhz: d.sm_clock_mhz,
                    mem_clock_mhz: d.mem_clock_mhz,
                    enc_pct: d.enc_pct,
                    dec_pct: d.dec_pct,
                    fan_pct: d.fan_pct,
                    procs: d.procs,
                };
            });
            return { metric: "gpu", gpus };
        }
        default:
            return msg;
        }
    }

    Socket {
        id: sock
        path: root.socketPath()
        connected: true
        onConnectedChanged: if (connected) write(root.metricName + ":" + root.tier + (root.includeProcs ? ":procs" : "") + "\n")
        parser: SplitParser {
            splitMarker: "\n"
            onRead: data => { root.data = root._merge(root.data, JSON.parse(data)); }
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

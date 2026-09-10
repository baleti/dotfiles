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

    // Whether any panel currently wants this metric's full rolling history.
    // Set by SysmonSvc's per-metric refcount -- a GraphPill refs it on
    // expand and unrefs on collapse. The always-visible compact pills only
    // ever read the latest sample (`last()` of a series), so while every
    // graph panel for this metric is collapsed there is no reason to
    // accumulate -- or allocate, or fan binding invalidations out across
    // three monitors' worth of derived properties over -- the 600-point
    // tiered buffers: the per-second delta is folded into length-1 arrays
    // instead (see `_cap`), which keeps every compact reading correct for a
    // fraction of the per-tick cost. Expanding a panel flips this true,
    // which forces a reconnect so sysmond resends the whole buffer as one
    // `full` snapshot and the graph is populated immediately rather than
    // drawing itself in one point per second.
    property bool historyWanted: false

    // Mirrors sysmond.rs's TIER_CAPACITY -- can't import the Rust constant
    // directly, so this just has to be kept in sync (rarely changes).
    readonly property int _tierCapacity: 600
    // 600 while a panel wants history, 1 otherwise (see historyWanted).
    readonly property int _cap: root.historyWanted ? root._tierCapacity : 1

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
    onHistoryWantedChanged: {
        if (root.historyWanted) {
            // Need the whole buffer now -- reconnect so sysmond replies
            // with a `full` snapshot instead of us waiting to re-fill one
            // point per second from the delta stream.
            sock.connected = false;
            sock.connected = true;
        } else {
            // Demand dropped -- keep only the latest point of every series
            // and let the rest go.
            if (root.data && Object.keys(root.data).length > 0)
                root.data = root._reshape(root.data, 1);
        }
    }

    // Append `extra`'s points onto `arr` IN PLACE, then drop from the front
    // so it never exceeds `cap` -- mirrors sysmond's own ring-buffer
    // eviction. No concat / fresh array per tick; one splice only when the
    // buffer is actually over capacity. `cap` is 1 while nothing wants
    // history, `_tierCapacity` while something does.
    function _pushTrim(arr, extra, cap) {
        if (!arr)
            return;
        if (extra && extra.length) {
            for (let i = 0; i < extra.length; i++)
                arr.push(extra[i]);
        }
        if (arr.length > cap)
            arr.splice(0, arr.length - cap);
    }

    // Last `cap` points of `a` as a fresh array (one slice, no splice) --
    // used for `full` snapshots and when history demand drops, both of
    // which replace a series wholesale rather than appending to it.
    function _tail(a, cap) {
        if (!a || a.length === 0)
            return [];
        return a.length > cap ? a.slice(a.length - cap) : a.slice();
    }

    // Build a `data`-shaped object from a full snapshot (or from our own
    // current `data`, when demand drops), tail-trimming every history
    // series to `cap`. The point-in-time GPU fields (detail scalars, procs)
    // are never history -- copied straight across.
    function _reshape(src, cap) {
        switch (root.metricName) {
        case "cpu":
            return { metric: "cpu", total: root._tail(src.total, cap),
                     cores: (src.cores ?? []).map(c => root._tail(c, cap)) };
        case "temp":
            return { metric: "temp", celsius: root._tail(src.celsius, cap) };
        case "mem":
            return { metric: "mem",
                     used_pct: root._tail(src.used_pct, cap),
                     cached_pct: root._tail(src.cached_pct, cap),
                     swap_used_pct: root._tail(src.swap_used_pct, cap),
                     swap_in_bps: root._tail(src.swap_in_bps, cap),
                     swap_out_bps: root._tail(src.swap_out_bps, cap) };
        case "net":
        case "disk": {
            const listKey = root.metricName === "net" ? "interfaces" : "devices";
            const aKey = root.metricName === "net" ? "rx_bps" : "read_bps";
            const bKey = root.metricName === "net" ? "tx_bps" : "write_bps";
            const out = { metric: root.metricName };
            out[listKey] = (src[listKey] ?? []).map(item => {
                const o = { name: item.name };
                o[aKey] = root._tail(item[aKey], cap);
                o[bKey] = root._tail(item[bKey], cap);
                return o;
            });
            return out;
        }
        case "gpu":
            return { metric: "gpu", gpus: (src.gpus ?? []).map(g => root._gpuEntry(g, root._tail(g.util_pct, cap), root._tail(g.vram_pct, cap), root._tail(g.power_pct, cap))) };
        }
        return src;
    }

    // No object-spread here -- this engine's JS dialect doesn't support it
    // (confirmed live: `{ ...g }` crashed the whole shell, "Unexpected
    // token '...'"). Every point-in-time GPU field is copied explicitly.
    function _gpuEntry(g, utilArr, vramArr, powerArr) {
        return {
            name: g.name,
            vendor: g.vendor,
            util_pct: utilArr,
            vram_pct: vramArr,
            power_pct: powerArr,
            temp_c: g.temp_c,
            power_w: g.power_w,
            power_limit_w: g.power_limit_w,
            vram_used_mb: g.vram_used_mb,
            vram_total_mb: g.vram_total_mb,
            sm_clock_mhz: g.sm_clock_mhz,
            mem_clock_mhz: g.mem_clock_mhz,
            enc_pct: g.enc_pct,
            dec_pct: g.dec_pct,
            fan_pct: g.fan_pct,
            procs: g.procs ?? [],
        };
    }

    // Merges one incoming line into `root.data`. `msg.full` (2026-09-05
    // protocol rework -- see sysmon/src/lib.rs's `Snapshot` doc comment)
    // means every array is the COMPLETE current buffer (a fresh connection,
    // or one of sysmond's periodic resyncs); otherwise every array is just
    // the point(s) appended since the previous message on this connection
    // and we append-and-trim, mirroring the daemon's own ring-buffer
    // eviction.
    function _ingest(msg) {
        const cap = root._cap;
        const d = root.data;
        const fresh = msg.full || !d || Object.keys(d).length === 0 || d.metric !== msg.metric;
        if (fresh) {
            root.data = root._reshape(msg, cap);
            return;
        }

        switch (root.metricName) {
        case "cpu":
            root._pushTrim(d.total, msg.total, cap);
            for (let i = 0; i < (d.cores ?? []).length; i++)
                root._pushTrim(d.cores[i], (msg.cores ?? [])[i], cap);
            break;
        case "temp":
            root._pushTrim(d.celsius, msg.celsius, cap);
            break;
        case "mem":
            root._pushTrim(d.used_pct, msg.used_pct, cap);
            root._pushTrim(d.cached_pct, msg.cached_pct, cap);
            root._pushTrim(d.swap_used_pct, msg.swap_used_pct, cap);
            root._pushTrim(d.swap_in_bps, msg.swap_in_bps, cap);
            root._pushTrim(d.swap_out_bps, msg.swap_out_bps, cap);
            break;
        case "net":
        case "disk": {
            const listKey = root.metricName === "net" ? "interfaces" : "devices";
            const aKey = root.metricName === "net" ? "rx_bps" : "read_bps";
            const bKey = root.metricName === "net" ? "tx_bps" : "write_bps";
            const byName = {};
            for (const item of d[listKey] ?? [])
                byName[item.name] = item;
            for (const nd of msg[listKey] ?? []) {
                const cur = byName[nd.name];
                if (!cur) {
                    // Shouldn't happen -- a new interface/device forces
                    // sysmond to send this whole message full instead.
                    (d[listKey] = d[listKey] ?? []).push(nd);
                    continue;
                }
                root._pushTrim(cur[aKey], nd[aKey], cap);
                root._pushTrim(cur[bKey], nd[bKey], cap);
            }
            break;
        }
        case "gpu": {
            const byName = {};
            for (const g of d.gpus ?? [])
                byName[g.name] = g;
            for (const nd of msg.gpus ?? []) {
                const cur = byName[nd.name];
                if (!cur) {
                    // Shouldn't happen -- the GPU list never changes post-startup.
                    (d.gpus = d.gpus ?? []).push(nd);
                    continue;
                }
                root._pushTrim(cur.util_pct, nd.util_pct, cap);
                root._pushTrim(cur.vram_pct, nd.vram_pct, cap);
                root._pushTrim(cur.power_pct, nd.power_pct, cap);
                // Point-in-time, never deltas -- always take the incoming value.
                cur.temp_c = nd.temp_c;
                cur.power_w = nd.power_w;
                cur.power_limit_w = nd.power_limit_w;
                cur.vram_used_mb = nd.vram_used_mb;
                cur.vram_total_mb = nd.vram_total_mb;
                cur.sm_clock_mhz = nd.sm_clock_mhz;
                cur.mem_clock_mhz = nd.mem_clock_mhz;
                cur.enc_pct = nd.enc_pct;
                cur.dec_pct = nd.dec_pct;
                cur.fan_pct = nd.fan_pct;
                cur.procs = nd.procs ?? [];
            }
            break;
        }
        }

        // Publish a fresh `data` off the just-mutated buffers. `_reshape`
        // with the current cap is a single `.slice()` per series (the
        // buffers are already <= cap here, so no trimming happens) -- one
        // small allocation per tick, not the whole-object concat rebuild
        // the old delta path did, and effectively free while collapsed
        // (every series is length 1). Fresh array refs matter: downstream
        // `SysmonSvc` list properties and `Bar.qml`'s graph wrappers only
        // re-fire on a new reference, not an in-place mutation.
        root.data = root._reshape(d, root._cap);
    }

    Socket {
        id: sock
        path: root.socketPath()
        connected: true
        onConnectedChanged: if (connected) write(root.metricName + ":" + root.tier + (root.includeProcs ? ":procs" : "") + "\n")
        parser: SplitParser {
            splitMarker: "\n"
            onRead: line => {
                try {
                    root._ingest(JSON.parse(line));
                } catch (e) {
                    console.warn("sysmon:", root.metricName, "ingest failed:", e);
                }
            }
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

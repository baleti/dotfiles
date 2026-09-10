import QtQuick
import Quickshell
import Quickshell.Io

// Streams one sub-metric's tiered top-process snapshot ring from sysmond
// (`prochist:<sub>:<tier>`, see sysmon/src/lib.rs) for GraphPill's
// graph-hover tooltip. Same request-once-then-stream / reconnect-on-change
// contract as TieredSocket.qml: switching `tier` or `sub`, or toggling
// `wanted`, closes the socket and opens a fresh one with a new request
// line. sysmond collects this history continuously (not just while a panel
// is open), so a hover works even for spans nobody was watching -- but the
// socket itself only connects while some panel actually wants it.
Item {
    id: root

    // "cpu" | "mem" | "net" | "disk" | "gpu:<name>". "temp" reuses "cpu".
    required property string sub
    property string tier: "10m"
    property bool wanted: false

    // [{secs_ago, value, procs: [{pid, name, value, util_pct, detail}]}],
    // oldest-first, tail-aligned with the matching metric's graph series for
    // the same tier (both rings finalize a bucket together server-side).
    property var snaps: []

    // Mirrors sysmond's TIER_CAPACITY.
    readonly property int _cap: 600

    function socketPath(): string {
        return `${Quickshell.env("XDG_RUNTIME_DIR")}/sysmond.sock`;
    }

    // Single imperative driver -- `connected` is never declaratively bound
    // (a bind would be lost the first time we toggle it for a reconnect),
    // the reconnect Timer below re-asserts it if the daemon drops us.
    function _sync() {
        if (root.wanted && root.sub.length > 0) {
            sock.connected = false;
            sock.connected = true;
        } else {
            sock.connected = false;
            root.snaps = [];
        }
    }
    onWantedChanged: _sync()
    onTierChanged: _sync()
    onSubChanged: _sync()
    Component.onCompleted: _sync()

    function _ingest(msg) {
        if (msg.metric !== "prochist")
            return;
        if (msg.full) {
            root.snaps = msg.snaps ?? [];
            return;
        }
        // Delta: append the newly-finalized bucket(s), drop from the front
        // past capacity -- mirrors the daemon's own ring eviction.
        const merged = root.snaps.slice();
        for (const s of (msg.snaps ?? []))
            merged.push(s);
        if (merged.length > root._cap)
            merged.splice(0, merged.length - root._cap);
        root.snaps = merged;
    }

    Socket {
        id: sock
        path: root.socketPath()
        onConnectedChanged: if (connected) write("prochist:" + root.sub + ":" + root.tier + "\n")
        parser: SplitParser {
            splitMarker: "\n"
            onRead: line => {
                try {
                    root._ingest(JSON.parse(line));
                } catch (e) {
                    console.warn("prochist:", root.sub, "ingest failed:", e);
                }
            }
        }
    }

    Timer {
        interval: 2000
        repeat: true
        running: root.wanted && root.sub.length > 0 && !sock.connected
        onTriggered: sock.connected = true
    }
}

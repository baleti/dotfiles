pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// Alt-tab session state (overhauled 2026-09-10). Owns everything that must
// behave identically whether or not a grid is ever drawn: the window list,
// the selection, tap-vs-hold, and confirming. WinSwitch.qml (one per monitor)
// is only a view onto this plus the search/DSL UI.
//
// Input arrives from ~/.config/hypr/winswitch.lua as events on Hyprland's own
// socket2, in the exact order the compositor saw the keys:
//
//   winswitch tab next|prev   ALT+Tab / ALT+SHIFT+Tab pressed; the window list
//                             (focus-history order at that press) was written
//                             to $XDG_RUNTIME_DIR/winswitch-windows.json first
//   winswitch altup           Alt released (in-compositor poll)
//
// State machine:
//   idle    + tab    -> start session: selection = the focused window, then
//                       advance by one. Grid is not drawn yet.
//   pending + tab    -> advance (no restart, whatever the timing)
//   pending + altup  -> confirm, grid never drawn (a tap)
//   pending + showDelayMs elapses -> draw the grid
//   shown   + layer mapped + captureSettleMs -> start thumbnail capture
//   shown   + tab    -> advance, or cycle autocomplete once locked
//   shown   + altup  -> confirm, unless locked into search mode
// So ALT+Tab, SHIFT+Tab, release always lands back on the focused window
// (a no-op), however fast it's typed.
QtObject {
    id: root

    // An Alt release before this counts as a tap: switch without ever
    // mapping a surface.
    readonly property int showDelayMs: 80
    // Thumbnail capture makes Hyprland render every window on its main
    // thread, which stalls it (measured: up to ~240ms without replies). Run
    // concurrently with the grid's first frame, that stall held the layer
    // back from mapping (+400ms after the press vs +137ms without capture),
    // so capture waits for Hyprland's `openlayer` event plus this settle
    // time. The fallback covers a missed event.
    readonly property int captureSettleMs: 150
    readonly property int captureFallbackMs: 600

    property bool active: false
    property bool shown: false
    property string monitor: ""
    property int sessionId: 0
    // [{index, address, class, title, workspace, pid, width, height, active}],
    // index 0 = most recently focused.
    property var windows: []
    // Index into `windows`, -1 if no listed window had focus at the press
    // (e.g. an empty workspace) so the first "next" lands on index 0.
    property int selected: -1
    // Search mode (a printable key was typed): Alt release no longer
    // confirms, Tab cycles autocomplete instead. Set by WinSwitch.qml.
    property bool locked: false
    // address -> {path, width, height}. Kept across sessions (pruned to live
    // windows) so a hold shows the last capture immediately while a fresh one
    // runs; the backend writes a new file name per capture, so Image's
    // pixmap cache can never serve a stale picture for a reused path.
    property var thumbnails: ({})
    // address -> merged tmux/claude fields, reset per session.
    property var enrichMeta: ({})

    signal lockedTab(string direction)

    property bool _capturePending: false

    readonly property Connections _events: Connections {
        target: Hyprland
        function onRawEvent(event: var): void {
            if (event.name === "openlayer") {
                if (event.data === "quickshell-winswitch")
                    root._onMapped();
                return;
            }
            if (event.name !== "custom" || !event.data.startsWith("winswitch "))
                return;
            const rest = event.data.slice("winswitch ".length);
            if (rest === "altup")
                root._onAltUp();
            else if (rest.startsWith("tab "))
                root._onTab(rest.slice(4));
        }
    }

    // Written by winswitch.lua right before each tab event (socket2 lines are
    // capped at ~1KB, too small for the list). Read synchronously so the
    // session starts in the same event-loop turn as its tab event, keeping
    // tab/altup strictly ordered.
    readonly property FileView _listFile: FileView {
        id: listFile
        path: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/winswitch-windows.json"
        blockAllReads: true
        printErrors: false
    }

    function _onTab(direction) {
        if (!root.active) {
            let list;
            try {
                listFile.reload();
                list = JSON.parse(listFile.text());
            } catch (e) {
                console.warn(`winswitch: bad window list: ${e}`);
                return;
            }
            if (!Array.isArray(list) || list.length === 0)
                return;
            root._startSession(list);
        }
        if (root.locked)
            root.lockedTab(direction);
        else
            root.advance(direction);
    }

    function _onAltUp() {
        if (root.active && !root.locked)
            root.confirm(root.selected);
    }

    function _resolveMonitor() {
        const name = Hyprland.focusedMonitor?.name ?? "";
        const screens = Quickshell.screens;
        if (screens.some(s => s.name === name))
            return name;
        return screens.length > 0 ? screens[0].name : "";
    }

    function _startSession(list) {
        const rows = list.map((w, index) => Object.assign({ index }, w));
        const live = {};
        for (const w of rows)
            live[w.address] = true;
        const kept = {};
        for (const a in root.thumbnails)
            if (live[a])
                kept[a] = root.thumbnails[a];

        root.sessionId++;
        root._pendingThumbnails = ({});
        root._pendingEnrich = ({});
        root.thumbnails = kept;
        root.enrichMeta = ({});
        root.windows = rows;
        root.selected = rows.findIndex(w => w.active);
        root.locked = false;
        root.shown = false;
        root.monitor = root._resolveMonitor();
        root.active = true;
        showTimer.restart();
    }

    // Cyclic over the full list; WinSwitch.qml has its own over filtered
    // results for search mode.
    function advance(direction) {
        const n = root.windows.length;
        if (n === 0)
            return;
        const cur = root.selected;
        root.selected = direction === "prev" ? (cur <= 0 ? n - 1 : cur - 1) : (cur + 1) % n;
    }

    function confirm(i) {
        const w = root.windows[i];
        root.close();
        if (w && !w.active)
            root.focusWindow(w.address);
    }

    function close() {
        if (!root.active)
            return;
        showTimer.stop();
        captureTimer.stop();
        root._capturePending = false;
        root.shown = false;
        root.locked = false;
        root.active = false;
    }

    // winswitch.focus() is defined in winswitch.lua; a dispatch request is
    // evaluated as `hl.dispatch(<request>)`, so no hyprctl process is needed.
    function focusWindow(address) {
        Hyprland.dispatch(`winswitch.focus("${address}")`);
    }

    readonly property Timer _showTimer: Timer {
        id: showTimer
        interval: root.showDelayMs
        repeat: false
        onTriggered: {
            if (!root.active)
                return;
            root._capturePending = true; // holds only: a tap never pays for a capture run
            captureTimer.interval = root.captureFallbackMs;
            captureTimer.restart();
            root.shown = true;
        }
    }

    function _onMapped() {
        if (root.active && root._capturePending) {
            captureTimer.interval = root.captureSettleMs;
            captureTimer.restart();
        }
    }

    readonly property Timer _captureTimer: Timer {
        id: captureTimer
        repeat: false
        onTriggered: {
            if (!root.active || !root._capturePending)
                return;
            root._capturePending = false;
            backend.running = false;
            backend.running = true;
        }
    }

    // ---- thumbnail/enrichment backend (~/.config/hypr/winswitch) ----------
    // Captures every window once and exits; output is NDJSON keyed by
    // address. Not killed on close, so a quick hold-release still finishes
    // refreshing the cache for next time.
    readonly property Process _backend: Process {
        id: backend
        command: [Quickshell.env("HOME") + "/.config/hypr/winswitch/target/release/winswitch"]
        stdout: SplitParser {
            onRead: line => root._handleLine(line)
        }
    }

    function _handleLine(line) {
        let msg;
        try {
            msg = JSON.parse(line);
        } catch (e) {
            return;
        }
        switch (msg.type) {
        case "thumbnail":
            root._pendingThumbnails[msg.address] = { path: msg.path, width: msg.width, height: msg.height };
            root._scheduleFlush();
            break;
        case "enrich":
            root._pendingEnrich[msg.address] = Object.assign({}, root._pendingEnrich[msg.address] || {}, msg.meta);
            root._scheduleFlush();
            break;
        }
    }

    // Coalesce the burst of NDJSON lines into one dictionary reassignment
    // per frame; every delegate binds to these dictionaries.
    property var _pendingThumbnails: ({})
    property var _pendingEnrich: ({})
    readonly property Timer _flushTimer: Timer {
        id: flushTimer
        interval: 16
        repeat: false
        onTriggered: root._flushPending()
    }
    function _scheduleFlush() {
        if (!flushTimer.running)
            flushTimer.start();
    }
    function _flushPending() {
        if (Object.keys(root._pendingThumbnails).length > 0) {
            root.thumbnails = Object.assign({}, root.thumbnails, root._pendingThumbnails);
            root._pendingThumbnails = {};
        }
        if (Object.keys(root._pendingEnrich).length > 0) {
            const e = Object.assign({}, root.enrichMeta);
            for (const a in root._pendingEnrich)
                e[a] = Object.assign({}, e[a] || {}, root._pendingEnrich[a]);
            root.enrichMeta = e;
            root._pendingEnrich = {};
        }
    }
}

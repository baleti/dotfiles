pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "../theme"

// Renderer side of the headless notifyd (~/.config/hypr/notifyd/). notifyd
// owns org.freedesktop.Notifications and does all the tracking / timeout /
// action-routing; it writes the current popup set to
// ~/.cache/notifyd/state.json, this singleton watches that file and exposes
// it as `popups`, and NotifLayer/NotifCard draw them. Card clicks go back to
// notifyd through `notifyctl` (same CLI the mod+n keybinds use).
//
// History (mod+CTRL+n) and the action menu (mod+SHIFT+n) still go straight
// through notifyctl -> notifyd and don't touch this file.
//
// Multi-monitor overflow: the focused monitor always gets the newest
// notifications first. `monitors.json` lists further monitors that take the
// overflow, in order, once the focused one fills up. If the whole set still
// doesn't fit even spread across every listed monitor, the assignment is
// split into pages and `pages`/`currentPage` below rotate through them on a
// timer, so everything eventually gets shown instead of the tail silently
// never appearing. How much fits where is decided from real card heights,
// reported into `measuredHeights` by a hidden NotifCard each NotifLayer
// instantiates off-screen -- see that file.
Singleton {
    id: root

    readonly property string notifyctl:
        Quickshell.env("HOME") + "/.config/hypr/notifyd/target/release/notifyctl"

    // Kept in sync with notifyd's state.json by id, so a state write for one
    // notification doesn't rebuild every card. Each row has one `n` role:
    // { id, app_name, sender, summary, body, icon, urgency, timestamp,
    //   actions: [{key,label}], default_action }. `sender` is the D-Bus
    //   unique name that called Notify -- used by summonSource() to find the
    //   originating window. Newest first.
    ListModel {
        id: popups
        dynamicRoles: true
    }
    property alias popupModel: popups

    FileView {
        id: stateFile
        path: Quickshell.env("HOME") + "/.cache/notifyd/state.json"
        watchChanges: true
        onFileChanged: stateFile.reload()
        onLoaded: root._sync(stateFile.text())
        onLoadFailed: popups.clear()
    }

    function _sync(txt) {
        let wanted;
        try {
            wanted = JSON.parse(txt).popups || [];
        } catch (e) {
            popups.clear();
            return;
        }
        const wantedIds = wanted.map(p => p.id);

        for (let i = popups.count - 1; i >= 0; i--) {
            if (wantedIds.indexOf(popups.get(i).n.id) < 0)
                popups.remove(i);
        }

        const prunedHeights = {};
        for (const id of wantedIds) {
            if (id in root.measuredHeights)
                prunedHeights[id] = root.measuredHeights[id];
        }
        root.measuredHeights = prunedHeights;
        for (let j = 0; j < wanted.length; j++) {
            const p = wanted[j];
            let at = -1;
            for (let k = 0; k < popups.count; k++) {
                if (popups.get(k).n.id === p.id) { at = k; break; }
            }
            if (at < 0) {
                popups.insert(j, { n: p });
            } else {
                if (at !== j)
                    popups.move(at, j, 1);
                if (JSON.stringify(popups.get(j).n) !== JSON.stringify(p))
                    popups.set(j, { n: p });
            }
        }
    }

    // ---- multi-monitor overflow / paging ---------------------------

    // User-edited: which further monitors take overflow, in order, once the
    // focused one is full, and how long each rotation page stays up.
    property var overflowMonitors: []
    property int rotateSeconds: 6

    FileView {
        id: monitorsConfig
        path: Quickshell.env("HOME") + "/.config/quickshell/notifications/monitors.json"
        watchChanges: true
        onFileChanged: monitorsConfig.reload()
        onLoaded: root._syncMonitorConfig(monitorsConfig.text())
        onLoadFailed: {
            root.overflowMonitors = [];
            root.rotateSeconds = 6;
        }
    }

    function _syncMonitorConfig(txt) {
        try {
            const parsed = JSON.parse(txt);
            root.overflowMonitors = Array.isArray(parsed.monitors) ? parsed.monitors : [];
            root.rotateSeconds = typeof parsed.rotate_seconds === "number" ? parsed.rotate_seconds : 6;
        } catch (e) {
            root.overflowMonitors = [];
            root.rotateSeconds = 6;
        }
    }

    // Focused monitor first (gets the newest notifications), then whatever's
    // left in monitors.json that isn't already the focused one.
    readonly property string focusedMonitorName: Hyprland.focusedMonitor?.name ?? ""
    readonly property var orderedMonitors: {
        const seq = [];
        if (root.focusedMonitorName.length > 0)
            seq.push(root.focusedMonitorName);
        for (const m of root.overflowMonitors) {
            if (seq.indexOf(m) < 0)
                seq.push(m);
        }
        return seq;
    }

    // Matches NotifLayer's real geometry exactly: PanelWindow height is
    // screen.height - Theme.barHeight, and the card Column starts 6px into
    // that (its anchors.topMargin, matching Bar.qml's pill spacing) with
    // nothing reserved below the last card. Anything more conservative
    // here just strands an extra card on the overflow monitor that would
    // have fit fine.
    function _availableHeight(monitorName) {
        for (const s of Quickshell.screens) {
            if (s.name === monitorName)
                return s.height - Theme.barHeight - 6;
        }
        return 600;
    }

    // Real per-notification heights, reported by a hidden off-screen
    // NotifCard in each NotifLayer (see notifications/NotifLayer.qml) --
    // guessing height from summary/body character counts was tried and
    // consistently wrong (WordWrap's actual line breaks don't line up with
    // any fixed chars-per-line constant), so this uses the same QML text
    // layout the real cards use instead of approximating it.
    property var measuredHeights: ({})
    function reportHeight(id, h) {
        if (root.measuredHeights[id] === h)
            return;
        const copy = Object.assign({}, root.measuredHeights);
        copy[id] = h;
        root.measuredHeights = copy;
    }
    function _heightFor(n) {
        const h = root.measuredHeights[n.id];
        return (typeof h === "number" && h > 0) ? h : 100; // fallback until measured
    }

    // Splits the current (newest-first) notification list into pages: each
    // page greedily fills every ordered monitor to capacity before moving to
    // the next monitor, then the next page picks up where the last left off.
    // With one page, nothing rotates -- everything already fits somewhere.
    readonly property var pages: {
        const monitors = root.orderedMonitors;
        const flat = [];
        for (let i = 0; i < popups.count; i++)
            flat.push(popups.get(i).n);
        if (monitors.length === 0 || flat.length === 0)
            return [];

        const caps = monitors.map(m => root._availableHeight(m));
        const pagesOut = [];
        let idx = 0;
        while (idx < flat.length) {
            const page = {};
            for (let mi = 0; mi < monitors.length; mi++) {
                const bucket = [];
                let used = 0;
                while (idx < flat.length) {
                    // Column spacing (8px) only sits *between* cards, so it
                    // only counts once there's already something in the
                    // bucket -- charging it up front stranded a card that
                    // would have fit right at the bottom of the monitor.
                    const gap = bucket.length > 0 ? 8 : 0;
                    const h = root._heightFor(flat[idx]);
                    if (bucket.length > 0 && used + gap + h > caps[mi])
                        break;
                    bucket.push(flat[idx]);
                    used += gap + h;
                    idx++;
                    if (used >= caps[mi])
                        break;
                }
                page[monitors[mi]] = bucket;
            }
            pagesOut.push(page);
            if (monitors.every(m => page[m].length === 0))
                break; // no monitor has any room at all -- bail, don't spin
        }
        return pagesOut;
    }

    property int currentPage: 0
    onPagesChanged: root.currentPage = 0 // always surface the newest first

    Timer {
        interval: root.rotateSeconds * 1000
        running: root.pages.length > 1
        repeat: true
        onTriggered: root.currentPage = (root.currentPage + 1) % root.pages.length
    }

    // What NotifLayer on `monitorName` should show right now.
    function cardsFor(monitorName) {
        if (root.pages.length === 0)
            return [];
        const page = root.pages[Math.min(root.currentPage, root.pages.length - 1)];
        return page[monitorName] ?? [];
    }

    // ---- card clicks -> notifyd (via notifyctl) --------------------
    function invokeDefault(id) {
        Quickshell.execDetached([root.notifyctl, "invoke", String(id)]);
    }
    function invokeKey(id, key) {
        Quickshell.execDetached([root.notifyctl, "invoke-action", String(id), key]);
    }
    function dismiss(id) {
        Quickshell.execDetached([root.notifyctl, "dismiss", String(id)]);
    }
    function closeAll() {
        Quickshell.execDetached([root.notifyctl, "close-all"]);
    }
    // Pointer entered/left a card: hold notifyd's countdown while hovered,
    // then restart it at its full duration on leave (see NotifCard).
    function hoverStart(id) {
        Quickshell.execDetached([root.notifyctl, "hover-start", String(id)]);
    }
    function hoverEnd(id) {
        Quickshell.execDetached([root.notifyctl, "hover-end", String(id)]);
    }

    // Left-click on a card whose notification has no default action: bring
    // the window that sent it to the current workspace and focus it,
    // pulling it out of its per-app scratch workspace if that's where it's
    // hiding (e.g. Signal). All the window matching -- by app_name/class and
    // by the sender's pid -- lives in the script; this just hands it the
    // two hints from the notification.
    function summonSource(n) {
        Quickshell.execDetached([
            Quickshell.env("HOME") + "/.config/hypr/scripts/notify-summon.sh",
            (n.app_name ?? "").toString(),
            (n.sender ?? "").toString()
        ]);
    }
}

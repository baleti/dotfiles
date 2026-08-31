pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Reads ~/.cache/claude-usage/state.json, written by the standalone
// ~/.config/claude-usage/claude-usage-daemon.py poller (same
// headless-daemon-writes-JSON + quickshell-reads-it pattern as
// rssd/notifyd -- see RssSvc.qml/NotifSvc.qml). This singleton never talks
// to the network itself; the daemon owns the adaptive polling interval
// (locked/active/idle) and all 3 accounts' OAuth credentials.
Singleton {
    id: root

    readonly property string _stateFile: Quickshell.env("HOME") + "/.cache/claude-usage/state.json"

    // [{account, session_pct, session_resets_at, weekly_pct,
    //   weekly_resets_at, fetched_at, error}], one entry per ~/.claude*.
    property var accounts: []
    property string pollMode: ""
    property int pollIntervalS: 0
    property string updatedAt: ""

    readonly property bool hasData: accounts.length > 0

    // Highest percent across every account for each kind -- drives the
    // compact pill's headline numbers/color. 0 (not -1) when nothing has
    // loaded yet, same "nothing alarming to show" convention as the other
    // metric pills use before their first real reading.
    readonly property real worstSessionPct: {
        let m = 0;
        for (const a of root.accounts)
            if (typeof a.session_pct === "number")
                m = Math.max(m, a.session_pct);
        return m;
    }
    readonly property real worstWeeklyPct: {
        let m = 0;
        for (const a of root.accounts)
            if (typeof a.weekly_pct === "number")
                m = Math.max(m, a.weekly_pct);
        return m;
    }

    FileView {
        id: stateFile
        path: root._stateFile
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                const d = JSON.parse(stateFile.text());
                root.accounts = d.accounts || [];
                root.pollMode = d.poll_mode || "";
                root.pollIntervalS = d.poll_interval_s || 0;
                root.updatedAt = d.updated_at || "";
            } catch (e) {
                console.warn("ClaudeUsageSvc: bad state.json:", e);
            }
        }
        onLoadFailed: {}
    }
}

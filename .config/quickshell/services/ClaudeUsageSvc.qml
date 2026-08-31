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
    //   weekly_resets_at, fetched_at, error, stale}], one entry per
    // ~/.claude*, always in that fixed order. `stale: true` means this
    // cycle's fetch failed (commonly a 429 -- see claude-usage.md's
    // Backoff section) and these are the last successfully fetched
    // numbers, carried forward rather than blanked; `error` names why.
    // ClaudeUsagePill/ClaudeUsageExpanded both iterate this directly, not
    // an aggregate -- each account's own number is what matters here.
    property var accounts: []
    // {account: [{pid, status, cwd, tmux, updated_at_ms, context_tokens,
    //   last_output_tokens}]} -- up to 6 most-recently-active live `claude`
    // processes per account (of routinely 20-40 alive at once here, almost
    // all idle), local-only (no network), refreshed every 30s regardless
    // of the accounts/backoff tier above. See claude-usage-daemon.py's
    // list_sessions()/context_tokens_for().
    property var sessions: ({})
    // "locked" | "active" | "idle" | "backoff" -- see claude-usage.md.
    property string pollMode: ""
    property int pollIntervalS: 0
    property string updatedAt: ""

    readonly property bool hasData: accounts.length > 0

    FileView {
        id: stateFile
        path: root._stateFile
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                const d = JSON.parse(stateFile.text());
                root.accounts = d.accounts || [];
                root.sessions = d.sessions || ({});
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

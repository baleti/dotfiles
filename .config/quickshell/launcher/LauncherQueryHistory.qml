pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Search-box history (query-dsl.md's "Search-box history"): one submitted
// query per array entry, oldest first. Persisted to
// ~/.cache/quickshell/launcher-query-history.json as a plain JSON array -
// deliberately separate from LauncherHistory.qml's launch-frecency data
// (a different corpus entirely - see the doc's "one history list per
// picker" reasoning).
Singleton {
    id: root

    readonly property string _path:
        Quickshell.env("HOME") + "/.cache/quickshell/launcher-query-history.json"

    property var entries: []  // oldest first, like fzf's own --history file

    FileView {
        id: hist
        path: root._path
        atomicWrites: true
        onLoaded: root._loadJson(hist.text())
        onLoadFailed: {}  // no history yet - start empty
        onSaveFailed: err => console.warn("launcher-query-history: save failed:", err)
    }

    function _loadJson(txt) {
        try {
            const parsed = JSON.parse(txt);
            root.entries = Array.isArray(parsed) ? parsed : [];
        } catch (e) {
            root.entries = [];
        }
    }
    function _save() { hist.setText(JSON.stringify(root.entries)); }

    // HIST_IGNORE_ALL_DUPS + HIST_REDUCE_BLANKS (query-dsl.md): normalize
    // whitespace, drop any existing occurrence, re-append at the end so a
    // repeat floats back to "most recent" instead of piling up. Called
    // both on a real accept (launch()) and on selection-move after typing
    // (Ctrl+J/Ctrl+K, PageDown/PageUp) - see AppLauncher.qml's Keys.onPressed.
    function record(query) {
        const q = query.trim().replace(/\s+/g, " ");
        if (!q) return;
        const i = root.entries.indexOf(q);
        if (i >= 0) root.entries.splice(i, 1);
        root.entries.push(q);
        root.entriesChanged();
        root._save();
    }

    // Most-recent-first, for Ctrl+R.
    function listMostRecentFirst() {
        return root.entries.slice().reverse();
    }
}

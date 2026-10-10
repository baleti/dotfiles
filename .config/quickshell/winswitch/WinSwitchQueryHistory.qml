pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Search-box history (query-dsl.md's "Search-box history"): one submitted
// query per array entry, oldest first. Persisted to
// ~/.cache/quickshell/winswitch-query-history.json as a plain JSON array -
// its own file, separate from the launcher's (query-dsl.md's "one history
// list per picker, not shared across them").
Singleton {
    id: root

    readonly property string _path:
        Quickshell.env("HOME") + "/.cache/quickshell/winswitch-query-history.json"

    property var entries: []  // oldest first, like fzf's own --history file

    FileView {
        id: hist
        path: root._path
        atomicWrites: true
        onLoaded: root._loadJson(hist.text())
        onLoadFailed: root._finishLoad([])  // no history yet - start empty
        onSaveFailed: err => console.warn("winswitch-query-history: save failed:", err)
    }

    // The file is read asynchronously and the singleton is built lazily, so
    // the first record() after a (re)load could run before the old history
    // arrived and then save over it (this is how the history shrank to a single
    // entry). Until loaded, new queries wait in `_early` and are appended after.
    property bool loaded: false
    property var _early: []

    function _loadJson(txt) {
        let parsed = [];
        try {
            const j = JSON.parse(txt);
            if (Array.isArray(j)) parsed = j;
        } catch (e) {
            // unreadable: keep the file untouched until a record() rewrites it
        }
        root._finishLoad(parsed);
    }
    function _finishLoad(parsed) {
        root.loaded = true;
        root.entries = parsed;
        const early = root._early;
        root._early = [];
        for (const q of early)
            root.record(q);
    }
    function _save() { hist.setText(JSON.stringify(root.entries)); }

    // HIST_IGNORE_ALL_DUPS + HIST_REDUCE_BLANKS (query-dsl.md): normalize
    // whitespace, drop any existing occurrence, re-append at the end so a
    // repeat floats back to "most recent" instead of piling up. Called
    // both on a real accept (confirm()) and on selection-move after typing
    // (_advance/_advanceRow) - see WinSwitch.qml.
    function record(query) {
        const q = query.trim().replace(/\s+/g, " ");
        if (!q) return;
        if (!root.loaded) {
            root._early.push(q);
            return;
        }
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

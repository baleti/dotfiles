pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Search-box history (query-dsl.md's "Search-box history"): one submitted
// query per array entry, oldest first. Persisted to
// ~/.cache/quickshell/claude-usage-query-history.json as a plain JSON
// array - its own file, separate from every other picker's (query-dsl.md's
// "one history list per picker, not shared across them").
Singleton {
    id: root

    readonly property string _path:
        Quickshell.env("HOME") + "/.cache/quickshell/claude-usage-query-history.json"

    property var entries: []  // oldest first, like fzf's own --history file

    FileView {
        id: hist
        path: root._path
        atomicWrites: true
        onLoaded: root._loadJson(hist.text())
        onLoadFailed: {}  // no history yet - start empty
        onSaveFailed: err => console.warn("claude-usage-query-history: save failed:", err)
    }

    // Default query (query-dsl.md "/get-default, /set-default"): text run in front of every
    // typed query. Plain text, its own file next to the history.
    property string defaultQuery: ""
    FileView {
        id: defFile
        path: Quickshell.env("HOME") + "/.cache/quickshell/claude-usage-query-default.txt"
        atomicWrites: true
        watchChanges: true   // the claude-agents daemon (web / Android clients) writes this file too
        onFileChanged: reload()
        onLoaded: root.defaultQuery = defFile.text().replace(/\n+$/, "")
        onLoadFailed: {}  // none set yet
        onSaveFailed: err => console.warn("claude-usage-query-default: save failed:", err)
    }
    // Every non-empty base query ever set, most recent first (the Tab list after "/bq ").
    property var baseHistory: []
    FileView {
        id: baseHistFile
        path: Quickshell.env("HOME") + "/.cache/quickshell/claude-usage-base-query-history.json"
        atomicWrites: true
        watchChanges: true
        onFileChanged: reload()
        onLoaded: { try { const p = JSON.parse(baseHistFile.text()); root.baseHistory = Array.isArray(p) ? p : []; } catch (e) { root.baseHistory = []; } }
        onLoadFailed: {}
        onSaveFailed: err => console.warn("claude-usage-base-query-history: save failed:", err)
    }
    // current first (if set), then the previous ones, no duplicates
    function baseCandidates() {
        const cur = root.defaultQuery.trim();
        return (cur ? [cur] : []).concat(root.baseHistory.filter(x => x !== cur));
    }
    function setDefault(q) {
        const prev = root.defaultQuery.trim();
        root.defaultQuery = q;
        defFile.setText(q);
        if (q !== "" && prev !== "" && prev !== q && root.baseHistory.indexOf(prev) < 0)
            root.baseHistory = [prev].concat(root.baseHistory);   // the outgoing one (may predate the history file)
        if (q !== "") root.baseHistory = [q].concat(root.baseHistory.filter(x => x !== q)).slice(0, 100);
        baseHistFile.setText(JSON.stringify(root.baseHistory));
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
    // both on a real accept (focusHyprWindow) and on selection-move after
    // typing (handleKey) - see ClaudeUsageExpanded.qml.
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

    // zsh-autosuggestions (query-dsl.md "Search-box history"): the unfinished
    // remainder of the newest entry that starts with `text`, "" if none.
    function suggest(text) {
        if (!text || !text.trim()) return "";
        for (let i = root.entries.length - 1; i >= 0; i--) {
            const e = root.entries[i];
            if (e.length > text.length && e.startsWith(text)) return e.slice(text.length);
        }
        return "";
    }
}

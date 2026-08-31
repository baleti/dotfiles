pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Data layer for the RSS reader. rssd (the Python poller,
// ~/.config/rssd/rssd.py) owns all feed fetching + parsing: it uses
// feedparser (which safely handles malformed XML, disables external entity
// resolution, and sanitises feed HTML -- strips <script>/<style>/<iframe>,
// event-handler attributes, javascript: URIs) and validates every
// downloaded image by magic bytes with a size cap. This singleton only
// reads the JSON it writes to ~/.cache/rssd/ -- it never touches the
// network or parses a feed itself.
//
//   items.jsonl  append-only article archive (one JSON object per line)
//   read.json    { "<item key>": <unix seconds> }, shared with the curses
//                reader (~/.config/rssd/reader.py)
Singleton {
    id: root

    readonly property string _cache: Quickshell.env("HOME") + "/.cache/rssd"
    readonly property string _rssd: Quickshell.env("HOME") + "/.config/rssd/rssd.py"

    // newest first, deduped. Each row is the raw record from rssd plus:
    //   key       stable id (id || link)
    //   sortKey   published || fetched_at
    //   iconUrl / imageUrl   file:// urls (or "")
    property var items: []
    property var tags: []
    property bool refreshing: false

    // { key: unixSeconds }
    property var read: ({})
    // bumped on every markRead/toggle so views depending on isRead() refresh
    property int readRevision: 0

    readonly property int unreadCount: {
        let n = 0;
        for (let i = 0; i < root.items.length; i++)
            if (root.read[root.items[i].key] === undefined)
                n++;
        return n;
    }

    function isRead(key) { return root.read[key] !== undefined; }

    function markRead(key) {
        if (!key || root.read[key] !== undefined)
            return;
        root.read[key] = Math.floor(Date.now() / 1000);
        root.readRevision++;
        readFile.setText(JSON.stringify(root.read));
    }

    function toggleRead(key) {
        if (!key)
            return;
        if (root.read[key] !== undefined)
            delete root.read[key];
        else
            root.read[key] = Math.floor(Date.now() / 1000);
        root.readRevision++;
        readFile.setText(JSON.stringify(root.read));
    }

    function markReadKeys(keys) {
        const now = Math.floor(Date.now() / 1000);
        let changed = false;
        for (const k of keys)
            if (k && root.read[k] === undefined) { root.read[k] = now; changed = true; }
        if (changed) {
            root.readRevision++;
            readFile.setText(JSON.stringify(root.read));
        }
    }

    function refresh() {
        if (!root.refreshing) {
            root.refreshing = true;
            fetchProc.running = true;
        }
    }

    // ---- items.jsonl ------------------------------------------------
    FileView {
        id: itemsFile
        path: root._cache + "/items.jsonl"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root._parseItems(itemsFile.text())
        onLoadFailed: { root.items = []; root.tags = []; }
    }

    function _fileUrl(p) {
        if (!p)
            return "";
        return p.startsWith("/") ? "file://" + p : p;
    }

    function _parseItems(txt) {
        const seen = ({});
        const rows = [];
        const tagset = ({});
        const lines = txt.split("\n");
        for (let i = 0; i < lines.length; i++) {
            const line = lines[i].trim();
            if (!line)
                continue;
            let r;
            try {
                r = JSON.parse(line);
            } catch (e) {
                continue;
            }
            const key = r.id || r.link || "";
            if (!key || seen[key])
                continue;
            seen[key] = true;
            r.key = key;
            r.sortKey = r.published || r.fetched_at || "";
            r.iconUrl = root._fileUrl(r.icon);
            r.imageUrl = root._fileUrl(r.image);
            for (const t of (r.tags || []))
                tagset[t] = true;
            rows.push(r);
        }
        rows.sort((a, b) => a.sortKey < b.sortKey ? 1 : (a.sortKey > b.sortKey ? -1 : 0));
        root.items = rows;
        root.tags = Object.keys(tagset).sort();
    }

    // ---- read.json ------------------------------------------------
    FileView {
        id: readFile
        path: root._cache + "/read.json"
        atomicWrites: true
        onLoaded: {
            try {
                root.read = JSON.parse(readFile.text()) || ({});
            } catch (e) {
                root.read = ({});
            }
            root.readRevision++;
        }
        onLoadFailed: { root.read = ({}); }
        onSaveFailed: err => console.warn("rss read.json save failed:", err)
    }

    // ---- fetch (rssd run) ---------------------------------------
    Process {
        id: fetchProc
        command: ["python3", root._rssd]
        onExited: {
            root.refreshing = false;
            itemsFile.reload();
        }
    }
}

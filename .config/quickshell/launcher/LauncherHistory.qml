pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Launch frecency for the app launcher -- so the apps you actually use sit
// on top, the way rofi's drun did. Persisted to
// ~/.cache/quickshell/launcher-history.json as { "<id>": {count,last} };
// seeded once from rofi's own ~/.cache/rofi3.druncache so the ranking
// carries over.
Singleton {
    id: root

    readonly property string _path:
        Quickshell.env("HOME") + "/.cache/quickshell/launcher-history.json"
    readonly property string _rofiPath:
        Quickshell.env("HOME") + "/.cache/rofi3.druncache"

    // { "<DesktopEntry.id>": { count: int, last: unixSeconds } }
    property var data: ({})

    FileView {
        id: hist
        path: root._path
        atomicWrites: true
        onLoaded: root._loadJson(hist.text())
        onLoadFailed: root._seedFromRofi()
        onSaveFailed: err => console.warn("launcher-history: save failed:", err)
    }

    FileView {
        id: rofi
        path: root._rofiPath
        // Loaded on demand (only when there's no history file yet).
        onLoaded: {
            const map = {};
            for (const line of rofi.text().split("\n")) {
                const m = line.match(/^\s*(\d+)\s+(.+?)(?:\.desktop)?\s*$/);
                if (m && parseInt(m[1]) > 0)
                    map[m[2]] = { count: parseInt(m[1]), last: 0 };
            }
            root.data = map;
            root._save();
        }
        onLoadFailed: {} // no rofi history -- just start empty
    }

    function _loadJson(txt) {
        try {
            root.data = JSON.parse(txt) || {};
        } catch (e) {
            root.data = {};
        }
    }
    function _seedFromRofi() { rofi.reload(); }
    function _save() { hist.setText(JSON.stringify(root.data)); }

    // Frecency: launch count weighted heavily, with a small recency bump so
    // something used a lot long ago still loses to something used recently.
    function score(id) {
        const e = root.data[id];
        if (!e)
            return 0;
        const ageDays = e.last > 0 ? (Date.now() / 1000 - e.last) / 86400 : 9999;
        const recency = ageDays < 3 ? 3 : (ageDays < 14 ? 2 : (ageDays < 60 ? 1 : 0));
        return (e.count || 0) * 4 + recency;
    }

    function bump(id) {
        if (!id)
            return;
        const e = root.data[id] || { count: 0, last: 0 };
        e.count = (e.count || 0) + 1;
        e.last = Math.floor(Date.now() / 1000);
        root.data[id] = e;
        root.dataChanged();
        root._save();
    }
}

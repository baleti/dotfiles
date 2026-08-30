pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Resolves freedesktop icon names to real file paths via
// scripts/resolve-icons.py -- quickshell's own image://icon/ provider
// misses the hicolor fallback under this KDE icon-theme setup, so many app
// icons (thunderbird, dolphin, freecad, ...) came back blank. The launcher
// falls back to the provider for anything this misses.
Singleton {
    id: root

    // name -> absolute file path
    property var map: ({})

    function pathFor(name) {
        if (!name)
            return "";
        const p = root.map[name];
        return p ? "file://" + p : "";
    }

    // Called by the launcher with every app's icon name once the entry set
    // is known (and again if it changes).
    function resolve(names) {
        const uniq = [...new Set(names.filter(n => !!n))];
        if (uniq.length === 0)
            return;
        proc.command = ["python3", Quickshell.env("HOME") + "/.config/quickshell/scripts/resolve-icons.py"]
            .concat(uniq);
        proc.running = true;
    }

    Process {
        id: proc
        stdout: StdioCollector {
            id: out
            onStreamFinished: {
                try {
                    root.map = JSON.parse(out.text) || {};
                } catch (e) {
                    console.warn("launcher-icons: resolve-icons.py output unparseable:", e);
                }
            }
        }
    }
}

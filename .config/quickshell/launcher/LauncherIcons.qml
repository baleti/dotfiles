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

    // Signature (sorted \0-joined name list) of the last set we actually
    // resolved, and a one-slot queue for a newer set that arrived while a
    // resolve was already running.
    property string _lastSig: ""
    property var _pending: null

    function pathFor(name) {
        if (!name)
            return "";
        const p = root.map[name];
        return p ? "file://" + p : "";
    }

    // Called by every AppLauncher instance (one per monitor) whenever its
    // entry set changes -- which includes every qs hot-reload and every
    // DesktopEntries re-scan, i.e. the same ~130-name set several times a
    // second during a reload storm. resolve-icons.py is a full icon-theme
    // filesystem walk in a Python subprocess, so:
    //   - skip entirely if the name set is unchanged since last time, and
    //   - never launch a second run while one is in flight -- a second
    //     `proc.running = true` on this shared Process orphans the first
    //     child, which under quickshell's spawn path leaks as a <defunct>
    //     process (seen piling up in bursts during development reloads).
    function resolve(names) {
        const uniq = [...new Set(names.filter(n => !!n))].sort();
        if (uniq.length === 0)
            return;
        const sig = uniq.join("\n");
        if (sig === root._lastSig)
            return;
        if (proc.running) {
            root._pending = uniq;
            return;
        }
        root._lastSig = sig;
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
        onExited: {
            if (root._pending) {
                const next = root._pending;
                root._pending = null;
                root.resolve(next);
            }
        }
    }
}

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Static wallpaper layer, one per monitor. No wallpaper manager was ever
// set up here before (confirmed 2026-08-26: no hyprpaper/swaybg/swww
// running, no config) -- this is a plain background-layer window holding
// an Image, the standard minimal pattern (no picker UI, no transitions,
// no audio-reactive effects -- all deliberately skipped, see conversation
// 2026-08-27).
//
// Source is a fixed path (~/.local/state/quickshell/wallpaper.png), not a
// literal wallpaper filename -- scripts/set-wallpaper.sh is the only
// sanctioned way to change it, and scripts/wallpaper-watch.sh regenerates
// the Material You theme (gen-theme.py) the moment that file's mtime
// changes, so switching wallpapers re-themes automatically instead of
// needing a separate manual script run (2026-08-27).
Item {
    id: root

    // A QML file can only have one top-level object -- wraps the shared
    // wallpaper-path state and the per-monitor Variants below into one.
    readonly property string wallpaperPath: `${Quickshell.env("HOME")}/.local/state/quickshell/wallpaper.png`
    // Image doesn't reload from disk on its own when the bytes at an
    // unchanged `source` path change (cache: true so it doesn't needlessly
    // re-decode every frame otherwise) -- watch the file's mtime and bump a
    // cache-busting query string to force a real reload.
    property int generation: 0

    readonly property FileView watcher: FileView {
        path: root.wallpaperPath
        watchChanges: true
        onFileChanged: root.generation++
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            required property var modelData
            screen: modelData

            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }

            WlrLayershell.layer: WlrLayer.Background
            WlrLayershell.exclusionMode: ExclusionMode.Ignore
            color: "black"

            // Purely decorative, nothing to click -- let input pass through
            // to whatever's actually on the desktop underneath.
            mask: Region {}

            Image {
                anchors.fill: parent
                source: `file://${root.wallpaperPath}?g=${root.generation}`
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: true
            }
        }
    }
}

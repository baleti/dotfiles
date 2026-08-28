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

    // FileView's own watchChanges reacted to set-wallpaper.sh's write with
    // a 20-40s delay in practice (reported 2026-08-28) -- far slower than
    // wallpaper-watch.sh's unrelated 2s mtime-poll loop that drives the
    // *theme* regen, which is why colors updated fast while the actual
    // background image lagged badly behind them. set-wallpaper.sh now
    // calls this directly (`qs ipc call background reload`) as the primary
    // trigger, same IPC pattern bar-toggle.sh already uses for panels; the
    // FileView watcher above stays as a slower fallback, not the only path.
    IpcHandler {
        target: "background"
        function reload(): void { root.generation++; }
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

            // Two-layer crossfade, not a single Image bound straight to
            // root.generation -- swapping `source` on one Image discards
            // the old pixmap the instant it's set, so the PanelWindow's own
            // black shows through for the ~1 frame (or longer, on a slow
            // decode) until the new one finishes loading async. Reported as
            // a visible black flash on every wallpaper switch, 2026-08-28.
            // Whichever layer is currently in back loads the new image;
            // once it actually reaches Image.Ready (not just "source set"),
            // Behavior-animated opacity crossfades it to front while the
            // old front fades out simultaneously -- old pixels stay on
            // screen the whole time, nothing is ever fully transparent.
            Item {
                id: crossfade
                anchors.fill: parent

                property bool frontIsA: true
                property string pendingUrl: `file://${root.wallpaperPath}?g=${root.generation}`

                // Imperative assignment into whichever layer is currently
                // in back, not a QML binding on either Image's `source` --
                // a binding would keep tracking pendingUrl on BOTH layers
                // regardless of front/back, defeating the whole point.
                Component.onCompleted: imgA.source = pendingUrl
                onPendingUrlChanged: {
                    if (frontIsA)
                        imgB.source = pendingUrl;
                    else
                        imgA.source = pendingUrl;
                }

                Image {
                    id: imgA
                    anchors.fill: parent
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    cache: true
                    opacity: crossfade.frontIsA ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 700; easing.type: Easing.InOutQuad } }
                    onStatusChanged: {
                        if (status === Image.Ready && source === crossfade.pendingUrl && !crossfade.frontIsA)
                            crossfade.frontIsA = true;
                    }
                }

                Image {
                    id: imgB
                    anchors.fill: parent
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    cache: true
                    opacity: crossfade.frontIsA ? 0 : 1
                    Behavior on opacity { NumberAnimation { duration: 700; easing.type: Easing.InOutQuad } }
                    onStatusChanged: {
                        if (status === Image.Ready && source === crossfade.pendingUrl && crossfade.frontIsA)
                            crossfade.frontIsA = false;
                    }
                }
            }
        }
    }
}

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
    // unchanged `source` path change -- bump a query string to give each
    // switch a distinct URL. Both Images below also run cache: false: Qt's
    // pixmap cache for file:// URLs was observed keying on just the path,
    // ignoring the query string entirely, so cache: true silently kept
    // serving the very first decoded wallpaper forever regardless of a
    // "new" ?g=N url (reported 2026-08-28: colors updated every switch,
    // the displayed image never did after the very first one). No real
    // cost to disabling it here -- the two-layer crossfade already only
    // ever (re)decodes when a genuinely new wallpaper is picked, not on
    // every repaint.
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

            // A two-layer manual crossfade (alternating which Image loads
            // the next source, swapping opacity once Image.Ready) was
            // tried here first and had a real bug: it could get stuck
            // showing a stale wallpaper indefinitely if a second switch's
            // pendingUrl overwrote the in-flight back layer's `source`
            // before that first load ever reached Ready, since the
            // Ready-swap handler only fired for an exact pendingUrl match
            // (reported 2026-08-28: file on disk and the theme both
            // updated correctly on every switch, confirmed via md5sum, but
            // the rendered image itself stopped updating at all after the
            // very first successful switch). Replaced with something far
            // simpler: asynchronous: false. A single Image bound straight
            // to the current source, decoded synchronously -- for a
            // desktop-sized local PNG/JPG that's a few tens of ms, cheap
            // enough that Qt still presents the *old* frame right up until
            // the new pixmap is ready in the same paint, with no
            // async-loading gap for the PanelWindow's black to show
            // through and no hand-rolled state machine to get stuck.
            Image {
                anchors.fill: parent
                source: `file://${root.wallpaperPath}?g=${root.generation}`
                fillMode: Image.PreserveAspectCrop
                asynchronous: false
                cache: false
            }
        }
    }
}

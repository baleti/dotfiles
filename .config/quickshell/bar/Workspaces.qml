import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "../theme"

// hyprland/workspaces equivalent: {name} buttons, click to activate. Also
// drives a hover-preview popup (rendered by Bar.qml, outside this Row's own
// bounds -- same split as ClaudeUsageExpanded's hover thumbnail) showing a
// live capture of every window on the hovered workspace.
Row {
    id: root

    required property ShellScreen screen

    spacing: 2

    // `Hyprland.dispatch()` sends a raw `dispatch <cmd>` string over the
    // socket, which this install's Lua-scriptable Hyprland fork doesn't
    // understand (see hyprland_lua_binding_dispatch_syntax memory) -- has
    // to go through `hyprctl repl` + `hl.dispatch(hl.dsp.focus(...))`
    // instead, same as ClaudeUsageExpanded.qml's focusHyprWindow().
    function switchToWorkspace(id) {
        switchProc.exec(["hyprctl", "repl", "hl.dispatch(hl.dsp.focus({ workspace = " + id + " }))"]);
    }

    Process { id: switchProc }

    // ---- hover-preview capture -----------------------------------------
    //
    // Reuses the claude-usage panel's thumb-capture binary (address-keyed
    // hyprland-toplevel-export-v1 capture, proven fast enough for a plain
    // hover trigger there -- see ClaudeUsageExpanded.qml's own hover
    // thumbnail) rather than winswitch's capture-every-window backend,
    // which stalls Hyprland's main thread for ~240ms because it captures
    // the *entire* window set on every run (see WinSwitchState.qml). A
    // workspace preview only ever needs the handful of windows on one
    // workspace, so one thumb-capture process per window, backgrounded and
    // waited on from a single Process/bash invocation (Quickshell doesn't
    // make it convenient to fire an arbitrary number of concurrent
    // Process{} objects from a JS array), stays cheap however many
    // workspaces exist.
    readonly property string thumbBin: Quickshell.env("HOME") + "/.config/claude-usage/thumb-capture/target/release/thumb-capture"
    readonly property string thumbDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/quickshell-ws-thumbs"
    property int thumbSeq: 0
    // Guards a capture batch's results against a since-changed hover
    // target, same idea as ClaudeUsageExpanded's _pendingAddress check.
    property int _pendingSeq: -1

    property bool thumbHovering: false
    property string thumbWsName: ""
    // [{address, title, path}], path already fixed up-front (per-seq, so a
    // fresh capture never lands on the same filename an Image may still
    // have cached) -- individual entries whose file never materializes
    // (window closed mid-capture, export timeout) just stay as an empty
    // placeholder frame in the popup rather than blocking the others.
    property var thumbWindows: []
    // Set to a batch's seq only once its Process has exited, i.e. once
    // every entry's file either exists or never will. The popup's Image
    // delegates gate their `source` on this rather than on thumbWindows
    // directly: thumbWindows (and therefore each entry's `path`) is filled
    // in immediately so titles/placeholders show right away, but binding
    // Image.source to a path that doesn't exist yet would just fail once
    // and never retry -- QML Image doesn't re-request a URL that hasn't
    // itself changed, so the reload has to be driven by *this* flipping,
    // not by thumbWindows changing.
    property int thumbReadySeq: -1
    // Bottom-left of the hovered pill, in scene coordinates (Bar.qml's root
    // Item has no offset from the scene -- see Workspaces_hover_thumbnail
    // popup in Bar.qml), so the popup can anchor itself without needing a
    // reference to Bar's root.
    property point thumbAnchor: Qt.point(0, 0)
    // The hovered workspace's own monitor size (logical pixels, same space
    // hyprctl reports window `at`/`size` in) -- the popup draws a
    // monitor-shaped canvas at this aspect ratio and places each window's
    // capture at its real (relX, relY, relW, relH) within it, rather than a
    // plain row of same-size thumbnails, so the preview reads as "this
    // workspace's actual layout" the way a real overview would.
    property real thumbMonitorW: 0
    property real thumbMonitorH: 0

    Process { id: mkdirThumbProc }
    Component.onCompleted: mkdirThumbProc.exec(["mkdir", "-p", root.thumbDir])

    readonly property Timer _hoverTimer: Timer {
        id: hoverTimer
        interval: 350
        repeat: false
        onTriggered: root._startHoverCapture()
    }

    property var _pendingWs: null

    // Called on pill hover-enter; the actual capture is debounced so
    // sweeping the pointer across several workspaces doesn't spawn a batch
    // of processes per pill passed over.
    function requestHoverPreview(ws, anchorX, anchorY) {
        root._pendingWs = ws;
        root.thumbAnchor = Qt.point(anchorX, anchorY);
        root.thumbHovering = true;
        hoverTimer.restart();
    }

    function cancelHoverPreview() {
        hoverTimer.stop();
        root._pendingWs = null;
        root.thumbHovering = false;
    }

    function _startHoverCapture() {
        const ws = root._pendingWs;
        if (!ws)
            return;
        const wins = ws.toplevels ? ws.toplevels.values : [];
        root.thumbWsName = ws.name;
        root.thumbMonitorW = ws.monitor ? ws.monitor.width : 0;
        root.thumbMonitorH = ws.monitor ? ws.monitor.height : 0;
        const monX = ws.monitor ? ws.monitor.x : 0;
        const monY = ws.monitor ? ws.monitor.y : 0;
        if (wins.length === 0) {
            root.thumbWindows = [];
            return;
        }
        root.thumbSeq += 1;
        const seq = root.thumbSeq;
        root._pendingSeq = seq;
        // `at`/`size` come from hyprctl's own client JSON (lastIpcObject --
        // Quickshell's typed HyprlandToplevel doesn't expose geometry any
        // other way), in the same absolute-desktop coordinate space as
        // monitor.x/y, hence subtracting the monitor's own origin to get a
        // position relative to it, which is what the popup's canvas scales
        // against (see wsThumbPopup in Bar.qml).
        const entries = wins.map((w, i) => {
            const ipc = w.lastIpcObject || {};
            const at = ipc.at || [0, 0];
            const size = ipc.size || [0, 0];
            return {
                address: w.address,
                title: w.title,
                path: root.thumbDir + "/" + seq + "-" + i + ".png",
                seq: seq,
                relX: at[0] - monX,
                relY: at[1] - monY,
                relW: size[0],
                relH: size[1]
            };
        });
        root.thumbWindows = entries;
        const cmds = entries.map(e => "'" + root.thumbBin + "' '" + e.address + "' '" + e.path + "' &").join("\n");
        captureProc.exec(["bash", "-c", cmds + "\nwait\n"]);
    }

    readonly property Process _captureProc: Process {
        id: captureProc
        onExited: {
            // A stale batch (hover moved on before this one finished, or
            // moved on and back so a newer one is already pending) leaves
            // thumbReadySeq alone -- nothing in the current popup is bound
            // to this seq, and a soon-to-arrive newer batch will set it
            // for real.
            if (root._pendingSeq === root.thumbSeq)
                root.thumbReadySeq = root._pendingSeq;
        }
    }

    Repeater {
        // ScriptModel (not a plain array) so Repeater diffs by object
        // identity -- an unrelated workspace change elsewhere used to
        // rebuild every delegate here, causing a visible flicker.
        model: ScriptModel {
            // Exclude special/scratch workspaces (negative ids, per
            // Hyprland convention) -- these back the mod+<key> pinned-app
            // scratch feature in hyprland/keybinds.lua, not a real
            // workspace to switch to. Scoped to this bar's own monitor.
            values: Hyprland.workspaces.values.filter(ws => ws.id > 0 && ws.monitor?.name === root.screen.name)
        }

        Rectangle {
            id: wsBtn

            required property HyprlandWorkspace modelData

            readonly property bool isActive: modelData.active
            readonly property bool isUrgent: modelData.urgent

            implicitWidth: label.implicitWidth + 16
            implicitHeight: 24
            width: implicitWidth
            height: implicitHeight
            radius: 7
            color: isActive ? Theme.cyan : isUrgent ? Theme.red : hover.containsMouse ? Qt.rgba(0.2, 0.8, 1, 0.15) : "transparent"

            Text {
                id: label
                anchors.centerIn: parent
                text: wsBtn.modelData.name
                color: wsBtn.isActive || wsBtn.isUrgent ? "#1a1a1a" : Theme.muted
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
            }

            MouseArea {
                id: hover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.switchToWorkspace(wsBtn.modelData.id)
                onEntered: {
                    const p = wsBtn.mapToItem(null, 0, wsBtn.height);
                    root.requestHoverPreview(wsBtn.modelData, p.x, p.y);
                }
                onExited: root.cancelHoverPreview()
            }
        }
    }
}

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import "../theme"
import "../services"

// Alt-tab grid (ALT+Tab / ALT+SHIFT+Tab) -- replaces the old standalone GTK
// winswitch binary (~/.config/hypr/winswitch). That binary is now a headless
// backend only: it still does the real work (window enumeration, live
// thumbnail capture via wayland-toplevel-export/dmabuf, tmux/Claude
// correlation -- see its own src/wayland_capture.rs and enrich.rs, both
// unchanged by this rewrite) and streams NDJSON to stdout instead of
// drawing a GTK grid itself. This file is the presentation layer only.
//
// PHASE 1 (this file, 2026-09-09): live thumbnails, title labels,
// mouse/Tab/Enter/Escape navigation and confirm -- no search/filter DSL yet
// (that's WinSwitchQueryDsl.qml, a follow-up porting query.rs the same way
// QueryDsl.qml already ports the launcher's grammar). Grid layout here is
// also a simpler fixed-cell-size GridView, not yet the aspect-ratio-tuned
// `grid_dims`/`cell_size` math the old ui.rs used -- fine for a skeleton,
// worth revisiting alongside the DSL pass if the fixed layout ever looks
// cramped with a lot of very wide or very tall windows mixed together.
//
// One instance per monitor; only the one WinSwitchState latched is ever
// shown (see WinSwitchState.qml's own doc for why `cycle` is reentrant).
PanelWindow {
    id: root

    // `screen` is PanelWindow's own property, set from shell.qml's Variants
    // (do NOT redeclare it -- see AppLauncher.qml's identical note).
    //
    // `open` only ever flips true once the backend's `windows` line
    // actually arrives -- the surface is never mapped at all for what
    // turns out to be a tap. An earlier version of this grabbed keyboard
    // input *immediately* on every press, before knowing tap vs. hold, to
    // avoid missing a quick Alt release; that traded one problem for three
    // worse ones (a visible flicker on every press regardless of
    // opacity/size tricks, a noisy single-instant `is_alt_down()` read, and
    // occasionally a grab that hadn't finished establishing by the time
    // Alt was released, leaving the grid stuck open needing Enter/Escape --
    // all reported 2026-09-09). The real fix was moving the debounce into
    // the backend instead (`main.rs`'s `TAP_HOLD_DEBOUNCE`): by the time a
    // `windows` line can possibly arrive, the backend has already spent
    // that debounce plus enumeration confirming Alt was still down, which
    // gives the compositor's focus grab handshake ample headroom to finish
    // before a human can react and release -- so this is back to the
    // simple "never do anything until we're sure" shape.
    property bool open: false
    // The direction that *started* the current determination, captured at
    // spawn time -- read back once `windows` arrives to seed `selected` at
    // index 1 (or the last index for "prev"), not 0. index 0 is always the
    // *currently* focused window (see hyprctl.rs::list_windows's own doc);
    // classic alt-tab releases onto the *previously* active one on a single
    // tap, so leaving `selected` at its default 0 made a release-to-confirm
    // silently re-focus the already-focused window -- looked exactly like
    // "nothing happened" (reported 2026-09-09).
    property string _initialDirection: "next"

    property var windows: []
    property var thumbnails: ({}) // index -> {path, width, height}
    property var enrichMeta: ({}) // index -> merged tmux/claude fields
    property int selected: 0

    function _recompute() {
        const wantsSession = WinSwitchState.active && WinSwitchState.monitor === root.screen.name;
        if (!wantsSession)
            root.open = false;
    }
    Component.onCompleted: root._recompute()
    Connections {
        target: WinSwitchState
        function onActiveChanged() { root._recompute(); }
        function onMonitorChanged() { root._recompute(); }
        // Fires for *every* cycle() call, including the one that opens a
        // session. Two cases: a confirmed grid already showing (`open`)
        // just gets its selection advanced in place -- the whole point of
        // `cycle` being reentrant, see WinSwitchState's own doc. A repeat
        // Alt+Tab press that lands before the previous press's own
        // determination has resolved (`open` still false) restarts fresh
        // instead -- kills whatever backend invocation was still
        // undetermined and spawns a new one for *this* press, so rapid
        // repeat taps resolve against the latest press instead of getting
        // lost waiting on a stale one.
        function onCycleSeqChanged() {
            if (WinSwitchState.monitor !== root.screen.name)
                return;
            if (root.open)
                root._advance(WinSwitchState.pendingDirection);
            else
                root._startSession();
        }
    }

    onOpenChanged: {
        if (root.open) {
            focusGrab.active = true;
            // `card` (an Item), not the PanelWindow root itself, is what
            // needs `focus`/`forceActiveFocus()` -- same reason
            // AppLauncher.qml focuses its inner TextInput rather than
            // itself. Deferred a tick, matching AppLauncher's own
            // `Qt.callLater` -- requesting focus before the surface has
            // actually mapped doesn't stick.
            Qt.callLater(() => card.forceActiveFocus());
        } else {
            focusGrab.active = false;
        }
    }
    function hide() {
        root._log("hide() called");
        WinSwitchState.close();
    }

    // 2026-09-09 rapid-tap investigation: temporary, verbose on purpose.
    // Lands in `qs log` (console.log is captured there) -- correlate
    // against ~/.cache/winswitch-backend.log's per-invocation lines (same
    // millisecond epoch timestamps) to see exactly where the two sides'
    // view of the world diverges.
    function _log(msg) {
        console.log(`[winswitch ${Date.now()}] ${msg}`);
    }

    function _startSession() {
        root._log(`_startSession dir=${WinSwitchState.pendingDirection} backendRunning=${backendProc.running}`);
        root.windows = [];
        root.thumbnails = ({});
        root.enrichMeta = ({});
        root.selected = 0;
        root._initialDirection = WinSwitchState.pendingDirection;
        // Unconditional stop first (a harmless no-op if nothing was
        // running): a repeat tap arriving before the previous invocation
        // resolved means that previous backend's *output* is now stale and
        // about to be replaced above, but the process itself would
        // otherwise keep running to completion in the background --
        // pointless work, and its trailing NDJSON lines would otherwise
        // still land in `_handleLine` and corrupt the new session's state.
        // (The old backend's own tap-path side effect, if it had already
        // gotten far enough to run `hyprctl::focus_window` before being
        // killed, already happened independently by that point -- nothing
        // here can or needs to undo that.)
        backendProc.running = false;
        backendProc.command = [
            Quickshell.env("HOME") + "/.config/hypr/winswitch/target/release/winswitch",
            WinSwitchState.pendingDirection,
        ];
        backendProc.running = true;
        root._log(`_startSession spawned, backendRunning=${backendProc.running}`);
    }

    function _advance(direction) {
        const n = root.windows.length;
        if (n === 0) return;
        root.selected = direction === "prev" ? (root.selected - 1 + n) % n : (root.selected + 1) % n;
    }

    function confirm(i) {
        const w = root.windows[i];
        root._log(`confirm i=${i} address=${w ? w.address : "none"} title=${w ? w.title : ""}`);
        if (!w) return;
        // hyprctl repl + a Lua snippet, not `hyprctl dispatch
        // focuswindow:...` -- this Hyprland build is Lua-scriptable
        // (hl.* API) rather than stock-dispatch, mirrors
        // ~/.config/hypr/winswitch/src/hyprctl.rs::focus_window exactly.
        focusProc.command = ["hyprctl", "repl",
            `local ws = hl.get_windows({})\nfor i, win in ipairs(ws) do\n    if tostring(win.address) == "${w.address}" then\n        hl.dispatch(hl.dsp.focus({ window = win }))\n        break\n    end\nend`];
        focusProc.running = true;
        root.hide();
    }

    // ---- backend process --------------------------------------------
    readonly property Process backendProc: Process {
        stdout: SplitParser {
            onRead: line => root._handleLine(line)
        }
    }
    readonly property Process focusProc: Process {}

    function _handleLine(line) {
        let msg;
        try {
            msg = JSON.parse(line);
        } catch (e) {
            root._log(`_handleLine: JSON.parse failed on: ${line}`);
            return; // a partial/garbled line -- ignore, never crash the panel over it
        }
        root._log(`_handleLine type=${msg.type}${msg.type === "windows" ? " n=" + msg.list.length : ""}${msg.type === "thumbnail" || msg.type === "enrich" ? " index=" + msg.index : ""}`);
        switch (msg.type) {
        case "tap":
            // The backend already dispatched the focus switch itself, and
            // (see `open`'s doc) no surface was ever mapped for this
            // determination -- just tell WinSwitchState the session's done.
            root.hide();
            break;
        case "windows": {
            root.windows = msg.list;
            const n = msg.list.length;
            // index 0 is always the currently-focused window (see
            // `_initialDirection`'s doc) -- classic alt-tab starts the
            // selection on the *previous* one instead, same as the old
            // GTK version's own `start_idx`.
            root.selected = n > 0 ? (root._initialDirection === "prev" ? n - 1 : Math.min(1, n - 1)) : 0;
            root.open = true; // first time the surface actually maps -- see `open`'s doc
            break;
        }
        case "thumbnail": {
            const t = Object.assign({}, root.thumbnails);
            t[msg.index] = { path: msg.path, width: msg.width, height: msg.height };
            root.thumbnails = t;
            break;
        }
        case "enrich": {
            const e = Object.assign({}, root.enrichMeta);
            e[msg.index] = Object.assign({}, e[msg.index] || {}, msg.meta);
            root.enrichMeta = e;
            break;
        }
        }
    }

    // ---- layout -------------------------------------------------------
    readonly property int cellWidth: 220
    readonly property int cellHeight: 190
    readonly property int thumbAreaHeight: 150

    // Raised from 0.8 -- with enough open windows the grid's natural
    // content height regularly exceeded the old budget, clipping the last
    // row right at the edge instead of comfortably fitting it (reported
    // 2026-09-09).
    readonly property int _availW: root.screen ? Math.round(root.screen.width * 0.92) : 1800
    readonly property int _availH: root.screen ? Math.round(root.screen.height * 0.92) : 1000
    readonly property int _cols: Math.max(1, Math.min(Math.floor(root._availW / root.cellWidth), Math.max(1, Math.ceil(Math.sqrt(root.windows.length)))))
    readonly property int gridWidth: Math.min(root._availW, root._cols * root.cellWidth)

    // ---- window ---------------------------------------------------
    anchors { top: true; left: true }
    implicitWidth: root.screen ? root.screen.width : 1920
    implicitHeight: root.screen ? root.screen.height : 1080
    color: "transparent"
    visible: root.open
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    WlrLayershell.namespace: "quickshell-winswitch"
    exclusionMode: ExclusionMode.Ignore

    HyprlandFocusGrab {
        id: focusGrab
        windows: [root]
        onCleared: {
            root._log("focusGrab.onCleared");
            root.hide();
        }
        onActiveChanged: root._log(`focusGrab.active=${focusGrab.active}`)
    }

    MouseArea {
        anchors.fill: parent
        onClicked: root.hide()
    }

    Rectangle {
        id: card
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        width: Math.max(root.gridWidth + 32, 200)
        height: Math.min(root._availH, Math.ceil(root.windows.length / root._cols) * root.cellHeight + 32)
        radius: Theme.rounding
        color: Theme.bgAlpha
        border.color: Theme.cyan
        border.width: 1
        focus: true

        MouseArea { anchors.fill: parent } // swallow clicks so they don't reach the backdrop

        GridView {
            id: grid
            anchors.fill: parent
            anchors.margins: 16
            cellWidth: root.cellWidth
            cellHeight: root.cellHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            currentIndex: root.selected
            model: root.windows

            delegate: Item {
                id: cellItem
                required property var modelData
                required property int index
                width: grid.cellWidth
                height: grid.cellHeight

                readonly property var thumb: root.thumbnails[modelData.index]
                readonly property bool isSelected: modelData.index === root.selected

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 4
                    radius: Theme.rounding - 4
                    color: cellItem.isSelected ? Qt.rgba(Theme.cyan.r, Theme.cyan.g, Theme.cyan.b, 0.16) : "transparent"
                    border.color: cellItem.isSelected ? Theme.cyan : "transparent"
                    border.width: 1

                    Rectangle { // thumbnail frame placeholder, matches ui.rs's outline-only "thumb-frame"
                        id: frame
                        anchors.top: parent.top
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.topMargin: 6
                        width: parent.width - 16
                        height: root.thumbAreaHeight
                        radius: 4
                        color: Qt.rgba(1, 1, 1, 0.02)
                        border.color: Qt.rgba(1, 1, 1, 0.18)
                        border.width: 1

                        Image {
                            anchors.centerIn: parent
                            width: frame.width - 4
                            height: frame.height - 4
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            visible: !!cellItem.thumb
                            source: cellItem.thumb ? cellItem.thumb.path : ""
                        }
                    }

                    Text {
                        anchors.top: frame.bottom
                        anchors.topMargin: 4
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: parent.width - 12
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideRight
                        maximumLineCount: 2
                        wrapMode: Text.Wrap
                        text: cellItem.modelData.title || cellItem.modelData.class
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 2
                        color: Theme.text
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: root.selected = cellItem.modelData.index
                    onClicked: root.confirm(cellItem.modelData.index)
                }
            }
        }

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape) {
                root.hide();
                event.accepted = true;
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.confirm(root.selected);
                event.accepted = true;
            } else if (event.key === Qt.Key_Tab) {
                root._advance(event.modifiers & Qt.ShiftModifier ? "prev" : "next");
                event.accepted = true;
            } else if (event.key === Qt.Key_Right) {
                root.selected = Math.min(root.windows.length - 1, root.selected + 1);
                event.accepted = true;
            } else if (event.key === Qt.Key_Left) {
                root.selected = Math.max(0, root.selected - 1);
                event.accepted = true;
            } else if (event.key === Qt.Key_Down) {
                root.selected = Math.min(root.windows.length - 1, root.selected + root._cols);
                event.accepted = true;
            } else if (event.key === Qt.Key_Up) {
                root.selected = Math.max(0, root.selected - root._cols);
                event.accepted = true;
            }
        }

        // Classic alt-tab: releasing Alt (not typing Enter) is what
        // confirms the held selection -- ported from the old GTK version's
        // own `key_release_event` handler (Alt_L/Alt_R, only outside
        // search-lock mode -- no lock mode exists yet in this phase-1
        // skeleton, so no guard needed here until WinSwitchQueryDsl.qml
        // lands). Qt.Key_Alt covers Alt_L on a standard layout; AltGr
        // (right Alt on many non-US layouts) reports as Qt.Key_AltGr
        // separately, so both are handled the same way here.
        Keys.onReleased: event => {
            root._log(`Keys.onReleased key=${event.key} isAutoRepeat=${event.isAutoRepeat}`);
            if (event.key === Qt.Key_Alt || event.key === Qt.Key_AltGr) {
                root.confirm(root.selected);
                event.accepted = true;
            }
        }
    }
}

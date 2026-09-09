pragma Singleton
import QtQuick

// Shared open/active state for the Quickshell alt-tab grid (ALT+Tab /
// ALT+SHIFT+Tab), same single-top-level-target / latched-monitor pattern as
// LauncherState -- WinSwitch.qml is instantiated once per monitor
// (shell.qml's Variants), this singleton is how the single top-level
// `winswitch` IpcHandler in shell.qml drives them without a per-screen
// IpcHandler target collision.
//
// Unlike the launcher, `cycle(direction)` is reentrant: called both from
// the IpcHandler (a fresh ALT+Tab/ALT+SHIFT+Tab keypress) and, once the
// grid is already open, from the grid's own Tab/Shift+Tab key handling --
// see WinSwitch.qml's `Keys.onPressed`. Only the *first* call (nothing open
// yet) needs to spawn the backend; every call after that is just "advance
// the selection," so the old winswitch's own Unix-socket forwarding trick
// for repeat Tab presses has no equivalent here at all -- Quickshell's
// panel is already a live, focused surface once open.
QtObject {
    id: root

    property bool active: false
    property string monitor: ""
    // Bumped on every cycle() call while already active, read by
    // WinSwitch.qml's Connections below to know a cycle was requested
    // without needing its own IpcHandler (see module doc).
    property string pendingDirection: ""
    property int cycleSeq: 0

    // `mon` is only consulted on the transition into `active` (matches
    // LauncherState.toggle's own division of labor: monitor resolution via
    // `Hyprland.focusedMonitor` stays in shell.qml, where that import
    // already exists, rather than duplicated into every *State singleton).
    function cycle(direction: string, mon: string): void {
        console.log(`[winswitch ${Date.now()}] WinSwitchState.cycle dir=${direction} mon=${mon} active(before)=${root.active}`);
        if (root.active) {
            root.pendingDirection = direction;
            root.cycleSeq++;
        } else {
            root.monitor = mon || "";
            root.pendingDirection = direction;
            root.cycleSeq++;
            root.active = true;
        }
    }

    function close(): void {
        console.log(`[winswitch ${Date.now()}] WinSwitchState.close`);
        root.active = false;
    }
}

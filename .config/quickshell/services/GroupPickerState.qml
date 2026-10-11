pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// mod+Tab: the alt+tab grid (winswitch/WinSwitch.qml, state in WinSwitchState)
// restricted to the tabs of the active window's Hyprland group -- same grid,
// thumbnails, search box and query DSL, no second copy of any of it. This
// singleton only fetches the group's rows (~/bin/group-windows list
// --winswitch, same row shape as winswitch-windows.json) and hands them to
// WinSwitchState.startGroup(); `groupPicker toggle` closes it again if it is
// already up.
QtObject {
    id: root

    // `address`: show that window's group instead of the active window's
    // (`qs ipc call groupPicker openFor 0x...`, handy for testing).
    function toggle(mon: string, address: string): void {
        if (WinSwitchState.active) {
            WinSwitchState.close("toggle");
            return;
        }
        if (listProc.running)
            return;
        listProc.command = [Quickshell.env("HOME") + "/bin/group-windows", "list", "--winswitch"]
            .concat(address ? [address] : []);
        listProc.running = true;
    }

    // mod+Tab / mod+Shift+Tab (winswitch.lua `gtab`): behaves like alt+tab. The grid opens
    // on the first press and stays up while the modifier is held; each further press steps
    // forward (Shift: back); releasing the modifier switches to the selected tab ("altup",
    // handled by WinSwitchState). The group's list is fetched asynchronously, so presses
    // and an early release that arrive before it is ready are kept and replayed.
    property var _queued: []
    property bool _released: false
    property bool _loading: false

    readonly property Connections _events: Connections {
        target: Hyprland
        function onRawEvent(event: var): void {
            if (event.name !== "custom" || !event.data.startsWith("winswitch "))
                return;
            const rest = event.data.slice("winswitch ".length);
            if (rest.startsWith("gtab "))
                root._onGroupTab(rest.slice(5));
            else if (rest === "altup" && root._loading)
                root._released = true;
        }
    }

    function _onGroupTab(direction: string): void {
        if (WinSwitchState.active && WinSwitchState.groupMode) {
            WinSwitchState.altHeld = true;
            if (WinSwitchState.locked)
                WinSwitchState.lockedTab(direction);
            else
                WinSwitchState.advance(direction);
            return;
        }
        if (WinSwitchState.active)
            return;     // the alt+tab grid is up
        root._queued = root._queued.concat([direction]);
        if (root._loading)
            return;
        root._loading = true;
        root._released = false;
        listProc.command = [Quickshell.env("HOME") + "/bin/group-windows", "list", "--winswitch"];
        listProc.running = true;
    }

    readonly property Process _list: Process {
        id: listProc
        stdout: StdioCollector {
            id: listOut
            onStreamFinished: {
                let rows;
                const steps = root._queued, released = root._released;
                root._queued = [];
                root._loading = false;
                root._released = false;
                try { rows = JSON.parse(listOut.text); } catch (e) { return; }
                WinSwitchState.startGroup(rows);
                if (!WinSwitchState.active)
                    return;
                root._anchor = rows.find(r => !r.pending).address;
                pollTimer.restart();
                if (steps.length > 0)
                    WinSwitchState.altHeld = true;
                for (const d of steps)
                    WinSwitchState.advance(d);
                if (released)
                    WinSwitchState.confirm(WinSwitchState.selected);   // tapped and let go already
            }
        }
    }

    // While the grid is open, follow the group: windows that group-open is still adding
    // (or that get closed) appear/disappear without reopening it.
    property string _anchor: ""
    readonly property Timer _poll: Timer {
        id: pollTimer
        interval: 1000
        repeat: true
        onTriggered: {
            if (!WinSwitchState.active || !WinSwitchState.groupMode) {
                pollTimer.stop();
                return;
            }
            if (!pollProc.running) {
                pollProc.command = [Quickshell.env("HOME") + "/bin/group-windows", "list", "--winswitch", root._anchor];
                pollProc.running = true;
            }
        }
    }
    readonly property Process _pollProc: Process {
        id: pollProc
        stdout: StdioCollector {
            id: pollOut
            onStreamFinished: {
                let rows;
                try { rows = JSON.parse(pollOut.text); } catch (e) { return; }
                WinSwitchState.updateGroup(rows);
            }
        }
    }
}

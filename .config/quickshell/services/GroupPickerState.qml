pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

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

    readonly property Process _list: Process {
        id: listProc
        stdout: StdioCollector {
            id: listOut
            onStreamFinished: {
                let rows;
                try { rows = JSON.parse(listOut.text); } catch (e) { return; }
                WinSwitchState.startGroup(rows);
                if (rows.length > 0) {
                    root._anchor = rows[0].address;
                    pollTimer.restart();
                }
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

pragma Singleton
import QtQuick

// Open/close + latched-monitor state for the Revit VM RDP picker (launcher entry "RDP: Revit VM"). One RdpVmPicker.qml per monitor
// (shell.qml's Variants); same pattern as LauncherState.
QtObject {
    id: root

    property bool active: false
    property string monitor: ""

    function toggle(mon: string): void {
        if (root.active) {
            root.active = false;
        } else {
            root.monitor = mon || "";
            root.active = true;
        }
    }

    function close(): void {
        root.active = false;
    }
}

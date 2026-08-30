pragma Singleton
import QtQuick

// Shared open/close state for the app launcher (mod + Super_l). One
// AppLauncher.qml is instantiated per monitor (shell.qml's Variants); this
// singleton is how the single top-level `launcher` IpcHandler in shell.qml
// drives them without a per-screen IpcHandler target collision -- same
// pattern as MprisPickerState. `monitor` is latched at open so the launcher
// stays on the output it opened on even if the pointer (follow_mouse=1)
// drifts away.
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

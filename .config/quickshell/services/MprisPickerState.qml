pragma Singleton
import QtQuick

// Shared open/close state for the MPRIS player picker (ALT+CTRL+SHIFT+m and
// the media pill's middle-click). One MprisPicker.qml is nested in every
// per-monitor Bar PanelWindow (shell.qml's Variants) rather than being its
// own PanelWindow -- a 3rd layer-shell surface per output doesn't reliably
// map here (see [[quickshell_panelwindow_ipc_gotchas]] / VolumeOsd's
// unresolved per-output issue). This singleton is how the single top-level
// `mprisPicker` IpcHandler in shell.qml drives all those instances at once
// without a per-screen IpcHandler target collision (the same problem
// bar-toggle.sh works around for the graph panels).
//
// `monitor` is latched when the picker opens and only that monitor's
// instance renders, so the picker stays put even if the pointer
// (follow_mouse=1) later drifts onto another output.
QtObject {
    id: root

    property bool active: false
    property string monitor: ""

    // A second press toggles it closed -- same feel as the bar's own panels
    // and the clipboard picker.
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

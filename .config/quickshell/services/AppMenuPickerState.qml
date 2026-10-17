pragma Singleton
import QtQuick

// Open/close + latched-monitor state for the global-menu picker
// (mod+a). One AppMenuPicker.qml is instantiated per monitor
// (shell.qml's Variants); this singleton is how the single top-level
// `appMenu` IpcHandler drives them without a per-screen target
// collision -- same pattern as ClipboardPickerState (mod+v), which this
// picker's own QML rewrite otherwise mirrors closely.
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

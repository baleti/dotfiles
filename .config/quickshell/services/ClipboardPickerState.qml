pragma Singleton
import QtQuick

// Open/close + latched-monitor state for the clipboard-picker (mod+v).
// One ClipboardPicker.qml is instantiated per monitor (shell.qml's
// Variants); this singleton is how the single top-level `clipboardPicker`
// IpcHandler drives them without a per-screen target collision -- same
// pattern as LauncherState/RssReaderState. The GTK version's pidfile+SIGTERM
// toggle (second press of mod+v closes it) is now just this boolean --
// there's no longer a separate process to signal, the frontend is always
// running as part of quickshell.
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

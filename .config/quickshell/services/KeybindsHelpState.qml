pragma Singleton
import QtQuick

// Open/close + latched-monitor state for the keyboard-shortcuts panel
// (mod + ?). One KeybindsHelp.qml is instantiated per monitor (shell.qml
// Variants); this singleton is how the single top-level `keybindsHelp`
// IpcHandler drives them without a per-screen target collision -- identical
// to LauncherState / RssReaderState.
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

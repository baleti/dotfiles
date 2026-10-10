pragma Singleton
import QtQuick

// Open/close + latched-monitor state for the group picker (mod+Tab). One
// GroupPicker.qml per monitor (shell.qml's Variants); this singleton is how the
// single top-level `groupPicker` IpcHandler drives them -- same pattern as
// NotificationPickerState / ClipboardPickerState.
QtObject {
    id: root

    property bool active: false
    property string monitor: ""
    // address -> {path, width, height}. Kept across opens so a tab shows its
    // last capture instantly while a fresh one is taken (the backend writes a
    // new file name per capture, so Image's pixmap cache can't go stale).
    property var thumbnails: ({})

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

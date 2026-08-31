pragma Singleton
import QtQuick

// Open/close + latched-monitor state for the RSS reader (mod + R). One
// RssReader.qml is instantiated per monitor (shell.qml Variants); this
// singleton is how the single top-level `rssReader` IpcHandler drives them
// without a per-screen target collision -- identical to LauncherState.
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

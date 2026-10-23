pragma Singleton
import QtQuick
import Quickshell.Hyprland

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
    // Address of the window focused when the launcher opened -- the target of
    // window actions such as /move-to-workspace (the launcher's own layer
    // surface takes keyboard focus afterwards).
    property string windowAddress: ""
    // Workspace focused at open, for /move-workspace.
    property int workspaceId: -1

    function toggle(mon: string): void {
        if (root.active) {
            root.active = false;
        } else {
            root.monitor = mon || "";
            root.windowAddress = Hyprland.activeToplevel ? String(Hyprland.activeToplevel.address) : "";
            root.workspaceId = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1;
            root.active = true;
        }
    }

    // Handed over from the native launcher (~/.config/hypr/launcher-ui) when the query
    // needs the DSL engine: opens with `query` already typed.
    property string pendingQuery: ""
    function openWith(mon: string, query: string): void {
        if (root.active)
            return;
        root.pendingQuery = query;
        root.toggle(mon);
    }

    function close(): void {
        root.active = false;
    }
}

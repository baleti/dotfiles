pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Renderer side of the headless notifyd (~/.config/hypr/notifyd/). notifyd
// owns org.freedesktop.Notifications and does all the tracking / timeout /
// action-routing; it writes the current popup set to
// ~/.cache/notifyd/state.json, this singleton watches that file and exposes
// it as `popups`, and NotifLayer/NotifCard draw them. Card clicks go back to
// notifyd through `notifyctl` (same CLI the mod+n keybinds use).
//
// History (mod+CTRL+n) and the action menu (mod+SHIFT+n) still go straight
// through notifyctl -> notifyd and don't touch this file.
Singleton {
    id: root

    readonly property string notifyctl:
        Quickshell.env("HOME") + "/.config/hypr/notifyd/target/release/notifyctl"

    // Kept in sync with notifyd's state.json by id, so a state write for one
    // notification doesn't rebuild every card. Each row has one `n` role:
    // { id, app_name, sender, summary, body, icon, urgency, timestamp,
    //   actions: [{key,label}], default_action }. `sender` is the D-Bus
    //   unique name that called Notify -- used by summonSource() to find the
    //   originating window. Newest first.
    ListModel {
        id: popups
        dynamicRoles: true
    }
    property alias popupModel: popups

    FileView {
        id: stateFile
        path: Quickshell.env("HOME") + "/.cache/notifyd/state.json"
        watchChanges: true
        onFileChanged: stateFile.reload()
        onLoaded: root._sync(stateFile.text())
        onLoadFailed: popups.clear()
    }

    function _sync(txt) {
        let wanted;
        try {
            wanted = JSON.parse(txt).popups || [];
        } catch (e) {
            popups.clear();
            return;
        }
        const wantedIds = wanted.map(p => p.id);

        for (let i = popups.count - 1; i >= 0; i--) {
            if (wantedIds.indexOf(popups.get(i).n.id) < 0)
                popups.remove(i);
        }
        for (let j = 0; j < wanted.length; j++) {
            const p = wanted[j];
            let at = -1;
            for (let k = 0; k < popups.count; k++) {
                if (popups.get(k).n.id === p.id) { at = k; break; }
            }
            if (at < 0) {
                popups.insert(j, { n: p });
            } else {
                if (at !== j)
                    popups.move(at, j, 1);
                if (JSON.stringify(popups.get(j).n) !== JSON.stringify(p))
                    popups.set(j, { n: p });
            }
        }
    }

    // ---- card clicks -> notifyd (via notifyctl) --------------------
    function invokeDefault(id) {
        Quickshell.execDetached([root.notifyctl, "invoke", String(id)]);
    }
    function invokeKey(id, key) {
        Quickshell.execDetached([root.notifyctl, "invoke-action", String(id), key]);
    }
    function dismiss(id) {
        Quickshell.execDetached([root.notifyctl, "dismiss", String(id)]);
    }
    function closeAll() {
        Quickshell.execDetached([root.notifyctl, "close-all"]);
    }

    // Left-click on a card whose notification has no default action: bring
    // the window that sent it to the current workspace and focus it,
    // pulling it out of its per-app scratch workspace if that's where it's
    // hiding (e.g. Signal). All the window matching -- by app_name/class and
    // by the sender's pid -- lives in the script; this just hands it the
    // two hints from the notification.
    function summonSource(n) {
        Quickshell.execDetached([
            Quickshell.env("HOME") + "/.config/hypr/scripts/notify-summon.sh",
            (n.app_name ?? "").toString(),
            (n.sender ?? "").toString()
        ]);
    }
}

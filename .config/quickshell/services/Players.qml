pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris

// Adapted from the caelestia-shell reference (services/Players.qml) with the
// Caelestia.Config dependency stripped out. "Current player" selection
// deliberately reads ~/.config/playerctl-current instead of inventing a new
// concept -- that file is the existing single source of truth shared with
// the Hyprland keybinds (mod+ctrl+x/z, mod+ctrl+shift+p, XF86Audio*) and
// ~/.config/hypr/scripts/playerctl-picker.sh, so this stays in sync with
// them rather than drifting into a second, independent "current player".
QtObject {
    id: root

    readonly property list<MprisPlayer> list: Mpris.players.values

    readonly property string wantedSuffix: currentFile.text().trim()

    readonly property MprisPlayer active: {
        if (wantedSuffix) {
            const match = list.find(p => p.dbusName === `org.mpris.MediaPlayer2.${wantedSuffix}`);
            if (match)
                return match;
        }
        return list.find(p => p.isPlaying) ?? list[0] ?? null;
    }

    function getIdentity(player: MprisPlayer): string {
        return player?.identity ?? "";
    }

    function getArtUrl(player: MprisPlayer): string {
        if (!player)
            return "";
        if (player.trackArtUrl)
            return player.trackArtUrl;

        const url = player.metadata["xesam:url"] ?? "";
        if (url.startsWith("https://www.youtube.com/watch")) {
            const id = url.match(/[?&]v=([\w-]{11})/)?.[1];
            return id ? `https://img.youtube.com/vi/${id}/hqdefault.jpg` : "";
        }
        return "";
    }

    readonly property FileView currentFile: FileView {
        path: `${Quickshell.env("HOME")}/.config/playerctl-current`
        watchChanges: true
        onFileChanged: reload()
    }
}

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

    // Untagged files (e.g. yt-dlp downloads) give MPD no title; derive
    // "Artist - Title" from the file name in xesam:url instead.
    function fileLabel(player: MprisPlayer): string {
        const url = player?.metadata["xesam:url"] ?? "";
        if (!url.startsWith("file://"))
            return "";
        let name = decodeURIComponent(url.split("/").pop());
        name = name.replace(/\.[A-Za-z0-9]{2,4}$/, "").replace(/\s*\[[\w-]{11}\]$/, "");
        return name;
    }

    function getTitle(player: MprisPlayer): string {
        if (!player)
            return "";
        if (player.trackTitle)
            return player.trackTitle;
        const n = fileLabel(player);
        const i = n.indexOf(" - ");
        return (player.trackArtist && i > 0) ? n.slice(i + 3) : n;
    }

    function getArtist(player: MprisPlayer): string {
        if (!player)
            return "";
        if (player.trackArtist || player.trackTitle)
            return player.trackArtist;
        const n = fileLabel(player);
        const i = n.indexOf(" - ");
        return i > 0 ? n.slice(0, i) : "";
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

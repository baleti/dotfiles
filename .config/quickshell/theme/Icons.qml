pragma Singleton
import QtQuick

// Nerd Font / Font Awesome glyphs, carried over from the old
// ~/.config/waybar/config.jsonc and ~/.config/hypr/scripts/waybar-mpris.sh.
QtObject {
    readonly property string volMuted: ""
    readonly property string volHeadphone: ""
    readonly property string volHeadset: ""
    readonly property var volLevels: ["", "", ""]

    readonly property var backlightLevels: ["", "", "", "", "", "", "", "", ""]

    readonly property string wifi: ""
    readonly property string ethernet: ""

    readonly property string cpu: ""
    // fa-memory (RAM stick glyph) -- was fa-reorder ("", a
    // hamburger/list icon with no relation to memory) before 2026-08-29.
    readonly property string memory: ""
    readonly property string temp: ""
    readonly property string network: ""
    readonly property string disk: ""
    // md-swap_horizontal -- a different icon set/shape than network's
    // fa-exchange, so the two don't read as the same glyph.
    readonly property string swap: "󰓡"

    readonly property string batteryCharging: ""
    readonly property string batteryPlugged: ""
    readonly property var batteryLevels: ["", "", "", "", ""]

    // Old script's play/pause glyphs were empty strings (never actually set) -
    // using standard Font Awesome play/pause instead.
    readonly property string play: ""
    readonly property string pause: ""
    readonly property string prev: ""
    readonly property string next: ""

    function levelIcon(levels: var, fraction: real): string {
        const idx = Math.min(levels.length - 1, Math.max(0, Math.round(fraction * (levels.length - 1))));
        return levels[idx];
    }
}

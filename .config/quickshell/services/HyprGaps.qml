pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// The screen-edge gap Hyprland is currently applying to tiled windows
// (general:gaps_out from hypr/appearance.lua, or whatever a live
// `hyprctl keyword`/workspace rule has overridden it to since) -- queried
// once at startup so the bar, its popup panels, and notification cards
// match real window edges exactly instead of each hardcoding their own
// stale copy of that number (they drifted out of sync with
// appearance.lua's gaps_out before this existed).
QtObject {
    id: root

    // Fallback until hyprctl answers (matches appearance.lua's default),
    // and what's used outside a live Hyprland session (e.g. HYPRLAND_
    // INSTANCE_SIGNATURE unset) where the query below silently no-ops.
    property int left: 5
    property int right: 5
    // Vertical gap a tiled window gets between the bar's reserved
    // exclusiveZone and the window's own top edge -- what a popup panel's
    // (calendar/media/graph pills) top, and the notification card stack's
    // top, should sit below the bar by too.
    property int top: 5

    // hyprctl reports gaps_out as a CSS-margin-shorthand string ("top
    // right bottom left", or fewer values per CSS shorthand rules).
    // bottom is parsed but unused -- nothing here anchors to it.
    function _applyCss(css) {
        const parts = css.trim().split(/\s+/).map(Number).filter(n => !isNaN(n));
        if (parts.length === 0)
            return;
        let top, right, left;
        if (parts.length === 1) { top = right = left = parts[0]; }
        else if (parts.length === 2) { top = parts[0]; right = left = parts[1]; }
        else if (parts.length === 3) { top = parts[0]; right = left = parts[1]; }
        else { top = parts[0]; right = parts[1]; left = parts[3]; }
        root.top = top;
        root.right = right;
        root.left = left;
    }

    readonly property Process _proc: Process {
        command: ["hyprctl", "getoption", "general:gaps_out", "-j"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const data = JSON.parse(text);
                    if (data.css)
                        root._applyCss(data.css);
                } catch (e) {
                    // Not running inside a live Hyprland session, or
                    // hyprctl's output shape changed -- keep the fallback.
                }
            }
        }
    }
}

pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Hyprland's live decoration:rounding + general:border_size
// (hypr/appearance.lua), queried once at startup the same way HyprGaps
// queries gaps_out. A window's actual visible outer corner curve is NOT
// just `rounding` -- confirmed straight from Hyprland's own renderer
// (src/render/OpenGL.cpp, CHyprOpenGLImpl::renderBorder):
//
//   float round = data.round + (data.round == 0 ? 0 : scaledBorderSize);
//   shader->setUniformFloat(SHADER_RADIUS_OUTER, ... round);
//
// i.e. the border is drawn as a ring *outside* the content rect, and the
// outer edge of that ring -- the silhouette a window actually shows the
// world -- has radius = rounding + border_size (an AutoCAD-style outward
// curve offset by the border's full thickness, not half of it). That's
// outerRadius below; anything that wants its own rounded corner to read
// as the same curve family as a real window (not just numerically equal
// to the bare `rounding` config value) should use it instead.
QtObject {
    id: root

    property int rounding: 10
    property int borderSize: 2
    readonly property int outerRadius: rounding + borderSize

    readonly property Process _roundingProc: Process {
        command: ["hyprctl", "getoption", "decoration:rounding", "-j"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const n = JSON.parse(text).int;
                    if (typeof n === "number")
                        root.rounding = n;
                } catch (e) {
                    // Not a live Hyprland session -- keep the fallback.
                }
            }
        }
    }

    readonly property Process _borderProc: Process {
        command: ["hyprctl", "getoption", "general:border_size", "-j"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const n = JSON.parse(text).int;
                    if (typeof n === "number")
                        root.borderSize = n;
                } catch (e) {
                    // Not a live Hyprland session -- keep the fallback.
                }
            }
        }
    }
}

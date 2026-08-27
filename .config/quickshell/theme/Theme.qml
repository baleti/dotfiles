pragma Singleton
import QtQuick

// Palette matches ~/.config/hypr/appearance.lua (cyan->green active-border
// gradient, dark islands) and the old waybar style.css.
QtObject {
    readonly property color bg: "#1a1a1a"
    readonly property color bgAlpha: Qt.rgba(0.102, 0.102, 0.102, 0.9)
    readonly property color border: Qt.rgba(0.349, 0.349, 0.349, 0.55)
    readonly property color text: "#d8dee9"
    readonly property color textDim: "#a0a8b0"
    readonly property color muted: "#888888"
    readonly property color cyan: "#33ccff"
    readonly property color green: "#00ff99"
    readonly property color red: "#ff5555"
    readonly property color orange: "#f5a70a"

    readonly property int rounding: 10
    readonly property int barHeight: 38
    readonly property int pillPadH: 11

    readonly property string fontFamily: "JetBrains Mono"
    readonly property string iconFontFamily: "MesloLGS Nerd Font"
    readonly property int fontSize: 13
}

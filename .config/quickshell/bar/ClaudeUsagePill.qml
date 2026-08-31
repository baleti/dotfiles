import QtQuick
import "../theme"
import "../services"

// Compact per-account session% readout for all 3 Claude Code accounts on
// this machine (~/.claude, ~/.claude2, ~/.claude3), in that fixed order --
// weekly% lives only in the detail panel (too much for a bar pill to carry
// at a glance across 3 accounts). Backed by ClaudeUsageSvc, which just
// reads the JSON the standalone claude-usage-daemon.py poller writes; this
// pill never touches the network. Click, or CTRL+ALT+c (keybinds.lua ->
// bar-toggle.sh -> Bar.qml's IpcHandler), toggles the detail panel
// (ClaudeUsageExpanded) -- no hover-open here, unlike media/calendar, since
// a percentage readout doesn't need a passing-glance preview.
Rectangle {
    id: root

    signal toggled

    implicitWidth: row.implicitWidth + Theme.pillPadH * 2
    implicitHeight: Theme.barHeight - 10
    width: implicitWidth
    height: implicitHeight

    color: Theme.bgAlpha
    border.color: Theme.border
    border.width: 1
    radius: Theme.rounding

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 8

        // Small hand-drawn sunburst mark (no bundled Claude logo asset
        // exists anywhere on this system -- checked -- and there's no
        // Nerd Font glyph for it either, so this is a from-scratch stand-in
        // rather than an embedded brand asset), in Claude's own accent
        // color, purely as a leading icon for this pill.
        Canvas {
            id: logo
            width: 14
            height: 14
            anchors.verticalCenter: parent.verticalCenter
            onPaint: {
                const ctx = getContext("2d");
                ctx.reset();
                const cx = width / 2, cy = height / 2;
                const rays = 8;
                const outer = width / 2;
                const inner = outer * 0.3;
                const halfAngle = (Math.PI / rays) * 0.38;
                ctx.fillStyle = "#DA7756";
                ctx.beginPath();
                for (let i = 0; i < rays; i++) {
                    const a = (i / rays) * Math.PI * 2 - Math.PI / 2;
                    const aL = a - halfAngle, aR = a + halfAngle;
                    ctx.moveTo(cx + Math.cos(aL) * inner, cy + Math.sin(aL) * inner);
                    ctx.lineTo(cx + Math.cos(aL) * outer, cy + Math.sin(aL) * outer);
                    ctx.lineTo(cx + Math.cos(aR) * outer, cy + Math.sin(aR) * outer);
                    ctx.lineTo(cx + Math.cos(aR) * inner, cy + Math.sin(aR) * inner);
                    ctx.closePath();
                }
                ctx.fill();
            }
        }

        Repeater {
            model: ClaudeUsageSvc.accounts

            delegate: Text {
                required property var modelData

                text: (typeof modelData.session_pct === "number")
                    ? Math.round(modelData.session_pct) + "%"
                    : "--"
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
                font.bold: true
                // Stale (carried-forward-after-an-error) reading -- dimmed
                // rather than hidden, since it's still the best number we
                // have; a hard "--" only shows once there's never been a
                // successful fetch for this account at all.
                opacity: modelData.stale ? 0.55 : 1
                color: (typeof modelData.session_pct === "number")
                    ? Theme.rampColor(modelData.session_pct / 100)
                    : Theme.muted
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        Text {
            visible: !ClaudeUsageSvc.hasData
            text: "--"
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
            color: Theme.muted
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    MouseArea {
        anchors.fill: parent
        onClicked: root.toggled()
    }
}

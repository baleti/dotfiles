import QtQuick
import QtQuick.Effects
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

    // Claude's brand orange (#DA7756 -> hue 15deg, sat 0.641, light 0.596),
    // but with its saturation scaled by how close the *current* generated
    // scheme's own primary hue is to that same orange -- a warm (red/
    // yellow) theme lets it stay close to full brand vividness, a cool
    // (blue/cyan) one tones it down toward grey, rather than sitting there
    // as a fixed hardcoded orange clashing with whatever wallpaper-derived
    // palette is active. Hue and lightness stay pinned to the brand's own
    // (it should still read as orange, just quieter), only saturation
    // moves. minSat (0.12) is a floor, not zero -- fully desaturating would
    // erase the "orange" identity entirely on a strongly cool theme.
    function rgbToHsl(c) {
        const r = c.r, g = c.g, b = c.b;
        const max = Math.max(r, g, b), min = Math.min(r, g, b);
        const l = (max + min) / 2;
        if (max === min)
            return { h: 0, s: 0, l: l };
        const d = max - min;
        const s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
        let h;
        if (max === r)
            h = (g - b) / d + (g < b ? 6 : 0);
        else if (max === g)
            h = (b - r) / d + 2;
        else
            h = (r - g) / d + 4;
        return { h: h * 60, s: s, l: l };
    }

    readonly property color logoColor: {
        const brandH = 15, brandL = 0.596;
        const themeHsl = root.rgbToHsl(Theme.cyan);
        const dist = Math.min(Math.abs(brandH - themeHsl.h), 360 - Math.abs(brandH - themeHsl.h));
        const warmth = 1 - dist / 180; // 1 = theme hue aligned with orange, 0 = its exact opposite
        // 0.641 (the brand color's own saturation) read as too faint even
        // at warmth=1, and 0.12 as flat grey at warmth=0 -- both raised
        // (twice, nudged up further the second time) so it reads as
        // orange (muted on a cool theme, vivid on a warm one) across the
        // whole range instead of only near max warmth.
        const minSat = 0.58, maxSat = 0.94;
        const sat = minSat + (maxSat - minSat) * warmth;
        return Qt.hsla(brandH / 360, sat, brandL, 1);
    }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 8

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

        // The real claude.ai favicon (extracted from Brave's own Favicons
        // cache -- ~/.brave-claude/Default/Favicons -- i.e. what the
        // browser actually downloaded visiting the site, not a redrawn
        // guess). No bundled logo asset exists anywhere else on this
        // system and there's no Nerd Font glyph for it. Trailing, not
        // leading -- this is the icon end of the pill, the numbers are the
        // point. Recolored (MultiEffect's colorization at full strength
        // replaces RGB but keeps the source alpha shape) to root.logoColor
        // -- a theme-warmth-scaled orange, not a fixed hardcoded one (see
        // that property's own comment). Plain Theme.cyan and Theme.text
        // were both tried first: cyan read as "not actually Claude's icon
        // anymore", Theme.text as flat low-contrast grey against this
        // bar's dark background.
        Image {
            id: logoSrc
            source: "assets/claude-logo.png"
            width: 14
            height: 14
            smooth: true
            visible: false
            anchors.verticalCenter: parent.verticalCenter
        }
        MultiEffect {
            source: logoSrc
            anchors.verticalCenter: parent.verticalCenter
            width: logoSrc.width
            height: logoSrc.height
            colorization: 1
            colorizationColor: root.logoColor
        }
    }

    MouseArea {
        anchors.fill: parent
        onClicked: root.toggled()
    }
}

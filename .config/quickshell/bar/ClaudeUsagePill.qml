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

    // Not Claude's brand orange at all any more (tried: hue pinned to the
    // brand's own 15deg with only saturation scaled toward/away from it by
    // theme warmth -- still read as an outside color forced to blend in,
    // not something that belongs to this theme). Instead: search the
    // *current* generated scheme's own colors for whichever one already
    // sits closest to orange, and use that swatch exactly as generated.
    // Theme.orange itself is deliberately excluded -- it's a fixed
    // hardcoded fallback color (see Theme.qml), not something generated
    // from the wallpaper, so using it here would be the same "not
    // actually this theme's own color" problem in a different disguise.
    //
    // The candidate list originally left out Theme.cyan/Theme.green
    // (scheme.primary/secondary) -- only searching seriesPalette +
    // intensityRamp picked seriesPalette's #e8a400 (hue 42, into yellow
    // territory) on a scheme where scheme.secondary (Theme.green, despite
    // the name -- it's just whatever hue the generator landed on) was
    // #ffb693 (hue 19, genuinely orange, reported "too yellow, doesn't
    // match any theme color" 2026-08-31). Both accents are just as
    // legitimately theme-generated as the series/ramp swatches, so they
    // belong in the search too.
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
        const targetH = 30; // canonical "orange" reference hue
        const candidates = Theme.seriesPalette.concat(Theme.intensityRamp, [Theme.cyan, Theme.green]);
        let best = candidates[0], bestDist = 360;
        for (const hex of candidates) {
            const hsl = root.rgbToHsl(Qt.color(hex));
            const dist = Math.min(Math.abs(hsl.h - targetH), 360 - Math.abs(hsl.h - targetH));
            if (dist < bestDist) {
                bestDist = dist;
                best = hex;
            }
        }
        return Qt.color(best);
    }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 8

        // The real claude.ai favicon (extracted from Brave's own Favicons
        // cache -- ~/.brave-claude/Default/Favicons -- i.e. what the
        // browser actually downloaded visiting the site, not a redrawn
        // guess). No bundled logo asset exists anywhere else on this
        // system and there's no Nerd Font glyph for it. Leading, matching
        // every other bar pill's icon-then-value convention -- the numbers
        // are still the point, the logo just marks which pill they belong
        // to. Recolored (MultiEffect's colorization at full strength
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
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggled()
    }
}

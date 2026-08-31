import QtQuick
import "../theme"
import "../services"

// Compact "S <session%> W <weekly%>" readout across all 3 Claude Code
// accounts on this machine (~/.claude, ~/.claude2, ~/.claude3) -- worst
// (highest) percent of either kind across the 3, since that's the one that
// actually constrains you next. Backed by ClaudeUsageSvc, which just reads
// the JSON the standalone claude-usage-daemon.py poller writes; this pill
// never touches the network. Click, or CTRL+ALT+c (keybinds.lua ->
// bar-toggle.sh -> Bar.qml's IpcHandler), toggles the per-account detail
// panel (ClaudeUsageExpanded) -- no hover-open here, unlike media/calendar,
// since a percentage readout doesn't need a passing-glance preview.
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
        spacing: 6

        Text {
            text: qsTr("S")
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 2
            color: Theme.textDim
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            text: Math.round(ClaudeUsageSvc.worstSessionPct) + "%"
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
            font.bold: true
            color: Theme.rampColor(ClaudeUsageSvc.worstSessionPct / 100)
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            text: qsTr("W")
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 2
            color: Theme.textDim
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            text: Math.round(ClaudeUsageSvc.worstWeeklyPct) + "%"
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
            font.bold: true
            color: Theme.rampColor(ClaudeUsageSvc.worstWeeklyPct / 100)
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    MouseArea {
        anchors.fill: parent
        onClicked: root.toggled()
    }
}

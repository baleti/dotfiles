import QtQuick
import QtQuick.Layouts
import "../theme"
import "../services"

// Detail panel for ClaudeUsagePill: session%/weekly% (+ reset time) for
// each of the 3 Claude Code accounts on this machine, plus the poller's
// current adaptive-interval tier so it's obvious why a number looks stale.
// Same sibling-overlay / collapses-to-0-height-when-closed shape as
// MediaExpanded/CalendarExpanded, but click/CTRL+ALT+c-toggled only -- no
// hover-open, and no real keyboard focus grab (nothing here needs arrow-key
// navigation, so it deliberately stays out of shell.qml's
// HyprlandFocusGrab/holdsFocus machinery Bar.qml's other panels use).
Rectangle {
    id: root

    property bool expanded: false
    property real panelWidth: 320

    width: panelWidth
    implicitHeight: expanded ? content.implicitHeight + 24 : 0
    height: implicitHeight
    visible: height > 0
    clip: true
    radius: Theme.rounding
    color: Theme.bgAlpha
    border.color: Theme.border
    border.width: 1

    readonly property bool hovered: mouseArea.containsMouse

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.AllButtons
        onWheel: wheel => wheel.accepted = true
    }

    // "resets in Xd Yh" / "Xh Ym" / "<1m" -- ISO8601 in, coarse relative-time
    // out. null (an account whose tier wasn't returned, e.g. it's disabled)
    // reads as "--", not "resets in NaN".
    function fmtResets(iso) {
        if (!iso)
            return "--";
        const target = new Date(iso).getTime();
        if (isNaN(target))
            return "--";
        let deltaS = Math.round((target - Date.now()) / 1000);
        if (deltaS <= 0)
            return qsTr("resetting");
        const days = Math.floor(deltaS / 86400);
        deltaS -= days * 86400;
        const hours = Math.floor(deltaS / 3600);
        deltaS -= hours * 3600;
        const mins = Math.floor(deltaS / 60);
        if (days > 0)
            return qsTr("resets in %1d %2h").arg(days).arg(hours);
        if (hours > 0)
            return qsTr("resets in %1h %2m").arg(hours).arg(mins);
        if (mins > 0)
            return qsTr("resets in %1m").arg(mins);
        return qsTr("resets in <1m");
    }

    // "12s ago" / "4m ago" -- same coarse style, for the daemon's own
    // updated_at (staleness indicator, not a countdown).
    function fmtAgo(iso) {
        if (!iso)
            return qsTr("never");
        const t = new Date(iso).getTime();
        if (isNaN(t))
            return qsTr("never");
        const deltaS = Math.max(0, Math.round((Date.now() - t) / 1000));
        if (deltaS < 60)
            return qsTr("%1s ago").arg(deltaS);
        if (deltaS < 3600)
            return qsTr("%1m ago").arg(Math.floor(deltaS / 60));
        return qsTr("%1h ago").arg(Math.floor(deltaS / 3600));
    }

    readonly property var pollModeLabels: ({
        "locked": qsTr("polling hourly (locked/screen off)"),
        "active": qsTr("polling every 30s (active)"),
        "idle": qsTr("polling every 5m (idle)"),
    })

    // Re-render the relative-time strings once a second while open -- they
    // read off Date.now()/live deltas, which QML has no binding source for
    // on its own.
    Timer {
        interval: 1000
        running: root.expanded
        repeat: true
        onTriggered: root.tick = root.tick + 1
    }
    property int tick: 0

    Column {
        id: content
        x: 12
        y: 12
        width: parent.width - 24
        spacing: 10

        Text {
            width: parent.width
            text: root.tick >= 0
                ? (root.pollModeLabels[ClaudeUsageSvc.pollMode] || qsTr("Claude usage"))
                    + " -- " + qsTr("updated %1").arg(root.fmtAgo(ClaudeUsageSvc.updatedAt))
                : ""
            color: Theme.textDim
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 2
            elide: Text.ElideRight
        }

        Repeater {
            model: ClaudeUsageSvc.accounts

            delegate: Column {
                width: content.width
                spacing: 2

                required property var modelData

                Text {
                    text: modelData.account || ""
                    color: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize
                    font.bold: true
                }

                Text {
                    visible: !!modelData.error
                    width: parent.width
                    text: qsTr("error: %1").arg(modelData.error || "")
                    color: Theme.red
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                    elide: Text.ElideRight
                }

                RowLayout {
                    visible: !modelData.error
                    width: parent.width
                    spacing: 10

                    Text {
                        text: qsTr("session %1%").arg(Math.round(modelData.session_pct ?? 0))
                        color: Theme.rampColor((modelData.session_pct ?? 0) / 100)
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 1
                    }
                    Text {
                        text: root.tick >= 0 ? root.fmtResets(modelData.session_resets_at) : ""
                        color: Theme.textDim
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 2
                    }
                    Item { Layout.fillWidth: true }
                }

                RowLayout {
                    visible: !modelData.error
                    width: parent.width
                    spacing: 10

                    Text {
                        text: qsTr("weekly %1%").arg(Math.round(modelData.weekly_pct ?? 0))
                        color: Theme.rampColor((modelData.weekly_pct ?? 0) / 100)
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 1
                    }
                    Text {
                        text: root.tick >= 0 ? root.fmtResets(modelData.weekly_resets_at) : ""
                        color: Theme.textDim
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 2
                    }
                    Item { Layout.fillWidth: true }
                }
            }
        }

        Text {
            visible: !ClaudeUsageSvc.hasData
            width: parent.width
            text: qsTr("waiting for claude-usage-daemon...")
            color: Theme.muted
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 1
        }
    }
}

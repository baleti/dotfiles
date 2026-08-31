import QtQuick
import QtQuick.Layouts
import Quickshell
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

    // Coarse "Xd Yh" / "Xh Ym" / "Xm" / "<1m" for a delta in seconds --
    // shared by the per-limit reset countdown and the backoff/staleness
    // lines below.
    function fmtDelta(deltaS) {
        if (deltaS <= 0)
            return qsTr("<1m");
        const days = Math.floor(deltaS / 86400);
        deltaS -= days * 86400;
        const hours = Math.floor(deltaS / 3600);
        deltaS -= hours * 3600;
        const mins = Math.floor(deltaS / 60);
        if (days > 0)
            return qsTr("%1d %2h").arg(days).arg(hours);
        if (hours > 0)
            return qsTr("%1h %2m").arg(hours).arg(mins);
        if (mins > 0)
            return qsTr("%1m").arg(mins);
        return qsTr("<1m");
    }

    // "resets in Xd Yh" -- ISO8601 in. null (an account whose tier wasn't
    // returned, e.g. it's disabled) reads as "--", not "resets in NaN".
    function fmtResets(iso) {
        if (!iso)
            return "--";
        const target = new Date(iso).getTime();
        if (isNaN(target))
            return "--";
        const deltaS = Math.round((target - Date.now()) / 1000);
        return deltaS <= 0 ? qsTr("resetting") : qsTr("resets in %1").arg(root.fmtDelta(deltaS));
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

    readonly property string homeDir: Quickshell.env("HOME") || ""

    // "/home/user1/foo" -> "~/foo" (or "~" for the home dir itself); left
    // as-is otherwise. Paired with Text.ElideLeft at the call site so a
    // long path still shows its most identifying (rightmost) part.
    function shortCwd(cwd) {
        if (!cwd)
            return "";
        if (cwd === root.homeDir)
            return "~";
        if (root.homeDir && cwd.startsWith(root.homeDir + "/"))
            return "~" + cwd.slice(root.homeDir.length);
        return cwd;
    }

    // 274308 -> "274k", 850 -> "850", null/undefined -> "--". Context
    // tokens routinely run into the hundreds of thousands here, so this
    // stays readable at a glance instead of a long raw digit string.
    function fmtTokens(n) {
        if (typeof n !== "number")
            return "--";
        if (n < 1000)
            return String(n);
        return (n / 1000).toFixed(n < 10000 ? 1 : 0) + "k";
    }

    function fmtAgoMs(ms) {
        return ms ? root.fmtAgo(new Date(ms).toISOString()) : qsTr("never");
    }

    readonly property var statusColors: ({
        "busy": Theme.red,
        "waiting": Theme.orange,
        "idle": Theme.muted,
    })
    function statusColor(status) {
        return root.statusColors[status] || Theme.textDim;
    }

    readonly property var pollModeLabels: ({
        "locked": qsTr("polling hourly (locked/screen off)"),
        "active": qsTr("polling every 2m (active)"),
        "idle": qsTr("polling every 5m (idle)"),
    })

    // Backoff isn't a fixed label like the other 3 tiers -- it's a live
    // countdown to when polling resumes, computed from updated_at (when
    // this backoff started) + poll_interval_s (how long it runs), same
    // pair every other mode uses for its own bookkeeping.
    function modeLine() {
        if (ClaudeUsageSvc.pollMode === "backoff") {
            const resumeMs = new Date(ClaudeUsageSvc.updatedAt).getTime() + ClaudeUsageSvc.pollIntervalS * 1000;
            const deltaS = Math.round((resumeMs - Date.now()) / 1000);
            return qsTr("rate limited (429) -- retrying in %1").arg(root.fmtDelta(Math.max(0, deltaS)));
        }
        return root.pollModeLabels[ClaudeUsageSvc.pollMode] || qsTr("Claude usage");
    }

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
            text: root.tick >= 0 ? root.modeLine() + " -- " + qsTr("updated %1").arg(root.fmtAgo(ClaudeUsageSvc.updatedAt)) : ""
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
                readonly property bool hasSession: typeof modelData.session_pct === "number"
                readonly property bool hasWeekly: typeof modelData.weekly_pct === "number"

                Text {
                    text: modelData.account || ""
                    color: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize
                    font.bold: true
                }

                // A stale reading still shows its (dimmed) numbers below --
                // this is just the "why" note, not a replacement for them.
                // Only a genuinely never-fetched account has no numbers to
                // dim, in which case this is the only line shown.
                Text {
                    visible: !!modelData.error
                    width: parent.width
                    text: parent.hasSession || parent.hasWeekly
                        ? qsTr("%1 -- showing last known values").arg(modelData.error)
                        : qsTr("error: %1").arg(modelData.error)
                    color: Theme.red
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                    elide: Text.ElideRight
                }

                RowLayout {
                    visible: parent.hasSession
                    opacity: modelData.stale ? 0.55 : 1
                    width: parent.width
                    spacing: 10

                    Text {
                        text: qsTr("session %1%").arg(Math.round(modelData.session_pct))
                        color: Theme.rampColor(modelData.session_pct / 100)
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
                    visible: parent.hasWeekly
                    opacity: modelData.stale ? 0.55 : 1
                    width: parent.width
                    spacing: 10

                    Text {
                        text: qsTr("weekly %1%").arg(Math.round(modelData.weekly_pct))
                        color: Theme.rampColor(modelData.weekly_pct / 100)
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

                // Up to 6 most-recently-active live `claude` processes for
                // this account (of routinely 20-40 alive at once here,
                // almost all idle resumed shells -- see
                // claude-usage-daemon.py's list_sessions()). Local-only,
                // refreshed every 30s regardless of the tier above.
                readonly property var procs: ClaudeUsageSvc.sessions[modelData.account] || []

                Text {
                    visible: parent.procs.length > 0
                    text: qsTr("processes")
                    color: Theme.textDim
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 3
                    topPadding: 2
                }

                Repeater {
                    model: parent.procs

                    delegate: Column {
                        width: content.width
                        spacing: 0

                        required property var modelData

                        RowLayout {
                            width: parent.width
                            spacing: 6

                            Text {
                                text: modelData.status || "?"
                                color: root.statusColor(modelData.status)
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 2
                                Layout.preferredWidth: 46
                            }
                            Text {
                                text: qsTr("pid %1").arg(modelData.pid)
                                color: Theme.text
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 2
                            }
                            Text {
                                text: root.fmtTokens(modelData.context_tokens) + qsTr(" tok")
                                color: Theme.textDim
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 2
                            }
                            Item { Layout.fillWidth: true }
                            Text {
                                text: root.tick >= 0 ? root.fmtAgoMs(modelData.updated_at_ms) : ""
                                color: Theme.muted
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 3
                            }
                        }

                        Text {
                            width: parent.width
                            text: root.shortCwd(modelData.cwd) + (modelData.tmux ? qsTr("  tmux %1").arg(modelData.tmux) : "")
                            color: Theme.muted
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 3
                            elide: Text.ElideLeft
                            horizontalAlignment: Text.AlignRight
                        }
                    }
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
